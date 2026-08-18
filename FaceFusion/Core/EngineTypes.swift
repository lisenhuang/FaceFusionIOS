//
//  EngineTypes.swift
//  FaceFusion
//
//  The vocabulary every other file speaks: what a model is, how the engine is
//  configured, what a detected face looks like, and what one swapped frame
//  cost.
//
//  On the Mac these types were the IPC contract between the app and an XPC
//  service, which is why they are all `Codable` and all `Sendable`. iOS has no
//  XPC for third-party apps, so nothing here crosses a process boundary any
//  more — but the shapes are validated against a working implementation and
//  they are still the one place a face, a policy or a stage timing is defined.
//  Keeping them wire-shaped costs nothing and keeps the preference store able
//  to persist a configuration verbatim.
//

import Foundation

// MARK: - Model catalogue

/// The models the engine knows how to load. Raw values match the file stem of
/// the corresponding FaceFusion asset, and are the keys used in `models.json`.
enum ModelID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case faceDetector   = "yoloface_8n"
    case faceLandmarker = "2dfan4"
    case faceRecognizer = "arcface_w600k_r50"
    case faceSwapper    = "inswapper_128_fp16"
    case faceEnhancer   = "gfpgan_1.4"
    case faceOccluder   = "dfl_xseg"

    /// Models without which no swap can run at all.
    static let required: [ModelID] = [.faceDetector, .faceRecognizer, .faceSwapper]

    // Conformance to CodingKeyRepresentable (declared above) comes free for a
    // String-backed enum, and makes `[ModelID: String]` encode as a JSON
    // object rather than a flat alternating key/value array — which keeps a
    // persisted configuration readable when debugging.

    var displayName: String {
        switch self {
        case .faceDetector:   return String(localized: "Face Detector", bundle: .uiLanguage)
        case .faceLandmarker: return String(localized: "Landmark Refiner", bundle: .uiLanguage)
        case .faceRecognizer: return String(localized: "Identity Encoder", bundle: .uiLanguage)
        case .faceSwapper:    return String(localized: "Face Swapper", bundle: .uiLanguage)
        case .faceEnhancer:   return String(localized: "Face Enhancer", bundle: .uiLanguage)
        case .faceOccluder:   return String(localized: "Occlusion Mask", bundle: .uiLanguage)
        }
    }

    var purpose: String {
        switch self {
        case .faceDetector:   return String(localized: "Finds faces and their five key points in every frame.", bundle: .uiLanguage)
        case .faceLandmarker: return String(localized: "Refines alignment with 68 landmarks for a steadier result.", bundle: .uiLanguage)
        case .faceRecognizer: return String(localized: "Encodes the identity of your source face.", bundle: .uiLanguage)
        case .faceSwapper:    return String(localized: "Performs the actual face replacement.", bundle: .uiLanguage)
        case .faceEnhancer:   return String(localized: "Restores detail and sharpness in the swapped face.", bundle: .uiLanguage)
        case .faceOccluder:   return String(localized: "Keeps hands, hair and objects that cross the face from being painted over.", bundle: .uiLanguage)
        }
    }
}

// MARK: - Configuration

enum ComputePolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Core ML picks between ANE, GPU and CPU.
    case automatic
    /// Excludes the Neural Engine; sometimes better for fp32 graphs.
    case gpu
    /// Prefers the Neural Engine, falling back to CPU.
    case neuralEngine
    /// Reference path. Slow, but never depends on Core ML op coverage.
    case cpu

    var id: String { rawValue }

    /// The string the Core ML execution provider expects.
    var mlComputeUnits: String {
        switch self {
        case .automatic:    return "ALL"
        case .gpu:          return "CPUAndGPU"
        case .neuralEngine: return "CPUAndNeuralEngine"
        case .cpu:          return "CPUOnly"
        }
    }

    var displayName: String {
        switch self {
        case .automatic:    return String(localized: "Automatic", bundle: .uiLanguage)
        case .gpu:          return String(localized: "GPU", bundle: .uiLanguage)
        case .neuralEngine: return String(localized: "Neural Engine", bundle: .uiLanguage)
        case .cpu:          return String(localized: "CPU only", bundle: .uiLanguage)
        }
    }

    /// One line of plain English for the Settings picker. Written to stop the
    /// obvious mistake: on the Mac, pinning these graphs to the Neural Engine
    /// measured 17× *slower* than letting Core ML choose, because they are
    /// convolutional generators the ANE largely rejects and the run degenerates
    /// into constant fallback. An iPhone's balance is not a Mac's, which is why
    /// the choice is exposed at all — but it is a thing to measure, not guess.
    var detail: String {
        switch self {
        case .automatic:
            return String(localized: "Lets the system spread the work across the Neural Engine, GPU and CPU. Fastest on most devices.", bundle: .uiLanguage)
        case .gpu:
            return String(localized: "Keeps everything on the GPU and CPU. Worth trying if Automatic stutters.", bundle: .uiLanguage)
        case .neuralEngine:
            return String(localized: "Prefers the Neural Engine. Much slower for these models on some devices — measure before keeping it.", bundle: .uiLanguage)
        case .cpu:
            return String(localized: "Uses the CPU alone. Very slow, but it always works.", bundle: .uiLanguage)
        }
    }
}

