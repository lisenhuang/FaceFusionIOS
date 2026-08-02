//
//  PreviewCanvas.swift
//  FaceFusion
//
//  Shows the current frame, the faces the engine can see, and lets a tap choose
//  which face gets replaced.
//
//  The Mac version of this file was nearly trivial: aspect-fit an image, draw a
//  box per face, turn a click into normalised coordinates. A phone asks for
//  more. The frame is the size of a hand, so judging whether a swap holds up
//  means being able to pinch into it; there is no modifier key to hold, so
//  comparing against the original means pressing and holding; and the whole
//  thing rotates underneath the user mid-gesture.
//
//  Every one of those lands on the same problem: the image, the face boxes and
//  the hit test have to agree about where a face is, under an arbitrary zoom and
//  pan, at any size, in either orientation. `CanvasTransform` at the bottom of
//  this file is the single answer to that question — the drawing and the tap both
//  go through it, so they cannot disagree. The pan is stored as a *fraction of
//  the fitted rect* rather than in points for exactly that reason: rotate the
//  device and the numbers describing the framing do not mention the screen at
//  all, so nothing has to be recomputed and the selection cannot drift.
//

import SwiftUI
import CoreVideo
import UIKit

struct PreviewCanvas: View {
    @Environment(AppModel.self) private var model

    /// Committed zoom and pan. The in-flight parts of a gesture live in
    /// `@GestureState` instead, which SwiftUI resets for us the moment a finger
    /// lifts — so an interrupted pinch cannot leave the canvas half-zoomed.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    @GestureState private var pinch = PinchState()
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var isPeeking = false

    /// What a live pinch is doing, carried together because the anchor is
    /// meaningless without the magnification it belongs to.
    private struct PinchState: Equatable {
        var magnification: CGFloat = 1
        var anchor: UnitPoint = .center
    }

