//
//  ModelManager.swift
//  FaceFusion
//
//  Owns the on-disk model library: what is installed, what is missing, and the
//  one-time download that closes the gap.
//
//  Downloads stream to a `.partial` file and resume where they stopped if they
//  are interrupted, then are verified against the SHA-256 in the bundled
//  manifest before being moved into place. A model that fails verification is
//  discarded rather than installed — unverified weights are the one thing this
//  app must never hand to the engine.
//
//  This is the only component in the app that touches the network at all.
//
//  The Mac build kept the models in a shared App Group container because the
//  engine ran in a second, separately sandboxed process and that container was
//  the only ground the two of them shared. In-process there is no second party,
//  so the library moves to the app's own Application Support directory: it is
//  backed up by default, is not purgeable behind the app's back the way Caches
//  is, and needs no entitlement. "Backed up by default" is precisely the part
//  that has to be undone, which `prepareContainer` does below.
//

import Foundation
import CryptoKit
import Observation
import os

struct ModelDescriptor: Codable, Identifiable, Sendable {
    var id: String
    var url: URL
    var sha256: String
    var bytes: Int64
    var required: Bool
    var vendor: String
    var license: String

    var modelID: ModelID? { ModelID(rawValue: id) }
    var fileName: String { "\(id).onnx" }
}

struct ModelManifest: Codable, Sendable {
    var manifestVersion: Int
    var release: String
    var models: [ModelDescriptor]
}

enum ModelInstallState: Equatable, Sendable {
    case missing
    case downloading(received: Int64, total: Int64)
    case verifying
    case installed
    case failed(String)
}

@MainActor
@Observable
final class ModelManager {

    private(set) var manifest: ModelManifest?
    private(set) var states: [String: ModelInstallState] = [:]
    private(set) var isWorking = false
    private(set) var lastError: String?

    /// Bytes moved during the current download session, for the aggregate bar.
    private(set) var sessionReceived: Int64 = 0
    private(set) var sessionTotal: Int64 = 0

    private var activeTask: Task<Void, Never>?

    /// The process-wide downloader. It has to be the shared instance rather
    /// than one of our own: it owns a background `URLSession`, and a second
    /// session claiming the same identifier is a hard runtime error.
    private let downloader = Downloader.shared

    // MARK: - Locations

