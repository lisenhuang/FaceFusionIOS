//
//  MediaStore.swift
//  FaceFusion
//
//  Where a finished render goes.
//
//  On the Mac there was no file like this: `NSSavePanel` asked for a path
//  before the render began and the export wrote straight to it. iOS has no save
//  panel and nowhere writable outside the app's own container, so the order is
//  reversed — the render is written to a temporary file the app owns, and only
//  afterwards does the user say where it should end up. There are three answers
//  a person actually wants, and only one of them needs code here:
//
//  - **Photos**, which needs an authorisation and a library change request.
//  - **Files**, which SwiftUI's `.fileExporter` performs from a file URL.
//  - **Share**, which `ShareLink` performs from the same file URL.
//
//  So this file owns two things: the temporary directory a render lives in
//  until it is claimed — including making sure last week's abandoned renders
//  are not still sitting in it — and the Photos hand-off, with errors a person
//  can act on rather than a `PHPhotosError` nobody can read.
//
//  Add-only authorisation is deliberate, not caution for its own sake. Nothing
//  in the app ever reads the library: `PhotosPicker` runs out of process and
//  hands back only the item the user chose. Asking for full access would be
//  asking for something there is no code to use.
//
//  Temporary rather than permanent is also deliberate. `tmp` is never included
//  in an iCloud or iTunes backup, so a 500 MB render cannot quietly become part
//  of the user's backup, and the system is free to reclaim the space when the
//  app is not running — which is exactly the right policy for a file the user
//  has already saved somewhere else, or decided not to keep.
//

import Foundation
import Photos
import os

enum MediaStore {

    // MARK: - Locations

    /// Where a render is written before the user says what to do with it.
    ///
    /// Recomputed rather than cached, and the directory is re-created on every
    /// access: the system may empty `tmp` while the app is suspended, and a
    /// cached URL to a directory that no longer exists turns the next export
    /// into a write failure a long way from the cause.
    static var exportsDirectory: URL {
        directory(named: "Exports")
    }

    /// The sibling of `exportsDirectory`, holding files copied out of the photo
    /// picker.
    ///
    /// A `PhotosPickerItem` is not a file URL, and the whole pipeline —
    /// `AVURLAsset`, `CIImage(contentsOf:)`, the SHA of a manifest entry —
    /// works in file URLs, so a pick has to be written down somewhere first.
    /// It lives here rather than in `Exports` so that "everything the user has
    /// not claimed" and "everything the app dragged in for itself" can be told
    /// apart when clearing up. Imports belong to `AppModel`'s media lifecycle:
    /// it deletes them when the source or target is cleared, and the launch
    /// sweep below catches whatever a crash left behind.
    static var importsDirectory: URL {
        directory(named: "Imports")
    }