/// Lower-level execution knobs. The defaults are what ships, and nothing in
/// the app varies them — they exist so a configuration can be stated in full.
struct EngineTuning: Codable, Sendable, Equatable {
    /// Every model here has fully static shapes, and telling Core ML so lets
    /// it take graph regions it would otherwise leave to the CPU.
    var requireStaticInputShapes: Bool
    /// "MLProgram" or "NeuralNetwork".
    var modelFormat: String
    /// Logs which unit each operator landed on. Expensive; diagnostics only.
    var profileComputePlan: Bool
    /// 0 leaves ORT's default.
    var intraOpThreads: Int
    /// How many independent `ORTSession`s to build for the face enhancer, so
    /// two frames can be restored at once instead of queueing on one session.
    ///
    /// The enhancer is both the slowest stage and the largest model, so this is
    /// the only place replication pays for itself — and it is not free: each
    /// replica is another ~340 MB of resident weights, on a device where the
    /// jetsam limit is the ceiling rather than the swap file. One replica is
    /// the safe default; ``DeviceCapabilities/isMemoryConstrained`` decides
    /// whether a second is affordable.
    var enhancerReplicas: Int

    init(requireStaticInputShapes: Bool = true,
         modelFormat: String = "MLProgram",
         profileComputePlan: Bool = false,
         intraOpThreads: Int = 0,
         enhancerReplicas: Int = 1) {
        self.requireStaticInputShapes = requireStaticInputShapes
        self.modelFormat = modelFormat
        self.profileComputePlan = profileComputePlan
        self.intraOpThreads = intraOpThreads
        self.enhancerReplicas = enhancerReplicas
    }
}

struct EngineConfiguration: Codable, Sendable {
    /// Absolute paths to each `.onnx` file, keyed by model.
    var modelPaths: [ModelID: String]
    /// Where Core ML may cache the models it compiles from the ONNX graphs.
    var modelCacheDirectory: String
    var compute: ComputePolicy
    var tuning: EngineTuning

    init(modelPaths: [ModelID: String],
         modelCacheDirectory: String,
         compute: ComputePolicy = .automatic,
         tuning: EngineTuning = EngineTuning()) {
        self.modelPaths = modelPaths
        self.modelCacheDirectory = modelCacheDirectory
        self.compute = compute
        self.tuning = tuning
    }
}

struct EnginePreparation: Codable, Sendable {
    var loadedModels: [ModelID]
    /// True when Core ML accepted at least one graph; false means pure CPU.
    var usingCoreML: Bool
    var executionProvider: String
    var warmupSeconds: Double

    init(loadedModels: [ModelID], usingCoreML: Bool,
         executionProvider: String, warmupSeconds: Double) {
        self.loadedModels = loadedModels
        self.usingCoreML = usingCoreML
        self.executionProvider = executionProvider
        self.warmupSeconds = warmupSeconds
    }
}

// MARK: - Faces

struct FaceBox: Codable, Sendable, Hashable {
    var x: Double, y: Double, width: Double, height: Double
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

struct DetectedFace: Codable, Sendable, Hashable {
    /// Stable within one frame: index in detection order (left to right).
    var index: Int
    var box: FaceBox
    var score: Double
    /// Five key points in image pixels: left eye, right eye, nose, mouth L, mouth R.
    var landmarks: [[Double]]

    init(index: Int, box: FaceBox, score: Double, landmarks: [[Double]]) {
        self.index = index; self.box = box; self.score = score; self.landmarks = landmarks
    }
}

struct FrameAnalysis: Codable, Sendable {
    var faces: [DetectedFace]
    /// Parallel to `faces`, and empty unless the caller asked for identities.
    /// The per-frame overlay does not need them; the "who is in this video"
    /// scan does, and paying for them there only is the difference between one
    /// extra model pass per face and none.
    var identities: [FaceIdentity]

    init(faces: [DetectedFace], identities: [FaceIdentity] = []) {
        self.faces = faces
        self.identities = identities
    }
}

/// What `analyzeFaces` should do beyond detecting. Alignment has to match the
/// settings the swap will run with, or the identities compared at swap time
/// are not the ones the picker collected.
struct AnalysisOptions: Codable, Sendable {
    var detectorScore: Double
    var refineLandmarks: Bool
    /// Skips the recognizer when only boxes are wanted.
    var includeIdentities: Bool