    /// Everything this app writes that is not a user document.
    ///
    /// Resolved once, because the path never changes for the lifetime of the
    /// process and every frame of the engine's compile cache hangs off it.
    static let containerDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("FaceFusion", isDirectory: true)
    }()

    static var modelsDirectory: URL {
        containerDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where Core ML keeps the graphs it compiles from the ONNX models.
    ///
    /// It sits beside the models rather than in Caches on purpose: compiling
    /// these graphs takes long enough to be visible on first launch, and a
    /// directory the system may delete at any moment would mean paying that
    /// cost again at the least convenient time.
    static var compileCacheDirectory: URL {
        containerDirectory.appendingPathComponent("CoreMLCompiled", isDirectory: true)
    }

    func location(of descriptor: ModelDescriptor) -> URL {
        Self.modelsDirectory.appendingPathComponent(descriptor.fileName)
    }

    // MARK: - Loading

    init() {
        Self.prepareContainer()
        loadManifest()
        refreshInstallStates()
    }

    /// Creates the library and takes it out of the backup set.
    ///
    /// About 560 MB of weights live here, and every byte of it can be fetched
    /// again from a public URL. Letting that into an iCloud backup would spend
    /// the user's storage — and their upload — on something the app can
    /// reproduce for free, which is exactly what `isExcludedFromBackup` exists
    /// to prevent. The compiled Core ML graphs are worse still: they are
    /// device-specific, so a backup would carry them to a phone that cannot
    /// use them.
    private static func prepareContainer() {
        let fileManager = FileManager.default
        for directory in [containerDirectory, modelsDirectory, compileCacheDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                EngineLog.models.error(
                    "Could not create \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        var container = containerDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try container.setResourceValues(values)
        } catch {
            // Not fatal: the app still works, the user's backup is just larger
            // than it should be. Worth a line in the log, not an alert.
            EngineLog.models.error(
                "Could not exclude the model library from backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadManifest() {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json") else {
            lastError = "The bundled model manifest is missing from the app."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            lastError = "The model manifest could not be read: \(error.localizedDescription)"
        }
    }

    /// Marks a model installed only when the file is present *and* its size
    /// matches, so a truncated file is treated as missing rather than trusted.
    func refreshInstallStates() {
        guard let manifest else { return }
        for descriptor in manifest.models {
            let path = location(of: descriptor)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            states[descriptor.id] = (size == descriptor.bytes) ? .installed : .missing
        }
    }

    // MARK: - Queries

    var requiredModels: [ModelDescriptor] { manifest?.models.filter(\.required) ?? [] }
    var optionalModels: [ModelDescriptor] { manifest?.models.filter { !$0.required } ?? [] }

    func isInstalled(_ descriptor: ModelDescriptor) -> Bool {
        states[descriptor.id] == .installed
    }

    /// True once every required model is present — the point at which the app
    /// becomes fully usable offline.
    var isReady: Bool {
        !requiredModels.isEmpty && requiredModels.allSatisfy(isInstalled)
    }

    var missingRequired: [ModelDescriptor] { requiredModels.filter { !isInstalled($0) } }

    /// Total bytes still to fetch for the given set.
    func downloadSize(for descriptors: [ModelDescriptor]) -> Int64 {
        descriptors.filter { !isInstalled($0) }.reduce(0) { $0 + $1.bytes }
    }

    /// What the library currently occupies, for the Settings screen.
    ///
    /// Taken from the manifest rather than from `stat`, which costs nothing and
    /// is exact: a model only counts as installed when its size already matches
    /// the manifest to the byte.
    var installedBytes: Int64 {
        guard let manifest else { return 0 }
        return manifest.models.filter(isInstalled).reduce(0) { $0 + $1.bytes }
    }

    /// Absolute paths of everything installed, keyed for the engine.
    func installedPaths() -> [ModelID: String] {
        guard let manifest else { return [:] }
        var paths: [ModelID: String] = [:]
        for descriptor in manifest.models where isInstalled(descriptor) {
            if let id = descriptor.modelID {
                paths[id] = location(of: descriptor).path
            }
        }
        return paths
    }

    // MARK: - Installing

    func install(_ descriptors: [ModelDescriptor]) {
        guard !isWorking else { return }
        let pending = descriptors.filter { !isInstalled($0) }
        guard !pending.isEmpty else { return }

        isWorking = true
        lastError = nil
        sessionReceived = 0
        sessionTotal = pending.reduce(0) { $0 + $1.bytes }

        activeTask = Task { [weak self] in
            guard let self else { return }
            for descriptor in pending {
                if Task.isCancelled { break }
                do {
                    try await self.download(descriptor)
                    self.states[descriptor.id] = .installed
                } catch is CancellationError {
                    self.states[descriptor.id] = .missing
                    break
                } catch {
                    self.states[descriptor.id] = .failed(error.localizedDescription)
                    self.lastError = "\(descriptor.id): \(error.localizedDescription)"
                }
            }
            self.isWorking = false
            self.refreshInstallStates()
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
    }

    /// Removes an installed model from disk.
    func remove(_ descriptor: ModelDescriptor) {
        try? FileManager.default.removeItem(at: location(of: descriptor))
        states[descriptor.id] = .missing
    }

    /// Reclaims the whole library.
    ///
    /// The compiled Core ML graphs go with it: they are derived from the files
    /// being deleted, they are the larger half of the directory on some
    /// devices, and leaving them behind would mean "remove all models" did not
    /// free what the user was shown. The caller is expected to have unloaded
    /// the engine first — deleting a graph a live session has memory-mapped
    /// leaves that session working from a file with no name, which is
    /// survivable but pointless.
    func removeAll() {
        guard let manifest else { return }
        let fileManager = FileManager.default
        for descriptor in manifest.models {
            try? fileManager.removeItem(at: location(of: descriptor))
        }
        try? fileManager.removeItem(at: Self.compileCacheDirectory)
        try? fileManager.createDirectory(at: Self.compileCacheDirectory,
                                         withIntermediateDirectories: true)
        refreshInstallStates()
        lastError = nil
        EngineLog.models.notice("Removed the model library and the compiled graph cache")
    }

    // MARK: - Download

    private func download(_ descriptor: ModelDescriptor) async throws {
        let destination = location(of: descriptor)
        let staged = destination.appendingPathExtension("partial")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: Self.modelsDirectory,
                                        withIntermediateDirectories: true)

        states[descriptor.id] = .downloading(received: 0, total: descriptor.bytes)
        let baseline = sessionReceived

        try await downloader.download(key: descriptor.id,
                                      from: descriptor.url,
                                      to: staged) { [weak self] written, _ in
            // URLSession calls this from its own queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.states[descriptor.id] = .downloading(received: written,
                                                          total: descriptor.bytes)
                self.sessionReceived = baseline + written
            }
        }

        // Verify before installing. A mismatch means a corrupted or substituted
        // file, and installing it would hand unverified weights to the engine.
        states[descriptor.id] = .verifying
        let path = staged
        let digest = try await Task.detached(priority: .userInitiated) {
            try ModelManager.sha256(of: path)
        }.value

        guard digest == descriptor.sha256.lowercased() else {
            try? fileManager.removeItem(at: staged)
            downloader.discardResumeData(for: descriptor.id)
            throw ModelError.checksum(expected: descriptor.sha256, actual: digest)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staged, to: destination)
        sessionReceived = baseline + descriptor.bytes
    }

    /// Streaming SHA-256 so a 300 MB model never lands in memory whole.
    ///
    /// That mattered on a Mac for tidiness. On a phone it is the difference
    /// between hashing a model and being killed for it: reading 340 MB into one
    /// `Data` is a jetsam-sized allocation on top of whatever the engine is
    /// already holding.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ModelError: LocalizedError {
    case transport(String)
    case checksum(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return message
        case .checksum:
            return "The downloaded file did not match its expected checksum and was discarded."
        }
    }
}
