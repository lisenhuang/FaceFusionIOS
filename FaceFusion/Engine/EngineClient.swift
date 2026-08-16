//
//  EngineClient.swift
//  FaceFusion
//
//  The engine and the app's view of it, in one file — because on iOS they are
//  in one process.
//
//  macOS put inference behind an XPC service so that half a gigabyte of model
//  weights never landed in the UI's address space and a fault inside ONNX
//  Runtime took down a restartable helper instead of the app. Third-party apps
//  on iOS have no XPC services, so the models live here, in the app. Two costs
//  of the old design leave with the process boundary and are simply gone:
//  frames no longer have to be `IOSurface`s handed across by reference, and
//  options no longer have to be JSON re-encoded per frame. A `CVPixelBuffer`
//  goes in and a `CVPixelBuffer` comes out.
//
//  What survives is the part that was never about IPC: a concurrent queue on
//  which inference runs in parallel, with anything that *replaces* engine state
//  running as a barrier. ONNX Runtime allows concurrent `Run` calls on one
//  session, and the stages of a frame land on different hardware — the swapper
//  and enhancer on the GPU, the surrounding pixel work on the CPU — so letting
//  several frames overlap keeps both busy instead of leaving each idle while
//  the other works. It measured 1.8x end to end on the Mac.
//
//  The one thing the helper process bought that cannot be replaced is crash
//  isolation. `handleMemoryPressure()` is the partial answer: the app cannot
//  survive a fault inside ORT, but it can survive a jetsam warning by handing
//  the enhancer's weights back and finishing the render with a softer face.
//

import Foundation
import CoreVideo
import Observation
import os

// MARK: - The engine

/// What the engine is allowed to do to the on-disk library when a preparation
/// fails, handed in rather than reached for.
///
/// The engine is given a cache directory to compile into and knows nothing about
/// the library that owns it — which is right, and worth keeping right, because
/// the same engine is driven by the app's normal start and by the benchmark.
/// These three closures are the whole of the exception: two marks either side of
/// a compile, and a verification pass that is only ever run after everything
/// cheaper has already failed.
struct EngineRecoveryHooks: Sendable {
    var compileStarted: @Sendable () -> Void
    var compileFinished: @Sendable () -> Void
    /// Re-hashes the installed models, deletes the ones whose bytes no longer
    /// match the manifest, and answers with their ids.
    var verifyInstalledModels: @Sendable () -> [String]
}

/// In-process engine. Everything below the `async` surface is synchronous work
/// on `queue`; nothing here touches the main actor.
final class FaceFusionEngine: @unchecked Sendable {

    private let pipeline = SwapPipeline()

    private let recovery: EngineRecoveryHooks

    /// Whether the compiled-graph cache has already been thrown away and rebuilt
    /// once for this engine — which is once per process, since the app builds
    /// exactly one.
    ///
    /// The guard is not a nicety. A model file that genuinely cannot produce a
    /// working session would otherwise wipe the cache, recompile every graph and
    /// fail again on *every* launch, turning a bug that costs a re-download into
    /// one that costs the battery. Read and written only from inside the barrier
    /// block, so it needs no lock.
    private var recoveredThisProcess = false

    init(recovery: EngineRecoveryHooks) {
        self.recovery = recovery
    }