    /// Press and hold shows the untouched frame, which is the touch equivalent
    /// of the scrubber's compare button. It reads the original directly rather
    /// than flipping `model.showsOriginal`, so a hold cannot leave the toggle in
    /// a state the user did not choose.
    private var displayedBuffer: CVPixelBuffer? {
        if isPeeking || model.showsOriginal { return model.previewFrame }
        return model.previewResult ?? model.previewFrame
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The one place the style rules allow a hard-coded colour. A
                // letterbox that followed the scheme would put a swapped face on
                // white paper in daylight and change how the skin tones read;
                // near-black in both schemes is the neutral surround every photo
                // app settles on, and it is a deliberate choice rather than an
                // oversight.
                shape.fill(Color(white: 0.07))

                if let buffer = displayedBuffer {
                    loaded(buffer: buffer, available: geometry.size)
                } else {
                    placeholder
                }

                if model.isPreviewing { previewingPill }
            }
            .clipShape(shape)
        }
        // A new target is a new picture: inheriting the previous one's framing
        // would show the corner of a photo the user has not seen whole yet.
        .onChange(of: model.targetURL) { resetFraming(animated: false) }
        .accessibilityElement(children: .contain)
    }

    // MARK: - The loaded frame

    @ViewBuilder
    private func loaded(buffer: CVPixelBuffer, available: CGSize) -> some View {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                               height: CVPixelBufferGetHeight(buffer))
        let fitted = CanvasTransform.fittedRect(for: frameSize, in: available)
        let transform = CanvasTransform(fitted: fitted,
                                        zoom: liveZoom,
                                        pan: livePan(fitted: fitted, in: available),
                                        frameSize: frameSize)
        let displayed = transform.displayed

        CanvasImage(buffer: buffer)
            .frame(width: displayed.width, height: displayed.height)
            .position(x: displayed.midX, y: displayed.midY)

        FaceOverlay(faces: model.previewFaces,
                    selected: model.selectedFaceIndices,
                    transform: transform)
            .allowsHitTesting(false)

        // One transparent layer takes every gesture, covering the letterbox as
        // well as the picture. A tap that lands outside the image is dropped by
        // the 0...1 check rather than by the layer's shape, because once the
        // image is zoomed it extends past the canvas and its bounds are no
        // longer a useful hit region.
        Color.clear
            .contentShape(.rect)
            .onTapGesture(count: 2) { location in
                doubleTap(at: location, transform: transform)
            }
            .onTapGesture { location in
                tap(at: location, transform: transform)
            }
            .gesture(panGesture(fitted: fitted),
                     // `.subviews` disables this view's own gesture while
                     // leaving anything below it working. At 1× there is
                     // nothing to pan to, and a drag that silently does nothing
                     // would still swallow the scroll of the controls beneath
                     // the canvas on a phone in portrait.
                     including: liveZoom > 1 ? .all : .subviews)
            .simultaneousGesture(magnifyGesture(fitted: fitted, available: available))
            .simultaneousGesture(peekGesture)
            // None of the gestures above mean anything to VoiceOver, so the
            // layer that carries them is what carries the description of what is
            // on screen instead.
            .accessibilityElement()
            .accessibilityLabel(accessibilityDescription)

        if transform.zoom > 1.01 { resetButton(zoom: transform.zoom) }
    }

    /// Shown only while zoomed. Double tap is the quick way back, but it is
    /// invisible and unreachable under VoiceOver, so the way out is also a
    /// button that says how far in the user currently is.
    private func resetButton(zoom shown: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    resetFraming(animated: true)
                } label: {
                    Label(String(format: "%.1f×", shown),
                          systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Reset zoom")
            }
        }
    }

    private var previewingPill: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Previewing…").font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(12)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 34, weight: .thin))
                .accessibilityHidden(true)
            Text("Choose a video or photo to see it here")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        // Legible against the near-black letterbox in both schemes, which is
        // the only surface this text ever sits on.
        .foregroundStyle(.white.opacity(0.35))
    }

    private var accessibilityDescription: String {
        guard !model.previewFaces.isEmpty else { return String(localized: "Preview. No faces found.", bundle: .uiLanguage) }
        let selected = model.selectedFaceIndices.count
        let found = model.previewFaces.count
        return found == 1
            ? String(localized: "Preview. 1 face found, \(selected) will be replaced.", bundle: .uiLanguage)
            : String(localized: "Preview. \(found) faces found, \(selected) will be replaced.", bundle: .uiLanguage)
    }

    // MARK: - Live gesture values

    /// The zoom as it stands this instant: committed, times whatever the finger
    /// is currently doing, clamped to the allowed range.
    private var liveZoom: CGFloat {
        CanvasTransform.clampZoom(zoom * pinch.magnification)
    }

    /// The pan as it stands this instant.
    ///
    /// Two corrections, in order. First the zoom change is re-anchored so the
    /// point between the user's fingers stays under them — pinching about the
    /// centre instead feels like the image is escaping. Then the drag is added,
    /// converted from points into fractions of the fitted rect. The conversion
    /// divides by the *fitted* width rather than the displayed one, and that is
    /// not a slip: a pan of `d / fitted.width` moves the image by exactly `d`
    /// points at every zoom, which is what makes the picture track the finger.
    private func livePan(fitted: CGRect, in available: CGSize) -> CGSize {
        let target = liveZoom
        var value = CanvasTransform.anchoredPan(
            pan,
            from: zoom,
            to: target,
            anchor: CanvasTransform.anchor(pinch.anchor, in: available, fitted: fitted))

        if fitted.width > 0, fitted.height > 0 {
            value.width += dragTranslation.width / fitted.width
            value.height += dragTranslation.height / fitted.height
        }
        return CanvasTransform.clampPan(value, zoom: target)
    }

    // MARK: - Gestures

    private func magnifyGesture(fitted: CGRect, available: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = PinchState(magnification: value.magnification,
                                   anchor: value.startAnchor)
            }
            .onEnded { value in
                let target = CanvasTransform.clampZoom(zoom * value.magnification)
                let anchor = CanvasTransform.anchor(value.startAnchor,
                                                    in: available, fitted: fitted)
                // The pan has to be re-anchored against the *old* zoom, so it is
                // computed before `zoom` is replaced.
                let settled = CanvasTransform.anchoredPan(pan, from: zoom,
                                                          to: target, anchor: anchor)
                withAnimation(.smooth(duration: 0.15)) {
                    pan = CanvasTransform.clampPan(settled, zoom: target)
                    zoom = target
                }
            }
    }

    private func panGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard fitted.width > 0, fitted.height > 0 else { return }
                let moved = CGSize(width: pan.width + value.translation.width / fitted.width,
                                   height: pan.height + value.translation.height / fitted.height)
                pan = CanvasTransform.clampPan(moved, zoom: zoom)
            }
    }

    /// Press and hold to see the original.
    ///
    /// A long press followed by a zero-distance drag is the standard way to ask
    /// "is the finger still down?": the long press decides when the hold has
    /// counted, and the drag keeps the gesture alive until release. Reacting to
    /// touch-down instead would flash the original under every tap, and the
    /// press's own distance limit means a pan cancels the peek rather than
    /// dragging a stale frame around.
    private var peekGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isPeeking) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
    }

    // MARK: - Taps

    private func tap(at location: CGPoint, transform: CanvasTransform) {
        let normalized = transform.normalized(at: location)
        guard (0 ... 1).contains(normalized.x), (0 ... 1).contains(normalized.y) else { return }
        model.selectFace(atNormalized: normalized)
    }

    /// Double tap resets the framing — and, when there is nothing to reset,
    /// zooms in on what was tapped instead. A gesture that does nothing half the
    /// time reads as broken, and zooming to the tap is what every other photo
    /// view on the device does with the same two taps.
    private func doubleTap(at location: CGPoint, transform: CanvasTransform) {
        if zoom > 1.01 {
            resetFraming(animated: true)
            return
        }
        let target: CGFloat = 2
        let anchor = CanvasTransform.anchor(location, in: transform.fitted)
        let framed = CanvasTransform.anchoredPan(pan, from: zoom, to: target, anchor: anchor)
        withAnimation(.smooth(duration: 0.22)) {
            pan = CanvasTransform.clampPan(framed, zoom: target)
            zoom = target
        }
    }

    private func resetFraming(animated: Bool) {
        guard zoom != 1 || pan != .zero else { return }
        if animated {
            withAnimation(.smooth(duration: 0.22)) { zoom = 1; pan = .zero }
        } else {
            zoom = 1
            pan = .zero
        }
    }
}

