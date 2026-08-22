//
//  VideoPipeline.swift
//  FaceFusion
//
//  Video decode, per-frame processing and encode, built on AVFoundation.
//
//  This is what replaces FFmpeg: AVFoundation already speaks the container and
//  codec formats, and routes both decode and encode through VideoToolbox, so
//  there is nothing for the user to install. Almost none of it changes between
//  macOS and iOS — the reader, the writer, the composition that bakes in
//  rotation and the audio passthrough are the same code.
//
//  Four things do change, and all four are consequences of the platform rather
//  than of the framework:
//
//  - Frames are handed to the engine as `CVPixelBuffer`s. In-process there is
//    no boundary to pass an IOSurface across, so there is nothing to unwrap.
//  - How many frames are kept in flight is no longer a constant. A phone
//    throttles, and once it does, a deeper queue makes the export slower rather
//    than faster, so the depth is re-derived from the thermal state as the
//    export runs and only ever ratchets down from where it started.
//  - The idle timer is held off. A ten-minute render on a locked screen is a
//    ten-minute render that gets suspended partway through.
//  - The export is written in segments and can pause. iOS takes the hardware
//    codecs away from an app that is no longer in front, so leaving the app
//    closes the file rather than corrupting it, and returning opens a new one
//    where the last left off. `ExportSuspension` explains the constraint; the
//    seam is joined without re-encoding. An export nobody interrupts is still
//    a single segment and a single pass.
//

import Foundation
import os
import AVFoundation
import CoreVideo
import CoreMedia
import UIKit

// MARK: - Description of a source video

struct VideoInfo: Equatable, Sendable {
    /// Size after the track's rotation metadata is applied.
    var displaySize: CGSize
    var duration: CMTime
    var nominalFrameRate: Float
    var estimatedFrameCount: Int
    var hasAudio: Bool
    var codecDescription: String

    var durationSeconds: Double { duration.seconds }
}

// MARK: - Progress

struct ExportProgress: Sendable {
    var framesWritten: Int
    var totalFrames: Int
    var framesPerSecond: Double
    var facesSwappedInLastFrame: Int

    var fraction: Double {
        totalFrames > 0 ? min(1, Double(framesWritten) / Double(totalFrames)) : 0
    }

    /// Nil until there is enough throughput history to be meaningful.
    var estimatedTimeRemaining: TimeInterval? {
        guard framesPerSecond > 0.01, totalFrames > framesWritten else { return nil }
        return Double(totalFrames - framesWritten) / framesPerSecond
    }
}

// MARK: - Pipeline

enum VideoPipeline {

    // MARK: Inspection

