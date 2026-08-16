//
//  EngineBenchmark.swift
//  FaceFusion
//
//  Measures which execution-provider settings are actually fastest on *this*
//  device, instead of assuming.
//
//  On the Mac this was a `--benchmark` flag, run once by a developer, and its
//  results became the shipping defaults. Two of them are worth restating,
//  because they are the reason this exists at all:
//
//  - Declaring static input shapes was a free 35% — every graph here has fully
//    static shapes, and telling Core ML so lets it absorb regions it otherwise
//    leaves on the CPU.
//  - Forcing `CPUAndNeuralEngine` was **17× slower** than letting Core ML
//    choose. These are convolutional generators the ANE largely rejects, so
//    pinning them there degenerates into constant fallback. Guessing produced
//    exactly the wrong answer, and it took a measurement to find out.
//
//  A phone is not that Mac. It has a proportionally much larger Neural Engine,
//  a much smaller GPU, a thermal budget measured in minutes and a memory
//  ceiling enforced by jetsam — so the Mac's ranking is a starting hypothesis
//  here, not a result. Rather than bake in a guess for every device Apple
//  ships, the sweep moves into Settings and the user's own device answers the
//  question in a couple of minutes.
//
//  The measurement runs on the frame the user is previewing, not on a
//  synthetic one. A drawn pattern is not a face: the detector finds nothing in
//  it, the swapper never runs, and the sweep would compare seven configurations
//  at doing almost no work. Real media is also the honest test — the cost of a
//  frame depends on its resolution and on how many faces are in it.
//

import Foundation
import Observation
import CoreVideo
import os

@MainActor
@Observable
final class EngineBenchmark {

    /// One configuration and what it measured. `stages` is nil until the row
    /// has run, which is what the results table shows a spinner for.
    struct Row: Identifiable {
        let id: String
        var name: String
        var compute: ComputePolicy
        var tuning: EngineTuning
        var stages: StageSeconds?
        var error: String?

        /// Frames per second implied by the mean total. The table quotes this
        /// rather than milliseconds because it is the number the user feels.
        var framesPerSecond: Double? {
            guard let total = stages?.total, total > 0 else { return nil }
            return 1 / total
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    /// The conclusion, or the reason there is not one. Also persisted into
    /// `Preferences.benchmarkSummary` so Settings can show it on a later launch.
    private(set) var verdict: String?

    @ObservationIgnored private var isCancelled = false

    // MARK: - The sweep

    /// One configuration per variable, each isolating a single change against
    /// the shipping default. `enhance` is not on `Row` because it is not a
    /// property of the execution provider — it is here so the sweep can show
    /// what turning the enhancer off is worth, which on the Mac was the largest
    /// single saving available.
    private struct Configuration {
        /// Stable, English, and never shown. It is the row's identity and what
        /// the log prints, so that switching language cannot reshuffle a run in
        /// progress or make two devices' logs incomparable.
        var name: String
        /// What Settings puts in the table.
        var displayName: String
        var compute: ComputePolicy
        var tuning: EngineTuning
        var enhance: Bool
    }

    /// Every tuning keeps `enhancerReplicas` at 1: replication only pays when
    /// two frames are in the enhancer at once, which a one-frame-at-a-time
    /// sweep never has, so a second replica here would cost 340 MB and measure
    /// nothing.
    private static let sweep: [Configuration] = [
        Configuration(name: "Automatic",
                      displayName: String(localized: "Automatic", bundle: .uiLanguage),
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "Automatic, flexible shapes",
                      displayName: String(localized: "Automatic, flexible shapes", bundle: .uiLanguage),
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: false),
                      enhance: true),
        Configuration(name: "GPU",
                      displayName: String(localized: "GPU", bundle: .uiLanguage),
                      compute: .gpu,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "Neural Engine",
                      displayName: String(localized: "Neural Engine", bundle: .uiLanguage),
                      compute: .neuralEngine,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
        Configuration(name: "Older graph format",
                      displayName: String(localized: "Older graph format", bundle: .uiLanguage),
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true,
                                           modelFormat: "NeuralNetwork"),
                      enhance: true),
        Configuration(name: "Automatic, without enhancement",
                      displayName: String(localized: "Automatic, without enhancement", bundle: .uiLanguage),
                      compute: .automatic,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: false),
        Configuration(name: "CPU only",
                      displayName: String(localized: "CPU only", bundle: .uiLanguage),
                      compute: .cpu,
                      tuning: EngineTuning(requireStaticInputShapes: true),
                      enhance: true),
    ]

