//
//  ExportSuspension.swift
//  FaceFusion
//
//  Notices when the app leaves the foreground during a render, and holds the
//  execution assertion that lets the writer close its file on the way out.
//
//  Why this file exists at all is worth writing down, because the constraint is
//  not obvious and it is not one more code can argue with.
//
//  An export decodes and encodes through VideoToolbox and runs four models per
//  frame on the GPU and the Neural Engine. iOS grants all three of those to the
//  foreground app only. Leave the app and the codec sessions are torn down;
//  what the render sees on the way back is `AVError.operationInterrupted`, an
//  `AVAssetWriter` that will never accept another frame, and a half-written MP4
//  with no index — a file that is not a shorter video, it is not a video. There
//  is no background mode that exempts a compute job from this and no entitlement
//  that buys one; an app that keeps rendering in the background is an app that
//  gets its command buffers aborted and then gets jetsammed for holding half a
//  gigabyte of weights while it does.
//
//  So the render does not try to survive the background. It gets *out* of the
//  way of it: the moment the app is told it is leaving, the frame loop stops
//  feeding the encoder and closes the file it has, which becomes a complete and
//  valid segment. Coming back starts a new segment where that one ended, and the
//  segments are joined at the end without re-encoding. The user sees a progress
//  bar that pauses and picks up rather than an error.
//
//  Two halves, because the two callers are on different threads:
//
//  - `ExportSuspensionMonitor` is main-actor bound. It owns the notification
//    observers and the `UIApplication` background-task assertion, both of which
//    have to be.
//  - `ExportSuspensionState` is the flag itself, behind a lock, so the frame
//    loop can ask "am I still in the foreground" between frames without hopping
//    to the main actor several times a second.
//

import Foundation
import UIKit
import os

/// The half of the monitor the render loop touches.
///
/// A flag rather than a stream of events on purpose. What the loop needs to
/// know at a frame boundary is the *current* state, not the history: if the app
/// left and came back while a frame was inside the engine, there is nothing to
/// react to and the loop should keep going.
final class ExportSuspensionState: Sendable {

    private let backgrounded = OSAllocatedUnfairLock(initialState: false)

    /// True from `didEnterBackground` until `willEnterForeground`.
    var isBackgrounded: Bool { backgrounded.withLock { $0 } }

    fileprivate func set(_ value: Bool) {
        backgrounded.withLock { $0 = value }
    }

    /// Parks a paused export until the app is on screen again.
    ///
    /// Polled rather than continuation-based, which looks lazy and is not: a
    /// suspended app executes no code at all, so the loop below runs exactly
    /// once when the export pauses and once more when the user returns. There
    /// is no third wake-up to be saved. What polling buys instead is
    /// cancellation for free — `Task.sleep` throws when the user taps Cancel
    /// on the paused progress bar, which a hand-rolled continuation would have
    /// to arrange for itself.
    func waitForForeground() async throws {
        while isBackgrounded {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}

/// Watches one export's worth of foreground transitions.
///
/// Created when a render starts and stopped when it ends, rather than living
/// for the life of the app: the assertion it takes is only ever wanted while
/// there is a file open, and an observer that outlives its export would keep a
/// dead render's state alive.
@MainActor
final class ExportSuspensionMonitor {

    /// `nonisolated` because the render loop reads it from its own thread. Safe
    /// because it is a `let` and everything inside it is behind a lock.
    nonisolated let state = ExportSuspensionState()

    private var observers: [NSObjectProtocol] = []
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    init() {
        let centre = NotificationCenter.default
        // Weakly, so that an observer the export forgot to remove cannot be
        // what keeps a finished render's monitor — and its assertion — alive.
        observers = [
            centre.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            centre.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredForeground() }
            },
        ]
    }

    /// Removes the observers and lets go of the assertion.
    ///
    /// Explicit rather than in `deinit` because the assertion must be given back
    /// on the main actor and at a moment of the export's choosing — a `deinit`
    /// runs whenever the last reference happens to go, which for a render that
    /// threw is somewhere inside an error path.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        endAssertion()
    }

    /// Called by the export once the file it had open is closed, so the
    /// assertion is not held for the whole time the user is away.
    func checkpointFinished() {
        endAssertion()
    }

    private func enteredBackground() {
        state.set(true)

        // What the assertion is for: draining is skipped, but ending the
        // session and writing the index still has to happen, and it is
        // precisely the work iOS would otherwise suspend us in the middle of.
        // The window is around thirty seconds — far more than closing a file
        // needs, and nowhere near enough to be mistaken for a way to keep
        // rendering.
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(
            withName: "Closing the export file"
        ) { [weak self] in
            // Expiry. The system is going to suspend the app whatever it is
            // told; handing the assertion back is the difference between being
            // suspended and being killed for holding one too long.
            MainActor.assumeIsolated {
                EngineLog.engine.error("ran out of background time before the export file was closed")
                self?.endAssertion()
            }
        }
    }

    private func enteredForeground() {
        state.set(false)
        endAssertion()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