    static func inspect(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let (naturalSize, transform, duration, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate)

        // Rotation metadata means the stored pixels may be transposed relative
        // to how the video should appear.
        let displaySize = naturalSize.applying(transform)
        let corrected = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        let assetDuration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var codec = "Video"
        if let description = try await track.load(.formatDescriptions).first {
            let subType = CMFormatDescriptionGetMediaSubType(description)
            codec = fourCCString(subType)
        }

        let seconds = assetDuration.seconds.isFinite ? assetDuration.seconds : 0
        let effectiveRate = frameRate > 0 ? Double(frameRate) : 30
        return VideoInfo(displaySize: corrected,
                         duration: assetDuration,
                         nominalFrameRate: frameRate,
                         estimatedFrameCount: max(1, Int(seconds * effectiveRate)),
                         hasAudio: !audioTracks.isEmpty,
                         codecDescription: codec)
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "avc1", "h264": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        default: return text.uppercased()
        }
    }

    // MARK: Output size

    /// Long edge an exported video is bounded to.
    ///
    /// Not a quality budget so much as the thing that makes the quality budget
    /// spendable. `closeUpDetail` matches a face by generating as many pixels as
    /// the face occupies, and the passes it costs grow with the square of that:
    /// an ordinary close-up is ~510px of face at this bound and 16 passes, but
    /// the same shot at 4K is ~1000px and would want 64. So 4K does not buy a
    /// sharper face, it buys the same soft face in a heavier file — bounding the
    /// frame is what puts a match inside reach at all.
    ///
    /// It bounds the *long* edge, so footage shot in portrait stays portrait.
    static let maximumExportDimension = 1920

    /// `size` bounded to `maximumExportDimension`, preserving aspect ratio.
    ///
    /// Returns `size` untouched when it already fits, so every video at or below
    /// the bound — which is most of them — encodes at exactly the dimensions it
    /// always did. Only a downscale rounds to even dimensions, which 4:2:0
    /// chroma requires and which the uncapped path never had to promise.
    static func exportSize(for size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > CGFloat(maximumExportDimension), longest > 0 else { return size }

        let scale = CGFloat(maximumExportDimension) / longest
        return CGSize(width: max(2, (size.width * scale / 2).rounded() * 2),
                      height: max(2, (size.height * scale / 2).rounded() * 2))
    }

    // MARK: Single frames

    /// Decodes one upright frame, for the preview canvas.
    static func frame(at time: CMTime, in url: URL) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Applies the rotation metadata, so faces arrive the right way up.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero

        let (cgImage, _) = try await generator.image(at: time)
        return try PixelSurface.makeBuffer(from: cgImage)
    }

    /// The same exact seek, bounded to a long edge.
    ///
    /// The preview on a phone does not need a 4K frame to show a face on a
    /// 6-inch screen, and swapping one costs several times what swapping a
    /// 1280px one does. The *export* still runs at full resolution — it decodes
    /// through the reader below, not through this — so nothing the user keeps
    /// is affected by what the preview decided to look at.
    static func frame(at time: CMTime, in url: URL, maximumDimension: Int) async throws -> CVPixelBuffer {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)

        let (cgImage, _) = try await generator.image(at: time)
        return try PixelSurface.makeBuffer(from: cgImage)
    }

    /// A generator tuned for the face scan rather than for display.
    ///
    /// The scan is deciding who is in the video, not rendering anything, so it
    /// can accept the nearest frame the decoder already has and a bounded size.
    /// Exact seeks at full resolution across dozens of samples is most of the
    /// difference between a scan that takes seconds and one that takes minutes.
    static func makeScanGenerator(for url: URL, maximumDimension: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        return generator
    }

    // MARK: Export

    struct ExportRequest {
        var source: URL
        /// A temporary file the caller owns. There is no save panel on iOS, so
        /// the render lands in the app's own container and the result bar then
        /// offers Photos, Files or Share.
        var destination: URL
        var options: SwapOptions
        /// HEVC keeps the file small; H.264 plays everywhere.
        var useHEVC: Bool = true
        /// Roughly 0.2 bits per pixel per frame at 1x.
        var qualityMultiplier: Double = 1.0
        /// How many frames may be inside the engine at once.
        ///
        /// A frame alternates between the GPU (four model invocations) and the
        /// CPU (warps, masking, compositing), and decode and encode sit either
        /// side of it. Processed strictly one at a time, whichever unit is not
        /// currently busy sits idle. Overlapping a few frames keeps them all
        /// fed. Beyond about four the units are saturated and the only effect
        /// is more resident frame buffers.
        ///
        /// The Mac hard-coded three. Here the starting value comes from the
        /// device — core count, memory and how warm it already is — because the
        /// same number is wrong at both ends of the product range, and because
        /// on a phone "more resident frame buffers" is not a shrug, it is how
        /// the app gets killed.
        var concurrentFrames: Int

        init(source: URL,
             destination: URL,
             options: SwapOptions,
             useHEVC: Bool = true,
             qualityMultiplier: Double = 1.0,
             concurrentFrames: Int? = nil) {
            self.source = source
            self.destination = destination
            self.options = options
            self.useHEVC = useHEVC
            self.qualityMultiplier = qualityMultiplier
            self.concurrentFrames = concurrentFrames
                ?? DeviceCapabilities.recommendedProfile(enhancing: options.enhanceFace)
                    .concurrentFrames
        }
    }

    /// Reads every frame, hands it to the engine, and writes the result.
    ///
    /// No longer one pass, and the reason is the platform rather than the
    /// pipeline. iOS revokes the hardware codecs the moment the app stops being
    /// the foreground app, so a render that is still going when the user checks
    /// a message does not merely slow down — the reader and the writer are torn
    /// down under it, and what is left on disk is an MP4 with no index, which is
    /// not a shorter video, it is not a video. No background mode exempts a
    /// compute job from that and no entitlement buys one.
    ///
    /// So leaving the app *ends a segment* rather than ending the export. The
    /// frames inside the engine are dropped, the file is closed while there is
    /// still background time to close it, and coming back opens a new one at the
    /// frame after the last that reached disk. `join` puts the pieces together
    /// at the end without re-encoding anything.
    ///
    /// An export nobody interrupts is still exactly one segment, still carries
    /// the audio the way it always did, and reaches its destination by being
    /// renamed rather than copied. Nothing about the file a user gets changes
    /// unless they left the app — and then what changes is that they get one.
    ///
    /// `onResume` is called after each pause, before any frame is decoded again.
    /// It exists for one thing: a memory warning almost certainly arrived while
    /// the app was on its way out or on its way back, because a suspended export
    /// holding half a gigabyte of weights is the most jetsam-worthy thing on the
    /// device, and answering one costs the enhancer and the occluder. Picking up
    /// without them would put a visible change of quality in the middle of the
    /// video, at exactly the frame the user left.
    static func export(_ request: ExportRequest,
                       engine: EngineClient,
                       onResume: (@MainActor @Sendable () async -> Void)? = nil,
                       progress: @escaping @MainActor (ExportProgress) -> Void) async throws {

        // Renders are long and the user has no reason to keep touching the
        // screen while one runs, so the device would otherwise lock and suspend
        // the app partway through. Restored on every exit path, including a
        // thrown error and a cancellation — a `defer` cannot await, so the
        // restore is a hop rather than a call, which is fine: nothing depends
        // on it having happened by the time `export` returns.
        //
        // This stops the screen locking. It cannot stop the user pressing Home,
        // which is what the monitor below is for.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        let monitor = await MainActor.run { ExportSuspensionMonitor() }
        let suspension = monitor.state
        defer { Task { @MainActor in monitor.stop() } }

        // Removed however this ends — finished, cancelled or thrown. A segment
        // is worthless to anything but the export that wrote it.
        let workspace = MediaStore.makeSegmentWorkspace()
        defer { MediaStore.removeSegmentWorkspace(workspace) }

        let totalFrames = try await inspect(request.source).estimatedFrameCount

        /// Finished pieces, in playing order.
        var segments: [URL] = []
        /// Source time of the last frame that reached disk; the next segment
        /// picks up after it.
        var writtenThrough: CMTime?
        var framesWritten = 0
        var throughput: Double = 0

        while true {
            let url = workspace.appendingPathComponent("segment-\(segments.count).mp4")
            let piece = try await writeSegment(
                request: request,
                engine: engine,
                to: url,
                // Only the first piece carries the audio, and only because an
                // export nobody interrupts is then already the finished file.
                // Once there is a join to do, the audio is taken off the source
                // in one go and whatever this wrote is ignored.
                withAudio: segments.isEmpty,
                startingAfter: writtenThrough,
                totalFrames: totalFrames,
                framesAlreadyWritten: framesWritten,
                throughputSoFar: throughput,
                suspension: suspension,
                progress: progress)

            framesWritten = piece.framesWritten
            throughput = piece.throughput

            if let end = piece.writtenThrough {
                segments.append(url)
                writtenThrough = end
            } else {
                // Nothing landed: the app left before a single frame came back
                // out of the engine, or the file could not be closed in the time
                // left. There is no piece here, and the next attempt starts from
                // wherever this one was asked to.
                try? FileManager.default.removeItem(at: url)
            }

            guard piece.wasInterrupted else { break }

            EngineLog.engine.notice(
                "export paused at \(framesWritten)/\(totalFrames) frames with \(segments.count) segment(s) on disk")

            // The file is closed. Holding the assertion for however long the
            // user is away is how an app gets killed for holding one too long.
            await MainActor.run { monitor.checkpointFinished() }

            try await suspension.waitForForeground()
            try Task.checkCancellation()
            await onResume?()

            EngineLog.engine.notice("export resumed at \(framesWritten)/\(totalFrames) frames")
        }

        guard !segments.isEmpty else {
            throw MediaError.writerFailed(
                String(localized: "No frames could be read from this video.", bundle: .uiLanguage))
        }

        if segments.count == 1 {
            // The ordinary path. The piece already is the export, audio and all,
            // so this is a rename within one temporary directory rather than
            // half a gigabyte of copying.
            if FileManager.default.fileExists(atPath: request.destination.path) {
                try FileManager.default.removeItem(at: request.destination)
            }
            try FileManager.default.moveItem(at: segments[0], to: request.destination)
        } else {
            try await join(segments, audioFrom: request.source, into: request.destination)
        }

        let finalProgress = ExportProgress(framesWritten: framesWritten,
                                           totalFrames: max(totalFrames, framesWritten),
                                           framesPerSecond: throughput,
                                           facesSwappedInLastFrame: 0)
        await MainActor.run { progress(finalProgress) }
    }

    /// What one uninterrupted stretch of an export produced.
    private struct SegmentOutcome {
        /// Source time of the last frame that reached the file, or nil when the
        /// segment produced nothing worth keeping — in which case the caller
        /// deletes it and starts the next one from the same place.
        var writtenThrough: CMTime?
        /// True when the app left the foreground, false when the video ended.
        var wasInterrupted: Bool
        /// Cumulative across the whole export, not across this segment, because
        /// it is what the progress bar shows.
        var framesWritten: Int
        var throughput: Double
    }

    /// One stretch of frames, from `startingAfter` until either the video ends
    /// or the app leaves the foreground.
    private static func writeSegment(request: ExportRequest,
                                     engine: EngineClient,
                                     to destination: URL,
                                     withAudio: Bool,
                                     startingAfter: CMTime?,
                                     totalFrames: Int,
                                     framesAlreadyWritten: Int,
                                     throughputSoFar: Double,
                                     suspension: ExportSuspensionState,
                                     progress: @escaping @MainActor (ExportProgress) -> Void
    ) async throws -> SegmentOutcome {

        let asset = AVURLAsset(url: request.source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let (naturalSize, preferredTransform, nominalRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let rotated = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(rotated.width).rounded(),
                                height: abs(rotated.height).rounded())
        let displaySize = Self.exportSize(for: sourceSize)

        // The engine expects upright faces. Rather than rotating every frame
        // ourselves, hand the reader a video composition and let AVFoundation
        // bake the rotation in on the GPU. This matters more on a phone than on
        // a Mac: most footage shot on one carries a rotation.
        let needsComposition = !preferredTransform.isIdentity

        let reader = try AVAssetReader(asset: asset)
        if let startingAfter {
            // Decoding restarts here rather than at zero. The reader begins at
            // the sync sample at or before this time and drops what precedes the
            // range, and the loop below drops anything at or before the frame
            // already written, so the seam is exactly one frame wide and no
            // frame is written twice.
            reader.timeRange = CMTimeRange(start: startingAfter, duration: .positiveInfinity)
        }
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        // Scaled on the way out of the decoder rather than after the swap, so
        // that the frame copy, the detector's read into its 640 canvas and the
        // paste all run at the exported size instead of the source's — and so
        // that a face's footprint, which is what `closeUpDetail` resolves its
        // boost from, is the exported one. AVFoundation does the scaling as part
        // of decoding, which is both the cheapest place for it and the only one
        // that also makes the swap itself cheaper.
        let isDownscaled = displaySize != sourceSize

        let videoOutput: AVAssetReaderOutput
        if needsComposition {
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            // A composition renders at a size it derives from the asset, and the
            // pixel-buffer keys below never reach it. This is what keeps the
            // rotated path — most footage shot on a phone — agreeing with the
            // plain one instead of writing full-resolution frames into a
            // bounded writer.
            if isDownscaled { composition.renderSize = displaySize }
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack],
                                                             videoSettings: videoOutputSettings)
            output.videoComposition = composition
            videoOutput = output
        } else {
            var settings = videoOutputSettings
            if isDownscaled {
                settings[kCVPixelBufferWidthKey as String] = Int(displaySize.width)
                settings[kCVPixelBufferHeightKey as String] = Int(displaySize.height)
            }
            videoOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                   outputSettings: settings)
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MediaError.readerFailed(String(localized: "Could not read this video's frames.", bundle: .uiLanguage))
        }
        reader.add(videoOutput)

        // Writer
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        // An export must not say what made it. Empty is already the default, so
        // this asserts the invariant rather than changing behaviour: it is the
        // line that has to be deleted before a title, an author or a "created
        // with" tag could ever reach a file that leaves this device. Nothing is
        // carried over from the source asset's metadata either — the reader
        // hands over samples, not the container it found them in.
        writer.metadata = []

        let pixelCount = Double(displaySize.width * displaySize.height)
        let frameRate = nominalRate > 0 ? Double(nominalRate) : 30
        let bitrate = Int(pixelCount * frameRate * 0.15 * request.qualityMultiplier)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(1_500_000, min(bitrate, 120_000_000)),
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        if request.useHEVC {
            compression[AVVideoQualityKey] = 0.9
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: request.useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(displaySize.width),
            AVVideoHeightKey: Int(displaySize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        writerInput.expectsMediaDataInRealTime = false
        // Rotation is already baked into the pixels, so the output needs no
        // transform of its own — setting one here would rotate it twice.
        writerInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(displaySize.width),
                kCVPixelBufferHeightKey as String: Int(displaySize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])

        guard writer.canAdd(writerInput) else {
            throw MediaError.writerFailed("Could not set up the video encoder.")
        }
        writer.add(writerInput)

        // Every input must be attached before writing starts — `AVAssetWriter`
        // refuses `add(_:)` afterwards. The samples are pumped later, once the
        // frames are done.
        let audio = withAudio ? try await AudioPassthrough.attach(to: writer, from: asset) : nil

        guard writer.startWriting() else {
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The encoder refused to start.")
        }
        // Every segment is a clip in its own right, starting at zero, so the
        // frames below are written at their offset from the first one this
        // segment kept rather than at their time in the source. A segment whose
        // timeline began at ten seconds would need an edit list to describe, and
        // the join would then have to reason about one.
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription
                                          ?? "The decoder refused to start.")
        }

        var framesInSegment = 0
        /// Counted separately from `framesInSegment` because it is what paces
        /// the thermal check below: frames go in bursts of `depth` and come out
        /// one at a time, so counting the ones that came out would ask the same
        /// question several times while the queue fills and not at all while it
        /// drains.
        var framesSubmitted = 0
        var lastReport = Date()
        var framesSinceReport = 0
        var throughput = throughputSoFar

        /// Source time of this segment's first kept frame, and of its last.
        var segmentStart: CMTime?
        var lastWritten: CMTime?
        /// How long the final frame should be held for, which the join needs to
        /// know so the seam does not gain or lose a frame's worth of time.
        /// Measured between written frames, with the track's nominal rate only
        /// as the seed for a segment that writes exactly one.
        var frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 600)

        // Frames in the engine, oldest first. Submitting several keeps the GPU
        // and CPU stages of different frames overlapping; draining in FIFO
        // order keeps what reaches the writer strictly monotonic in time,
        // which AVAssetWriter requires.
        struct InFlight {
            var task: Task<SwapResult, Error>
            var output: CVPixelBuffer
            var time: CMTime
            /// Retained so the decoder cannot recycle the input underneath us.
            var sample: CMSampleBuffer
        }
        var inFlight: [InFlight] = []

        /// Whether a drain put a frame in the file, or gave up because the app
        /// is on its way out.
        enum Drain { case wrote, interrupted }

        // The starting depth is the ceiling for the whole run. Throttling can
        // only lower it and cooling can only return it to here — a device that
        // has recovered does not get to push harder than the profile allowed
        // when it was cold.
        let startingDepth = max(1, request.concurrentFrames)
        var depth = startingDepth

        // The audio has to be fed *alongside* the frames, not after them.
        // AVAssetWriter applies backpressure across all of its inputs together:
        // an input that has been added but never fed eventually stops its
        // siblings from accepting data, and the frame loop below would then
        // wait on `isReadyForMoreMediaData` forever. Each input is fed by its
        // own task, so neither can starve the other.
        let audioTask: Task<Void, Error>? = audio.map { passthrough in
            Task { try await passthrough.copy() }
        }

        defer {
            // On cancellation or a thrown error, stop the decoder and let go of
            // any frames still inside the engine.
            for item in inFlight { item.task.cancel() }
            audioTask?.cancel()
            if reader.status == .reading { reader.cancelReading() }
        }

        /// Waits for the oldest frame and writes it.
        func drainOldest() async throws -> Drain {
            guard !inFlight.isEmpty else { return .wrote }
            let item = inFlight.removeFirst()

            let result: SwapResult
            do {
                result = try await item.task.value
            } catch {
                // A frame that failed while the app is leaving failed *because*
                // the app is leaving: the GPU refuses command buffers submitted
                // from the background, and Core ML goes with it. Reporting that
                // as a broken render would be reporting the pause as a fault.
                if suspension.isBackgrounded { return .interrupted }
                throw error
            }

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if suspension.isBackgrounded { return .interrupted }
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            let base = segmentStart ?? item.time
            if !adaptor.append(item.output, withPresentationTime: item.time - base) {
                // Same reasoning as above, and this is the likelier of the two:
                // the encoder is a VideoToolbox session living in another
                // process, and it is taken away the moment the app is no longer
                // in front.
                if suspension.isBackgrounded { return .interrupted }
                throw MediaError.writerFailed(writer.error?.localizedDescription
                                              ?? "A frame could not be encoded.")
            }
            if segmentStart == nil { segmentStart = base }
            if let previous = lastWritten, item.time > previous {
                frameDuration = item.time - previous
            }
            lastWritten = item.time

            framesInSegment += 1
            framesSinceReport += 1

            let elapsed = Date().timeIntervalSince(lastReport)
            if elapsed >= 0.4 {
                let instantaneous = Double(framesSinceReport) / elapsed
                // Smooth the rate so the estimate does not jitter per frame.
                throughput = throughput == 0 ? instantaneous
                                             : throughput * 0.7 + instantaneous * 0.3
                lastReport = Date()
                framesSinceReport = 0

                let snapshot = ExportProgress(framesWritten: framesAlreadyWritten + framesInSegment,
                                              totalFrames: totalFrames,
                                              framesPerSecond: throughput,
                                              facesSwappedInLastFrame: result.facesSwapped)
                await MainActor.run { progress(snapshot) }
            }
            return .wrote
        }

        var interrupted = false

        submitting: while true {
            try Task.checkCancellation()
            // Asked once per frame rather than waited on, so the export stops
            // feeding the encoder within a frame of the app being told it is
            // going away — while there is still background time to close the
            // file with.
            if suspension.isBackgrounded { interrupted = true; break }

            guard let sample = videoOutput.copyNextSampleBuffer() else { break }
            guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

            // Resuming lands on the sync sample before the frame we want, so
            // the frames between it and the seam arrive again and are dropped.
            if let startingAfter, presentationTime <= startingAfter { continue }

            let width = CVPixelBufferGetWidth(input)
            let height = CVPixelBufferGetHeight(input)

            // Each in-flight frame needs its own destination.
            //
            // These come from the adaptor's own pool rather than being
            // recycled by hand: `append` retains the buffer and the encoder
            // reads it asynchronously, so a buffer handed straight back to the
            // engine gets overwritten while it is still being encoded. The
            // pool only vends a buffer once the encoder has released it.
            let output: CVPixelBuffer
            if let pool = adaptor.pixelBufferPool {
                var pooled: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled)
                guard status == kCVReturnSuccess, let pooled else {
                    throw MediaError.pixelBuffer("The encoder ran out of frame buffers.")
                }
                // The pool is built at the size the writer was configured with,
                // and the decoder is asked for that same size — but only the
                // writer's half of that is ours to guarantee. Rather than trust
                // the two to agree, check: the engine requires its source and
                // destination to be the same size and asserts it with a
                // `precondition`, so a decoder that rounded differently would
                // take the export down with a trap instead of an error. An
                // off-size frame is worth an honest failure at `append`, not a
                // crash here.
                if CVPixelBufferGetWidth(pooled) == width,
                   CVPixelBufferGetHeight(pooled) == height {
                    output = pooled
                } else {
                    output = try PixelSurface.makeBuffer(width: width, height: height)
                }
            } else {
                output = try PixelSurface.makeBuffer(width: width, height: height)
            }

            let options = request.options
            let task = Task { try await engine.swap(input, into: output, options: options) }
            inFlight.append(InFlight(task: task, output: output,
                                     time: presentationTime, sample: sample))

            framesSubmitted += 1
            // Roughly once a second of export, ask the device how it is doing.
            // Thermal transitions take tens of seconds, so this is far more
            // often than it needs to be and still costs nothing measurable.
            if framesSubmitted % 30 == 0 {
                let profile = DeviceCapabilities.recommendedProfile(
                    enhancing: request.options.enhanceFace)
                let adjusted = min(startingDepth, max(1, profile.concurrentFrames))
                if adjusted != depth {
                    EngineLog.engine.notice(
                        "Export depth \(depth) → \(adjusted) (\(profile.reason, privacy: .public))")
                    depth = adjusted
                }
            }

            // A `while` rather than the Mac's `if`, because `depth` can now
            // shrink underneath a queue that is already deeper than it: one
            // drain per frame would only ever converge back to the old depth.
            while inFlight.count >= depth {
                if try await drainOldest() == .interrupted {
                    interrupted = true
                    break submitting
                }
            }
        }

        // Whatever is still in the engine is finished and written — unless the
        // app is leaving, in which case it is dropped. Encoding three more
        // frames from the background is exactly the thing that cannot be done,
        // and redoing them on the way back costs a fraction of a second.
        if !interrupted {
            while !inFlight.isEmpty {
                try Task.checkCancellation()
                if try await drainOldest() == .interrupted { interrupted = true; break }
            }
        }
        for item in inFlight { item.task.cancel() }
        inFlight.removeAll()

        if !interrupted, reader.status == .failed {
            // The decoder is a VideoToolbox session too, and it is revoked on
            // the same rule as the encoder. `AVError.operationInterrupted` here
            // means the app lost the foreground between the loop's last check
            // and now, which is a pause rather than a broken video.
            if suspension.isBackgrounded {
                interrupted = true
            } else {
                throw MediaError.readerFailed(reader.error?.localizedDescription
                                              ?? "Decoding stopped unexpectedly.")
            }
        }

        // Usually finished long ago — audio passthrough is far cheaper than the
        // frames — but its failures still have to surface here, except when the
        // segment is being abandoned and the audio will be taken off the source
        // at the join instead.
        if interrupted {
            audioTask?.cancel()
            _ = try? await audioTask?.value
        } else {
            try await audioTask?.value
        }

        guard let segmentStart, let lastWritten else {
            // Not one frame reached the file. There is no segment to keep and
            // nothing for the caller to advance past.
            writer.cancelWriting()
            return SegmentOutcome(writtenThrough: nil,
                                  wasInterrupted: interrupted,
                                  framesWritten: framesAlreadyWritten,
                                  throughput: throughput)
        }

        writerInput.markAsFinished()

        // Pinning the end matters for a piece that is going to be joined: the
        // join reads each file's duration to know where the next one starts, and
        // a writer left to infer it can hold the last frame for a different
        // length than the rest. The one case that must *not* be pinned is a
        // complete first segment, whose audio track legitimately runs a little
        // past the last video frame — ending the session at the video's end
        // would cut it off, which is a regression on the path nothing went
        // wrong on.
        if interrupted || !withAudio {
            writer.endSession(atSourceTime: lastWritten - segmentStart + frameDuration)
        }

        await writer.finishWriting()
        if writer.status != .completed {
            // Closing the file is the one piece of work that has to happen after
            // the app has already been told to go, and the assertion that buys
            // time for it can expire. Losing the segment costs the frames in it,
            // not the export: the caller starts the next one from where this one
            // was asked to begin.
            if interrupted {
                EngineLog.engine.error(
                    "could not close the paused export segment, rendering it again: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
                writer.cancelWriting()
                return SegmentOutcome(writtenThrough: nil,
                                      wasInterrupted: true,
                                      framesWritten: framesAlreadyWritten,
                                      throughput: throughput)
            }
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The file could not be finished.")
        }

        return SegmentOutcome(writtenThrough: lastWritten,
                              wasInterrupted: interrupted,
                              framesWritten: framesAlreadyWritten + framesInSegment,
                              throughput: throughput)
    }

    /// Puts the pieces of a paused export back together.
    ///
    /// Nothing is re-encoded. The segments go into a composition end to end,
    /// which is only a description of where the samples are, and a passthrough
    /// export copies those samples into one file — so joining costs the time it
    /// takes to read and write the bytes once, not the time it took to make
    /// them.
    ///
    /// The audio comes off the original rather than out of the segments. Only
    /// the first segment has any, it stops wherever the user happened to leave
    /// the app, and re-reading one track from the source is both simpler and
    /// exactly what the uninterrupted path does.
    private static func join(_ segments: [URL],
                             audioFrom source: URL,
                             into destination: URL) async throws {

        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.writerFailed(
                String(localized: "The paused export could not be joined back together.", bundle: .uiLanguage))
        }

        var cursor = CMTime.zero
        for url in segments {
            let piece = AVURLAsset(url: url)
            guard let track = try await piece.loadTracks(withMediaType: .video).first else { continue }
            // The *track's* range, emphatically not the asset's duration. An
            // asset is as long as its longest track, and the first segment has
            // an audio track that is very probably longer than its own video:
            // the passthrough copies audio far faster than frames encode, so a
            // pause ten seconds into a minute of footage leaves a segment
            // holding ten seconds of pictures and most of a minute of sound.
            // Advancing the cursor by that would put a gap the length of the
            // difference in front of the next segment and drag the join out of
            // sync with the audio laid down below.
            let range = try await track.load(.timeRange)
            guard range.duration > .zero else { continue }
            try videoTrack.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }

        guard cursor > .zero else {
            throw MediaError.writerFailed(
                String(localized: "The paused export could not be joined back together.", bundle: .uiLanguage))
        }

        let original = AVURLAsset(url: source)
        if let sourceAudio = try await original.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // Bounded by both: a source whose audio runs past its last frame
            // must not lengthen the render, and a video whose frames outlast the
            // audio must not ask for samples that are not there.
            let span = CMTimeMinimum(try await original.load(.duration), cursor)
            if span > .zero {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: span),
                                               of: sourceAudio, at: .zero)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError.writerFailed(
                String(localized: "The paused export could not be joined back together.", bundle: .uiLanguage))
        }
        // The same invariant the writer asserts: an export must not say what
        // made it. A passthrough session copies the source asset's metadata by
        // default, and the source here is a composition of our own files, so
        // there is nothing to copy — this is the line that keeps it that way.
        session.metadata = []

        if #available(iOS 18.0, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            try await joinUsingDeprecatedExport(session, into: destination)
        }
    }

    /// `exportAsynchronously` is the only way to run a session at this project's
    /// deployment target, and is deprecated at the SDK it is built against.
    ///
    /// Marked deprecated itself so that calling it here is not a warning: the
    /// annotation is a note that this function disappears when the deployment
    /// target reaches 18, not a claim about the app.
    @available(iOS, deprecated: 18.0,
               message: "Superseded by AVAssetExportSession.export(to:as:).")
    private static func joinUsingDeprecatedExport(_ session: AVAssetExportSession,
                                                  into destination: URL) async throws {
        session.outputURL = destination
        session.outputFileType = .mp4
        // `AVAssetExportSession` is not `Sendable` and the handler below is, so
        // the capture has to be spelled out as deliberate. It is: `cancelExport`
        // is the one method on the class meant to be called from somewhere other
        // than where the export was started, and calling it is the documented
        // way to stop one. The unsafety is in the type system, not in the call.
        nonisolated(unsafe) let running = session
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                running.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            // Cancel arrives while the bytes are being copied. Without this the
            // session runs to the end and the user who asked to stop is handed a
            // finished video for their trouble.
            running.cancelExport()
        }
        // Ahead of the status check so that a cancellation reads as one rather
        // than as a join that failed for reasons nobody can act on.
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw MediaError.writerFailed(
                session.error?.localizedDescription
                ?? String(localized: "The paused export could not be joined back together.", bundle: .uiLanguage))
        }
    }

    /// Carries the original audio track across untouched — no decode, no
    /// re-encode, so it costs almost nothing and loses nothing.
    ///
    /// Split into attach-then-copy for a reason that is easy to get wrong:
    /// `AVAssetWriter` accepts inputs only before `startWriting()`, and
    /// afterwards `canAdd` simply returns false. Creating the audio input at
    /// the point the samples are written — which is necessarily after the video
    /// frames — means it is never added at all, and the export silently comes
    /// out mute. `attach` therefore runs alongside the video input, and `copy`
    /// runs at the end.
    ///
    /// The samples come from a reader of its own. One reader feeding both a
    /// video and an audio output would impose interleaving requirements the
    /// frame loop cannot meet while it keeps several frames in flight.
    private struct AudioPassthrough {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput

        /// Returns nil when the source has no audio; throws when it has audio
        /// that cannot be carried, which is worth saying out loud rather than
        /// discovering on playback.
        static func attach(to writer: AVAssetWriter,
                           from asset: AVURLAsset) async throws -> AudioPassthrough? {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            guard let formatDescription = try await track.load(.formatDescriptions).first else {
                return nil
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else {
                throw MediaError.readerFailed(String(localized: "This video's audio track could not be read.", bundle: .uiLanguage))
            }
            reader.add(output)

            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: nil,
                                           sourceFormatHint: formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                let codec = VideoPipeline.fourCCString(
                    CMFormatDescriptionGetMediaSubType(formatDescription))
                throw MediaError.writerFailed(
                    String(localized: "This video's \(codec) audio cannot be stored in an MP4.", bundle: .uiLanguage))
            }
            writer.add(input)

            return AudioPassthrough(reader: reader, output: output, input: input)
        }

        func copy() async throws {
            defer { input.markAsFinished() }

            guard reader.startReading() else {
                throw MediaError.readerFailed(reader.error?.localizedDescription
                                              ?? "The audio track could not be read.")
            }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard input.append(sample) else {
                    throw MediaError.writerFailed("The audio could not be written.")
                }
            }
            if reader.status == .failed {
                throw MediaError.readerFailed(reader.error?.localizedDescription
                                              ?? "Reading the audio stopped unexpectedly.")
            }
            if reader.status == .reading { reader.cancelReading() }
        }
    }
}
