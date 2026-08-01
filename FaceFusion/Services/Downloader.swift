//
//  Downloader.swift
//  FaceFusion
//
//  An async wrapper around a *background* `URLSessionDownloadTask`.
//
//  The whole library is about 900 MB. On a Mac that was a few minutes with the
//  app in front of you; on a phone it is a few minutes during which the user
//  will lock the screen, take a call, or switch away — and a default session is
//  suspended along with the app, so the transfer would stall and then die.
//  A background session is handed to `nsurlsessiond`, which keeps going while
//  the app is suspended and relaunches it afterwards to report the result.
//
//  That changes three things about the shape of this file compared with the
//  Mac version, and each of them is a trap if ignored:
//
//  1. **The session is a singleton and is never invalidated.** Creating a
//     second background session with the same identifier is a hard error, and
//     the delegate is the only route by which a finished transfer is reported —
//     including to a process that was launched for no other reason. So there is
//     one `Downloader`, created once, holding one session that lives as long as
//     the process. `URLSession` retains its delegate until it is invalidated,
//     which here means forever: a deliberate cycle, not a leak.
//  2. **Callbacks can arrive with nobody waiting.** The download may finish
//     while the app is dead. The system relaunches us, the delegate fires, and
//     there is no continuation to resume — so the file is staged and held until
//     someone asks for that model, at which point they get it immediately.
//  3. **Tasks outlive the call that made them.** On relaunch a transfer is
//     still in flight, so `download` first asks the session what it is already
//     doing and reattaches rather than starting the same 278 MB again. Tasks
//     are matched to models by `taskDescription`, which is the only piece of
//     our own state that survives the app being killed.
//
//  Everything else — the async signature, the resume-data behaviour, moving the
//  finished file to a caller-owned location — is unchanged, so `ModelManager`
//  reads exactly as it did.
//

import Foundation
import os

final class Downloader: NSObject, @unchecked Sendable {

    /// The one downloader for the process. Not a convenience: see the header.
    static let shared = Downloader()

    /// Must be stable across launches — it is how the system finds the session
    /// that owns the transfers it has been running in our absence.
    static let sessionIdentifier = "com.lisenhuang.FaceFusion.models"

    /// One in-flight request, from the caller's point of view.
    private struct Job {
        var continuation: CheckedContinuation<URL, Error>?
        var onProgress: (Int64, Int64) -> Void
        var task: URLSessionDownloadTask?
    }

    private struct Storage {
        /// Live requests, keyed by model id.
        var jobs: [String: Job] = [:]
        /// Resume payloads from interrupted downloads, keyed by the model id.
        var resumeData: [String: Data] = [:]
        /// Results that arrived before anyone was waiting for them.
        var unclaimed: [String: Result<URL, Error>] = [:]
        /// What UIKit gave us when it woke the app to deliver session events.
        var backgroundCompletion: (() -> Void)?
    }

    /// Delegate callbacks arrive on the session's own queue while `download` is
    /// awaited from the main actor, so every field above is touched from at
    /// least two threads. `withLockUnchecked` rather than `withLock` because
    /// the state holds continuations, closures and `Error`s, none of which are
    /// `Sendable` — the lock is what makes them safe, and the compiler cannot
    /// see that.
    private let storage = OSAllocatedUnfairLock(uncheckedState: Storage())

