//
//  StudioView.swift
//  FaceFusion
//
//  The main workspace: pick a face, pick a video, judge the result on a single
//  frame, then export.
//
//  It is the same workspace as the Mac's, with the same controls in the same
//  order and the same words on them, arranged three different ways. What changes
//  between the arrangements is only *where* each piece goes — never what it says
//  or what it does — so every section below is defined exactly once and the
//  three layout functions do nothing but place them:
//
//  - `sidebar`     a control column beside the canvas. iPad, and big phones
//                  turned sideways.
//  - `sideBySide`  canvas left, controls right, action bar closing the column.
//                  A phone in landscape, where there is no vertical room for a
//                  bar under the canvas.
//  - `stacked`     canvas on top, controls scrolling underneath, action bar
//                  pinned to the bottom safe area. A phone upright — and an
//                  iPad in Slide Over, which is 320 pt wide and is a phone as
//                  far as layout is concerned.
//
//  Two habits from the Mac version are worth keeping in mind while reading. The
//  sliders commit on release rather than on change, because a drag emits a value
//  per pixel of travel and each one would queue a full-frame swap. And nothing
//  here decides which faces are selected: `AppModel.selectedFaceIndices` does,
//  because for the *Choose* mode that is a question about identity and a view
//  has boxes, not identities.
//
//  The one genuine departure from macOS is what happens after a render. There is
//  no Finder to reveal a file in, so the finished bar offers the three places a
//  result actually wants to go: Photos, Files, and the share sheet.
//

import SwiftUI
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers

