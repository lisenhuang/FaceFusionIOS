//
//  EngineLog.swift
//  FaceFusion
//
//  One subsystem for the whole app, so a run reads back in order:
//
//      log stream --predicate 'subsystem == "com.lisenhuang.FaceFusion"'
//
//  On the Mac this existed because the engine ran out of process and its
//  failures were invisible in the app's console. In-process that argument is
//  gone, but the categories are not: a per-frame timing line and a download
//  progress line are different kinds of noise, and being able to filter to one
//  of them is the difference between reading a log and scrolling past it.
//
//  Nothing in this app calls `print`. `Logger` is nearly free when no-one is
//  listening, redacts interpolated values by default, and does not spill onto
//  a shipping build's stdout.
//

import Foundation
import os

enum EngineLog {
    static let subsystem = "com.lisenhuang.FaceFusion"

    /// Model loading, execution-provider selection and device limits.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Per-frame inference.
    static let inference = Logger(subsystem: subsystem, category: "inference")
    /// The app's side of the engine: preparation, cancellation, memory pressure.
    static let client = Logger(subsystem: subsystem, category: "client")
    /// Downloads and installation.
    static let models = Logger(subsystem: subsystem, category: "models")
    /// Metal device setup, pipeline compilation and GPU fallbacks. Its own
    /// category because "the GPU path quietly gave up" is the one failure that
    /// costs speed without costing correctness, so it has to be findable.
    static let metal = Logger(subsystem: subsystem, category: "metal")
}
