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
//  Files are named for their contents: `<id>-<first 16 hex of sha256>.onnx`.
//  The install question is therefore answered by the name, not by a size that
//  two different sets of weights can share — the failure the old scheme could
//  not even detect was a manifest whose digest changed but whose byte count did
//  not, after which the wrong weights were served forever with nothing able to
//  discover it. The cost of that correctness is paid once, by the adoption pass
//  in `reconcileLibrary`, which renames what is already on disk rather than
//  making anyone fetch 900 MB again.
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

    /// The first 16 hex characters — 64 bits — of the manifest digest.
    ///
    /// Long enough that two generations of a model colliding is not something
    /// that happens by accident, and short enough that the file is still
    /// recognisable as a model in a log line, a crash report or a file listing,
    /// which a 64-character digest would drown out.
    var digestPrefix: String { String(sha256.lowercased().prefix(16)) }

    /// Content-addressed, so the name itself answers "are these the right
    /// weights?". Nothing writes to this name without having hashed what it
    /// wrote first, which is what makes the cheap name-and-size check in
    /// `refreshInstallStates` sound.
    var fileName: String { "\(id)-\(digestPrefix).onnx" }

    /// What every build before this one wrote. Read exactly once, by the
    /// adoption pass, and never written again.
    var legacyFileName: String { "\(id).onnx" }

    /// Where a download accumulates until it has been verified.
    var partialFileName: String { "\(fileName).partial" }

    /// Identifies the transfer to `Downloader`, and survives the app being
    /// killed as the task's description.
    ///
    /// The digest is in it for the same reason it is in the partial file's
    /// name: a background task or a resume payload left over from an older
    /// manifest must never be matched to this descriptor and `Range`-resumed
    /// against a different URL, which would splice the head of one model onto
    /// the tail of another and produce a file that only the checksum could
    /// catch — after the whole download had been paid for.
    var downloadKey: String { "\(id)-\(digestPrefix)" }
}

struct ModelManifest: Codable, Sendable {
    var manifestVersion: Int
    var release: String
    var models: [ModelDescriptor]
}

enum ModelInstallState: Equatable, Sendable {
    /// The launch pass has not decided yet whether the bytes on disk are these
    /// weights. Deliberately not `missing`: a user who already has the model
    /// must never be shown a download for it, not even for the second it takes
    /// to hash what they have.
    case checking
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

    /// True until the launch pass has finished deciding what is on disk.
    ///
    /// Everything that could offer the user a download waits on this. The pass
    /// takes milliseconds for a library that is already in the digest-named
    /// scheme and seconds for one that has to be hashed and adopted, and during
    /// those seconds "not installed yet" would be a lie.
    private(set) var isPreparingLibrary = true

    /// Bytes moved during the current download session, for the aggregate bar.
    private(set) var sessionReceived: Int64 = 0
    private(set) var sessionTotal: Int64 = 0

    private var activeTask: Task<Void, Never>?

    /// Partial files this process is in the middle of writing or verifying.
    /// The sweep refuses to touch them; see `sweep`.
    private var inFlightPartials: Set<String> = []

    /// The process-wide downloader. It has to be the shared instance rather
    /// than one of our own: it owns a background `URLSession`, and a second
    /// session claiming the same identifier is a hard runtime error.
    private let downloader = Downloader.shared

    // MARK: - Locations

