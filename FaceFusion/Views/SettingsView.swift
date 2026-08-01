//
//  SettingsView.swift
//  FaceFusion
//
//  The sheet behind the gear: how the app looks, how hard it pushes this
//  particular device, what is on disk, and what the app promises about where
//  the work happens.
//
//  There was no equivalent on the Mac, and the reason there is one here is the
//  Performance section. The Mac shipped one execution-provider configuration
//  because the sweep only ever had to be run on one class of machine: `ALL`
//  with static shapes, with `CPUAndNeuralEngine` measuring 17× *slower* because
//  these are convolutional generators the ANE largely rejects. That result does
//  not transfer. An iPhone's ANE-to-GPU balance is not a Mac's, and it is not
//  the same between an A-series and an M-series iPad either, so the sweep moves
//  from a `--benchmark` command-line flag to a button — the answer has to be
//  measured on the device in the user's hand, not guessed from a Mac.
//
//  Everything else here exists because a phone is not a Mac in a different way:
//  the app's library is 900 MB of redownloadable weights on a device sold with
//  128 GB, so the user needs a way to see it and reclaim it, and the offline
//  promise is the whole reason to run a face swapper locally rather than upload
//  to a website, so it is written down rather than implied.
//

import SwiftUI
import Foundation

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable private var preferences = Preferences.shared

    /// Owned by the sheet rather than by `AppModel`: a measurement is a thing
    /// the user starts here and reads here, and nothing outside this screen has
    /// any use for the rows. The winning policy is written to `Preferences`,
    /// which is what actually outlives the sheet.
    @State private var benchmark = EngineBenchmark()

    @State private var isConfirmingRemoveAll = false
    @State private var isReloadingEngine = false

    private var manager: ModelManager { model.models }
    private var catalogue: [ModelDescriptor] { manager.manifest?.models ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                performanceSection
                modelsSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Remove all models?",
                                isPresented: $isConfirmingRemoveAll,
                                titleVisibility: .visible) {
                Button("Remove all models", role: .destructive) {
                    Task { await removeAllModels() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This frees \(formatBytes(manager.installedBytes)). The app cannot swap a face again until they are downloaded, which needs a connection.")
            }
            // A download finishing while this sheet is open is the normal way
            // out of the "no models" state, and the engine will not start
            // itself. Without this the user closes Settings onto a studio that
            // looks ready and is not.
            .onChange(of: manager.isReady) { _, ready in
                guard ready else { return }
                Task { await model.startEngineIfPossible() }
            }
        }
        // The sheet is its own presentation, so the theme has to be applied
        // here as well as on `RootView` — otherwise choosing Dark repaints the
        // studio behind and leaves the picker that changed it in Light.
        .preferredColorScheme(preferences.theme.colorScheme)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            // Segmented reads as three equal choices, which is what these are.
            // At an accessibility size three words cannot share a phone's width
            // without each being clipped to a letter, so the control becomes a
            // menu instead of becoming unreadable.
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Theme", selection: $preferences.theme) {
                    themeOptions(showsSymbol: true)
                }
            } else {
                Picker("Theme", selection: $preferences.theme) {
                    themeOptions(showsSymbol: false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Applies straight away. The preview stays near‑black in both, so a swap is always judged against the same surround.")
        }
    }

    @ViewBuilder
    private func themeOptions(showsSymbol: Bool) -> some View {
        ForEach(AppTheme.allCases) { theme in
            if showsSymbol {
                Label(theme.label, systemImage: theme.symbol).tag(theme)
            } else {
                // A segmented control shows a `Label` as its icon alone, which
                // would leave three unlabelled circles.
                Text(theme.label).tag(theme)
            }
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        Section {
            ForEach(ComputePolicy.allCases) { policy in
                computeRow(policy)
            }

            measureControl

            ForEach(benchmark.rows) { row in
                benchmarkRow(row)
            }

            verdictRow

            deviceRows
        } header: {
            Text("Performance")
        } footer: {
            if isReloadingEngine {
                Text("Loading the models with the new setting…")
            } else {
                Text("Changing this reloads the models, which takes a few seconds.")
            }
        }
    }

    private func computeRow(_ policy: ComputePolicy) -> some View {
        Button {
            guard policy != preferences.compute else { return }
            preferences.compute = policy
            Task { await reloadEngine() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(policy.displayName)
                        .foregroundStyle(.primary)
                    Text(policy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(policy == preferences.compute ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isReloadingEngine || benchmark.isRunning)
        .accessibilityAddTraits(policy == preferences.compute ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var measureControl: some View {
        if benchmark.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Measuring…").font(.callout)
                    Spacer(minLength: 8)
                    quietButton("Stop") { benchmark.cancel() }
                }
                Text("Every setting is timed on the frame you are working on. This takes a few minutes and the device will get warm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Button {
                Task { await measure() }
            } label: {
                Label("Measure on this device", systemImage: "speedometer")
            }
            .disabled(!canMeasure)

            if !canMeasure {
                Text(measureHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canMeasure: Bool {
        manager.isReady && model.sourceURL != nil && model.targetURL != nil && !isReloadingEngine
    }

    private var measureHint: String {
        guard manager.isReady else { return "The models have to be installed before anything can be timed." }
        return "Load a face and a video or photo first. The measurement runs on the frame you are working on, so the numbers describe your own material rather than a synthetic one."
    }

    /// The row of a completed sweep.
    ///
    /// The per-stage columns are the point of the table — they are how it
    /// becomes obvious that the enhancer is most of a frame — but seven numbers
    /// have never fitted across a phone. They scroll sideways inside the row so
    /// that the page itself never does.
    private func benchmarkRow(_ row: EngineBenchmark.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.name).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    headline(for: row)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.callout.weight(.medium))
                    headline(for: row)
                }
            }

            if let stages = row.stages {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 14) {
                        stageColumn("detect", stages.detect)
                        stageColumn("landmarks", stages.landmarks)
                        stageColumn("match", stages.match)
                        stageColumn("swap", stages.swap)
                        stageColumn("paste", stages.paste)
                        stageColumn("enhance", stages.enhance)
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else if let error = row.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func headline(for row: EngineBenchmark.Row) -> some View {
        if let stages = row.stages {
            HStack(spacing: 6) {
                if row.id == fastestRowID {
                    Text("Fastest")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: .capsule)
                }
                Text(rate(stages.total))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if row.error != nil {
            Text("Failed").font(.caption).foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Which configuration won, so far. Recomputed rather than stored because
    /// rows arrive one at a time and the leader changes as they do.
    private var fastestRowID: String? {
        var bestID: String?
        var bestTotal = Double.greatestFiniteMagnitude
        for row in benchmark.rows {
            guard let total = row.stages?.total, total > 0, total < bestTotal else { continue }
            bestTotal = total
            bestID = row.id
        }
        return bestID
    }

    private func stageColumn(_ name: String, _ seconds: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "%.0f", seconds * 1000))
                .font(.caption.monospacedDigit())
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int((seconds * 1000).rounded())) milliseconds")
    }

    /// "465 ms · 2.2 fps". Both, because one answers "is this slow" and the
    /// other answers "how long will my video take".
    private func rate(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return String(format: "%.0f ms · %.2f fps", seconds * 1000, 1 / seconds)
    }

    @ViewBuilder private var verdictRow: some View {
        if let verdict = benchmark.verdict {
            Label {
                Text(verdict).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .font(.callout)
        } else if !benchmark.isRunning, let summary = preferences.benchmarkSummary {
            Label {
                Text("Last measured: \(summary)").fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// What the export loop is currently willing to do, and why.
    ///
    /// The reason string is worth showing rather than hiding: an export that
    /// suddenly halves its frame rate is otherwise indistinguishable from a
    /// bug, and "critical" in this row is the entire explanation.
    private var deviceRows: some View {
        let capabilities = DeviceCapabilities.shared
        let profile = capabilities.profile(enhancing: model.enhanceFace)
        let thermal = DeviceCapabilities.thermalDescription(capabilities.thermalState)

        return Group {
            LabeledContent("This device",
                           value: "\(DeviceCapabilities.deviceModelIdentifier) · \(DeviceCapabilities.performanceCoreCount) cores")
            LabeledContent("Thermal state", value: thermal.capitalized)
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent("Frames at once", value: "\(profile.concurrentFrames)")
                Text(profile.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            ForEach(catalogue) { descriptor in
                modelRow(descriptor)
            }

            LabeledContent("On disk", value: formatBytes(manager.installedBytes))

            if manager.isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(manager.sessionReceived),
                                 total: Double(max(manager.sessionTotal, 1)))
                        .accessibilityLabel("Download progress")
                    HStack(spacing: 8) {
                        Text("\(formatBytes(manager.sessionReceived)) of \(formatBytes(manager.sessionTotal))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        quietButton("Stop") { manager.cancel() }
                    }
                }
            } else if missingBytes > 0 {
                Button {
                    manager.install(catalogue)
                } label: {
                    Label("Download missing (\(formatBytes(missingBytes)))",
                          systemImage: "arrow.down.circle")
                }
            }

            Button(role: .destructive) {
                isConfirmingRemoveAll = true
            } label: {
                Label("Remove all models", systemImage: "trash")
            }
            .disabled(manager.installedBytes == 0 || manager.isWorking)

            if let error = manager.lastError {
                Banner(kind: .error, text: error)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Kept out of your iCloud backup on purpose: every byte can be fetched again, and 900 MB of weights is not worth your backup space.")
        }
    }

    private var missingBytes: Int64 { manager.downloadSize(for: catalogue) }

    /// `LabeledContent` rather than a hand-built row: it is the one container
    /// that already knows to stack its label above its value when the text no
    /// longer fits beside it, which is most of what this screen needs at an
    /// accessibility size.
    private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        LabeledContent {
            Text(statusText(for: descriptor))
                .font(.callout.monospacedDigit())
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.modelID?.displayName ?? descriptor.id)
                if !descriptor.required {
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusText(for descriptor: ModelDescriptor) -> String {
        switch manager.states[descriptor.id] ?? .missing {
        case .installed:
            return formatBytes(descriptor.bytes)
        case .missing:
            return "\(formatBytes(descriptor.bytes)) · not installed"
        case .downloading(let received, let total):
            return "\(Int(Double(received) / Double(max(total, 1)) * 100))%"
        case .verifying:
            return "Verifying…"
        case .failed:
            return "Failed"
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            privacyLine("lock.shield",
                        "Every face is detected, encoded and swapped on this device. No photo, video or frame is ever uploaded.")
            privacyLine("wifi.slash",
                        "The one‑time model download is the only thing the app uses the network for. After it, everything works with no connection at all.")
            privacyLine("person.badge.shield.exclamationmark",
                        "The face‑swapping models are published for non‑commercial research use. Only swap faces of people who have agreed to it.")
        } header: {
            Text("Privacy")
        }
    }

    private func privacyLine(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: versionString)

            ForEach(catalogue) { descriptor in
                LabeledContent {
                    Text(descriptor.license)
                        .font(.callout)
                        .multilineTextAlignment(.trailing)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.modelID?.displayName ?? descriptor.id)
                        Text(descriptor.vendor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("The models come from the published FaceFusion release. Each keeps its own licence, listed above.")
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Actions

    /// A text button with an invisible 44 pt target, for the secondary actions
    /// that would look overbearing as pills.
    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The frame belongs inside the label: wrapped around the `Button`
            // it would centre the button in a larger box rather than enlarge
            // what the button accepts a tap on.
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.tint)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func measure() async {
        // The sweep leaves the engine holding whichever configuration it timed
        // last, which is the CPU baseline — 40× slower than the default on the
        // Mac's measurements. `EngineBenchmark.finish` already puts the winning
        // policy back, on every exit including cancellation, so there is nothing
        // to do here. Reloading again would only undo that work.
        await benchmark.run(model: model)
    }

    /// Rebuilds the sessions so a changed policy actually takes effect.
    ///
    /// This is `restartEngine` rather than unload-then-start, and the difference
    /// is not cosmetic. New sessions hold no projected source identity, but
    /// `startEngineIfPossible` only re-encodes the portrait when `sourceFace` is
    /// nil — so called the other way round the engine comes back with no source
    /// at all, while the studio still says "Face ready." and leaves Export
    /// enabled. The next render then fails on its first frame with "no face was
    /// found in the source image", and nothing recovers it short of removing and
    /// re-adding the face. `restartEngine` clears `sourceFace` first, which is
    /// exactly what makes the re-encode happen.
    private func reloadEngine() async {
        guard manager.isReady, !isReloadingEngine else { return }
        isReloadingEngine = true
        await model.restartEngine()
        isReloadingEngine = false
    }

    /// Unloads before deleting. A live session has its graphs memory-mapped,
    /// and deleting the files underneath it leaves it working from a file with
    /// no name — survivable, but there is no reason to find out.
    private func removeAllModels() async {
        await model.engine.unloadModels()
        manager.removeAll()
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
