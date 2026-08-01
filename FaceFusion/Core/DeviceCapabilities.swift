//
//  DeviceCapabilities.swift
//  FaceFusion
//
//  How hard to push this particular device.
//
//  On the Mac the answer was a constant: three frames in flight, measured once,
//  shipped. A phone has two ceilings a Mac effectively does not — a thermal
//  budget and a hard memory limit — and one of them moves while the app is
//  running. A ten-minute export on a device that has been in a pocket, or in
//  the sun, will be throttled partway through, and once the SoC is throttling,
//  keeping more frames in flight makes the export *slower*: the work queues
//  anyway, and every queued frame is holding its buffers resident while it
//  waits. So the export depth is derived from the hardware and from the current
//  thermal state rather than guessed.
//
//  The statics are deliberately `nonisolated`. The export loop re-reads them
//  from a background task every thirty frames, and hopping to the main actor to
//  ask how warm the device is would be absurd; every one of them is a cheap
//  read of process-wide state that is safe from any thread. The observable
//  instance exists only for the UI, which wants to redraw when the answer
//  changes.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class DeviceCapabilities {

    /// One observer for the process. Settings reads this; the export loop uses
    /// the statics below, because it is not on the main actor and does not want
    /// to be.
    static let shared = DeviceCapabilities()

    /// Republished on the main actor whenever the system says it changed, so a
    /// SwiftUI view showing the thermal state — or a profile derived from it —
    /// updates without polling.
    private(set) var thermalState: ProcessInfo.ThermalState

    /// A block observer is never taken away for you, so the token has to
    /// survive until `deinit` — and `deinit` is not main-actor isolated, hence
    /// `nonisolated(unsafe)`. It is written once during `init` and read once
    /// during `deinit`, so there is no race for the compiler to protect.
    @ObservationIgnored
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        // `queue: .main` puts the callback on the main thread, but the closure
        // is still nonisolated as far as the compiler is concerned, so the hop
        // is written out rather than assumed. Thermal transitions happen a
        // handful of times an hour; an extra turn of the run loop is nothing.
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshThermalState() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshThermalState() {
        let current = Self.thermalState
        guard current != thermalState else { return }
        // Worth a line in the log: "the export got slower halfway through" is
        // otherwise indistinguishable from a bug in the pipeline.
        EngineLog.engine.notice(
            "Thermal state \(Self.thermalDescription(self.thermalState), privacy: .public) → \(Self.thermalDescription(current), privacy: .public)")
        thermalState = current
    }

    /// The profile as it stands right now.
    ///
    /// Touching the observable property is what registers the caller with the
    /// observation machinery: the static below reads `ProcessInfo` directly, so
    /// a view that called it would never be told to redraw when the device
    /// starts throttling.
    func profile(enhancing: Bool) -> PerformanceProfile {
        _ = thermalState
        return Self.recommendedProfile(enhancing: enhancing)
    }

    // MARK: - Process-wide facts

    /// Cores available to this process.
    ///
    /// Named for what it is used as rather than for what it measures: there is
    /// no public API for the performance-core count on Apple silicon, and
    /// `activeProcessorCount` counts efficiency cores too. It is still the
    /// right input, because it tracks the class of the chip — and because the
    /// number is halved below, the efficiency cores are effectively discounted.
    nonisolated static var performanceCoreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    nonisolated static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// True on a device with less than 6 GB of RAM, where a second enhancer
    /// replica and a deep export queue are how the app gets jetsammed.
    ///
    /// The comparison rounds *up* to whole gibibytes first, because
    /// `physicalMemory` reports what the kernel makes available rather than
    /// what is on the box: a nominal 6 GB phone answers somewhere around
    /// 5.7 GiB, and a naive `< 6 GiB` test would put every device in the
    /// constrained bucket.
    nonisolated static var isMemoryConstrained: Bool {
        let gibibyte: UInt64 = 1 << 30
        let rounded = (physicalMemoryBytes + gibibyte - 1) / gibibyte
        return rounded < 6
    }

    nonisolated static var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// e.g. "iPhone17,1". The App Store model name is not available offline, and
    /// this is what a support log needs anyway.
    ///
    /// `uname` on the simulator reports the *host* architecture, which is
    /// useless for identifying what is being simulated, so the simulator's own
    /// environment variable wins when it is present.
    nonisolated static var deviceModelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - Export depth

    /// How many frames the export should keep inside the engine at once.
    ///
    /// The rules, in the order they are applied:
    ///
    /// - **Base depth is half the cores, clamped to 2...4.** Two is the point
    ///   where decode, inference and encode actually overlap; past four the
    ///   sessions simply queue on the same GPU while each waiting frame holds
    ///   its buffers resident. The Mac measured 1.8× end to end at three.
    /// - **Enhancing costs one.** GFPGAN is the memory hog — 512×512 float
    ///   tensors in and out, per frame in flight, on top of its resident
    ///   weights — and it is also the slowest stage, so a deep queue in front
    ///   of it buys nothing but memory pressure.
    /// - **A memory-constrained device caps at two**, for the same reason.
    /// - **Thermal `.serious` caps at two, `.critical` at one.** These are
    ///   caps, never increases: a cooling device does not get to push harder
    ///   than the base rules allowed.
    /// - **Never below one.** A depth of zero exports nothing.
    nonisolated static func recommendedProfile(enhancing: Bool) -> PerformanceProfile {
        let cores = performanceCoreCount
        var depth = max(2, min(4, cores / 2))
        var notes = ["\(cores) cores"]

        if enhancing {
            depth -= 1
            notes.append("enhancing")
        }
        if isMemoryConstrained {
            depth = min(depth, 2)
            notes.append("limited memory")
        }

        let thermal = thermalState
        switch thermal {
        case .serious:  depth = min(depth, 2)
        case .critical: depth = min(depth, 1)
        default:        break
        }

        notes.append(thermalDescription(thermal))
        return PerformanceProfile(concurrentFrames: max(1, depth),
                                  reason: notes.joined(separator: ", "))
    }

    /// Lower case, because it is written into a sentence fragment as often as
    /// it is shown on its own — capitalise at the call site if a label needs it.
    nonisolated static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        default:        return "unknown"
        }
    }

    /// The thermal state as a sequence, for anything that would rather await a
    /// change than poll for one. Yields the current value immediately so a
    /// consumer does not have to read it separately before its first `await`,
    /// and unregisters when the stream is torn down.
    nonisolated static var thermalStateUpdates: AsyncStream<ProcessInfo.ThermalState> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(ProcessInfo.processInfo.thermalState)
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
            continuation.yield(ProcessInfo.processInfo.thermalState)
        }
    }
}