    init(detectorScore: Double = 0.5,
         refineLandmarks: Bool = true,
         includeIdentities: Bool = true) {
        self.detectorScore = detectorScore
        self.refineLandmarks = refineLandmarks
        self.includeIdentities = includeIdentities
    }
}

// MARK: - Identity

/// An L2-normalised ArcFace vector — the same 512 numbers the swapper is
/// conditioned on, reused here for a different purpose: deciding whether two
/// faces in different frames are the same person.
struct FaceIdentity: Codable, Sendable, Equatable {
    var vector: [Float]

    init(vector: [Float]) { self.vector = vector }

    /// Cosine distance: 0 for identical, 1 for unrelated, 2 for opposite.
    /// Both operands are already unit length, so the dot product *is* the
    /// cosine and no division is needed.
    ///
    /// For scale, with this model two photos of one person typically land
    /// between 0.2 and 0.5, and two different people above 0.7.
    /// Vectors of different lengths came from different models, so they are
    /// reported as unmatchable rather than compared over their common prefix —
    /// a truncated dot product looks like a perfectly ordinary distance.
    func distance(to other: FaceIdentity) -> Double {
        guard !vector.isEmpty, vector.count == other.vector.count else {
            return .greatestFiniteMagnitude
        }
        var dot: Float = 0
        for index in 0 ..< vector.count { dot += vector[index] * other.vector[index] }
        return 1 - Double(dot)
    }

    /// Nearest distance to any of `others`, or infinity when there are none.
    func nearestDistance(among others: [FaceIdentity]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for other in others { best = min(best, distance(to: other)) }
        return best
    }
}

/// The identities of the faces the user checked.
///
/// Sent to the engine once per change rather than riding in `SwapOptions`,
/// which is rebuilt for every frame — 512 floats per face at 60fps is a lot of
/// copying to do and throw away. `generation` rises on each send, and a swap
/// naming a generation the engine no longer holds is refused rather than
/// quietly swapping against a stale set.
struct ReferenceFaceSet: Codable, Sendable {
    var generation: Int
    var identities: [FaceIdentity]

    init(generation: Int, identities: [FaceIdentity]) {
        self.generation = generation
        self.identities = identities
    }
}

struct SourceAnalysis: Codable, Sendable {
    /// The face whose identity the engine is now conditioned on.
    var face: DetectedFace?
    var faceCount: Int
    /// Every face found in the portrait, left to right, so the app can offer a
    /// choice. `face` is always one of these; its `index` says which.
    var faces: [DetectedFace]
    init(face: DetectedFace?, faceCount: Int, faces: [DetectedFace] = []) {
        self.face = face; self.faceCount = faceCount; self.faces = faces
    }
}

// MARK: - Swapping

/// Which face(s) in the target frame get replaced.
enum FaceSelection: Codable, Sendable, Equatable {
    case all
    case largest
    /// Nearest to a point in normalised (0...1) frame coordinates. Survives
    /// resolution changes and frame-to-frame detector jitter better than an index.
    case nearestTo(x: Double, y: Double)
    /// Only faces matching one of the identities in the reference set the
    /// engine currently holds, within `maxDistance` cosine distance.
    ///
    /// This is the only selection that means the same thing throughout a
    /// video. An index is left-to-right order within a single frame, so two
    /// people crossing reassigns it; a fixed point stops naming anyone as soon
    /// as the subject moves. An identity keeps pointing at the person.
    case reference(generation: Int, maxDistance: Double)

    /// True when choosing faces costs an identity pass over every detection.
    var needsIdentities: Bool {
        if case .reference = self { return true }
        return false
    }
}

/// Default cosine distance for calling two faces the same person.
///
/// Mirrors FaceFusion's `reference_face_distance`. Loose enough to hold a
/// person across a turn of the head or a change of lighting, tight enough to
/// keep two different people apart.
let defaultFaceMatchDistance = 0.6

struct SwapOptions: Codable, Sendable {
    var selection: FaceSelection
    /// 0 keeps more of the target's identity, 1 pushes fully to the source.
    /// Mirrors FaceFusion's `face_swapper_weight`.
    var identityStrength: Double
    var enhanceFace: Bool
    /// 0...1, how much of the enhanced face is blended back in.
    var enhancementBlend: Double
    /// Feathering of the paste-back mask. Mirrors `face_mask_blur`.
    var maskBlur: Double
    /// Carve occluding objects — hands, hair — out of the paste mask, when the
    /// occluder model is loaded. Mirrors `occlusion` in `face_mask_types`.
    var maskOcclusion: Bool
    /// Minimum detector confidence.
    var detectorScore: Double
    /// Use the 68-point landmarker to refine alignment when available.
    var refineLandmarks: Bool