// MARK: - The frame itself

/// The decoded frame, converted once per frame rather than once per gesture tick.
///
/// `PixelSurface.makeCGImage` runs a Core Image render, which is cheap next to a
/// swap and ruinous at sixty times a second: a pinch re-evaluates the body on
/// every touch update, and converting a 1280 px frame each time turns a smooth
/// zoom into a slideshow. The Mac never noticed because its body ran on state
/// changes alone.
private struct CanvasImage: View {
    var buffer: CVPixelBuffer

    @State private var rendered: Rendered?

    /// The converted image together with the buffer it came from.
    ///
    /// Holding the buffer is not sentiment — it is what makes the identity check
    /// trustworthy. Release it and the next `CVPixelBufferCreate` is free to
    /// land on the same address, at which point a cache keyed on identity agrees
    /// that nothing changed and shows the previous frame for ever. While this
    /// reference exists that address cannot be handed out again.
    private struct Rendered {
        var buffer: CVPixelBuffer
        var image: UIImage
    }

    var body: some View {
        Group {
            if let image = rendered?.image {
                Image(uiImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
        .task(id: ObjectIdentifier(buffer)) {
            guard rendered?.buffer !== buffer else { return }
            // A failure clears the cache rather than keeping what was there: a
            // stale frame under the current settings is a worse answer than an
            // empty canvas.
            if let image = PixelSurface.makeUIImage(from: buffer) {
                rendered = Rendered(buffer: buffer, image: image)
            } else {
                rendered = nil
            }
        }
    }
}

// MARK: - Face boxes

/// Draws a box per detected face, highlighting the ones that will be replaced.
///
/// Which those are is decided by `AppModel.selectedFaceIndices` rather than
/// here: the rule used to be written out twice, and matching by identity is not
/// a question the view can answer at all — it has boxes, not identities.
///
/// The stroke widths are in points and deliberately do not scale with the zoom.
/// A line that grew with the picture would be a finger thick at 6×, covering the
/// very edge the user zoomed in to inspect.
private struct FaceOverlay: View {
    var faces: [DetectedFace]
    var selected: Set<Int>
    var transform: CanvasTransform

    var body: some View {
        Canvas { context, _ in
            for face in faces {
                let box = transform.rect(for: face.box)
                let active = selected.contains(face.index)
                let path = Path(roundedRect: box, cornerRadius: 6)
                context.stroke(path,
                               with: .color(active ? .accentColor : .white.opacity(0.35)),
                               lineWidth: active ? 2.5 : 1.2)
            }
        }
    }
}

// MARK: - Geometry

/// The map between the frame's pixels and the canvas's points, under the zoom
/// and pan in force right now.
///
/// This is the only geometry in the view layer, and everything that has to agree
/// about where a face is goes through it: the boxes drawn over the picture, and
/// the tap that picks one. Written once so the two cannot drift apart — the
/// failure mode when they do is a box that highlights one face while the tap
/// selects its neighbour, which looks like a broken detector rather than a
/// broken transform.
private struct CanvasTransform: Equatable {
    /// Where the frame sits with no zoom applied: aspect-fitted and centred in
    /// the space available.
    var fitted: CGRect
    /// 1 exactly fills `fitted`; `maximumZoom` is as far in as a pinch can go.
    var zoom: CGFloat
    /// Pan, as a signed fraction of the fitted rect's own width and height,
    /// measured from its centre.
    ///
    /// Fractions rather than points, because the framing then survives a
    /// rotation, a Slide Over resize and a change of layout without any of them
    /// having to be noticed: half a fitted width right is still half a fitted
    /// width right at any screen size. Points would have to be rescaled on every
    /// bounds change, and the one that is missed is the one that moves the
    /// user's selection.
    var pan: CGSize
    /// The frame's pixel dimensions, which is the space face boxes are in.
    var frameSize: CGSize

    static let minimumZoom: CGFloat = 1
    static let maximumZoom: CGFloat = 6

    /// Where the image is actually drawn.
    var displayed: CGRect {
        let width = fitted.width * zoom
        let height = fitted.height * zoom
        return CGRect(x: fitted.midX + pan.width * fitted.width - width / 2,
                      y: fitted.midY + pan.height * fitted.height - height / 2,
                      width: width, height: height)
    }

    /// A point on the canvas as a fraction of the frame: (0, 0) is the top-left
    /// pixel and (1, 1) the bottom-right.
    ///
    /// Outside 0...1 means the touch missed the picture, which the caller is
    /// expected to check. A degenerate rect answers (-1, -1) so that check
    /// rejects it rather than reporting a hit on the top-left corner.
    func normalized(at point: CGPoint) -> CGPoint {
        let rect = displayed
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: -1, y: -1) }
        return CGPoint(x: (point.x - rect.minX) / rect.width,
                       y: (point.y - rect.minY) / rect.height)
    }

    /// The inverse of `normalized(at:)`.
    func point(atNormalized normalized: CGPoint) -> CGPoint {
        let rect = displayed
        return CGPoint(x: rect.minX + normalized.x * rect.width,
                       y: rect.minY + normalized.y * rect.height)
    }

    /// A face's box, given in frame pixels, as a rectangle on the canvas.
    func rect(for box: FaceBox) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let rect = displayed
        let scaleX = rect.width / frameSize.width
        let scaleY = rect.height / frameSize.height
        return CGRect(x: rect.minX + CGFloat(box.x) * scaleX,
                      y: rect.minY + CGFloat(box.y) * scaleY,
                      width: CGFloat(box.width) * scaleX,
                      height: CGFloat(box.height) * scaleY)
    }