@MainActor
struct StudioView: View {
    @Environment(AppModel.self) private var model
    @Environment(StoreManager.self) private var purchases
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.presentSettings) private var presentSettings

    @State private var isSavingToFiles = false
    @State private var isSavingToPhotos = false
    /// Measured, not assumed: the action bar's height decides how much of the
    /// stacked layout is left for the canvas. See `stackedLayout`.
    @State private var actionBarHeight: CGFloat = 0
    /// What the last save attempt did, shown next to the buttons that did it.
    /// Local rather than on the model: the model already reports its own
    /// failures through `statusMessage`, and where a *file* went is a fact about
    /// this screen, not about the app.
    @State private var saveNotice: String?
    @State private var showsPaywall = false

    var body: some View {
        NavigationStack {
            workspace
                .navigationTitle("Morphiqo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        // Kept for the iPad, where dragging a clip out of Photos or Files onto
        // the window is the fastest way in. The model works out from the file
        // itself whether it is a face or a target.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.handleDrop(url) }
            return true
        }
        .fileExporter(isPresented: Binding(
                        get: { isSavingToFiles && purchases.isPro },
                        set: { isSavingToFiles = $0 }
                      ),
                      item: finishedURL.map(ExportedFile.init),
                      defaultFilename: finishedURL?.lastPathComponent) { result in
            switch result {
            case .success:
                saveNotice = "Saved to Files."
            case .failure(let error):
                saveNotice = error.localizedDescription
            }
        }
        // A new render supersedes whatever the last one's buttons had to say.
        .onChange(of: finishedURL) { saveNotice = nil }
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
    }

    // MARK: - The three shapes

    private var workspace: some View {
        GeometryReader { proxy in
            let layout = StudioLayout.resolve(horizontal: horizontalSizeClass,
                                              vertical: verticalSizeClass)
            Group {
                switch layout {
                case .sidebar:
                    sidebarLayout(layout, width: proxy.size.width)
                case .sideBySide:
                    sideBySideLayout(layout, width: proxy.size.width)
                case .stacked:
                    stackedLayout(layout, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Regular width. The Mac arrangement, near enough: everything you set on
    /// the left, everything you look at on the right.
    private func sidebarLayout(_ layout: StudioLayout, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            controlColumn(layout)
                .frame(width: columnWidth(layout, in: width))

            Divider()

            VStack(spacing: 0) {
                canvas.padding(Metrics.gutter)
                scrubber
                actionBar
            }
        }
    }

    /// A phone in landscape: 390 pt of height, most of it wanted by the canvas.
    /// The action bar moves to the foot of the control column, because a bar
    /// under the canvas would cost the canvas a sixth of what it has.
    private func sideBySideLayout(_ layout: StudioLayout, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                scrubber
            }

            Divider()

            VStack(spacing: 0) {
                controlColumn(layout)
                actionBar
            }
            .frame(width: columnWidth(layout, in: width))
        }
    }

    /// A phone upright, and any iPad window narrow enough to count as one.
    ///
    /// The canvas keeps a fixed share of the height rather than sizing to its
    /// content, so the frame does not jump every time a differently-shaped video
    /// is loaded. The controls scroll underneath it — at the largest
    /// accessibility text size there is several screens of them — and the action
    /// bar is pinned to the bottom safe area so Export is reachable without
    /// scrolling back for it.
    ///
    /// The share is taken of the height left *after* the action bar, which is
    /// why the bar measures itself below. It is not a fixed-height strip: a
    /// finished export at an accessibility text size is a checkmark, a filename,
    /// three full-width buttons and a save notice, several times taller than the
    /// idle hint. Taking 42% of the whole page regardless is how the scrolling
    /// controls end up with nothing left and the stack starts drawing behind the
    /// bar.
    private func stackedLayout(_ layout: StudioLayout, height: CGFloat) -> some View {
        let available = max(220, height - actionBarHeight)
        return VStack(spacing: 0) {
            canvas
                .frame(height: max(140, available * 0.42))
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
            scrubber
            controlColumn(layout)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    actionBarHeight = newHeight
                }
        }
    }

    /// How wide the control column is allowed to be.
    ///
    /// A fixed width was safe on the Mac, where the window could not be made
    /// narrower than the sidebar plus a usable canvas. Here the same 320 pt is a
    /// quarter of a 13" iPad and two thirds of a Split View pane, so it is
    /// clamped from both ends: never wider than the shape's natural width, never
    /// so wide that the canvas is left a sliver, never so narrow that a media
    /// well stops being a target worth dropping onto.
    private func columnWidth(_ layout: StudioLayout, in available: CGFloat) -> CGFloat {
        let share: CGFloat = layout == .sidebar ? 0.34 : 0.45
        return min(layout.sidebarWidth, max(232, available * share))
    }

    // MARK: - Control column

    private func controlColumn(_ layout: StudioLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mediaWells(layout)
                Divider()
                adjustments
                engineBadge.padding(.top, 4)
            }
            .padding(Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Nothing to bounce against when the controls are shorter than the
        // column, which on an iPad they usually are.
        .scrollBounceBehavior(.basedOnSize)
        // Material only when the column sits *beside* something and needs an
        // edge. Stacked, it is the page itself and a second surface would just
        // look like a mistake.
        .background(layout == .stacked
                    ? AnyShapeStyle(Color.clear)
                    : AnyShapeStyle(Material.regularMaterial))
    }

    /// The two wells, side by side only when the column is the full width of a
    /// phone and the text is small enough for two captions to share a line.
    /// Above accessibility sizes the captions are sentences, and two sentences
    /// in half a phone's width is a column of single words.
    private func mediaWells(_ layout: StudioLayout) -> some View {
        AdaptiveStack(axis: wellsAxis(layout),
                      horizontalAlignment: .leading,
                      verticalAlignment: .top,
                      spacing: Metrics.gutter) {
            sourceWell
            targetWell
        }
    }

    private func wellsAxis(_ layout: StudioLayout) -> Axis {
        layout == .stacked && !dynamicTypeSize.isAccessibilitySize ? .horizontal : .vertical
    }

    private var sourceWell: some View {
        MediaWell(title: "Source face",
                  systemImage: "person.crop.square",
                  hint: "Add the face you want to use",
                  isFilled: model.sourceBuffer != nil,
                  caption: sourceCaption,
                  accepted: [.image],
                  onPickFile: { url in Task { await model.useSource(url) } },
                  onPickPhoto: { item in Task { await model.useSource(pickedItem: item) } },
                  onClear: { model.clearSource() }) {
            if let buffer = model.sourceBuffer,
               let image = PixelSurface.makeCGImage(from: buffer) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
    }

    private var targetWell: some View {
        MediaWell(title: "Target",
                  systemImage: "photo.on.rectangle.angled",
                  hint: "Add the video or photo to put it into",
                  isFilled: model.targetURL != nil,
                  caption: targetCaption,
                  accepted: [.movie, .image],
                  onPickFile: { url in Task { await model.useTarget(url) } },
                  onPickPhoto: { item in Task { await model.useTarget(pickedItem: item) } },
                  onClear: { model.clearTarget() }) {
            if let buffer = model.previewFrame,
               let image = PixelSurface.makeCGImage(from: buffer) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
    }

    private var sourceCaption: String? {
        guard model.sourceBuffer != nil else { return nil }
        if model.sourceFace == nil {
            return model.sourceFaceCount == 0
                ? String(localized: "No face found — try a clearer, front-facing photo.", bundle: .uiLanguage)
                : String(localized: "Encoding…", bundle: .uiLanguage)
        }
        return model.sourceFaceCount > 1
            ? String(localized: "Using the largest of \(model.sourceFaceCount) faces.", bundle: .uiLanguage)
            : String(localized: "Face ready.", bundle: .uiLanguage)
    }

    private var targetCaption: String? {
        guard let target = model.target else { return nil }
        let size = "\(Int(target.displaySize.width))×\(Int(target.displaySize.height))"
        switch target {
        case .video(let info):
            let duration = Duration.seconds(info.durationSeconds)
                .formatted(.time(pattern: .minuteSecond))
            return "\(size) · \(duration) · \(info.codecDescription)"
        case .image(_, let format):
            // `format` is a file-extension token (HEIC, PNG) and stays as it is;
            // only the fallback word is language.
            let kind = format.isEmpty ? String(localized: "Photo", bundle: .uiLanguage) : format
            return "\(size) · \(kind)"
        }
    }

    // MARK: - Adjustments

    /// Named for what it holds rather than "Settings", which now means the sheet
    /// behind the gear. These are the knobs that change the picture; that is the
    /// screen that changes the app.
    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Settings")
            faceSection
            resemblanceSlider
            edgeSoftnessSlider
            enhanceToggle
            // Codec choice is meaningless for a photo; the photo path writes a
            // PNG, which is also why the export never re-encodes a JPEG twice.
            if !model.targetIsImage {
                codecToggle
            }
        }
    }

    private var faceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which face").font(.callout)

            // Segmented normally, a menu at accessibility sizes: three segments
            // sharing 300 pt cannot show "Choose" at AX5 and truncate it to a
            // letter, whereas a menu shows the full word and its selection.
            if dynamicTypeSize.isAccessibilitySize {
                facePicker.pickerStyle(.menu).labelsHidden()
            } else {
                facePicker.pickerStyle(.segmented).labelsHidden()
            }

            Text(faceModeHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.faceMode == .chosen {
                FacePicker()
                    .padding(.top, 4)
            }
        }
    }

    private var facePicker: some View {
        Picker("Which face", selection: Binding(get: { model.faceMode },
                                                set: { model.setFaceMode($0) })) {
            Text("Every").tag(AppModel.FaceMode.everyFace)
            Text("One").tag(AppModel.FaceMode.oneFace)
            Text("Choose").tag(AppModel.FaceMode.chosen)
        }
    }

    private var faceModeHint: String {
        switch model.faceMode {
        case .everyFace:
            return String(localized: "Replaces every face in the frame.", bundle: .uiLanguage)
        case .oneFace:
            return String(localized: "Replaces one face. Tap a different face in the preview to switch.", bundle: .uiLanguage)
        case .chosen:
            return model.targetIsImage
                ? String(localized: "Replaces only the faces you tick.", bundle: .uiLanguage)
                : String(localized: "Replaces only the people you tick, wherever they appear in the video.", bundle: .uiLanguage)
        }
    }

    private var resemblanceSlider: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resemblance").font(.callout)
                Spacer()
                Text(percentage(model.identityStrength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Committed on release, not on change: every intermediate value
            // would otherwise queue a swap of the whole frame.
            Slider(value: $model.identityStrength, in: 0 ... 1) { editing in
                if !editing { Task { await model.refreshPreview() } }
            }
            .accessibilityLabel("Resemblance")
            .accessibilityValue(percentage(model.identityStrength))

            Text("Higher keeps more of the source face; lower blends toward the original.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var edgeSoftnessSlider: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Edge softness").font(.callout)
                Spacer()
                Text(percentage(model.maskBlur))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $model.maskBlur, in: 0 ... 1) { editing in
                if !editing { Task { await model.refreshPreview() } }
            }
            .accessibilityLabel("Edge softness")
            .accessibilityValue(percentage(model.maskBlur))
        }
    }

    private var enhanceToggle: some View {
        @Bindable var model = model
        let installed = model.models.isInstalledModel(.faceEnhancer)

        return Toggle(isOn: $model.enhanceFace) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Enhance detail")
                Text(installed ? "Sharper skin and eyes. Slower."
                               : "Needs the Face Enhancer model.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!installed)
        .onChange(of: model.enhanceFace) { Task { await model.refreshPreview() } }
    }

    private var codecToggle: some View {
        @Bindable var model = model

        return Toggle(isOn: $model.useHEVC) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Export as HEVC")
                Text(model.useHEVC ? "Smaller files." : "H.264 plays anywhere.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    // MARK: - Engine badge

    private var engineBadge: some View {
        HStack(spacing: 6) {
            switch model.engine.state {
            case .ready(let summary):
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(summary.usingCoreML ? "Apple Neural Engine / GPU" : "CPU")
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Starting engine…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message).lineLimit(2)
            case .idle:
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Engine idle")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Canvas and scrubber

    private var canvas: some View {
        PreviewCanvas()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A photo has no timeline, but it still earns the before/after toggle —
    /// which is why that button does not live inside the slider row.
    private var scrubber: some View {
        @Bindable var model = model

        let timeline = model.targetInfo.flatMap { $0.durationSeconds > 0 ? $0 : nil }
        let canCompare = model.previewResult != nil
        // At accessibility sizes the toggle's label is a line of its own, so it
        // goes under the slider rather than squeezing it to nothing.
        let compareBelow = dynamicTypeSize.isAccessibilitySize

        return Group {
            if timeline != nil || canCompare {
                AdaptiveStack(axis: compareBelow ? .vertical : .horizontal,
                              horizontalAlignment: .leading,
                              verticalAlignment: .center,
                              spacing: 12) {
                    if let timeline {
                        HStack(spacing: 10) {
                            // Minimum widths rather than fixed ones: the columns
                            // still line up, and the labels are still legible
                            // when the text size doubles.
                            Text(timecode(model.previewTime))
                                .frame(minWidth: 46, alignment: .trailing)

                            Slider(value: $model.previewTime,
                                   in: 0 ... timeline.durationSeconds)
                                .disabled(model.isRendering)
                                .accessibilityLabel("Position")
                                .accessibilityValue(timecode(model.previewTime))

                            Text(timecode(timeline.durationSeconds))
                                .frame(minWidth: 46, alignment: .leading)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else if !compareBelow {
                        Spacer()
                    }

                    if canCompare { compareButton }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 10)
            }
        }
    }

    /// The deliberate version of the compare gesture. Pressing and holding the
    /// canvas does the same thing without leaving the picture; this one stays
    /// put, which is what you want when the difference is subtle.
    private var compareButton: some View {
        Button {
            model.showsOriginal.toggle()
        } label: {
            Label(model.showsOriginal ? "Showing original" : "Showing result",
                  systemImage: model.showsOriginal ? "eye.slash" : "eye")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Compare with the untouched frame")
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                switch model.phase {
                case .rendering:
                    renderingBar
                case .finished(let url):
                    finishedBar(url)
                case .failed(let message):
                    failureBar(message)
                default:
                    idleBar
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No fixed height, unlike the Mac's 62 pt: at the largest text sizes the
        // readiness line alone is three lines tall. The background reaches past
        // the safe area so the bar meets the bottom of the screen in the stacked
        // layout instead of floating above the home indicator.
        .background {
            Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
        }
    }

    private var idleBar: some View {
        // One row when the sentence and the button fit on one; otherwise the
        // button takes a line of its own and the full width, which is where a
        // thumb expects it on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                readinessLine
                Spacer(minLength: 8)
                exportButton
            }
            VStack(alignment: .leading, spacing: 10) {
                readinessLine
                exportButton.frame(maxWidth: .infinity)
            }
        }
    }

    private var readinessLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let message = model.statusMessage {
                Image(systemName: "info.circle").accessibilityHidden(true)
                Text(message)
            } else {
                Text(readinessHint)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var readinessHint: String {
        if model.sourceFace == nil && model.targetURL == nil {
            return String(localized: "Add a face and a video or photo to begin.", bundle: .uiLanguage)
        }
        if model.sourceFace == nil { return String(localized: "Add a source face.", bundle: .uiLanguage) }
        if model.targetURL == nil { return String(localized: "Add a target video or photo.", bundle: .uiLanguage) }
        if model.faceMode == .chosen && model.checkedPeople.isEmpty {
            return model.people.isEmpty
                ? String(localized: "Find the faces in the target, then tick the ones to replace.", bundle: .uiLanguage)
                : String(localized: "Tick at least one face to replace.", bundle: .uiLanguage)
        }
        return String(localized: "Ready to export.", bundle: .uiLanguage)
    }

    private var exportButton: some View {
        Button {
            if !model.targetIsImage && !purchases.isPro {
                showsPaywall = true
            } else {
                Task { await model.export() }
            }
        } label: {
            Label {
                Text(!model.targetIsImage && !purchases.isPro
                     ? "Unlock video export"
                     : (model.targetIsImage ? "Export photo" : "Export video"))
            } icon: {
                Image(systemName: !model.targetIsImage && !purchases.isPro
                      ? "lock.fill"
                      : "square.and.arrow.up")
            }
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canRender)
    }

    private var renderingBar: some View {
        AdaptiveStack(axis: dynamicTypeSize.isAccessibilitySize ? .vertical : .horizontal,
                      horizontalAlignment: .leading,
                      verticalAlignment: .center,
                      spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if model.targetIsImage {
                    // One frame: a percentage would go from 0 to 100 with
                    // nothing in between.
                    ProgressView().progressViewStyle(.linear)
                    Text("Rendering the photo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: model.progress?.fraction ?? 0)
                    HStack(spacing: 10) {
                        if let progress = model.progress {
                            Text("\(progress.framesWritten) / \(progress.totalFrames) frames")
                            if progress.framesPerSecond > 0 {
                                Text(String(format: "%.1f fps", progress.framesPerSecond))
                            }
                            if let remaining = progress.estimatedTimeRemaining {
                                Text("\(formatDuration(remaining)) left")
                            }
                        } else {
                            Text("Starting…")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Button("Cancel", role: .cancel) { model.cancelExport() }
                .controlSize(.large)
                .disabled(model.targetIsImage)
        }
    }

    /// Where a finished render can go, now that there is no Finder to reveal it
    /// in. Photos is what most people mean; Files is what they mean when the
    /// result is going somewhere else; and the share sheet covers everything
    /// neither of those anticipated.
    private func finishedBar(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Export complete").font(.callout.weight(.medium))
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button {
                    model.dismissResult()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            if purchases.isPro {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        saveToPhotosButton
                        saveToFilesButton
                        shareButton(url)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        saveToPhotosButton.frame(maxWidth: .infinity)
                        HStack(spacing: 10) {
                            saveToFilesButton
                            shareButton(url)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Upgrade to save, share, or export video.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Unlock Pro") { showsPaywall = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let notice = saveNotice ?? model.statusMessage {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveToPhotosButton: some View {
        Button {
            saveNotice = nil
            isSavingToPhotos = true
            Task {
                await model.saveFinishedToPhotos()
                isSavingToPhotos = false
                // The model surfaces a refused permission or a failed write
                // through `statusMessage`; silence there means it worked.
                if model.statusMessage == nil { saveNotice = "Saved to Photos." }
            }
        } label: {
            if isSavingToPhotos {
                ProgressView().controlSize(.small)
            } else {
                Label("Save to Photos", systemImage: "photo.badge.plus")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSavingToPhotos)
    }

    private var saveToFilesButton: some View {
        Button {
            saveNotice = nil
            isSavingToFiles = true
        } label: {
            Label("Save to Files", systemImage: "folder")
        }
        .buttonStyle(.bordered)
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
    }

    private func failureBar(_ message: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                failureLine(message)
                Spacer(minLength: 8)
                Button("Dismiss") { model.dismissResult() }
            }
            VStack(alignment: .leading, spacing: 10) {
                failureLine(message)
                Button("Dismiss") { model.dismissResult() }
            }
        }
    }

    private func failureLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var finishedURL: URL? {
        if case .finished(let url) = model.phase { return url }
        return nil
    }
}

// MARK: - Handing the file to the system

/// A finished render, in the form `.fileExporter` understands.
///
/// A file *reference* rather than `Data`, deliberately: a two-minute export is
/// several hundred megabytes and `SentTransferredFile` hands the system a path,
/// so the copy into the user's chosen folder happens outside this process's
/// address space. Loading it into memory to hand it back is exactly the kind of
/// thing that gets an app jetsammed while it is doing the user a favour.
///
/// The content type is `.data` because one wrapper serves both an MP4 and a PNG,
/// and the exporter takes the name — and therefore the extension — from
/// `defaultFilename`.
private struct ExportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(file.url)
        }
    }
}

#Preview {
    StudioView()
        .environment(AppModel())
        .environment(StoreManager.shared)
}