    /// Created lazily so `self` can be its delegate, and then primed in `init`
    /// so the laziness never races: `shared` is built exactly once, under the
    /// runtime's own one-shot lock.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Discretionary transfers are deferred until the system judges the
        // moment ideal — good for a podcast pre-fetch, wrong for a download the
        // user is watching a progress bar for and cannot use the app without.
        configuration.isDiscretionary = false
        // Without this the app is never relaunched to hear that the last model
        // arrived, and the library sits one file short until the user notices.
        configuration.sessionSendsLaunchEvents = true
        // A background session ignores per-request timeouts in favour of these.
        // The resource timeout is generous on purpose: 900 MB over a weak
        // connection, with the app suspended for most of it, is not a failure.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = session
    }

    // MARK: - Resume data

    func hasResumeData(for key: String) -> Bool {
        storage.withLockUnchecked { $0.resumeData[key] != nil }
    }

    func discardResumeData(for key: String) {
        storage.withLockUnchecked { $0.resumeData[key] = nil }
    }

    // MARK: - Downloading

    /// Downloads `url` to a caller-owned location.
    /// - Parameter key: identifies the model, and survives a relaunch as the
    ///   task's `taskDescription`.
    /// - Parameter onProgress: called with (bytesWritten, totalBytes); total is
    ///   -1 when the server does not advertise a length.
    func download(key: String,
                  from url: URL,
                  to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {

        try Task.checkCancellation()

        // Ask the session what it is already doing before starting anything.
        // After a relaunch this is where an in-flight transfer is recovered;
        // in the ordinary case it is one cheap round trip to `nsurlsessiond`.
        let running = await session.allTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first { $0.taskDescription == key }

        let temporaryURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attach(key: key,
                       url: url,
                       existing: running,
                       onProgress: onProgress,
                       continuation: continuation)
            }
        } onCancel: {
            cancelActive(key: key)
        }

        // The delegate has already relocated the file out of URLSession's
        // scratch space, so this move is ours to make.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)

        storage.withLockUnchecked {
            $0.resumeData[key] = nil
            $0.jobs[key] = nil
        }
    }

    /// Registers the waiter, then gets a task moving for it.
    private func attach(key: String,
                        url: URL,
                        existing: URLSessionDownloadTask?,
                        onProgress: @escaping (Int64, Int64) -> Void,
                        continuation: CheckedContinuation<URL, Error>) {

        let alreadyDone: Result<URL, Error>? = storage.withLockUnchecked { state in
            if let done = state.unclaimed.removeValue(forKey: key) { return done }
            state.jobs[key] = Job(continuation: continuation,
                                  onProgress: onProgress,
                                  task: existing)
            return nil
        }
        if let alreadyDone {
            EngineLog.models.notice("Claimed a background download of \(key, privacy: .public) that finished while the app was away")
            continuation.resume(with: alreadyDone)
            return
        }

        if let existing {
            EngineLog.models.notice("Reattached to the in-flight download of \(key, privacy: .public)")
            // A task recovered from a previous launch is normally already
            // running; resuming a running task is harmless, and a suspended one
            // needs it.
            existing.resume()
            cancelIfCancelledAlready(key: key)
            return
        }

        let resume = storage.withLockUnchecked { $0.resumeData.removeValue(forKey: key) }
        let task: URLSessionDownloadTask
        if let resume {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: URLRequest(url: url))
        }
        // The delegate has no closure to consult after a relaunch — this label
        // is how a callback finds the model it belongs to.
        task.taskDescription = key
        storage.withLockUnchecked { $0.jobs[key]?.task = task }
        task.resume()
        cancelIfCancelledAlready(key: key)
    }

    /// Closes the window between the cancellation handler being installed and
    /// the task existing.
    ///
    /// `withTaskCancellationHandler` runs `onCancel` immediately if the task is
    /// already cancelled, which can be before there is anything to cancel — and
    /// a cancellation that lands there would leave the transfer running and the
    /// continuation waiting for a callback that nobody is listening for.
    private func cancelIfCancelledAlready(key: String) {
        guard Task.isCancelled else { return }
        cancelActive(key: key)
    }

    /// The awaiting `Task` was cancelled, so stop the transfer but keep what has
    /// already been fetched: a cancelled 278 MB download should resume, not
    /// restart, when the user taps Download again.
    private func cancelActive(key: String) {
        let task = storage.withLockUnchecked { $0.jobs[key]?.task }
        guard let task else {
            // Nothing started yet — resolve the waiter ourselves, since no
            // delegate callback is coming.
            finish(key: key, with: .failure(CancellationError()))
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data else { return }
            self.storage.withLockUnchecked { $0.resumeData[key] = data }
        })
        // `didCompleteWithError` reports the cancellation and resolves the waiter.
    }

    /// Resolves the waiter for `key`, or parks the result until one appears.
    ///
    /// Always call this outside the lock's critical section for the resume
    /// itself — resuming a continuation runs arbitrary caller code, and doing
    /// that under an unfair lock is how a deadlock gets built.
    private func finish(key: String, with result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = storage.withLockUnchecked { state in
            if let job = state.jobs.removeValue(forKey: key) {
                return job.continuation
            }
            // Nobody is waiting. Hold a finished file so the next request for
            // this model is answered instantly; a failure with no audience is
            // dropped, because it would otherwise be reported to whoever asks
            // next for a transfer they never started.
            if case .success = result { state.unclaimed[key] = result }
            return nil
        }
        continuation?.resume(with: result)
    }

    private func progressHandler(for key: String) -> ((Int64, Int64) -> Void)? {
        storage.withLockUnchecked { $0.jobs[key]?.onProgress }
    }

    // MARK: - Background relaunch

    /// Called by the app delegate when the system wakes the app to deliver
    /// events for this session.
    ///
    /// The handler must be called once the session has replayed everything it
    /// has queued — `urlSessionDidFinishEvents` below — and not before. Calling
    /// it late, or not at all, costs the app its background execution
    /// allowance, and the remaining models simply stop arriving.
    func handleEventsForBackgroundURLSession(completionHandler: @escaping () -> Void) {
        // Touching the session matters as much as storing the handler: in a
        // relaunched process nothing else has referenced it yet, and the
        // queued callbacks only arrive once a session with this identifier
        // exists again.
        _ = session

        let previous = storage.withLockUnchecked { state -> (() -> Void)? in
            let old = state.backgroundCompletion
            state.backgroundCompletion = completionHandler
            return old
        }
        // Two wakes without an intervening finish would strand the first
        // handler, which UIKit treats as an unterminated background task.
        previous?()
    }
}

extension Downloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        progressHandler(for: key)?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }

        // A background session reports an error page as a perfectly successful
        // download of an HTML body, so the status has to be checked here or a
        // 404 becomes a checksum failure two steps later.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(key: key, with: .failure(ModelError.transport("Server returned HTTP \(response.statusCode).")))
            return
        }

        // This callback owns `location` only until it returns, so the file has
        // to be moved synchronously, right here.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(key: key, with: .success(staged))
        } catch {
            finish(key: key, with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        guard let error else { return }   // success already reported above

        let failure = error as NSError
        // Both a deliberate cancellation and a dropped connection can offer a
        // resume payload; keeping it is what makes the next attempt cheap.
        if let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            storage.withLockUnchecked { $0.resumeData[key] = data }
        }

        if failure.code == NSURLErrorCancelled {
            finish(key: key, with: .failure(CancellationError()))
        } else {
            EngineLog.models.error("Download of \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            finish(key: key, with: .failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = storage.withLockUnchecked { state -> (() -> Void)? in
            let handler = state.backgroundCompletion
            state.backgroundCompletion = nil
            return handler
        }
        guard let completion else { return }
        // UIKit requires this on the main thread; the delegate queue is not it.
        DispatchQueue.main.async { completion() }
    }
}
