//
//  PixelSurface.swift
//  FaceFusion
//
//  Pixel buffers, and getting still images into and out of them.
//
//  `CVPixelBuffer` is the currency of this app: it is what the video decoder
//  hands back, what Core Image renders into, what the encoder's pool vends, and
//  — now that the engine runs in-process — what a frame is handed to the
//  pipeline as. On the Mac that last role belonged to the `IOSurface` behind the
//  buffer, because an IOSurface is what XPC can pass by reference instead of
//  copying. With no process boundary left there is nothing to unwrap, so
//  `surface(of:)` is gone and every signature simply takes the buffer.
//
//  The buffers are still asked for IOSurface backing, which is not vestigial:
//  it is what makes them Metal-compatible, and the Metal image ops read the same
//  bytes the CPU paths do rather than a converted texture.
//
//  The one real change is the shared `CIContext`. The Mac built one per call,
//  which on a Mac is a rounding error. It is not on a phone: a Core Image
//  context carries compiled kernels and a command queue, and the face scan
//  renders dozens of frames back to back to cut thumbnails out of them. One
//  context, built once, is the difference between a scan that feels instant and
//  one that visibly stutters.
//

import Foundation
import os
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import UIKit

enum PixelSurface {

    /// The process's only Core Image context.
    ///
    /// Metal-backed, because the software renderer on a phone is a last resort
    /// rather than a fallback worth landing on silently. The working colour
    /// space is device RGB — that is, none at all: everything downstream treats
    /// BGRA as raw numbers, and a colour-managed round trip through linear sRGB
    /// would change the pixels the models see for no benefit the user could
    /// name. The Mac's `loadImage` already pinned this; the display path now
    /// matches it instead of quietly using a different one.
    ///
    /// `CIContext` is documented as thread-safe, which matters here: the
    /// preview, the scan and the export all reach for this from different
    /// tasks.
    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            // Nothing here renders the same graph twice, so cached
            // intermediates are pure resident memory on a device that measures
            // its budget in hundreds of megabytes.
            .cacheIntermediates: false,
        ]
        if let device = MetalContext.shared?.device ?? MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        EngineLog.metal.notice("No Metal device for Core Image; falling back to the software renderer.")
        return CIContext(options: options)
    }()

    /// Creates an IOSurface-backed BGRA pixel buffer.
    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MediaError.pixelBuffer("Could not allocate a \(width)x\(height) frame buffer.")
        }
        return buffer
    }

    /// Draws a decoded image into a fresh BGRA buffer, which is the form the
    /// engine takes a frame in.
    static func makeBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(width: image.width, height: image.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base,
                                      width: image.width, height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw MediaError.pixelBuffer("Could not draw the frame.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    // MARK: - Still images

    /// Decodes an image file into a BGRA pixel buffer, honouring EXIF
    /// orientation so a portrait shot from a phone arrives upright.
    static func loadImage(at url: URL, maximumDimension: Int = 2048) throws -> CVPixelBuffer {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw MediaError.decode("That image could not be read.")
        }

        var extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else {
            throw MediaError.decode("That image is empty.")
        }

        // Very large portraits cost detection time without improving the
        // identity embedding, which is computed from a 112px crop anyway.
        // A *target* photo is different — it is what gets written back out —
        // so that caller passes `.max` to skip this.
        var working = image
        let longest = max(extent.width, extent.height)
        if longest > CGFloat(maximumDimension) {
            let scale = CGFloat(maximumDimension) / longest
            working = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            extent = working.extent
        }
        // Move the image onto the origin: CIImage extents can be offset.
        working = working.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                            y: -extent.minY))

        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        let buffer = try makeBuffer(width: width, height: height)
        sharedContext.render(working, to: buffer,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    /// Writes a frame out as a still image, in whichever format the file
    /// extension names.
    ///
    /// The extension is the format decision: there is no save panel on iOS, so
    /// `MediaStore.makeOutputURL` picks `.png` or `.jpg` up front and this
    /// follows it. Getting that wrong writes a PNG with a `.jpg` on the end,
    /// which Photos will import and every other app will mislabel.
    static func write(_ buffer: CVPixelBuffer, to url: URL, quality: Double = 0.95) throws {
        guard let image = makeCGImage(from: buffer) else {
            throw MediaError.pixelBuffer("The finished frame could not be read back.")
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil) else {
            throw MediaError.writerFailed(
                "\(url.pathExtension.uppercased()) images cannot be written.")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.writerFailed("The image could not be saved.")
        }
    }

    // MARK: - Display

    static func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return sharedContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Wraps a pixel buffer as a `UIImage` for SwiftUI.
    ///
    /// Scale 1 deliberately: these are camera and decoder pixels, not artwork
    /// authored at @2x, and the preview canvas does its own aspect-fit from the
    /// pixel dimensions. A UIImage that claimed to be @3x would report a `size`
    /// a third of its pixel count and every box drawn over it would be wrong.
    static func makeUIImage(from buffer: CVPixelBuffer) -> UIImage? {
        guard let cgImage = makeCGImage(from: buffer) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Copies one buffer's pixels into another of the same size.
    static func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return }

        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(destination)
        let bytes = min(srcStride, dstStride)
        for y in 0 ..< height {
            memcpy(dst.advanced(by: y * dstStride), src.advanced(by: y * srcStride), bytes)
        }
    }
}

enum MediaError: LocalizedError {
    case decode(String)
    case pixelBuffer(String)
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .decode(let m), .pixelBuffer(let m), .readerFailed(let m),
             .writerFailed(let m), .unsupported(let m):
            return m
        case .noVideoTrack:
            return "That file does not contain a video track."
        }
    }
}
