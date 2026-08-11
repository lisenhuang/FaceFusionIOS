//
//  AppModel.swift
//  FaceFusion
//
//  Application state and the actions the UI can take.
//
//  This is the same model the Mac app runs on, and the rules it encodes are the
//  ones that took the longest to get right: *Choose* is the default because it
//  is the only face selection that names a person rather than a position; a new
//  target empties the checked people under a *new* generation rather than
//  leaving the mode; the export re-runs the swap instead of saving whatever the
//  preview happened to produce; and analysis aligns faces exactly the way the
//  swap will, because an identity encoded from raw detector points and one
//  encoded from refined landmarks are different vectors. None of that changes
//  on a phone, and none of it should be re-derived by a view.
//
//  What does change is everything at the edges — where a file comes from and
//  where the finished one goes:
//
//  - There are no open or save panels. Views hand in URLs, and a photo-library
//    item is not a URL at all, so `useSource(pickedItem:)` redeems the promise
//    into an `Imports` folder the app owns and deletes again.
//  - The export renders to a temporary file rather than to a place the user
//    chose in advance; the result bar then offers Photos, Files or Share.
//  - Settings live in `Preferences` so they survive a relaunch, but they keep
//    their names here and are forwarded, so the views read exactly as before.
//  - The video preview decodes to a bounded long edge. A phone cannot afford a
//    4K swap on every slider change, and it does not have to: the export
//    re-runs the swap from the original file at full resolution, so nothing the
//    user keeps is affected by what the preview chose to look at.
//