    /// Aspect-fit the frame inside the available space.
    static func fittedRect(for frameSize: CGSize, in available: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let scale = min(available.width / frameSize.width, available.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return minimumZoom }
        return min(max(zoom, minimumZoom), maximumZoom)
    }

    /// Stops the picture being dragged off the screen.
    ///
    /// The limit is derived rather than tuned. The image is `zoom` fitted-widths
    /// across and the letterbox is one, so the most either edge can travel
    /// before the opposite edge would pull inside the letterbox is
    /// `(zoom - 1) / 2` of a fitted width. At 1× that is zero, which is why a
    /// drag at rest cannot move anything and the picture is always centred.
    static func clampPan(_ pan: CGSize, zoom: CGFloat) -> CGSize {
        let limit = max(0, (zoom - 1) / 2)
        return CGSize(width: min(max(pan.width, -limit), limit),
                      height: min(max(pan.height, -limit), limit))
    }

    /// Re-frames a pan so the image point under `anchor` stays under it while
    /// the zoom changes.
    ///
    /// Falls out of the definition of `displayed`. Writing `a` for the anchor and
    /// `p` for the pan, both as fractions of the fitted rect measured from its
    /// centre, the image coordinate under the anchor is `n = (a - p) / zoom +
    /// ½`. Holding `n` fixed across a change from `z₀` to `z₁` and solving for
    /// the new pan gives `p₁ = a - (z₁ / z₀)(a - p₀)`, which is all this is.
    static func anchoredPan(_ pan: CGSize, from: CGFloat, to: CGFloat,
                            anchor: CGPoint) -> CGSize {
        guard from > 0, from.isFinite, to.isFinite else { return pan }
        let ratio = to / from
        return CGSize(width: anchor.x - ratio * (anchor.x - pan.width),
                      height: anchor.y - ratio * (anchor.y - pan.height))
    }

    /// A point on the canvas expressed the way `pan` is: a signed fraction of
    /// the fitted rect, from its centre.
    static func anchor(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGPoint(x: (point.x - fitted.midX) / fitted.width,
                       y: (point.y - fitted.midY) / fitted.height)
    }

    /// The same, for the unit point a pinch reports. `MagnifyGesture` measures
    /// its anchor against the whole gesture view — the letterbox included — so
    /// the available size is needed to get back to points first.
    static func anchor(_ unit: UnitPoint, in available: CGSize, fitted: CGRect) -> CGPoint {
        anchor(CGPoint(x: unit.x * available.width, y: unit.y * available.height), in: fitted)
    }
}