    /// Concurrent, with barriers for anything that mutates engine state.
    ///
    /// `prepare`, `analyzeSource`, `setReferenceFaces`, `unloadModels` and the
    /// memory-pressure unload replace the loaded models, the cached source
    /// identity or the reference set, so they run as barriers: no swap can be
    /// in flight while the ground shifts under it. Everything else — detection,
    /// analysis, swapping — only reads that state and runs concurrently.
    private let queue = DispatchQueue(label: "com.lisenhuang.FaceFusion.engine",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    // MARK: Lifecycle

    func prepare(_ config: EngineConfiguration) async throws -> EnginePreparation {
        EngineLog.engine.info(
            "preparing with \(config.modelPaths.count) model(s), compute=\(config.compute.rawValue, privacy: .public)")
        do {
            let preparation = try await perform(barrier: true) {
                try self.prepareOrRecover(config)
            }
            EngineLog.engine.info(
                "ready via \(preparation.executionProvider, privacy: .public) in \(preparation.warmupSeconds, format: .fixed(precision: 2))s")
            return preparation
        } catch {
            EngineLog.engine.error(
                "prepare failed: \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
            throw error
        }
    }

    /// Prepares, and repairs itself if that fails.
    ///
    /// Everything here is inside one barrier block, and that is the point rather
    /// than an implementation detail. No session is live while the compiled
    /// graphs are deleted, no frame is part-way through reading a graph that is
    /// about to stop existing, and no second `prepare` can slip between the two
    /// attempts and rebuild sessions against a directory this one is emptying.
    /// Doing the same thing from a caller would give up all three, and there are
    /// two callers — the app's normal start and the benchmark — so it would have
    /// to be done twice and stay right in both.
    ///
    /// The repair is deliberately indifferent to *why* the preparation failed.
    /// ORT reuses a compiled Core ML artifact by existence alone: no integrity
    /// check, no OS version and no runtime version in the cache key, and a
    /// non-atomic directory copy to produce it. A system update that invalidated
    /// what an older Core ML wrote, an artifact torn by a process kill and a
    /// half-written file all present as the same thing — a load that throws on
    /// every launch, for good, while Settings reports a complete and healthy
    /// library. Throwing the derived state away and building it again answers
    /// all of them, and nothing in the app did it before.
    private func prepareOrRecover(_ config: EngineConfiguration) throws -> EnginePreparation {
        // Bracketed around both attempts, and around the failure path too: what
        // this marks is "graphs may be half-written in that directory", which is
        // true from the first session until the last one is built or given up
        // on. `defer` rather than a matched call per exit, because the one exit
        // that must not miss it is the one that throws.
        recovery.compileStarted()
        defer { recovery.compileFinished() }

        do {
            return try pipeline.prepare(config)
        } catch {
            // The original text, kept whole: it is the only description of what
            // actually went wrong, and the second attempt either replaces it
            // with a success or with a different error.
            let original = error.localizedDescription
            let originalDetail = String(describing: error)

            guard !recoveredThisProcess else {
                EngineLog.engine.error(
                    "prepare failed and the compiled graph cache has already been rebuilt this run; not trying again: \(original, privacy: .public) [\(originalDetail, privacy: .public)]")
                throw error
            }
            recoveredThisProcess = true

            EngineLog.engine.error(
                "prepare failed, rebuilding the compiled graph cache and retrying once: \(original, privacy: .public) [\(originalDetail, privacy: .public)]")

            // Everything the pipeline holds, not just what failed: a partly
            // built set of sessions has some graphs mapped out of the directory
            // that is about to go, and the retry has to start from nothing
            // anyway.
            pipeline.unloadAll()
            Self.emptyCompileCache(at: config.modelCacheDirectory)

            do {
                let preparation = try pipeline.prepare(config)
                EngineLog.engine.notice(
                    "recovered: prepare succeeded after the compiled graph cache was rebuilt (first attempt: \(original, privacy: .public))")
                return preparation
            } catch {
                // Second stage, and the only moment the cost is justified: the
                // graphs were not the problem, so the files they are compiled
                // from are the next suspect. Re-hashing 900 MB is seconds of
                // `read` — unthinkable on every launch, cheap against a library
                // the user would otherwise be told to remove and fetch again in
                // full. Only what fails to verify is deleted, so the ordinary
                // download path re-fetches one model rather than six.
                pipeline.unloadAll()
                let discarded = recovery.verifyInstalledModels()
                EngineLog.engine.error(
                    """
                    prepare failed again after rebuilding the compiled graph cache: \
                    \(error.localizedDescription, privacy: .public) \
                    [\(String(describing: error), privacy: .public)] \
                    (first attempt: \(original, privacy: .public)); \
                    model files discarded as corrupt: \
                    \(discarded.isEmpty ? "none" : discarded.joined(separator: ","), privacy: .public)
                    """)
                throw error
            }
        }
    }

    /// Deletes the compiled-graph directory and puts an empty one back.
    ///
    /// Recreated rather than left for `SwapPipeline.prepare` to make: the
    /// directory being absent and the directory being empty are the same thing
    /// to ORT, but not to a reader of the file system, and a cache directory
    /// that briefly does not exist is exactly the state the app is careful to
    /// avoid everywhere else.
    private static func emptyCompileCache(at path: String) {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        // A directory that is not there is a failure only in `removeItem`'s
        // sense of the word — it is the state this is trying to reach.
        try? fileManager.removeItem(at: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            EngineLog.engine.notice(
                "emptied the compiled graph cache before retrying")
        } catch {
            EngineLog.engine.error(
                "could not empty the compiled graph cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unloadModels() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async(flags: .barrier) {
                self.pipeline.unloadAll()
                continuation.resume()
            }
        }
    }

    /// Answers a `UIApplication` memory warning.
    ///
    /// Deliberately not `async` and deliberately fire-and-forget: the system
    /// wants the memory back now, not after the three frames already inside the
    /// engine have finished. The work is queued as a barrier, so it lands
    /// between frames rather than underneath one.
    func handleMemoryPressure() {
        queue.async(flags: .barrier) {
            self.pipeline.memoryPressureUnloadOptional()
        }
    }

    // MARK: Analysis

    /// A barrier: it replaces the cached source identity that every in-flight
    /// swap is conditioning on.
    func analyzeSource(_ buffer: CVPixelBuffer,
                       refineLandmarks: Bool = true,
                       selecting index: Int? = nil) async throws -> SourceAnalysis {
        try Self.requireBGRA(buffer, "source")
        return try await perform(barrier: true) {
            try BGRAImage.wrapping(buffer, readOnly: true) { image in
                try self.pipeline.analyzeSource(image,
                                                refineLandmarks: refineLandmarks,
                                                selecting: index)
            }
        }
    }

    func detectFaces(_ buffer: CVPixelBuffer) async throws -> FrameAnalysis {
        try Self.requireBGRA(buffer, "frame")
        return try await perform {
            try BGRAImage.wrapping(buffer, readOnly: true) { image in
                try self.pipeline.detectFaces(in: image)
            }
        }
    }

    func analyzeFaces(_ buffer: CVPixelBuffer,
                      options: AnalysisOptions) async throws -> FrameAnalysis {
        try Self.requireBGRA(buffer, "frame")
        return try await perform {
            try BGRAImage.wrapping(buffer, readOnly: true) { image in
                try self.pipeline.analyzeFaces(in: image, options: options)
            }
        }
    }

    /// A barrier: the set it replaces is read by every in-flight swap.
    func setReferenceFaces(_ set: ReferenceFaceSet) async {
        EngineLog.engine.info(
            "reference faces: generation \(set.generation) with \(set.identities.count) identity(s)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async(flags: .barrier) {
                self.pipeline.setReferenceFaces(set)
                continuation.resume()
            }
        }
    }

    // MARK: Swapping

    func swap(_ input: CVPixelBuffer,
              into output: CVPixelBuffer,
              options: SwapOptions) async throws -> SwapResult {
        // An export keeps several frames inside the engine and cancels all of
        // them at once when the user gives up; the cheapest frame to cancel is
        // the one that has not started.
        try Task.checkCancellation()

        try Self.requireBGRA(input, "input")
        try Self.requireBGRA(output, "output")
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        guard width == CVPixelBufferGetWidth(output),
              height == CVPixelBufferGetHeight(output) else {
            throw makeEngineNSError(.invalidSurface,
                                    underlying: "size mismatch \(width)x\(height) vs \(CVPixelBufferGetWidth(output))x\(CVPixelBufferGetHeight(output))")
        }

        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await perform(cancellation: cancellation) {
                try BGRAImage.wrapping(input, readOnly: true) { source in
                    try BGRAImage.wrapping(output, readOnly: false) { destination in
                        try self.pipeline.swap(input: source, output: destination, options: options)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: Bridging

    /// Mirrors a task's cancellation into something a `DispatchQueue` block can
    /// read.
    ///
    /// This exists because of a trap: `Task.isCancelled` answers about the
    /// *current* task, and a block running on a dispatch queue has no current
    /// task, so it would read `false` forever no matter what the caller did.
    /// The entry check in `swap` catches frames cancelled before they were
    /// submitted; this catches the ones that were sitting behind two other
    /// frames and a barrier when the user pressed Cancel, which on a phone is
    /// most of them.
    private final class CancellationFlag: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { state.withLock { $0 } }
        func cancel() { state.withLock { $0 = true } }
    }

    /// Runs `body` on the queue and bridges it to `async`.
    ///
    /// XPC could fire either a reply block or an error handler, so the Mac
    /// client had to guard against resuming a continuation twice; there is only
    /// one completion path left here. The guard stays anyway — it costs one
    /// uncontended lock, and a double resume traps and takes the whole app with
    /// it, which is not a failure mode worth economising on.
    private func perform<T>(barrier: Bool = false,
                            cancellation: CancellationFlag? = nil,
                            _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<T, Error>) {
                let alreadyResumed = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            let work: () -> Void = {
                if cancellation?.isCancelled == true {
                    return finish(.failure(CancellationError()))
                }
                finish(Result(catching: { try body() }))
            }
            if barrier {
                self.queue.async(flags: .barrier, execute: work)
            } else {
                self.queue.async(execute: work)
            }
        }
    }

    /// The pipeline addresses pixels as B, G, R, A at ascending addresses and
    /// nothing downstream re-checks that. A camera or decoder buffer in any
    /// other format would be read as noise and produce a frame with no faces in
    /// it rather than an error, so it is refused here.
    private static func requireBGRA(_ buffer: CVPixelBuffer, _ label: String) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else {
            throw makeEngineNSError(.invalidSurface,
                                    underlying: "\(label) is not 32BGRA (got \(format))")
        }
    }
}

// MARK: - The app's view of it

/// What the UI observes: engine readiness, and the same calls the macOS client
/// offered.
///
/// Main-actor bound because it is view state, not because the work is: every
/// method below suspends into `FaceFusionEngine`, which is `nonisolated`, so
/// awaiting a swap does not park the main thread.
@MainActor
@Observable
final class EngineClient {

    enum State: Equatable {
        case idle
        case preparing
        case ready(EnginePreparationSummary)
        case failed(String)
    }

    struct EnginePreparationSummary: Equatable {
        var executionProvider: String
        var usingCoreML: Bool
        var loadedModels: [String]
        /// How long loading and compiling took. Worth showing: the first launch
        /// after an install pays for Core ML's compile, every launch after that
        /// reads the cache, and a user who sees thirty seconds once and two
        /// seconds afterwards has not hit a bug.
        var warmupSeconds: Double
    }

    private(set) var state: State = .idle

    /// The library's side of the recovery is bound here, at the one place that
    /// owns both: `ModelManager`'s statics know where the record and the model
    /// files are, and the engine only knows the directory it was handed.
    private let engine = FaceFusionEngine(recovery: EngineRecoveryHooks(
        compileStarted: ModelManager.markCompileStarted,
        compileFinished: ModelManager.markCompileFinished,
        verifyInstalledModels: ModelManager.verifyInstalledModels))

    /// Which models the running sessions were actually built from, or `nil`
    /// while there are no sessions.
    ///
    /// The set and the library's set are not the same question. An optional
    /// model that fails to load is skipped and logged — the pipeline runs
    /// without it rather than failing the launch — so the file can be installed
    /// and the stage silently absent, which is a face that never gets enhanced
    /// and a toggle that does nothing. `nil` rather than an empty set while the
    /// engine is idle or preparing, so a caller can tell "not loaded" from
    /// "nothing is loaded yet" and say the second thing instead of the first.
    var loadedModels: Set<ModelID>? {
        guard case .ready(let summary) = state else { return nil }
        return Set(summary.loadedModels.compactMap(ModelID.init(rawValue:)))
    }

    // MARK: Lifecycle

    func prepare(modelPaths: [ModelID: String],
                 cacheDirectory: URL,
                 compute: ComputePolicy,
                 tuning: EngineTuning = EngineTuning()) async throws {
        state = .preparing
        do {
            let config = EngineConfiguration(modelPaths: modelPaths,
                                             modelCacheDirectory: cacheDirectory.path,
                                             compute: compute,
                                             tuning: tuning)
            let result = try await engine.prepare(config)
            state = .ready(EnginePreparationSummary(
                executionProvider: result.executionProvider,
                usingCoreML: result.usingCoreML,
                loadedModels: result.loadedModels.map(\.rawValue),
                warmupSeconds: result.warmupSeconds))
        } catch {
            // Not logged again here: `FaceFusionEngine.prepare` already wrote
            // the failure with the underlying detail, and `AppModel` writes the
            // user-facing one. Three lines saying the same thing make the
            // console harder to read, not easier.
            let reported = Self.userFacing(error)
            state = .failed(reported.localizedDescription)
            throw reported
        }
    }

    /// The load path is the one place an error can carry a model's file name.
    ///
    /// A failure to build a session comes back from ONNX Runtime as its own
    /// status — "Load model from …/<weights>.onnx failed" — and a failure to
    /// read the swapper's projection comes back from Foundation quoting the same
    /// file. Both of those descriptions end up on screen, in the studio's
    /// readiness line and in `AppModel.statusMessage`, and no surface a user
    /// reads names a model or says where it came from. So anything from outside
    /// the engine's own domain is reported in the engine's own words and the
    /// original text is kept where it belongs: in `NSDebugDescriptionErrorKey`
    /// and in the line `FaceFusionEngine.prepare` has already logged.
    private static func userFacing(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain != engineErrorDomain else { return error }
        return makeEngineNSError(.modelLoadFailed, underlying: nsError.localizedDescription)
    }

    /// Drops every session. The state goes back to `.idle` rather than staying
    /// `.ready`, because callers gate work on `.ready` and a client that claims
    /// to be ready with no models loaded fails every frame instead of
    /// re-preparing.
    func unloadModels() async {
        await engine.unloadModels()
        state = .idle
    }

    /// Kept from the XPC client so `AppModel` reads the same, though there is
    /// no connection left to tear down: it returns the client to `.idle` and
    /// releases the weights in the background, so the caller is not blocked on
    /// half a gigabyte being freed.
    func disconnect() {
        state = .idle
        let engine = self.engine
        Task.detached(priority: .utility) { await engine.unloadModels() }
    }

    /// Forwarded from the app's memory-warning notification. Costs quality, not
    /// the render — see `SwapPipeline.memoryPressureUnloadOptional()`.
    func handleMemoryPressure() {
        EngineLog.client.notice("memory warning: asking the engine to release optional models")
        engine.handleMemoryPressure()
    }

    // MARK: Calls

    func analyzeSource(_ buffer: CVPixelBuffer,
                       selecting index: Int? = nil) async throws -> SourceAnalysis {
        // Fixed to the refined alignment the swap uses. Encoding the source one
        // way and target faces another shifts the identity vector away from
        // what the swapper was trained on.
        try await engine.analyzeSource(buffer, refineLandmarks: true, selecting: index)
    }

    func detectFaces(_ buffer: CVPixelBuffer) async throws -> FrameAnalysis {
        try await engine.detectFaces(buffer)
    }

    func analyzeFaces(_ buffer: CVPixelBuffer,
                      options: AnalysisOptions) async throws -> FrameAnalysis {
        try await engine.analyzeFaces(buffer, options: options)
    }

    /// Throwing to match the macOS client's shape, even though nothing in the
    /// in-process path can fail any more: callers already handle it, and
    /// changing the signature would ripple for no gain.
    func setReferenceFaces(_ set: ReferenceFaceSet) async throws {
        await engine.setReferenceFaces(set)
    }

    func swap(_ input: CVPixelBuffer,
              into output: CVPixelBuffer,
              options: SwapOptions) async throws -> SwapResult {
        try await engine.swap(input, into: output, options: options)
    }
}
