# FaceFusion for iPhone and iPad

A local-first face-swapping app for iOS, for video and for photos. Download the
models once; everything after that runs on the device, in aeroplane mode, and
nothing you feed it ever leaves the phone.

```
SwiftUI app  ──▶  in-process engine  ──▶  ONNX Runtime  ──▶  Core ML  ──▶  ANE / GPU
   │                    │                        ▲
   │                    │                        │
   │                    └── Metal kernels ───────┘  shared MTLBuffers: the GPU fills
   │                        (warp, pack, paste)     the tensor ORT then reads, no copy
   └── AVFoundation decode / encode  (replaces FFmpeg)
```

This is a port of [`FaceFusionMac`](../FaceFusionMac). The pipeline, the model
set, the alignment maths and the studio's controls are the same, and the numbers
are checked against the same OpenCV ground truth. What changed is everything the
platform forced to change, plus the pixel path, which was rewritten for the GPU.

## How it is put together

| Piece | Role | Lines |
|---|---|---|
| `Core/` | The vocabulary: model ids, options, identities, clustering, device capabilities | 877 |
| `Engine/` | The pipeline, the ONNX Runtime wrapper, and the Metal kernels | 4,028 |
| `Services/` | Media decode/encode, model downloads, Photos export, the on-device benchmark | 2,526 |
| `Model/` | Application state and every action the UI can take | 1,171 |
| `Views/` | The studio in three shapes, onboarding, settings | 3,211 |

### What iOS forced to change

**There is no XPC.** The Mac ran inference in a separate process so half a
gigabyte of weights never entered the UI's address space and a fault inside ONNX
Runtime killed a restartable helper instead of the app. Third-party iOS apps get
no XPC services, so the engine runs in-process. Two costs of the old design left
with the process boundary: frames no longer travel as `IOSurface`s handed across
by reference, and options are no longer JSON-encoded per frame. A
`CVPixelBuffer` goes in and a `CVPixelBuffer` comes out.

What survived is the part that was never about IPC — a concurrent queue where
inference runs in parallel and anything that *replaces* engine state runs as a
barrier. The crash isolation is genuinely gone; `handleMemoryPressure()` is the
partial answer, handing the enhancer's weights back so a jetsam warning costs
sharpness rather than the render.

**There are no open and save panels.** Media comes in through `PhotosPicker`,
the Files importer, or a drag onto an iPad window. Results go out to Photos,
Files, or the share sheet.

**Storage moved.** No App Group is needed for one process, so the models live in
Application Support — marked excluded from iCloud backup, because 560 MB of
redownloadable weights has no business in a user's backup.

## The pixel path, and why it was rewritten

The Mac's pixel work is scalar Swift over `DispatchQueue.concurrentPerform`. On
an M-series Mac that is tolerable — the README's own measurements show the model
stages dominating. On a phone the balance is different: the CPU is far weaker
relative to the GPU, and the export loop wants those cores for decode and encode.

So every hot pixel operation has a Metal kernel: `box_reduce`, `warp_bgra`,
`warp_to_tensor`, `pack_tensor`, `unpack_tensor`, `paste_back`. Three things
make this worth more than the obvious "run it on the GPU":

**Tensors are allocated out of shared-storage `MTLBuffer`s.** On Apple Silicon
the CPU and GPU address the same physical pages, so the kernel that fills a
tensor and the ONNX Runtime session that reads it are looking at the same bytes.
There is no upload and no download. Handing those bytes to ORT without a copy
needs an `NSMutableData` that borrows foreign memory, which none of Foundation's
`bytesNoCopy` constructors actually provide for a *mutable* data — they all hand
back an object with its own buffer. `BorrowedTensorData` is a small class-cluster
subclass that does. `TensorStorageTests` asserts the borrow rather than assuming
it, because if Foundation ever copied instead, everything would still work and
simply be slower while claiming not to be.

**Warp and pack are fused.** `warpedTensor` does in one kernel what the reference
did in two steps, skipping a full intermediate BGRA crop per model invocation —
five of them per face per frame.

**Decoder frames reach the GPU without a copy**, by wrapping the `CVPixelBuffer`'s
IOSurface base address in an `MTLBuffer` when it is page-aligned, and falling
back to the CPU path when it is not.

### The CPU implementations are still there, and still checked

Every kernel has a CPU counterpart — the reference implementation, kept as the
fallback for a device or a frame the GPU declines. That makes them
interchangeable at runtime, which means a disagreement between them would show up
as a video that flickers when one frame took a different path.

So they are compared directly. `MetalImageOps.withGPUDisabled` runs the same call
on the CPU, and `MetalParityTests` asserts the two agree to within one part in
255 across representative transforms, both channel orders, the padded detector
canvas, the fused warp, and the shrinking paste-back that trips the box
prefilter. The tolerance exists only because Metal compiles with fast maths and
may contract a multiply-add; it is not licence for a different algorithm.

## The pipeline

Per frame, mirroring FaceFusion 3.8.0's `inswapper` path — unchanged from macOS:

1. **Detect** — `yoloface_8n` on a 640×640 canvas → boxes + 5 key points.
2. **Refine** — `2dfan4` → 68 landmarks, reduced back to 5.
3. **Align** — least-squares similarity transform onto the `arcface_128` template.
4. **Condition** — the source portrait's ArcFace embedding, projected through the
   512×512 `emap` matrix stored as the last initializer *inside* the inswapper
   ONNX file. The divisor is the magnitude of the **original** embedding, not of
   the projected result.
5. **Swap** — `inswapper_128_fp16` on a 128×128 aligned crop.
6. **Composite** — feathered box mask, inverse warp, paste back.
7. **Restore** — optional `gfpgan_1.4` at 512×512 over the composited frame.

