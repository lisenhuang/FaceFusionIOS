//
//  MetalContext.swift
//  FaceFusion
//
//  The one Metal device, queue and shader library for the process.
//
//  Everything that touches the GPU goes through this: the compute kernels in
//  `MetalImageOps`, the shared-storage buffers behind `BGRAImage` and the ones
//  behind `TensorBuffer`. Having a single owner matters less for tidiness than
//  for memory — an `MTLDevice` and its command queue are process-wide resources
//  and building a second one per frame would be both slow and pointless.
//
//  `shared` is optional, and `nil` is not an error. A device with no usable
//  Metal, or a build where the shader library failed to make it into the
//  bundle, falls back to the CPU implementations in `ImageBuffer.swift`, which
//  are the validated ones anyway. The app still works; it is just slower.
//

import Foundation
import Metal
import os

final class MetalContext {

    /// Built once, lazily, on first use. `let` on a `static` in Swift is
    /// initialised atomically, so several frames racing in here get one context.
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue

    /// Optional on purpose. If `default.metallib` is missing the buffers are
    /// still worth having — a shared-storage allocation costs nothing extra and
    /// keeps `TensorBuffer` zero-copy — even though no kernel can run.
    let library: MTLLibrary?

    /// Compiling a compute pipeline takes milliseconds, so they are built once
    /// and kept. Several export frames encode concurrently, hence the lock;
    /// `MTLComputePipelineState` is not `Sendable`, hence `uncheckedState`.
    private let pipelines = OSAllocatedUnfairLock(uncheckedState: [String: MTLComputePipelineState]())

    /// Buffers are rounded up to this so `contents()` comes back page-aligned.
    /// Metal is free to sub-allocate anything smaller out of a heap, and a
    /// borrowed pointer that is not page-aligned cannot be wrapped with
    /// `makeBuffer(bytesNoCopy:)` later.
    private static let pageSize = Int(getpagesize())

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.library = device.makeDefaultLibrary()

        if library == nil {
            EngineLog.metal.error("Metal shader library unavailable — pixel work stays on the CPU")
        } else {
            EngineLog.metal.notice("Metal ready on \(device.name, privacy: .public)")
        }
    }

    /// Shared storage: on Apple Silicon the CPU and GPU address the same
    /// physical pages, so a buffer written by a kernel needs no download before
    /// ONNX Runtime or a `memcpy` reads it.
    func makeBuffer(length: Int) -> MTLBuffer? {
        guard length > 0 else { return nil }
        let page = Self.pageSize
        let rounded = (length + page - 1) / page * page
        return device.makeBuffer(length: rounded, options: .storageModeShared)
    }

    /// Cached compute pipeline for a kernel in `ImageOps.metal`.
    ///
    /// Two threads asking for the same uncached function will both compile it;
    /// that is a wasted millisecond once, not a correctness problem, and it is
    /// cheaper than holding the lock across a compile.
    func pipeline(_ function: String) throws -> MTLComputePipelineState {
        if let cached = pipelines.withLock({ $0[function] }) { return cached }

        guard let library, let kernel = library.makeFunction(name: function) else {
            throw makeEngineNSError(.inferenceFailed,
                                    underlying: "no Metal function named '\(function)'")
        }
        let state = try device.makeComputePipelineState(function: kernel)
        pipelines.withLock { $0[function] = state }
        return state
    }
}