import Foundation
import Observation
import os
import CoreVideo
import CoreMedia
import CoreTransferable
import AVFoundation
// `PhotosPickerItem` lives in PhotosUI's SwiftUI overlay, which only surfaces
// when SwiftUI is imported alongside it — hence the import in a model file
// that otherwise has no business knowing about views.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case choosingMedia
        case ready
        case rendering
        case finished(URL)
        case failed(String)
    }

    /// What the face is being swapped into. A photo is the same pipeline as a
    /// video with exactly one frame, so the two differ only at the edges:
    /// there is nothing to scrub, and the result is written by ImageIO rather
    /// than by an encoder.
    enum TargetMedia: Equatable {
        case video(VideoInfo)
        case image(size: CGSize, format: String)

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        var displaySize: CGSize {
            switch self {
            case .video(let info): return info.displaySize
            case .image(let size, _): return size
            }
        }
    }

    // MARK: Services

    let models = ModelManager()
    let engine = EngineClient()
    let purchases: StoreManager

    // MARK: Media

    private(set) var sourceURL: URL?
    private(set) var sourceBuffer: CVPixelBuffer?
    private(set) var sourceFace: DetectedFace?
    private(set) var sourceFaceCount = 0

    private(set) var targetURL: URL?
    private(set) var target: TargetMedia?

    /// Present only for video targets, so the scrubber and the frame-count
    /// progress simply do not appear for a photo.
    var targetInfo: VideoInfo? {
        if case .video(let info) = target { return info }
        return nil
    }

    var targetIsImage: Bool { target?.isImage ?? false }

    /// The frame currently shown, before any swap.
    private(set) var previewFrame: CVPixelBuffer?
    /// The same frame after swapping, when a preview has been generated.
    private(set) var previewResult: CVPixelBuffer?
    private(set) var previewFaces: [DetectedFace] = []
    /// Parallel to `previewFaces`, and populated only while choosing faces —
    /// the overlay cannot tell which boxes belong to the checked people
    /// without asking who each face is.
    private(set) var previewIdentities: [FaceIdentity] = []
    private(set) var isPreviewing = false
    /// Toggles the canvas between the original and the swapped frame.
    var showsOriginal = false

    /// Scrub position in seconds.
    var previewTime: Double = 0 {
        didSet { schedulePreviewFrameReload() }
    }

    /// Long edge a video frame is decoded to for the preview.
    ///
    /// Swapping a 4K frame costs several times what swapping a 1280px one
    /// does, and the difference is invisible on a phone screen. It is safe
    /// precisely because the export does not reuse this: it decodes the source
    /// file again, at its own resolution, and swaps again with the settings as
    /// they stand when Export is pressed.
    ///
    /// A *photo* target is deliberately not capped — see `setImageTarget`.
    static let previewMaximumDimension = 1280

    /// How much smaller the previewed frame is than the media itself, 1 when
    /// they are the same.
    ///
    /// Nothing in the geometry needs this: face boxes are in preview-frame
    /// pixels and the canvas normalises by the preview frame's own dimensions,
    /// so the cap is invisible to the view layer. It is exposed so the studio
    /// can say out loud that a preview is not the export.
    var previewScale: Double {
        guard let target, !target.isImage else { return 1 }
        let longest = max(target.displaySize.width, target.displaySize.height)
        guard longest > 0 else { return 1 }
        return min(1, Double(Self.previewMaximumDimension) / Double(longest))
    }

    // MARK: Options

    // These seven live in `Preferences` so they survive a relaunch, and are
    // forwarded here under their original names so every view that reads
    // `model.enhanceFace` still does. Reading through the forwarding property
    // registers the view with `Preferences`' observation, so changing one from
    // the Settings sheet redraws the studio without anything being wired up
    // between them.

    var enhanceFace: Bool {
        get { Preferences.shared.enhanceFace }
        set { Preferences.shared.enhanceFace = newValue }
    }

    var maskOcclusion: Bool {
        get { Preferences.shared.maskOcclusion }
        set { Preferences.shared.maskOcclusion = newValue }
    }

    var identityStrength: Double {
        get { Preferences.shared.identityStrength }
        set { Preferences.shared.identityStrength = newValue }
    }

    var maskBlur: Double {
        get { Preferences.shared.maskBlur }
        set { Preferences.shared.maskBlur = newValue }
    }

    var useHEVC: Bool {
        get { Preferences.shared.useHEVC }
        set { Preferences.shared.useHEVC = newValue }
    }

    /// Which units the engine may use.
    ///
    /// The execution provider is chosen when a session is created, so changing
    /// this has to rebuild every session. The setter restarts the engine rather
    /// than leaving a preference that quietly does nothing until the next
    /// launch — which is exactly how someone concludes the benchmark lied.
    var compute: ComputePolicy {
        get { Preferences.shared.compute }
        set {
            guard newValue != Preferences.shared.compute else { return }
            Preferences.shared.compute = newValue
            Task { await restartEngine() }
        }
    }

    /// *Choose* by default: it is the only mode that names a **person** rather
    /// than a position, and so the only one that survives a cut, a crossing, or
    /// the subject walking across frame. The other two are there for when that
    /// precision is not wanted.
    ///
    /// Generation 0 is deliberately one nobody has pushed, so a swap cannot run
    /// against it by accident. `startEngineIfPossible` replaces it with a real
    /// generation the moment there is an engine to push to.
    var faceSelection: FaceSelection

    // MARK: Choosing faces

    /// People found in the target, most prominent first.
    private(set) var people: [FaceScanner.Person] = []
    private(set) var checkedPeople: Set<Int> = []
    /// Non-nil only while a scan is running.
    private(set) var scanProgress: FaceScanner.ScanProgress?
    /// Distinguishes "not looked yet" from "looked and found nobody".
    private(set) var hasScanned = false

    /// How close a face has to be to a checked identity to count as that
    /// person. Exposed because no single threshold suits every clip: a
    /// disguise or hard side lighting needs a looser one, identical twins a
    /// tighter one.
    var matchDistance: Double {
        get { Preferences.shared.matchDistance }
        set { Preferences.shared.matchDistance = newValue }
    }

    /// Rises on every push to the engine, so a swap can never run against a
    /// set the engine has since replaced or forgotten.
    private var referenceGeneration = 0
    private var scanTask: Task<Void, Never>?

    var isScanning: Bool { scanProgress != nil }

    /// The three ways the user can say which faces to replace. Derived rather
    /// than stored: `faceSelection` remains the single source of truth, since
    /// it is what actually crosses to the engine.
    enum FaceMode: Hashable {
        case everyFace
        case oneFace
        case chosen
    }

    var faceMode: FaceMode {
        switch faceSelection {
        case .all: return .everyFace
        case .largest, .nearestTo: return .oneFace
        case .reference: return .chosen
        }
    }

    // MARK: Job

    private(set) var phase: Phase = .choosingMedia
    private(set) var progress: ExportProgress?
    private(set) var statusMessage: String?

    /// True while a finished render is being copied into the photo library, and
    /// true afterwards for the render currently in `.finished` — so a second
    /// tap on Save to Photos does not add a second copy of the same video.
    private(set) var isSavingToPhotos = false
    private(set) var finishedIsInPhotos = false

    private var exportTask: Task<Void, Never>?
    private var previewFrameTask: Task<Void, Never>?
    private var previewSwapTask: Task<Void, Never>?
    /// Rises on every preview, so a swap that finishes after the world moved on
    /// can tell that it is no longer the one being waited for. See
    /// `refreshPreview()`.
    private var previewGeneration = 0
    /// How many preview swaps are inside the engine. Drives `isPreviewing`; see
    /// the comment in `refreshPreview()` for why a count rather than a flag.
    private var previewsInFlight = 0

    /// Files this app copied out of the photo library, and is therefore
    /// responsible for deleting.
    private var importedSourceURL: URL?
    private var importedTargetURL: URL?

    /// Access to files the user picked from outside the app's container, held
    /// open for as long as the media is loaded.
    private var sourceAccess: ScopedFile?
    private var targetAccess: ScopedFile?

    init(purchases: StoreManager? = nil) {
        self.purchases = purchases ?? .shared
        // Seeded from the persisted threshold rather than from the constant, so
        // the first frame previewed after a launch matches what the user last
        // settled on rather than briefly using the default.
        faceSelection = .reference(generation: 0,
                                   maxDistance: Preferences.shared.matchDistance)
        // Nothing is loaded yet, so anything sitting in `Imports` belongs to a
        // session that was killed before it could tidy up — most likely a
        // whole copy of a video nobody will open again. Swept in the
        // background: a folder of large files is not worth delaying the first
        // frame for.
        Task.detached(priority: .utility) { AppModel.clearStaleImports() }
    }

    // MARK: - Derived

    var canRender: Bool {
        guard sourceFace != nil, targetURL != nil, models.isReady, phase != .rendering else {
            return false
        }
        // Rendering a whole video that changes nothing is never what was
        // meant, and the mistake is expensive enough to be worth blocking.
        if case .reference = faceSelection, checkedPeople.isEmpty { return false }
        return true
    }

    var isRendering: Bool { phase == .rendering }

    /// How hard the export will push this device, right now.
    ///
    /// Read through the observable `DeviceCapabilities` rather than the static,
    /// so a view showing it redraws when the device starts throttling instead of
    /// displaying whatever was true when it was first laid out.
    var exportProfile: PerformanceProfile {
        DeviceCapabilities.shared.profile(enhancing: enhanceFace)
    }

    /// Identities of the checked people, in the form the engine matches on.
    private var checkedIdentities: [FaceIdentity] {
        people.filter { checkedPeople.contains($0.id) }.map(\.identity)
    }

    /// Analysis has to align faces exactly the way the swap will. An identity
    /// encoded from the detector's raw key points and one encoded from refined
    /// landmarks are different vectors, and mixing the two would put a floor
    /// under every distance the matcher computes.
    var analysisOptions: AnalysisOptions {
        let options = swapOptions
        return AnalysisOptions(detectorScore: options.detectorScore,
                               refineLandmarks: options.refineLandmarks,
                               includeIdentities: true)
    }

    /// Which of `previewFaces` the current settings would replace.
    ///
    /// The canvas reads this rather than re-deriving the rule, which is the
    /// only way the highlight can agree with the swap for `.reference` — that
    /// case is a question about identity, and the view has no identities.
    var selectedFaceIndices: Set<Int> {
        switch faceSelection {
        case .all:
            return Set(previewFaces.map(\.index))

        case .largest:
            guard let largest = previewFaces.max(by: {
                $0.box.width * $0.box.height < $1.box.width * $1.box.height
            }) else { return [] }
            return [largest.index]

        case .nearestTo(let x, let y):
            guard let frame = previewFrame else { return [] }
            let point = CGPoint(x: x * Double(CVPixelBufferGetWidth(frame)),
                                y: y * Double(CVPixelBufferGetHeight(frame)))
            guard let nearest = nearestFace(to: point) else { return [] }
            return [previewFaces[nearest].index]

        case .reference(_, let maxDistance):
            guard previewIdentities.count == previewFaces.count else { return [] }
            let references = checkedIdentities
            guard !references.isEmpty else { return [] }
            var matched: Set<Int> = []
            for (face, identity) in zip(previewFaces, previewIdentities)
            where identity.nearestDistance(among: references) <= maxDistance {
                matched.insert(face.index)
            }
            return matched
        }
    }

    /// Index into `previewFaces` of the face whose centre is closest to a
    /// point in frame pixels.
    private func nearestFace(to point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, face) in previewFaces.enumerated() {
            let distance = hypot(face.box.x + face.box.width / 2 - Double(point.x),
                                 face.box.y + face.box.height / 2 - Double(point.y))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Options the engine should use, assembled from the UI state.
    var swapOptions: SwapOptions {
        SwapOptions(selection: faceSelection,
                    identityStrength: identityStrength,
                    enhanceFace: enhanceFace && models.isInstalledModel(.faceEnhancer),
                    enhancementBlend: 0.8,
                    maskBlur: maskBlur,
                    maskOcclusion: maskOcclusion && models.isInstalledModel(.faceOccluder),
                    detectorScore: 0.5,
                    // Kept on for both source and target. The source identity is
                    // encoded once at selection time, so flipping this per job
                    // would align the two differently and weaken the match.
                    refineLandmarks: true)
    }

    // MARK: - Engine lifecycle

    func startEngineIfPossible() async {
        // `loadableModels`, not `isReady`: it is nil until the launch pass has
        // finished, and a library already in the digest-named scheme reads as
        // complete before that pass has run. Starting the engine there would set
        // Core ML compiling graphs into the very directory the pass may still
        // empty, from files it may still be renaming.
        guard let wanted = models.loadableModels else {
            EngineLog.client.notice(
                "engine not started: manifest=\(self.models.manifest == nil ? "missing" : "loaded", privacy: .public) required=\(self.models.requiredModels.count) missing=\(self.models.missingRequired.map(\.id).joined(separator: ","), privacy: .public) dir=\(ModelManager.modelsDirectory.path, privacy: .public)")
            return
        }
        EngineLog.client.notice("starting engine with \(self.models.installedPaths().count) model(s)")
        // Being ready is not on its own a reason to stop. The set on disk moves
        // under a live engine now that Settings can delete a model and download
        // it back, and a session built without the enhancer or the landmarker
        // does not fail when asked for one — the pipeline skips the stage. So
        // the question is not "is there an engine" but "is it running the models
        // that are actually installed"; when it is not, prepare again.
        if case .ready(let summary) = engine.state,
           Set(summary.loadedModels.compactMap(ModelID.init(rawValue:))) == wanted { return }
        do {
            // A second enhancer session lets two frames be restored at once
            // instead of queueing on one, which is worth roughly the enhancer's
            // share of a frame — but it is another ~340 MB of resident weights,
            // and on a device where jetsam is the ceiling that is a trade only
            // the larger phones can make.
            let tuning = EngineTuning(
                enhancerReplicas: DeviceCapabilities.isMemoryConstrained ? 1 : 2)
            try await engine.prepare(modelPaths: models.installedPaths(),
                                     cacheDirectory: ModelManager.compileCacheDirectory,
                                     compute: Preferences.shared.compute,
                                     tuning: tuning)
            statusMessage = nil
            // A source chosen before the engine was up still needs encoding.
            if sourceBuffer != nil, sourceFace == nil { await analyzeSource() }
            // A fresh engine holds no reference identities — `prepare` drops
            // them along with the sessions that produced them — so anything
            // the user had checked has to be sent again.
            if case .reference = faceSelection { await applyCheckedFaces() }
        } catch {
            EngineLog.client.error("engine prepare failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = error.localizedDescription
        }
    }

    /// Rebuilds every session, which is what a change of execution provider
    /// requires.
    ///
    /// The source face is forgotten first on purpose: new sessions hold no
    /// projected source identity, and clearing it here is what makes
    /// `startEngineIfPossible` encode it again rather than leaving every frame
    /// conditioned on nothing.
    func restartEngine() async {
        await engine.unloadModels()
        sourceFace = nil
        await startEngineIfPossible()
    }

    /// Brings the engine back on whatever survived a removal.
    ///
    /// Settings has already unloaded and deleted by the time this runs — that
    /// order is not negotiable, since a live session has the graphs memory-
    /// mapped — so this either loads what is left or does nothing at all.
    ///
    /// The identities collected from the target go too. They came out of the old
    /// recognizer session and — if the landmark refiner is what was removed —
    /// out of a different alignment, so comparing them against anything the new
    /// session produces would be comparing vectors from two different graphs.
    /// Clearing `sourceFace` is what makes the portrait be encoded again:
    /// `startEngineIfPossible` only re-encodes when it is nil, so leaving it set
    /// would bring the engine back with no source while the studio still said
    /// "Face ready." and left Export enabled.
    func restartEngineAfterModelRemoval() async {
        resetPeople()
        sourceFace = nil
        invalidatePreviewResult()
        await startEngineIfPossible()
    }

    /// Answers the app's memory warning by handing back what is merely nice to
    /// have. The enhancer is the largest model in the process by a wide margin,
    /// so a warning costs the render some sharpness rather than costing the user
    /// the app.
    func handleMemoryWarning() {
        engine.handleMemoryPressure()
        statusMessage = String(localized: "Memory was running low, so detail enhancement and occlusion masking have been switched off. They return the next time the engine starts.", bundle: .uiLanguage)
    }

    // MARK: - Choosing media

    // A file the user picked or dropped. Anything from outside the app's own
    // container arrives security-scoped: readable only between
    // `startAccessingSecurityScopedResource` and its matching stop. The access
    // is opened here rather than in the picker because it has to stay open for
    // as long as the media is loaded — a video is re-read for every preview
    // frame, for the scan, and again for the whole export — and it is closed
    // when the slot is cleared or replaced.

    func useSource(_ url: URL) async {
        await setSource(url)
    }

    func useTarget(_ url: URL) async {
        await setTarget(url)
    }

    /// A photo-library pick, which is not a file until it is asked to be one.
    ///
    /// The copy is deleted again when the slot is cleared or replaced, so the
    /// container does not accumulate a copy of every portrait ever tried.
    ///
    /// Order matters here, and the obvious order is wrong. The file currently in
    /// use is not deleted until the replacement has proved it can be decoded:
    /// `setSource` and `setTarget` catch their own failures and leave the
    /// previous selection in place, so discarding first is how the app ends up
    /// holding a `targetURL` whose bytes it has already unlinked — still
    /// showing the old preview frame, still reporting `canRender`, and failing
    /// on the first frame of the export with a file-not-found.
    func useSource(pickedItem item: PhotosPickerItem) async {
        guard let staged = await stageImport(item) else { return }
        let previous = importedSourceURL
        importedSourceURL = staged
        await setSource(staged)
        if sourceURL == staged {
            // The replacement took; the copy it replaced is dead weight.
            discard(previous)
        } else {
            // It could not be decoded. Keep whatever was working.
            discard(staged)
            importedSourceURL = previous
        }
    }

    func useTarget(pickedItem item: PhotosPickerItem) async {
        guard let staged = await stageImport(item) else { return }
        let previous = importedTargetURL
        importedTargetURL = staged
        await setTarget(staged)
        if targetURL == staged {
            discard(previous)
        } else {
            discard(staged)
            importedTargetURL = previous
        }
    }

    func setSource(_ url: URL) async {
        let access = ScopedFile(url)
        do {
            let buffer = try PixelSurface.loadImage(at: url)
            sourceAccess?.release()
            sourceAccess = access
            sourceURL = url
            sourceBuffer = buffer
            sourceFace = nil
            sourceFaceCount = 0
            statusMessage = nil
            await analyzeSource()
            invalidatePreviewResult()
        } catch {
            access.release()
            statusMessage = error.localizedDescription
        }
    }

    private func analyzeSource() async {
        guard let buffer = sourceBuffer else { return }
        guard case .ready = engine.state else { return }
        do {
            let analysis = try await engine.analyzeSource(buffer)
            sourceFace = analysis.face
            sourceFaceCount = analysis.faceCount
            statusMessage = nil
            await refreshPreview()
        } catch {
            sourceFace = nil
            statusMessage = error.localizedDescription
        }
    }

    func setTarget(_ url: URL) async {
        if Self.isImage(url) {
            await setImageTarget(url)
        } else {
            await setVideoTarget(url)
        }
    }

    private func setVideoTarget(_ url: URL) async {
        let access = ScopedFile(url)
        do {
            let info = try await VideoPipeline.inspect(url)
            resetPeople()
            targetAccess?.release()
            targetAccess = access
            targetURL = url
            target = .video(info)
            previewTime = min(1.0, max(0, info.durationSeconds / 4))
            statusMessage = nil
            phase = .choosingMedia
            await loadPreviewFrame()
        } catch {
            access.release()
            statusMessage = error.localizedDescription
        }
    }

    private func setImageTarget(_ url: URL) async {
        let access = ScopedFile(url)
        do {
            // Full resolution: unlike the source portrait — which only ever
            // feeds a 112px crop — this is what gets written back out, so
            // shrinking it would quietly downgrade the export. It is also why
            // a photo is the one preview that is not capped: for a single
            // frame the saving would be small, and the exported file is this
            // buffer swapped again.
            let buffer = try PixelSurface.loadImage(at: url, maximumDimension: .max)
            resetPeople()
            targetAccess?.release()
            targetAccess = access
            targetURL = url
            target = .image(size: CGSize(width: CVPixelBufferGetWidth(buffer),
                                         height: CVPixelBufferGetHeight(buffer)),
                            format: url.pathExtension.uppercased())
            previewTime = 0
            previewFrame = buffer
            statusMessage = nil
            phase = .choosingMedia
            invalidatePreviewResult()
            await detectPreviewFaces()
            await refreshPreview()
            // The same rule as entering the mode by hand: a photo is one frame,
            // so finding its people is instant and asking for a button press
            // would be ceremony. A video stays a deliberate act.
            if faceMode == .chosen, !hasScanned { scanTargetForPeople() }
        } catch {
            access.release()
            statusMessage = error.localizedDescription
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        // Fall back to the extension when the metadata cannot be read, which
        // is exactly when the first answer is least trustworthy.
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = declared ?? UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image) && !type.conforms(to: .movie)
    }

    /// A drop onto the window as a whole, where the file has to speak for
    /// itself. Videos are unambiguous; a photo could be either role, so it
    /// fills the empty slot and otherwise replaces the face — swapping in a
    /// different face is the far more common second move.
    func handleDrop(_ url: URL) async {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .movie) || type.conforms(to: .video) {
            await useTarget(url)
        } else if let type, type.conforms(to: .image) {
            if sourceBuffer != nil, target == nil {
                await useTarget(url)
            } else {
                await useSource(url)
            }
        } else {
            statusMessage = String(localized: "That file type is not supported.", bundle: .uiLanguage)
        }
    }

    func clearSource() {
        sourceURL = nil; sourceBuffer = nil; sourceFace = nil; sourceFaceCount = 0
        sourceAccess?.release(); sourceAccess = nil
        discardImportedSource()
        invalidatePreviewResult()
    }

    func clearTarget() {
        targetURL = nil; target = nil; previewFrame = nil
        previewFaces = []
        targetAccess?.release(); targetAccess = nil
        discardImportedTarget()
        resetPeople()
        invalidatePreviewResult()
        phase = .choosingMedia
    }

    /// Identities are only meaningful against the target they were collected
    /// from, so a new target starts over.
    ///
    /// Starting over means an empty set under a *new* generation, not leaving
    /// the mode. Dropping back to one-face here would mean a new target
    /// silently changed what the app is about to do — and since *Choose* is the
    /// default, it would be impossible to keep. The empty set is what stops the
    /// old identities being matched against people who are not in this video.
    private func resetPeople() {
        scanTask?.cancel()
        scanTask = nil
        people = []
        checkedPeople = []
        previewIdentities = []
        scanProgress = nil
        hasScanned = false
        if case .reference = faceSelection {
            Task { await applyCheckedFaces() }
        }
    }

    // MARK: - Imports

    /// Where redeemed photo-library items are kept: a sibling of the exports
    /// folder, so both live under one directory the app can sweep.
    nonisolated static var importsDirectory: URL {
        MediaStore.exportsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Imports", isDirectory: true)
    }

    /// Copies a materialised library item into `Imports` and hands back the
    /// URL. Called from the transfer representation below, off the main actor.
    nonisolated fileprivate static func stageImportedFile(_ file: URL) throws -> URL {
        let directory = importsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The original name is kept as a suffix because the extension is load
        // bearing — `setTarget` decides photo or video from it, and both
        // decoders want it — and prefixed with a UUID so two picks of the same
        // asset cannot collide.
        let name = "\(UUID().uuidString)-\(file.lastPathComponent)"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    private func stageImport(_ item: PhotosPickerItem) async -> URL? {
        do {
            guard let imported = try await item.loadTransferable(type: ImportedFile.self) else {
                statusMessage = String(localized: "That item could not be read from your photo library.", bundle: .uiLanguage)
                return nil
            }
            return imported.url
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// Deletes every staged import. Only ever correct at launch, when by
    /// definition none of them is in use.
    nonisolated static func clearStaleImports() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
                at: importsDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? manager.removeItem(at: entry) }
    }

    /// Deletes one staged import, if there is one. Separate from the two
    /// slot-clearing helpers because replacing a slot has to delete a specific
    /// copy — the outgoing one, or the incoming one that failed — rather than
    /// whichever the slot happens to point at now.
    private func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func discardImportedSource() {
        discard(importedSourceURL)
        importedSourceURL = nil
    }

    private func discardImportedTarget() {
        discard(importedTargetURL)
        importedTargetURL = nil
    }

    // MARK: - Preview

    /// Debounces scrubbing so dragging the slider does not queue a decode per
    /// pixel of travel.
    private func schedulePreviewFrameReload() {
        previewFrameTask?.cancel()
        previewFrameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadPreviewFrame()
        }
    }

    private func loadPreviewFrame() async {
        // A photo target has no timeline: its single frame is decoded once,
        // when it is chosen.
        guard let url = targetURL, !targetIsImage else { return }
        do {
            let time = CMTime(seconds: previewTime, preferredTimescale: 600)
            // Bounded, unlike the export's own decode. The seek stays exact —
            // scrubbing to a moment and being shown a different one is worse
            // than the decode being slower.
            let frame = try await VideoPipeline.frame(
                at: time, in: url, maximumDimension: Self.previewMaximumDimension)
            guard !Task.isCancelled else { return }
            previewFrame = frame
            invalidatePreviewResult()
            await detectPreviewFaces()
            await refreshPreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func detectPreviewFaces() async {
        guard let frame = previewFrame, case .ready = engine.state else { return }
        do {
            if faceSelection.needsIdentities {
                let analysis = try await engine.analyzeFaces(frame, options: analysisOptions)
                previewFaces = analysis.faces
                previewIdentities = analysis.identities
            } else {
                // The overlay only needs boxes here, and the recognizer is a
                // model pass per face — not worth paying on every scrub.
                previewFaces = try await engine.detectFaces(frame).faces
                previewIdentities = []
            }
        } catch {
            previewFaces = []
            previewIdentities = []
        }
    }

    private func invalidatePreviewResult() {
        previewResult = nil
        showsOriginal = false
    }

    /// Runs the swap on just the visible frame. This is the fast feedback loop:
    /// it takes about as long as one frame of an export, so settings can be
    /// judged before committing to a full render.
    ///
    /// A preview can be a second long, and the main actor is free for all of it,
    /// so by the time one finishes the world may have moved: a newer preview may
    /// have superseded it, or the user may have pressed Export. Cancellation
    /// alone does not cover either case — a swap already inside the engine runs
    /// to completion regardless — so the task carries the generation it was
    /// started under and publishes nothing unless it is still the current one.
    func refreshPreview() async {
        guard sourceFace != nil, let frame = previewFrame, !isRendering else { return }
        guard case .ready = engine.state else { return }

        previewSwapTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let options = swapOptions
        previewSwapTask = Task { [weak self] in
            guard let self else { return }
            // Counted rather than a flag the newest task owns. A superseded
            // preview must not switch the pill off while its replacement is
            // still running — but keying that on the generation instead strands
            // the pill on forever whenever the generation moves without a new
            // task behind it, which is exactly what `export()` does when it
            // cancels an outstanding preview. Counting is the shape that
            // survives both: the pill is on while any swap is in flight.
            self.previewsInFlight += 1
            defer {
                self.previewsInFlight -= 1
                self.isPreviewing = self.previewsInFlight > 0
            }
            self.isPreviewing = true
            do {
                let width = CVPixelBufferGetWidth(frame)
                let height = CVPixelBufferGetHeight(frame)
                let output = try PixelSurface.makeBuffer(width: width, height: height)
                _ = try await self.engine.swap(frame, into: output, options: options)
                // `!isRendering` is the one that matters: an export started
                // while this was inside the engine, and assigning `.ready` here
                // would tear the render out of `.rendering` — taking the
                // progress bar and the Cancel button with it — while the export
                // carried on writing frames in the background.
                guard !Task.isCancelled,
                      generation == self.previewGeneration,
                      !self.isRendering else { return }
                self.previewResult = output
                self.phase = .ready
            } catch is CancellationError {
                // Superseded by a newer preview.
            } catch {
                guard generation == self.previewGeneration, !self.isRendering else { return }
                self.statusMessage = error.localizedDescription
            }
        }
        await previewSwapTask?.value
    }

    /// Picks whichever detected face is nearest the tap, in normalised
    /// coordinates so it survives the canvas being resized or the device being
    /// rotated.
    func selectFace(atNormalized point: CGPoint) {
        if case .reference = faceSelection {
            toggleFace(atNormalized: point)
            return
        }
        faceSelection = .nearestTo(x: Double(point.x), y: Double(point.y))
        Task { await refreshPreview() }
    }

    func selectAllFaces() {
        faceSelection = .all
        previewIdentities = []
        Task { await refreshPreview() }
    }

    /// Switches to single-face mode. Defaults to the largest face, which is
    /// almost always the subject, until the user taps a different one.
    func selectSingleFace() {
        faceSelection = .largest
        previewIdentities = []
        Task { await refreshPreview() }
    }

    func setFaceMode(_ mode: FaceMode) {
        switch mode {
        case .everyFace:
            selectAllFaces()
        case .oneFace:
            selectSingleFace()
        case .chosen:
            Task {
                // Entering the mode first, with whatever is checked (nothing,
                // at the start), so the picker appears immediately and can
                // explain itself rather than the segment silently not taking.
                await applyCheckedFaces()
                // A photo is one frame, so finding its people is instant and
                // waiting for a button press would be pure ceremony. A video
                // is not, so that one stays a deliberate act.
                if !hasScanned, targetIsImage { scanTargetForPeople() }
            }
        }
    }

    // MARK: - Choosing faces

    /// Finds the distinct people in the target so they can be checked off.
    func scanTargetForPeople() {
        guard case .ready = engine.state else {
            statusMessage = String(localized: "The engine is still starting.", bundle: .uiLanguage)
            return
        }
        guard let target else { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            self.statusMessage = nil
            self.scanProgress = FaceScanner.ScanProgress(framesScanned: 0,
                                                         totalFrames: 1,
                                                         peopleFound: 0)
            defer { self.scanProgress = nil }

            do {
                let found: [FaceScanner.Person]
                switch target {
                case .image:
                    guard let frame = self.previewFrame else { return }
                    found = try await FaceScanner.scan(photo: frame,
                                                       engine: self.engine,
                                                       options: self.analysisOptions)
                case .video(let info):
                    guard let url = self.targetURL else { return }
                    found = try await FaceScanner.scan(video: url,
                                                       duration: info.durationSeconds,
                                                       engine: self.engine,
                                                       options: self.analysisOptions) { update in
                        self.scanProgress = update
                    }
                }
                guard !Task.isCancelled else { return }

                self.people = found
                self.hasScanned = true
                // Nothing checked reads as "replace nobody", which is a
                // baffling thing to land on after a scan. The most prominent
                // person is who a single-face swap would have picked anyway.
                self.checkedPeople = found.first.map { Set([$0.id]) } ?? []
                await self.applyCheckedFaces()
            } catch is CancellationError {
                // Superseded, or the target changed underneath the scan.
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanProgress = nil
    }

    func togglePerson(_ id: Int) {
        if checkedPeople.contains(id) {
            checkedPeople.remove(id)
        } else {
            checkedPeople.insert(id)
        }
        Task { await applyCheckedFaces() }
    }

    func checkEveryPerson() {
        checkedPeople = Set(people.map(\.id))
        Task { await applyCheckedFaces() }
    }

    func uncheckEveryPerson() {
        checkedPeople = []
        Task { await applyCheckedFaces() }
    }

    /// Re-runs the preview against a changed match threshold. Cheap: the
    /// identities are already computed, only the comparison changes.
    func applyMatchDistance() async {
        guard case .reference(let generation, _) = faceSelection else { return }
        faceSelection = .reference(generation: generation, maxDistance: matchDistance)
        await refreshPreview()
    }

    /// Sends the checked identities to the engine and points the selection at
    /// them.
    ///
    /// Every push takes a new generation, so a swap that names an older one is
    /// refused by the engine rather than run against a set that has moved on.
    private func applyCheckedFaces() async {
        referenceGeneration += 1
        let generation = referenceGeneration
        // The mode takes effect even while the engine is still starting, so
        // the segmented control does not silently snap back. `startEngine`
        // pushes the set again once there is something to push it to.
        faceSelection = .reference(generation: generation, maxDistance: matchDistance)
        guard case .ready = engine.state else { return }
        do {
            try await engine.setReferenceFaces(
                ReferenceFaceSet(generation: generation, identities: checkedIdentities))
            invalidatePreviewResult()
            await detectPreviewFaces()
            await refreshPreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// A tap on the canvas while choosing faces checks or unchecks whoever was
    /// tapped — the same gesture as ticking their thumbnail.
    ///
    /// A face that matches nobody found so far is added rather than rejected.
    /// The scan samples the video, so it can miss someone who is only briefly
    /// on screen, and pointing at them is the obvious repair.
    private func toggleFace(atNormalized point: CGPoint) {
        guard let frame = previewFrame,
              previewIdentities.count == previewFaces.count,
              !previewFaces.isEmpty else { return }

        let location = CGPoint(x: point.x * CGFloat(CVPixelBufferGetWidth(frame)),
                               y: point.y * CGFloat(CVPixelBufferGetHeight(frame)))
        guard let index = nearestFace(to: location) else { return }
        let identity = previewIdentities[index]

        let nearest = people.min {
            $0.identity.distance(to: identity) < $1.identity.distance(to: identity)
        }
        if let nearest, nearest.identity.distance(to: identity) <= matchDistance {
            togglePerson(nearest.id)
        } else {
            addPerson(previewFaces[index], identity: identity)
        }
    }

    private func addPerson(_ face: DetectedFace, identity: FaceIdentity) {
        guard let frame = previewFrame else { return }
        let frameArea = Double(CVPixelBufferGetWidth(frame) * CVPixelBufferGetHeight(frame))
        let id = (people.map(\.id).max() ?? -1) + 1

        people.append(FaceScanner.Person(
            id: id,
            identity: identity,
            thumbnail: FaceScanner.thumbnail(from: frame, box: face.box),
            appearances: 1,
            firstSeen: previewTime,
            lastSeen: previewTime,
            coverage: frameArea > 0 ? (face.box.width * face.box.height) / frameArea : 0))
        checkedPeople.insert(id)
        hasScanned = true
        Task { await applyCheckedFaces() }
    }

    // MARK: - Export

    /// Renders the whole target with the settings as they stand now.
    ///
    /// There is no save panel to choose a destination in, so the render lands in
    /// a temporary file the app owns and `.finished` carries its URL. Where it
    /// goes after that is the user's next decision — Photos, Files, or a share
    /// sheet — and all three only need a valid file.
    func export() async {
        guard let targetURL, sourceFace != nil else { return }
        let isImage = targetIsImage

        guard purchases.isPro else {
            statusMessage = String(localized: "Exporting is a Pro feature. Upgrade to continue.", bundle: .uiLanguage)
            phase = .ready
            return
        }

        // PNG for a photo rather than the original format: a re-encoded JPEG
        // would lose a second generation of detail on a file the user is
        // keeping. Videos are always MP4, which is what the writer produces.
        let destination = MediaStore.makeOutputURL(basedOn: targetURL,
                                                   isImage: isImage,
                                                   png: isImage)

        // A preview may be inside the engine right now, and it would finish into
        // a world where a render has started. Cancelling it does not stop the
        // swap — the engine checks cancellation on entry, not mid-frame — but it
        // does bump the generation `refreshPreview` publishes against, so the
        // late result is discarded rather than applied over the render's state.
        previewSwapTask?.cancel()
        previewGeneration += 1

        phase = .rendering
        progress = ExportProgress(framesWritten: 0,
                                  totalFrames: isImage ? 1 : (targetInfo?.estimatedFrameCount ?? 0),
                                  framesPerSecond: 0,
                                  facesSwappedInLastFrame: 0)
        statusMessage = nil
        finishedIsInPhotos = false

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if isImage {
                    try await self.exportStillImage(to: destination)
                } else {
                    let request = VideoPipeline.ExportRequest(source: targetURL,
                                                              destination: destination,
                                                              options: self.swapOptions,
                                                              useHEVC: self.useHEVC)
                    try await VideoPipeline.export(request, engine: self.engine) { update in
                        self.progress = update
                    }
                }
                self.phase = .finished(destination)
                // The preference is what the user already said they wanted
                // done with a finished render; the result bar's own button is
                // then a no-op that says so rather than a second copy.
                if purchases.isPro && Preferences.shared.savesToPhotos {
                    await self.saveFinishedToPhotos()
                }
            } catch is CancellationError {
                self.phase = .ready
                self.statusMessage = String(localized: "Export cancelled.", bundle: .uiLanguage)
                try? FileManager.default.removeItem(at: destination)
            } catch {
                self.phase = .failed(error.localizedDescription)
                try? FileManager.default.removeItem(at: destination)
            }
        }
        exportTask = task
        await task.value
    }

    /// The photo path. The frame is swapped again rather than reusing what the
    /// preview produced, so the exported file always reflects the settings as
    /// they stand now and is written at the image's own resolution.
    func exportStillImage(to destination: URL) async throws {
        guard let frame = previewFrame else {
            throw MediaError.decode(String(localized: "The photo is no longer loaded.", bundle: .uiLanguage))
        }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let output = try PixelSurface.makeBuffer(width: width, height: height)

        let result = try await engine.swap(frame, into: output, options: swapOptions)
        try Task.checkCancellation()
        try PixelSurface.write(output, to: destination)

        previewResult = output
        progress = ExportProgress(framesWritten: 1,
                                  totalFrames: 1,
                                  framesPerSecond: 0,
                                  facesSwappedInLastFrame: result.facesSwapped)
    }

    /// Copies the finished render into the photo library.
    ///
    /// Add-only permission is asked for at this point rather than at launch: it
    /// is the first moment the request means anything, and a prompt that
    /// arrives with a finished video behind it explains itself.
    func saveFinishedToPhotos() async {
        guard purchases.isPro else {
            statusMessage = String(localized: "Saving and sharing results is a Pro feature. Upgrade to continue.", bundle: .uiLanguage)
            return
        }
        guard case .finished(let url) = phase else { return }
        guard !isSavingToPhotos else { return }
        guard !finishedIsInPhotos else {
            statusMessage = String(localized: "That render is already in your photo library.", bundle: .uiLanguage)
            return
        }

        isSavingToPhotos = true
        defer { isSavingToPhotos = false }

        guard await MediaStore.requestAddPermission() else {
            statusMessage = String(localized: "Morphiqo needs permission to add to your photo library. You can grant it in Settings, or save to Files instead.", bundle: .uiLanguage)
            return
        }
        do {
            if targetIsImage {
                try await MediaStore.saveImageToPhotos(url)
            } else {
                try await MediaStore.saveVideoToPhotos(url)
            }
            finishedIsInPhotos = true
            statusMessage = String(localized: "Saved to your photo library.", bundle: .uiLanguage)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
    }

    func dismissResult() {
        phase = .ready
        progress = nil
    }
}

// MARK: - Picked files

/// A file copied out of the photo library.
///
/// A `PhotosPickerItem` is not a file: it is a promise the library will
/// materialise on request, and for an iCloud asset that may mean downloading it
/// first. Everything downstream — `AVURLAsset`, `CIImage(contentsOf:)`, the
/// export's reader — needs a real URL, so the promise is redeemed once, into a
/// folder the app owns, and nothing else in the app has to know where a file
/// came from.
///
/// A file representation rather than `Data`: a two-gigabyte clip should reach
/// the disk without passing through memory on the way.
private struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            ImportedFile(url: try AppModel.stageImportedFile(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            ImportedFile(url: try AppModel.stageImportedFile(received.file))
        }
    }
}

/// A file outside the app's container, readable only while access is held.
///
/// A URL from the document picker is security-scoped: reading it without
/// `startAccessingSecurityScopedResource` fails with a permission error that
/// looks exactly like a corrupt file. The two calls must balance, hence the
/// recorded flag — `stopAccessing` on a URL that never needed scoping, or one
/// that failed to start, unbalances the count for whoever else holds it.
private struct ScopedFile {
    let url: URL
    private let isScoped: Bool

    init(_ url: URL) {
        self.url = url
        isScoped = url.startAccessingSecurityScopedResource()
    }

    func release() {
        if isScoped { url.stopAccessingSecurityScopedResource() }
    }
}

extension ModelManager {
    /// Convenience for checking a single optional model by id.
    func isInstalledModel(_ id: ModelID) -> Bool {
        states[id.rawValue] == .installed
    }
}
