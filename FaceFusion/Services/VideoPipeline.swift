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
//  Three things do change, and all three are consequences of the hardware
//  rather than of the framework:
//
//  - Frames are handed to the engine as `CVPixelBuffer`s. In-process there is
//    no boundary to pass an IOSurface across, so there is nothing to unwrap.
//  - How many frames are kept in flight is no longer a constant. A phone
//    throttles, and once it does, a deeper queue makes the export slower rather
//    than faster, so the depth is re-derived from the thermal state as the
//    export runs and only ever ratchets down from where it started.
//  - The idle timer is held off. A ten-minute render on a locked screen is a
//    ten-minute render that gets suspended partway through.
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
    static func export(_ request: ExportRequest,
                       engine: EngineClient,
                       progress: @escaping @MainActor (ExportProgress) -> Void) async throws {

        // Renders are long and the user has no reason to keep touching the
        // screen while one runs, so the device would otherwise lock and suspend
        // the app partway through. Restored on every exit path, including a
        // thrown error and a cancellation — a `defer` cannot await, so the
        // restore is a hop rather than a call, which is fine: nothing depends
        // on it having happened by the time `export` returns.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }

        let asset = AVURLAsset(url: request.source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let (naturalSize, preferredTransform, nominalRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let rotated = naturalSize.applying(preferredTransform)
        let displaySize = CGSize(width: abs(rotated.width).rounded(),
                                 height: abs(rotated.height).rounded())

        // The engine expects upright faces. Rather than rotating every frame
        // ourselves, hand the reader a video composition and let AVFoundation
        // bake the rotation in on the GPU. This matters more on a phone than on
        // a Mac: most footage shot on one carries a rotation.
        let needsComposition = !preferredTransform.isIdentity

        let reader = try AVAssetReader(asset: asset)
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let videoOutput: AVAssetReaderOutput
        if needsComposition {
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack],
                                                             videoSettings: videoOutputSettings)
            output.videoComposition = composition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                   outputSettings: videoOutputSettings)
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MediaError.readerFailed(String(localized: "Could not read this video's frames.", bundle: .uiLanguage))
        }
        reader.add(videoOutput)

        // Writer
        if FileManager.default.fileExists(atPath: request.destination.path) {
            try FileManager.default.removeItem(at: request.destination)
        }
        let writer = try AVAssetWriter(outputURL: request.destination, fileType: .mp4)

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
        let audio = try await AudioPassthrough.attach(to: writer, from: asset)

        guard writer.startWriting() else {
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The encoder refused to start.")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription
                                          ?? "The decoder refused to start.")
        }

        let totalFrames = try await inspect(request.source).estimatedFrameCount
        var framesWritten = 0
        var framesSubmitted = 0
        var lastReport = Date()
        var framesSinceReport = 0
        var throughput: Double = 0

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
        func drainOldest() async throws {
            guard !inFlight.isEmpty else { return }
            let item = inFlight.removeFirst()
            let result = try await item.task.value

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !adaptor.append(item.output, withPresentationTime: item.time) {
                throw MediaError.writerFailed(writer.error?.localizedDescription
                                              ?? "A frame could not be encoded.")
            }

            framesWritten += 1
            framesSinceReport += 1

            let elapsed = Date().timeIntervalSince(lastReport)
            if elapsed >= 0.4 {
                let instantaneous = Double(framesSinceReport) / elapsed
                // Smooth the rate so the estimate does not jitter per frame.
                throughput = throughput == 0 ? instantaneous
                                             : throughput * 0.7 + instantaneous * 0.3
                lastReport = Date()
                framesSinceReport = 0

                let snapshot = ExportProgress(framesWritten: framesWritten,
                                              totalFrames: totalFrames,
                                              framesPerSecond: throughput,
                                              facesSwappedInLastFrame: result.facesSwapped)
                await MainActor.run { progress(snapshot) }
            }
        }

        while let sample = videoOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)

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
                output = pooled
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
                try await drainOldest()
            }
        }

        while !inFlight.isEmpty {
            try Task.checkCancellation()
            try await drainOldest()
        }

        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription
                                          ?? "Decoding stopped unexpectedly.")
        }
        writerInput.markAsFinished()

        // Usually finished long ago — audio passthrough is far cheaper than
        // the frames — but its failures still have to surface here.
        try await audioTask?.value

        await writer.finishWriting()
        if writer.status == .failed {
            throw MediaError.writerFailed(writer.error?.localizedDescription
                                          ?? "The file could not be finished.")
        }

        let finalProgress = ExportProgress(framesWritten: framesWritten,
                                           totalFrames: max(totalFrames, framesWritten),
                                           framesPerSecond: throughput,
                                           facesSwappedInLastFrame: 0)
        await MainActor.run { progress(finalProgress) }
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