    /// True when a row is directly comparable with the others for the purpose
    /// of picking a compute policy: same enhancer setting, same graph format,
    /// same shape declaration. The two rows that vary something else are shown
    /// because they are informative, but letting "without enhancement" win
    /// would answer a question nobody asked — it is faster because it does
    /// less, not because of where it runs.
    private static func isPolicyCandidate(_ configuration: Configuration) -> Bool {
        configuration.enhance
            && configuration.tuning.requireStaticInputShapes
            && configuration.tuning.modelFormat == "MLProgram"
    }

    // MARK: - Running

    /// Sweeps every configuration and adopts the winner.
    ///
    /// `iterations` is 8 rather than the Mac's 12 deliberately. Seven
    /// configurations at twelve frames each, several of them pathologically
    /// slow, is long enough on a phone that the tail of the run measures
    /// thermal throttling rather than the configuration — the benchmark would
    /// start reporting on its own heat.
    func run(model: AppModel, iterations: Int = 8) async {
        guard !isRunning else { return }

        // Refusals, most fundamental first, each naming what to do about it.
        guard model.models.isReady else {
            verdict = String(localized: "Download the models first, then measure.", bundle: .uiLanguage)
            return
        }
        guard case .ready = model.engine.state else {
            verdict = String(localized: "The engine is still starting. Try again in a moment.", bundle: .uiLanguage)
            return
        }
        guard let frame = model.previewFrame, let source = model.sourceBuffer else {
            verdict = String(localized: "Choose a face and a photo or video first. The measurement runs on your own media, because the cost of a frame depends on what is in it.", bundle: .uiLanguage)
            return
        }
        guard model.sourceFace != nil else {
            verdict = String(localized: "No face was found in the source image, so there is nothing to measure. Try a clearer, front-facing photo.", bundle: .uiLanguage)
            return
        }
        guard !model.previewFaces.isEmpty else {
            verdict = String(localized: "No face was found in the frame you are previewing. Move to a frame with a face in it and measure again.", bundle: .uiLanguage)
            return
        }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        guard let output = try? PixelSurface.makeBuffer(width: width, height: height) else {
            verdict = String(localized: "There was not enough memory to run the measurement.", bundle: .uiLanguage)
            return
        }

        isRunning = true
        isCancelled = false
        verdict = nil
        rows = Self.sweep.map {
            Row(id: $0.name, name: $0.displayName, compute: $0.compute, tuning: $0.tuning)
        }

        let rounds = max(1, iterations)
        let startingThermalState = DeviceCapabilities.thermalState
        EngineLog.engine.notice(
            "benchmark: \(width)x\(height), \(rounds) iterations per configuration, \(Self.sweep.count) configurations")

        for (index, configuration) in Self.sweep.enumerated() {
            if isCancelled || Task.isCancelled { break }
            do {
                // Into the shipping cache directory, and each row leaves its own
                // set of compiled graphs behind in it. The execution-provider
                // options are part of ORT's cache key, so the seven variants do
                // not collide and do not overwrite the ones an ordinary launch
                // uses — but a directory that holds one set before a measurement
                // holds several afterwards, which is hundreds of megabytes of
                // graphs nothing will ask for again unless the user re-measures.
                //
                // They are not swept here, deliberately: the entries cannot be
                // mapped back to a configuration, so removing the sweep's would
                // mean removing everything, including the set the engine is about
                // to be restarted on. `reconcileCompileCache` collects them on a
                // later launch instead — the fingerprint it records describes the
                // shipping configuration alone, so a sweep that ends by adopting
                // a different compute policy is a mismatch at the next launch and
                // the whole directory goes, at the cost of one recompile.
                //
                // This is also the second caller of `prepare`, and the reason the
                // self-healing retry lives in the engine rather than in
                // `AppModel`: a compiled graph that has gone bad breaks a
                // measurement exactly as it breaks a launch, and neither caller
                // should have to know how to repair it.
                try await model.engine.prepare(modelPaths: model.models.installedPaths(),
                                               cacheDirectory: ModelManager.compileCacheDirectory,
                                               compute: configuration.compute,
                                               tuning: configuration.tuning)

                // Preparing drops every session, and with them the encoded
                // source identity, so the portrait is re-analysed per
                // configuration rather than once at the top.
                _ = try await model.engine.analyzeSource(source)

                var options = model.swapOptions
                options.enhanceFace = configuration.enhance
                // Fixed to the largest face, whatever the user has chosen.
                // `.reference` names a generation the fresh engine no longer
                // holds, so every row would be refused as stale; and one face
                // per frame is what the published per-stage figures describe,
                // which keeps these numbers comparable with them.
                options.selection = .largest

                // Discard the first two: Core ML lazily specialises on the
                // first real inference, so they measure compilation rather than
                // execution.
                for _ in 0 ..< 2 {
                    _ = try await model.engine.swap(frame, into: output, options: options)
                }

                var total = StageSeconds()
                for _ in 0 ..< rounds {
                    if isCancelled || Task.isCancelled { break }
                    let result = try await model.engine.swap(frame, into: output, options: options)
                    total = total + result.stages
                }
                if isCancelled || Task.isCancelled { break }

                let mean = total.scaled(by: 1.0 / Double(rounds))
                rows[index].stages = mean
                EngineLog.engine.notice(
                    "benchmark \(configuration.name, privacy: .public): \(String(format: "%.1f", mean.total * 1000), privacy: .public) ms/frame")
            } catch {
                // A configuration that will not load is a result too — an older
                // device may refuse the NeuralNetwork format outright — so the
                // row records why and the sweep carries on.
                rows[index].error = error.localizedDescription
                EngineLog.engine.error(
                    "benchmark \(configuration.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        await finish(model: model, startingThermalState: startingThermalState)
    }

    /// Asks the sweep to stop.
    ///
    /// A flag rather than task cancellation because there is nothing to cancel
    /// inside an inference: ONNX Runtime runs a graph to completion. The loop
    /// gives up at the next iteration boundary, so a press during a slow
    /// configuration still waits out the frame in flight — and the engine is
    /// restored either way, which is the part that matters.
    func cancel() {
        isCancelled = true
    }

    // MARK: - Conclusion

    private func finish(model: AppModel,
                        startingThermalState: ProcessInfo.ThermalState) async {
        let candidates = zip(Self.sweep, rows)
            .filter { Self.isPolicyCandidate($0.0) && $0.1.stages != nil }
            .map { $0.1 }

        if let best = candidates.min(by: { ($0.stages?.total ?? .infinity) < ($1.stages?.total ?? .infinity) }),
           let bestTotal = best.stages?.total, bestTotal > 0 {
            // Whole sentences rather than clauses concatenated onto a stem. The
            // English reads the same either way, but a translation cannot move
            // "faster than CPU" to where its own grammar wants it if it arrives
            // as a fragment already glued to a number.
            let winner = best.compute.displayName
            let fps = String(format: "%.1f", 1 / bestTotal)

            // Against the CPU baseline when it ran, because that is the number
            // that says how much Core ML is doing; against the field otherwise.
            var sentence: String
            if let baseline = candidates.first(where: { $0.compute == .cpu })?.stages?.total,
               baseline > 0, best.compute != .cpu {
                let ratio = String(format: "%.1f", baseline / bestTotal)
                sentence = String(localized: "\(winner) — \(fps) fps, \(ratio)× faster than CPU.", bundle: .uiLanguage)
            } else if candidates.count > 1 {
                sentence = String(localized: "\(winner) — \(fps) fps, the fastest of the \(candidates.count) settings measured.", bundle: .uiLanguage)
            } else {
                sentence = String(localized: "\(winner) — \(fps) fps.", bundle: .uiLanguage)
            }

            // A device that heated up during the run was measuring its own
            // throttling towards the end, so the ranking is worth repeating
            // when it has cooled.
            let endingThermalState = DeviceCapabilities.thermalState
            if endingThermalState.rawValue > startingThermalState.rawValue,
               endingThermalState == .serious || endingThermalState == .critical {
                sentence += " " + String(localized: "Your device became warm while measuring, so these figures are pessimistic.", bundle: .uiLanguage)
            }

            let summary = isCancelled
                ? sentence + " " + String(localized: "Measurement was stopped early.", bundle: .uiLanguage)
                : sentence
            verdict = summary
            // Adopting the winner is the whole point of the exercise; the
            // summary is kept alongside it so Settings can still say where the
            // setting came from on a later launch.
            Preferences.shared.compute = best.compute
            Preferences.shared.benchmarkSummary = summary
            EngineLog.engine.notice("benchmark verdict: \(summary, privacy: .public)")
        } else if isCancelled {
            verdict = String(localized: "Measurement was stopped before anything could be compared.", bundle: .uiLanguage)
        } else {
            verdict = String(localized: "Nothing could be measured on this device. The models may need reinstalling.", bundle: .uiLanguage)
        }

        isRunning = false

        // The sweep leaves the engine holding whichever configuration ran last
        // — CPU only, in this order, which is around 40× slower than the
        // default. Leaving that in place would make the app crawl because the
        // user pressed a button labelled "measure", so the engine is always put
        // back, cancelled or not.
        //
        // `restartEngine` rather than unload-then-start, and the difference is
        // not cosmetic. Rebuilding the sessions discards the projected source
        // identity inside the engine, but `startEngineIfPossible` only re-encodes
        // the portrait when `sourceFace` is nil — and it is not, because the
        // sweep refuses to run without one. Called the other way round the engine
        // comes back holding no source at all and every subsequent swap fails
        // with "no face was found in the source image", from a button labelled
        // "measure". `restartEngine` clears `sourceFace` first, which is exactly
        // what makes the re-encode happen.
        await model.restartEngine()
    }
}