    private static func directory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A free path for one render.
    ///
    /// The name is derived from the target the user chose, because it is what
    /// the share sheet and the Files browser show — a UUID would be correct and
    /// unhelpful. Uniqueness is not cosmetic: `AVAssetWriter` refuses to start
    /// when its destination already exists, and re-exporting the same clip
    /// twice after changing a slider is the most ordinary thing a user does.
    ///
    /// `png` chooses between the two still formats. PNG is the default for a
    /// photo target because re-encoding a JPEG through the swap would spend a
    /// second generation of detail for nothing.
    static func makeOutputURL(basedOn source: URL, isImage: Bool, png: Bool) -> URL {
        let directory = exportsDirectory
        let stem = sanitisedStem(source.deletingPathExtension().lastPathComponent)
        let ext = isImage ? (png ? "png" : "jpg") : "mp4"

        var candidate = directory.appendingPathComponent("\(stem)-faceswap.\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-faceswap-\(attempt).\(ext)")
            attempt += 1
        }
        sweepState.withLock { $0.vended.insert(candidate.lastPathComponent) }
        return candidate
    }

    /// A file name that cannot escape the exports directory or hide inside it.
    ///
    /// The stem comes from a file the user picked, so it can contain anything a
    /// filesystem or a cloud provider allowed — including a slash, which would
    /// silently move the render into a directory that does not exist, and a
    /// leading dot, which would make it invisible to the very picker the user
    /// is about to save it with.
    private static func sanitisedStem(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: banned).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "." })
        let trimmed = String(cleaned.prefix(64))
        // Never the app's name. An exported file travels to people who did not
        // make it, and its name should say nothing about what produced it — a
        // picked file whose stem sanitises down to nothing is the one path that
        // would otherwise put the product name on someone else's device.
        return trimmed.isEmpty ? "export" : trimmed
    }

    // MARK: - Clearing up

    private struct SweepState: Sendable {
        var hasRun = false
        /// File names this run handed out, which are the one thing the sweep
        /// must never touch.
        var vended: Set<String> = []
    }

    private static let sweepState = OSAllocatedUnfairLock(initialState: SweepState())

    /// Deletes renders and imports left behind by a previous launch.
    ///
    /// Two guards, because this is called from `scenePhase` becoming `.active`
    /// and that happens every time the app returns to the foreground, not only
    /// at launch:
    ///
    /// - It runs **once per process**. The first `.active` of a launch is the
    ///   only moment at which everything on disk is provably from an earlier
    ///   run, so that is the moment to clear it.
    /// - It never deletes a name `makeOutputURL` handed out this run, so even a
    ///   stray later call cannot remove the render whose Share button the user
    ///   is currently looking at.
    ///
    /// No clock is involved anywhere, which is the point: a rule written in
    /// terms of file ages has to guess how long a user might leave a finished
    /// render on screen, and guessing wrong deletes their work.
    ///
    /// Synchronous on purpose. This is a directory read and a handful of
    /// `unlink`s — metadata operations, whatever the size of the files — and
    /// having it finished before the first export can ask for a name is worth
    /// more than the microseconds.
    static func clearStaleOutputs() {
        let alreadySwept = sweepState.withLock { state -> Bool in
            defer { state.hasRun = true }
            return state.hasRun
        }
        guard !alreadySwept else { return }

        let keep = sweepState.withLock { $0.vended }
        let manager = FileManager.default
        var removed = 0
        var reclaimed: Int64 = 0

        for directory in [exportsDirectory, importsDirectory] {
            let entries = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []

            for entry in entries where !keep.contains(entry.lastPathComponent) {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                do {
                    try manager.removeItem(at: entry)
                    removed += 1
                    reclaimed += Int64(size)
                } catch {
                    // A file the system is still holding open is not worth
                    // failing a launch over; the next one will get it.
                    EngineLog.client.debug(
                        "could not remove stale file: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if removed > 0 {
            EngineLog.client.notice(
                "cleared \(removed) stale file(s), \(reclaimed) byte(s) reclaimed")
        }
    }

    // MARK: - Photos

    /// True once the app may add to the photo library, asking for permission if
    /// the question has not been put yet.
    ///
    /// The status is checked before requesting because `requestAuthorization`
    /// on an already-denied status returns immediately without showing
    /// anything: the user turned it off in Settings and only Settings can turn
    /// it back on. A caller that treats `false` as "the sheet was dismissed"
    /// leaves them with a button that does nothing, which is why the error
    /// below says where to go.
    static func requestAddPermission() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            // `.limited` is a read-access concept and is not expected here, but
            // it does grant adding, so treat it as a yes rather than refusing
            // on a status nobody has looked at.
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Copies a finished video into the photo library.
    static func saveVideoToPhotos(_ url: URL) async throws {
        try await addToLibrary(url, isVideo: true)
    }

    /// Copies a finished still into the photo library.
    static func saveImageToPhotos(_ url: URL) async throws {
        try await addToLibrary(url, isVideo: false)
    }

    /// The shared body of both.
    ///
    /// Photos copies the file rather than taking ownership of it — the resource
    /// options can be told to move it instead, which would save duplicating
    /// half a gigabyte, but it would also delete the file out from under the
    /// Share and Save to Files buttons sitting next to Save to Photos. Copying
    /// is what lets a render go to more than one place.
    ///
    /// The file therefore has to still exist when `performChanges` returns:
    /// nothing may delete it in a `defer` around this call.
    private static func addToLibrary(_ url: URL, isVideo: Bool) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SaveError.missingFile
        }
        guard await requestAddPermission() else {
            throw SaveError.notPermitted
        }

        // `creationRequestForAssetFrom…` returns nil when Photos will not take
        // the file at all, and a change block that registers no change is not
        // an error — it simply succeeds having done nothing, which would show
        // the user a tick for a save that never happened.
        let accepted = OSAllocatedUnfairLock(initialState: false)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = isVideo
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                accepted.withLock { $0 = request != nil }
            }
        } catch {
            // The underlying error is logged, never shown: a `PHPhotosError`
            // localises to "The operation couldn't be completed", which tells
            // the user nothing they can act on.
            EngineLog.client.error(
                "photo library save failed: \(error.localizedDescription, privacy: .public)")
            throw SaveError.libraryFailed
        }

        guard accepted.withLock({ $0 }) else {
            throw SaveError.unsupportedFile(isVideo: isVideo)
        }
        EngineLog.client.notice("saved \(isVideo ? "video" : "image", privacy: .public) to Photos")
    }

    /// Everything that can go wrong on the way to the library, in words.
    enum SaveError: LocalizedError {
        /// Permission was refused, or had been refused earlier.
        case notPermitted
        /// The render is no longer on disk — the system reclaimed `tmp`, or the
        /// export was cleared.
        case missingFile
        /// Photos declined the file itself.
        case unsupportedFile(isVideo: Bool)
        /// The library reported a failure. The detail is in the log.
        case libraryFailed

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return String(localized: "Morphiqo is not allowed to add to your photo library. You can turn that on in Settings, under Morphiqo.", bundle: .uiLanguage)
            case .missingFile:
                return String(localized: "That render is no longer available. Export it again.", bundle: .uiLanguage)
            case .unsupportedFile(let isVideo):
                return isVideo
                    ? String(localized: "Your photo library would not accept that video.", bundle: .uiLanguage)
                    : String(localized: "Your photo library would not accept that image.", bundle: .uiLanguage)
            case .libraryFailed:
                return String(localized: "The photo library could not save the file. Check that there is enough free space and try again.", bundle: .uiLanguage)
            }
        }
    }
}