    /// Everything this app writes that is not a user document.
    ///
    /// Resolved once, because the path never changes for the lifetime of the
    /// process and every frame of the engine's compile cache hangs off it.
    nonisolated static let containerDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("FaceFusion", isDirectory: true)
    }()

    nonisolated static var modelsDirectory: URL {
        containerDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Where Core ML keeps the graphs it compiles from the ONNX models.
    ///
    /// It sits beside the models rather than in Caches on purpose: compiling
    /// these graphs takes long enough to be visible on first launch, and a
    /// directory the system may delete at any moment would mean paying that
    /// cost again at the least convenient time.
    nonisolated static var compileCacheDirectory: URL {
        containerDirectory.appendingPathComponent("CoreMLCompiled", isDirectory: true)
    }

    /// The list of model files the compiled graphs were last reconciled
    /// against. Kept beside the two directories rather than inside either, so
    /// neither the sweep nor a cache wipe has to know about it.
    nonisolated static var compiledFromFile: URL {
        containerDirectory.appendingPathComponent("CompiledFrom.json")
    }

    func location(of descriptor: ModelDescriptor) -> URL {
        Self.modelsDirectory.appendingPathComponent(descriptor.fileName)
    }

    // MARK: - Loading

    init() {
        Self.prepareContainer()
        loadManifest()
        // Two steps, in this order, and the order is the whole point: publish
        // what a `stat` can prove immediately so an up-to-date library shows no
        // flicker at all, then let the launch pass resolve the rest off the
        // main actor before anything is called missing.
        publishInstallStates(unresolved: .checking)
        prepareLibrary()
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
            lastError = String(localized: "The model manifest could not be read: \(error.localizedDescription)", bundle: .uiLanguage)
        }
    }

    /// Marks a model installed only when the *digest-named* file is present and
    /// its size matches, so a truncated file is treated as missing rather than
    /// trusted.
    ///
    /// Deliberately not a hash. The name carries the digest, and the only two
    /// things that ever write to that name — a verified download and the
    /// adoption pass — hash before they do, so name plus size says everything
    /// re-reading 900 MB would say and says it in microseconds. Startup is the
    /// worst possible place to spend seconds re-learning what the file is
    /// already called.
    func refreshInstallStates() {
        publishInstallStates(unresolved: .missing)
    }

    /// The shared body of `refreshInstallStates` and the seeding done in
    /// `init`, which differ only in what they call a model they cannot prove is
    /// installed: missing once the launch pass has looked, still being checked
    /// before that.
    private func publishInstallStates(unresolved: ModelInstallState) {
        guard let manifest else { return }
        for descriptor in manifest.models {
            let size = Self.fileSize(at: location(of: descriptor))
            states[descriptor.id] = (size == descriptor.bytes) ? .installed : unresolved
        }
    }

    // MARK: - The launch pass

    /// Reconciles the library with the manifest once, before anything acts on
    /// an install state.
    ///
    /// The work is dispatched rather than awaited: `init` returns immediately
    /// and the first frame of UI draws while the disk is being read.
    private func prepareLibrary() {
        guard let manifest else {
            isPreparingLibrary = false
            return
        }
        let descriptors = manifest.models

        Task { [weak self] in
            guard let self else { return }
            let protected = await self.protectedPartialNames()

            // Hashing a 900 MB library is seconds of `read`, and the actor this
            // object lives on is the one drawing the screen — so all of it goes
            // to a detached task and only the verdicts cross back.
            let verdicts = await Task.detached(priority: .utility) {
                Self.reconcileLibrary(descriptors: descriptors,
                                      protectedPartials: protected)
            }.value

            // Every verdict lands in one step, and `isPreparingLibrary` drops
            // in the same one. Reporting them as they were reached would have
            // shown the library filling in, at the cost of publishing a state
            // nothing else in the app is prepared for: `isReady` counts only
            // the required models, so it flips the moment the third of five is
            // adopted, and two things act on that immediately. `RootView`'s
            // `task(id:)` starts the engine — which snapshots `installedPaths()`
            // on the spot, so the enhancer and the landmarker are simply absent
            // from a session the UI then reports as having them, for the rest of
            // the launch. And this pass still has the sweep and the
            // compiled-graph reconciliation to do, the second of which empties
            // the very directory Core ML would by then be compiling into.
            // Neither is a race worth winning: the spec asks for the library to
            // be decided *before* any install state is published, and deciding
            // it in one move is what makes that true.
            for (id, state) in verdicts { self.states[id] = state }
            self.isPreparingLibrary = false
        }
    }

    /// Adoption, then the sweep, then the compiled graphs — off the main actor,
    /// returning the verdict for every model rather than publishing any of them
    /// itself. The caller publishes the lot at once; see `prepareLibrary` for
    /// why a half-decided library must never be visible.
    ///
    /// Idempotent by construction: every branch is guarded by what is on disk,
    /// so the second run finds the digest-named files already there and does
    /// nothing at all.
    nonisolated private static func reconcileLibrary(
        descriptors: [ModelDescriptor],
        protectedPartials: Set<String>) -> [String: ModelInstallState] {

        var verdicts: [String: ModelInstallState] = [:]
        var installed: Set<String> = []
        for descriptor in descriptors {
            let state = adopt(descriptor)
            if state == .installed { installed.insert(descriptor.id) }
            verdicts[descriptor.id] = state
        }

        // Rule two of the sweep: a half-finished migration means the previous
        // generation is the only working copy the user has, and reclaiming it
        // would leave them with an app that cannot swap a face. Waiting costs
        // disk until the download that completes the set; not waiting costs
        // them the app.
        // Counted from the required set alone. `installed` holds the optional
        // models too, so subtracting its size from the required count reports a
        // negative number on exactly the library this line exists to explain.
        let outstanding = descriptors.filter { $0.required && !installed.contains($0.id) }
        if outstanding.isEmpty {
            sweep(keeping: descriptors, protecting: protectedPartials)
        } else {
            EngineLog.models.notice(
                "deferred the model sweep: \(outstanding.count) required model(s) still missing")
        }

        reconcileCompileCache()
        return verdicts
    }

    /// Decides what one model's bytes on disk are worth, adopting the legacy
    /// file when they turn out to be exactly the weights the manifest asks for.
    ///
    /// This is the part of the change that exists so that nobody re-downloads
    /// anything: an existing library is ~900 MB written under the old names,
    /// and looking only for digest-named files would make every byte of it
    /// invisible.
    nonisolated private static func adopt(_ descriptor: ModelDescriptor) -> ModelInstallState {
        let fileManager = FileManager.default
        let destination = modelsDirectory.appendingPathComponent(descriptor.fileName)
        if fileSize(at: destination) == descriptor.bytes { return .installed }

        let legacy = modelsDirectory.appendingPathComponent(descriptor.legacyFileName)
        guard let legacySize = fileSize(at: legacy) else { return .missing }

        guard legacySize == descriptor.bytes else {
            // The size-only scheme this replaces would have called it missing
            // too, so nothing usable is being thrown away — and on a phone the
            // space is worth more than a file no code path would ever open.
            try? fileManager.removeItem(at: legacy)
            return .missing
        }

        let digest = (try? sha256(of: legacy)) ?? ""
        guard digest == descriptor.sha256.lowercased() else {
            // Right size, wrong bytes: stale or corrupt, and the old scheme had
            // no way to notice. These are precisely the weights that would
            // otherwise have been served to the engine forever.
            try? fileManager.removeItem(at: legacy)
            EngineLog.models.notice(
                "discarded \(descriptor.id, privacy: .public): it was the expected size but not the expected weights")
            return .missing
        }

        do {
            // A truncated file may already sit under the new name; the verified
            // legacy copy is strictly better than whatever that is.
            try? fileManager.removeItem(at: destination)
            // A rename, not a copy. It is instant and needs no free space,
            // where copying 300 MB would need a second 300 MB on a device that
            // may well not have it.
            try fileManager.moveItem(at: legacy, to: destination)
            EngineLog.models.notice(
                "adopted \(descriptor.id, privacy: .public) under its digest name; no download needed")
            return .installed
        } catch {
            EngineLog.models.error(
                "could not adopt \(descriptor.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .missing
        }
    }

    /// Deletes everything in the models directory the current manifest does not
    /// claim: earlier generations of a model whose digest moved, ids that were
    /// renamed or dropped, and partial downloads nobody is waiting for. Nothing
    /// else ever reclaims those bytes, so without this they leak for the life
    /// of the install.
    ///
    /// The caller decides *when* it is safe to run — see the completeness rule
    /// in `reconcileLibrary`. This function enforces the other rule: a partial
    /// belonging to a live transfer is not litter.
    nonisolated private static func sweep(keeping descriptors: [ModelDescriptor],
                                          protecting protectedPartials: Set<String>) {
        let fileManager = FileManager.default
        let claimed = Set(descriptors.map(\.fileName))
        guard let entries = try? fileManager.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            // Content-addressed names are what make it safe to be this blunt:
            // anything the manifest still wants is named after a digest the
            // manifest still lists, so two generations could sit here side by
            // side if a future build ever wanted them to.
            if claimed.contains(name) || protectedPartials.contains(name) { continue }
            try? fileManager.removeItem(at: entry)
            EngineLog.models.notice("swept \(name, privacy: .public)")
        }
    }

    /// Throws away compiled graphs that nothing can ask for any more.
    ///
    /// ORT names each entry in that directory from a hash of its own —
    /// `COREML_<hash>_<n>` — and nothing in the name says which model produced
    /// it, so an entry cannot be mapped back to a file. The hash covers the
    /// model ORT compiled, its file name included, which means the adoption
    /// rename gives the very same weights a new key. That is correct, and worth
    /// the recompile it costs on the first launch after adoption: a graph built
    /// from the old file must never be handed back for a file that only happens
    /// to share an id. But it also leaves the old entry unreachable, and
    /// unreachable entries here are hundreds of megabytes.
    ///
    /// So the model file names are tracked instead. A name that was present at
    /// the last reconcile and is gone now means whatever was compiled from it
    /// is dead weight, and since the entries cannot be told apart the cache goes
    /// wholesale. Names that only *appear* change nothing — a new model simply
    /// compiles and adds an entry — so they do not trigger a wipe.
    nonisolated private static func reconcileCompileCache() {
        let fileManager = FileManager.default
        let present = Set(((try? fileManager.contentsOfDirectory(atPath: modelsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".onnx") })

        // No record at all is the update to this scheme itself: whatever is in
        // there was compiled by a build that named its models the old way, and
        // the adoption pass has just renamed every one of them. A record of
        // *nothing* is different — that is a library that has never compiled
        // anything — so the two cases must not be collapsed.
        let entries = (try? fileManager.contentsOfDirectory(atPath: compileCacheDirectory.path)) ?? []
        let stale = compiledFromNames().map { !$0.isSubset(of: present) } ?? !entries.isEmpty

        if stale {
            try? fileManager.removeItem(at: compileCacheDirectory)
            try? fileManager.createDirectory(at: compileCacheDirectory,
                                             withIntermediateDirectories: true)
            EngineLog.models.notice(
                "cleared the compiled graph cache: the models it was built from are gone")
        }
        recordCompiledFrom(present)
    }

    /// The recorded file names, or `nil` when nothing has ever been recorded.
    nonisolated private static func compiledFromNames() -> Set<String>? {
        guard let data = try? Data(contentsOf: compiledFromFile),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(names)
    }

    nonisolated private static func recordCompiledFrom(_ names: Set<String>) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? data.write(to: compiledFromFile, options: .atomic)
    }

    /// Size in bytes, or `nil` when there is no file there at all — a
    /// distinction `attributesOfItem` collapses and both callers need.
    nonisolated private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// The partial files no sweep may touch: one for every transfer this
    /// process is writing or verifying, and one for every transfer the
    /// background session still has work for — including a task it kept running
    /// while the app was not.
    private func protectedPartialNames() async -> Set<String> {
        var names = inFlightPartials
        for key in await downloader.activeKeys() {
            // The key is the digest-named file without its extension, which is
            // exactly what `download` stages under.
            names.insert("\(key).onnx.partial")
        }
        return names
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
        // Nothing is fetched until the launch pass has finished: a model it is
        // about to adopt still looks uninstalled while it is being hashed, and
        // downloading it again would be exactly the 900 MB this change exists
        // to save.
        guard !isWorking, !isPreparingLibrary else { return }
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
            await self.sweepIfComplete()
        }
    }

    /// Retries the sweep the launch pass may have deferred.
    ///
    /// This is the moment a half-finished migration finishes: the download that
    /// completes the required set is also the download after which the previous
    /// generation stops being anybody's only working copy.
    ///
    /// The compiled graphs are left alone here even though some of them have
    /// just been orphaned — the engine may be running on the others, and
    /// `reconcileCompileCache` will notice the files that went away at the next
    /// launch, before anything is loaded.
    private func sweepIfComplete() async {
        guard let manifest, isReady else { return }
        let descriptors = manifest.models
        let protected = await protectedPartialNames()
        await Task.detached(priority: .utility) {
            Self.sweep(keeping: descriptors, protecting: protected)
        }.value
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
        let fileManager = FileManager.default
        // The directory, not the manifest's list of names: a generation the
        // manifest has moved on from still occupies the user's disk, and a
        // "remove all models" that leaves 300 MB of it behind is a lie told to
        // the number on the Settings screen.
        for directory in [Self.modelsDirectory, Self.compileCacheDirectory] {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        Self.recordCompiledFrom([])
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

        // Claim the staging file for as long as it is ours, so a sweep running
        // alongside this download reads it as work in progress rather than as
        // an orphan.
        inFlightPartials.insert(descriptor.partialFileName)
        defer { inFlightPartials.remove(descriptor.partialFileName) }

        try await downloader.download(key: descriptor.downloadKey,
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
            downloader.discardResumeData(for: descriptor.downloadKey)
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
            return String(localized: "The downloaded file did not match its expected checksum and was discarded.", bundle: .uiLanguage)
        }
    }
}