    init(selection: FaceSelection = .all,
         identityStrength: Double = 0.5,
         enhanceFace: Bool = true,
         enhancementBlend: Double = 0.8,
         maskBlur: Double = 0.3,
         maskOcclusion: Bool = true,
         detectorScore: Double = 0.5,
         refineLandmarks: Bool = true) {
        self.selection = selection
        self.identityStrength = identityStrength
        self.enhanceFace = enhanceFace
        self.enhancementBlend = enhancementBlend
        self.maskBlur = maskBlur
        self.maskOcclusion = maskOcclusion
        self.detectorScore = detectorScore
        self.refineLandmarks = refineLandmarks
    }
}

/// Per-stage cost of one frame, in seconds. Used by the engine's periodic
/// timing log.
struct StageSeconds: Codable, Sendable, Equatable {
    var detect: Double = 0
    var landmarks: Double = 0
    /// Recognising which detections are the faces the user checked. Zero for
    /// every selection except `.reference`.
    var match: Double = 0
    var swap: Double = 0
    var paste: Double = 0
    var enhance: Double = 0
    var total: Double = 0

    init() {}

    static func + (a: StageSeconds, b: StageSeconds) -> StageSeconds {
        var out = StageSeconds()
        out.detect = a.detect + b.detect
        out.landmarks = a.landmarks + b.landmarks
        out.match = a.match + b.match
        out.swap = a.swap + b.swap
        out.paste = a.paste + b.paste
        out.enhance = a.enhance + b.enhance
        out.total = a.total + b.total
        return out
    }

    func scaled(by factor: Double) -> StageSeconds {
        var out = StageSeconds()
        out.detect = detect * factor
        out.landmarks = landmarks * factor
        out.match = match * factor
        out.swap = swap * factor
        out.paste = paste * factor
        out.enhance = enhance * factor
        out.total = total * factor
        return out
    }
}

struct SwapResult: Codable, Sendable {
    var facesFound: Int
    var facesSwapped: Int
    var inferenceSeconds: Double
    var stages: StageSeconds

    init(facesFound: Int, facesSwapped: Int,
         inferenceSeconds: Double, stages: StageSeconds = StageSeconds()) {
        self.facesFound = facesFound
        self.facesSwapped = facesSwapped
        self.inferenceSeconds = inferenceSeconds
        self.stages = stages
    }
}

// MARK: - Performance

/// Everything the export loop needs to know about how hard to push the
/// hardware. Derived from the device and the current thermal state rather
/// than guessed, because a phone that is throttling gets slower the harder
/// you push it.
struct PerformanceProfile: Sendable, Equatable {
    /// Frames inside the engine at once.
    var concurrentFrames: Int
    /// Shown in the UI, e.g. "8 cores, nominal".
    var reason: String
}

// MARK: - Errors

enum EngineError: Int, Codable, Sendable {
    case modelMissing = 1
    case modelLoadFailed = 2
    case noSourceFace = 3
    case inferenceFailed = 4
    case invalidSurface = 5
    case notPrepared = 6
    case cancelled = 7
    case referenceFacesStale = 8

    var message: String {
        switch self {
        case .modelMissing:    return String(localized: "A required AI model is missing. Reinstall the models from Settings.", bundle: .uiLanguage)
        case .modelLoadFailed: return String(localized: "A model could not be loaded. The file may be incomplete.", bundle: .uiLanguage)
        case .noSourceFace:    return String(localized: "No face was found in the source image. Try a clearer, front-facing photo.", bundle: .uiLanguage)
        case .inferenceFailed: return String(localized: "The engine failed while processing a frame.", bundle: .uiLanguage)
        case .invalidSurface:  return String(localized: "An internal image buffer was invalid.", bundle: .uiLanguage)
        case .notPrepared:     return String(localized: "The engine has not finished loading its models.", bundle: .uiLanguage)
        case .cancelled:       return String(localized: "Cancelled.", bundle: .uiLanguage)
        case .referenceFacesStale:
            return String(localized: "The chosen faces are no longer loaded. Scan the target again and reselect them.", bundle: .uiLanguage)
        }
    }
}

let engineErrorDomain = "com.lisenhuang.FaceFusion.EngineError"

func makeEngineNSError(_ code: EngineError, underlying: String? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: code.message]
    if let underlying { info[NSDebugDescriptionErrorKey] = underlying }
    return NSError(domain: engineErrorDomain, code: code.rawValue, userInfo: info)
}

// MARK: - JSON helpers

/// Kept from the Mac design even though no message is encoded on the hot path
/// any more: it is still the one place the encoder and decoder for these types
/// are configured, which is what a settings blob should go through.
enum EngineJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
