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

/// In-process engine. Everything below the `async` surface is synchronous work
/// on `queue`; nothing here touches the main actor.
final class FaceFusionEngine: @unchecked Sendable {

    private let pipeline = SwapPipeline()

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
                try self.pipeline.prepare(config)
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
                       refineLandmarks: Bool = true) async throws -> SourceAnalysis {
        try Self.requireBGRA(buffer, "source")
        return try await perform(barrier: true) {
            try BGRAImage.wrapping(buffer, readOnly: true) { image in
                try self.pipeline.analyzeSource(image, refineLandmarks: refineLandmarks)
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

    private let engine = FaceFusionEngine()

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
            state = .failed(error.localizedDescription)
            throw error
        }
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

    func analyzeSource(_ buffer: CVPixelBuffer) async throws -> SourceAnalysis {
        // Fixed to the refined alignment the swap uses. Encoding the source one
        // way and target faces another shifts the identity vector away from
        // what the swapper was trained on.
        try await engine.analyzeSource(buffer, refineLandmarks: true)
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