Choosing which faces get replaced works the same way too: *Every* and *One* are
geometric, and *Choose* matches on ArcFace identity so it keeps meaning the same
person across a cut, a crossing, or the subject walking out of frame. The
reference set carries a generation number, and a swap naming a generation the
engine no longer holds is refused rather than run against a stale set.

## Execution provider: measured, not assumed

The macOS build swept Core ML settings and found two results worth carrying over:
declaring static input shapes is a free 35%, and pinning these graphs to
`CPUAndNeuralEngine` is **17× slower** than letting Core ML choose, because they
are convolutional generators the ANE largely rejects and the run degenerates into
constant fallback.

`ALL` is therefore the default here too. But an iPhone's ANE-to-GPU balance is not
a Mac's, and inheriting a verdict reached on desktop silicon is exactly the kind
of assumption that costs 17×. So the sweep became a feature: **Settings →
Performance → Measure on this device** runs the configurations on the frame you
are actually working on, reports the per-stage milliseconds, and keeps the winner.

Concurrency is adaptive rather than fixed. `DeviceCapabilities.recommendedProfile`
sets how many frames may be inside the engine at once from the core count,
whether the device is memory-constrained, and the thermal state — and the export
loop lowers it when the device starts throttling, because pushing a phone that is
already thermally limited makes it slower, not faster.

## Layout

Three shapes, chosen by size class rather than by device, because "iPad" is not a
size — a Slide Over column is narrower than any phone, and a Max in landscape is
wider than a Split View pane:

| Shape | When | Arrangement |
|---|---|---|
| `sidebar` | regular width | controls left, canvas right |
| `sideBySide` | compact width, compact height | canvas left, controls right |
| `stacked` | compact width, regular height | canvas above, controls scrolling below |

Each section of the studio is defined once and the three layout functions do
nothing but place it. Verified on iPhone and iPad in portrait and both
landscapes, in light and dark.

Theme is **System / Light / Dark**, defaulting to System.

## Models

Fetched from the published FaceFusion asset release (`models-3.0.0`) and verified
against the SHA-256 digests in `FaceFusion/Resources/models.json` before
installation. A mismatch is discarded, not installed. The download runs on a
background `URLSession` so ~900 MB survives the app being suspended.

| Model | Size | Required | Licence |
|---|---|---|---|
| `yoloface_8n` | 12.7 MB | yes | GPL-3.0 |
| `arcface_w600k_r50` | 174 MB | yes | InsightFace, non-commercial |
| `inswapper_128_fp16` | 278 MB | yes | InsightFace, non-commercial |
| `2dfan4` | 98 MB | no | MIT |
| `gfpgan_1.4` | 340 MB | no | Apache-2.0 |

**The face-swapping models are licensed for non-commercial research use.** Only
swap faces of people who have agreed to it.

## Privacy

The only network request the app ever makes is the one-time model download.
There is no backend, no analytics and no telemetry. Photos and videos are read
from the pickers you choose, processed on the device, and written back to
Photos or Files. Nothing is uploaded, and the app works with the network off.

## Building

```sh
xcodebuild -project FaceFusion.xcodeproj -scheme FaceFusion \
           -configuration Release \
           -destination 'generic/platform=iOS' build
```

Swift Package Manager resolves ONNX Runtime 1.24.2 automatically. Build via the
**scheme**, not `-target`: SPM module maps are only generated for scheme builds.

Deployment target is **iOS 18**, iPhone and iPad. The app declares
`com.apple.developer.kernel.increased-memory-limit`, which it needs because the
models are large; if automatic signing ever objects, removing that key from
`FaceFusion/FaceFusion.entitlements` is safe — small devices then have to run
with *Enhance detail* off.

## Testing

```sh
# Unit tests — no models needed.
xcodebuild -project FaceFusion.xcodeproj -scheme FaceFusion \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           -only-testing:FaceFusionTests test
```

54 tests, none of which need a model on disk:

- **`GeometryTests`** — alignment and mask feathering against ground truth
  captured from the reference Python pipeline (OpenCV + ONNX Runtime), so a
  regression in the maths fails the build rather than quietly degrading output.
- **`ImageOpsTests`** — the CPU pixel behaviour, the CPU↔GPU parity described
  above, and the zero-copy tensor storage.
- **`FaceMatchingTests`** — identity distance and the clustering behind *Choose*.
- **`Float16BitsTests`** — the fp16 widening every model output passes through,
  now also checked against the hardware `Float16` the Mac build could not use.

The UI tests rotate the device and keep a screenshot of each orientation, and
assert the app's own frame actually became landscape — a screenshot of a rotated
simulator is easy to misread, so the assertion is on the layout's real input.

> A note for anyone diffing against macOS: two tests in `FaceMatchingTests` fail
> in the reference repository, and their fixture is why. Its pseudo-noise came
> from `x -> (x * 1.37).truncatingRemainder(dividingBy: 2) - 1`, which keeps the
> sign of its operand and so wanders over `[-2.994, 0.370]` with a mean of
> `-2.158` — a large DC offset rather than a small perturbation — and it was
> seeded on the seed alone, so two *different* people handed the same seed got
> byte-identical noise and landed 0.198 apart, well inside the clusterer's
> threshold. Both faults are fixed here rather than carried across; the code
> under test was never wrong.

## Debugging

```sh
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.lisenhuang.FaceFusion"' --level debug
```

Categories: `engine` (model loading, execution provider), `inference` (per-frame
stage timings, every 50 frames), `client`, `models` (downloads), `metal` (kernel
failures and fallbacks).

Note that the per-model load lines and `ready via …` are logged at `info`, which
`log show` omits unless you pass `--info`.
