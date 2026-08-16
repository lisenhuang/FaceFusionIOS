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
//  4. **Falling back to another source means a new task, never a resumed one.**
//     A model can name several places to fetch it from, and a resume payload
//     describes one transfer from one of them — so payloads are filed under the
//     model *and* the source that produced them, and are only ever handed back
//     to that source. Resuming one host's partial against another host's URL is
//     the single way this change could corrupt a file, and keying them apart is
//     what makes it impossible rather than merely unlikely.
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

    /// A finished transfer: the staged file, and where it came from.
    ///
    /// The source travels with the file rather than being inferred by the
    /// caller, because a task outlives the call that made it. A transfer that
    /// fell back to the second source and then completed while the app was
    /// dead is claimed by a call that has asked for nothing yet, and that call
    /// would otherwise report the primary — the one line in the log that exists
    /// to say a primary has gone away would be the line saying it had not.
    private struct Delivery {
        var file: URL
        var source: URL?
    }

    /// One in-flight request, from the caller's point of view.
    private struct Job {
        var continuation: CheckedContinuation<Delivery, Error>?
        var onProgress: (Int64, Int64) -> Void
        var task: URLSessionDownloadTask?
    }

    /// What a resume payload belongs to: the model, and the source it was
    /// being fetched from.
    ///
    /// Not the model alone. Its key already carries the digest, so it says
    /// which *weights* a payload is for — but every source of a model shares
    /// that key by construction, and a single slot per model would let a
    /// partial from a host that has just gone away be picked up by the attempt
    /// whose whole purpose is to try somewhere else. Filed this way, a partial
    /// can only ever continue the transfer that produced it.
    private struct ResumeKey: Hashable {
        var key: String
        var source: URL
    }

    private struct Storage {
        /// Live requests, keyed by model id.
        var jobs: [String: Job] = [:]
        /// Resume payloads from interrupted downloads, by model and source.
        var resumeData: [ResumeKey: Data] = [:]
        /// Results that arrived before anyone was waiting for them.
        var unclaimed: [String: Result<Delivery, Error>] = [:]
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
        storage.withLockUnchecked { state in
            state.resumeData.keys.contains { $0.key == key }
        }
    }

    /// Drops every source's payload for `key`.
    ///
    /// The caller reaches for this having just discarded bytes that failed
    /// verification, and at that point no source's partial is worth keeping:
    /// what they were building did not hash to what the manifest claims, and
    /// continuing any of them would rebuild exactly the same file.
    func discardResumeData(for key: String) {
        storage.withLockUnchecked { state in
            state.resumeData = state.resumeData.filter { $0.key.key != key }
        }
    }

    /// Every key this downloader still has work for.
    ///
    /// That is more than the transfers someone is currently awaiting: a task
    /// the session kept running while the app was dead, a file that arrived
    /// with nobody listening, and a resume payload waiting to be picked up are
    /// all downloads in progress from the library's point of view. `ModelManager`
    /// asks before it deletes anything, because a staging file belonging to one
    /// of these is not litter.
    func activeKeys() async -> Set<String> {
        var keys = storage.withLockUnchecked { state in
            Set(state.jobs.keys)
                .union(state.unclaimed.keys)
                .union(state.resumeData.keys.map(\.key))
        }
        for task in await session.allTasks {
            if let key = task.taskDescription { keys.insert(key) }
        }
        return keys
    }

    // MARK: - Downloading

    /// Downloads a model to a caller-owned location, from the first of
    /// `sources` that will serve it.
    /// - Parameter key: identifies the model, and survives a relaunch as the
    ///   task's `taskDescription`.
    /// - Parameter sources: the manifest's primary first, then its alternates.
    ///   All of them serve the same file — the digest is pinned per model, not
    ///   per source — so which one answers is nobody's business but this
    ///   function's, and is the reason it is safe to move on when one will not.
    /// - Parameter onProgress: called with (bytesWritten, totalBytes); total is
    ///   -1 when the server does not advertise a length.
    func download(key: String,
                  from sources: [URL],
                  to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {

        try Task.checkCancellation()

        // Ask the session what it is already doing before starting anything.
        // After a relaunch this is where an in-flight transfer is recovered;
        // in the ordinary case it is one cheap round trip to `nsurlsessiond`.
        let running = await session.allTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first { $0.taskDescription == key }

        // A recovered task has already committed to one of the sources, and its
        // own request is the only record of which — so the ones before it in the
        // list have effectively been tried and are skipped. A request naming
        // something this manifest no longer lists (the app updated while the
        // transfer was in flight) counts as the primary, since that is what any
        // build would have reached for first.
        var pending = sources
        if let url = running?.originalRequest?.url,
           let index = sources.firstIndex(of: url) {
            pending = Array(sources[index...])
        }
        let firstOrdinal = sources.count - pending.count + 1

        var recovered = running
        for (offset, source) in pending.enumerated() {
            try Task.checkCancellation()
            let ordinal = firstOrdinal + offset
            do {
                let delivery: Delivery = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        attach(key: key,
                               url: source,
                               existing: recovered,
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
                try fileManager.moveItem(at: delivery.file, to: destination)

                storage.withLockUnchecked { state in
                    state.resumeData = state.resumeData.filter { $0.key.key != key }
                    state.jobs[key] = nil
                }
                // Which source answered, every time and not only when it was not
                // the first: a run of these lines reading "2 of 2" is how anyone
                // finds out that the primary has quietly gone away. Taken from
                // the transfer rather than from this loop, which is only right
                // about it when the transfer was also started here.
                let served = delivery.source
                    .flatMap { sources.firstIndex(of: $0) }
                    .map { $0 + 1 } ?? ordinal
                EngineLog.models.notice(
                    "Downloaded \(key, privacy: .public) from source \(served, privacy: .public) of \(sources.count, privacy: .public)")
                return
            } catch {
                // The recovered task belonged to the attempt that just failed;
                // everything after this starts one of its own.
                recovered = nil
                guard Self.isSourceFailure(error), offset + 1 < pending.count else { throw error }
                EngineLog.models.error(
                    "Source \(ordinal, privacy: .public) of \(sources.count, privacy: .public) could not serve \(key, privacy: .public); falling back to the next one")
            }
        }

        // Only reachable for an empty `sources`, which no manifest entry can
        // produce: the primary URL is required and the alternates are extra.
        throw ModelError.transport(
            String(localized: "There is nowhere to download this from.", bundle: .uiLanguage))
    }

    /// Whether a failure is the *source's* and so worth trying the next one for.
    ///
    /// The case this whole mechanism exists for is a release that has been
    /// deleted, retagged or made private, and that arrives as a 404 or a 403 —
    /// so the rejected HTTP status the delegate raises counts, as do connection
    /// failures, timeouts and DNS, which are all `NSURLErrorDomain`.
    ///
    /// Nothing else does. A cancellation is the user's decision and asking a
    /// second host to honour it would be absurd. A failure moving the finished
    /// file is this device's, and would fail identically against every source.
    /// A checksum mismatch never reaches here at all — it is raised by the
    /// caller, after a *complete* download, and is evidence about the bytes
    /// rather than about the host.
    private static func isSourceFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let modelError = error as? ModelError {
            if case .transport = modelError { return true }
            return false
        }
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { return false }
        // A cancellation is reported as `CancellationError` above; this is for
        // one the system raised on us rather than one the user asked for.
        return failure.code != NSURLErrorCancelled
    }

    /// Registers the waiter, then gets a task moving for it.
    private func attach(key: String,
                        url: URL,
                        existing: URLSessionDownloadTask?,
                        onProgress: @escaping (Int64, Int64) -> Void,
                        continuation: CheckedContinuation<Delivery, Error>) {

        let alreadyDone: Result<Delivery, Error>? = storage.withLockUnchecked { state in
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

        // Only this source's own payload. One left by a source that failed
        // earlier stays where it is — it is not applicable here, and it is
        // still worth having if the user comes back and that host has returned.
        let resume = storage.withLockUnchecked {
            $0.resumeData.removeValue(forKey: ResumeKey(key: key, source: url))
        }
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
        // Read before the cancel, so the payload is filed under the source it
        // actually came from rather than whichever one is being tried by the
        // time the callback runs.
        let source = task.originalRequest?.url
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data, let source else { return }
            self.storage.withLockUnchecked {
                $0.resumeData[ResumeKey(key: key, source: source)] = data
            }
        })
        // `didCompleteWithError` reports the cancellation and resolves the waiter.
    }

    /// Resolves the waiter for `key`, or parks the result until one appears.
    ///
    /// Always call this outside the lock's critical section for the resume
    /// itself — resuming a continuation runs arbitrary caller code, and doing
    /// that under an unfair lock is how a deadlock gets built.
    private func finish(key: String, with result: Result<Delivery, Error>) {
        let continuation: CheckedContinuation<Delivery, Error>? = storage.withLockUnchecked { state in
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
            finish(key: key, with: .failure(ModelError.transport(
                String(localized: "Server returned HTTP \(response.statusCode).", bundle: .uiLanguage))))
            return
        }

        // This callback owns `location` only until it returns, so the file has
        // to be moved synchronously, right here.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(key: key, with: .success(
                Delivery(file: staged, source: downloadTask.originalRequest?.url)))
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
        //
        // Filed under the request that produced it, which is also the only
        // account of it that survives a relaunch. A payload whose origin cannot
        // be named is dropped rather than guessed at: the cost of that is one
        // download starting over, and the cost of guessing wrong is a partial
        // continuing somebody else's transfer.
        if let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let source = task.originalRequest?.url {
            storage.withLockUnchecked { $0.resumeData[ResumeKey(key: key, source: source)] = data }
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
