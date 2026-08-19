//
//  SettingsView.swift
//  FaceFusion
//
//  The sheet behind the gear: how the app looks, how hard it pushes this
//  particular device, what is on disk, and what the app promises about where
//  the work happens.
//
//  The Performance section offers a choice; it no longer measures one. It used
//  to carry a sweep that timed every execution-provider configuration on the
//  frame in hand, on the argument that an iPhone's ANE-to-GPU balance is not a
//  Mac's and the Mac's one-off answer does not transfer. The argument still
//  holds and the price stopped being worth paying: minutes of work and a device
//  warm enough to throttle, to settle a setting almost nobody moved. The
//  policies the sweep chose between are simply offered directly now.
//
//  Everything else here exists because a phone is not a Mac in a different way:
//  the app's library is 900 MB of redownloadable weights on a device sold with
//  128 GB, so the user needs a way to see it and reclaim it, and the offline
//  promise is the whole reason to run a face swapper locally rather than upload
//  to a website, so it is written down rather than implied.
//
//  The storage half of the screen is organised around the one distinction that
//  makes any of this worth doing: three of the five models are required and two
//  are not. The optional pair is roughly 438 MB of the 903 — nearly half the
//  library — and removing it leaves an app that still swaps faces, just without
//  landmark refinement or detail enhancement. Removing a required model stops
//  swapping until it has been downloaded again. Five undifferentiated rows and a
//  Remove All hid the only choice on this screen a user can make safely.
//

import SwiftUI
import Foundation
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Apple's in-app rating sheet. `ReviewPrompt` decides whether asking now
    /// can work; this is only how the action reaches it.
    @Environment(\.requestReview) private var requestReview

    @Bindable private var preferences = Preferences.shared

    /// What a confirmation is currently being asked about. One piece of state
    /// for all three destructive actions: they ask the same question about
    /// different sets, and three booleans would let two dialogs be true at once.
    @State private var pending: Removal?
    @State private var isRemoving = false
    @State private var isReloadingEngine = false

    /// What the last Check for Updates concluded, and whether its alert is up.
    /// Held separately from the launch check in `FaceFusionApp`, which shows
    /// only the one outcome worth interrupting somebody for.
    @State private var updateOutcome: UpdateChecker.Outcome?
    @State private var isCheckingForUpdate = false
    @State private var isShowingUpdateResult = false

    private enum Removal {
        case one(ModelDescriptor)
        case optional
        case all
    }

    private var manager: ModelManager { model.models }
    private var catalogue: [ModelDescriptor] { manager.manifest?.models ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                languageSection
                performanceSection
                storageSection
                requiredSection
                optionalSection
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
            // An alert, not a confirmation dialog. Both ask the same question,
            // but a confirmation dialog is an action sheet, and on iPhone iOS
            // always slides one up from the bottom edge — there is no anchoring
            // API for it there, so in a list this long the question arrives a
            // long way from the row that asked it. An alert lands in the middle
            // of a dimmed screen, which is as near the tap as the system
            // allows, and it reads as the interruption a removal deserves.
            .alert(confirmationTitle,
                   isPresented: Binding(get: { pending != nil },
                                        set: { if !$0 { pending = nil } }),
                   presenting: pending) { removal in
                Button("Remove", role: .destructive) {
                    Task { await remove(removal) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { removal in
                Text(confirmationMessage(for: removal))
            }
            // Every outcome gets an alert, including the boring one. A button
            // the user pressed that answers by doing nothing visible reads as
            // broken, and "up to date" is the answer most presses deserve.
            .alert(updateAlertTitle,
                   isPresented: $isShowingUpdateResult,
                   presenting: updateOutcome) { outcome in
                if case .available(let update) = outcome {
                    Button("Update") { UIApplication.shared.open(update.storeURL) }
                    Button("Not now", role: .cancel) { }
                } else {
                    Button("OK", role: .cancel) { }
                }
            } message: { outcome in
                Text(updateAlertMessage(for: outcome))
            }
            // A download finishing while this sheet is open is the normal way
            // out of the "no models" state, and the engine will not start
            // itself. Without this the user closes Settings onto a studio that
            // looks ready and is not.
            //
            // Keyed on the loadable *set* rather than on `isReady`, for the same
            // two reasons `RootView` is: it stays nil until the launch pass has
            // decided the library, and a single optional model fetched from the
            // rows below leaves `isReady` exactly where it was while changing
            // what the engine ought to be running on.
            .onChange(of: manager.loadableModels) { _, loadable in
                guard loadable != nil else { return }
                Task { await model.startEngineIfPossible() }
            }
        }
        // The sheet is its own presentation, so the theme has to be applied
        // here as well as on `RootView` — otherwise choosing Dark repaints the
        // studio behind and leaves the picker that changed it in Light.
        .preferredColorScheme(preferences.theme.colorScheme)
        // Same argument for the language: the picker that changes it lives on
        // this sheet, so this is the one screen that must not need dismissing
        // before the new language shows.
        .environment(\.locale, preferences.language.locale)
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

    // MARK: - Language

    private var languageSection: some View {
        Section {
            // A menu rather than a segmented control: ten options, three of
            // them in scripts whose glyphs do not abbreviate.
            Picker("Language", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Follows your device unless you choose otherwise. A device set to Traditional Chinese is shown Simplified Chinese; a language Morphiqo does not speak is shown English.")
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        Section {
            ForEach(ComputePolicy.allCases) { policy in
                computeRow(policy)
            }

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
        .disabled(isReloadingEngine)
        .accessibilityAddTraits(policy == preferences.compute ? [.isButton, .isSelected] : .isButton)
    }

    /// What the export loop is currently willing to do, and why.
    ///
    /// The reason string is worth showing rather than hiding: an export that
    /// suddenly halves its frame rate is otherwise indistinguishable from a
    /// bug, and "critical" in this row is the entire explanation.
    private var deviceRows: some View {
        let capabilities = DeviceCapabilities.shared
        let profile = capabilities.profile(enhancing: model.enhanceFace)
        let thermal = DeviceCapabilities.thermalLabel(capabilities.thermalState)

        return Group {
            // `LabeledContent`'s `value:` overload takes a `StringProtocol`, not
            // a `LocalizedStringKey`, so the word "cores" has to be localised
            // before it arrives rather than by the view.
            LabeledContent("This device",
                           value: "\(DeviceCapabilities.deviceModelIdentifier) · "
                                + String(localized: "\(DeviceCapabilities.performanceCoreCount) cores", bundle: .uiLanguage))
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

    // MARK: - Storage

    private var storageSection: some View {
        Section {
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
            } else if manager.isPreparingLibrary {
                // The launch pass can still be hashing a model it is about to
                // adopt, and until it is done "Download missing (340 MB)" is an
                // offer to re-fetch weights that are already on the device.
                // `install` refuses to start while the pass is running anyway,
                // so leaving the button up would only make it look broken.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the models already on this device…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if missingBytes > 0 {
                Button {
                    manager.install(catalogue)
                } label: {
                    Label("Download missing (\(formatBytes(missingBytes)))",
                          systemImage: "arrow.down.circle")
                }
            }

            Button {
                pending = .all
            } label: {
                Label("Remove all models", systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
            .disabled(!canRemove || manager.installedBytes == 0)

            if let error = manager.lastError {
                Banner(kind: .error, text: error)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if model.isRendering {
                Banner(kind: .info,
                       text: String(localized: "An export is running. Models cannot be removed until it finishes.",
                                    bundle: .uiLanguage))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Everything here can be downloaded again. Removing it costs the wait, not the work — no face, video or setting is touched. It is kept out of your iCloud backup for the same reason.")
        }
    }

    // MARK: - The two halves of the library

    private var requiredSection: some View {
        Section {
            ForEach(manager.requiredModels) { descriptor in
                modelRow(descriptor)
            }
        } header: {
            Text("Required")
        } footer: {
            Text("Face swapping needs all three. Remove one and the app returns to its download screen until it is fetched again.")
        }
    }

    private var optionalSection: some View {
        Section {
            ForEach(manager.optionalModels) { descriptor in
                modelRow(descriptor)
            }

            // The one action on this screen most people actually want, and the
            // reason the library is split in two at all: nearly half the disk
            // back, with an app that still works afterwards.
            if installedOptionalBytes > 0 {
                Button {
                    pending = .optional
                } label: {
                    Label("Free \(formatBytes(installedOptionalBytes)) and keep swapping",
                          systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
                .disabled(!canRemove)
            }
        } header: {
            Text("Optional")
        } footer: {
            Text("Almost half the library, and swapping keeps working without it. You lose steadier tracking and the sharper, more detailed result.")
        }
    }

    private var missingBytes: Int64 { manager.downloadSize(for: catalogue) }

    private var installedOptionalBytes: Int64 {
        manager.installedBytes(of: manager.optionalModels)
    }

    /// Removal is blocked while anything else owns the files: a download is
    /// mid-verify, the launch pass is renaming them from another task, an export
    /// has the engine running frame after frame, or a removal already started is
    /// still waiting for the engine to let go.
    private var canRemove: Bool {
        !manager.isWorking && !manager.isPreparingLibrary
            && !model.isRendering && !isRemoving && !isReloadingEngine
    }

    /// One model: what it does, what it costs, and the single control that acts
    /// on it — Remove when it is installed, Download when it is not.
    ///
    /// The name is the *function* — "Face Enhancer", not the weight file it is
    /// loaded from. Nothing a user reads names a model or says where it came
    /// from, and `ModelDescriptor.displayName` is what guarantees that even for
    /// a manifest entry this build does not recognise.
    private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        // At an accessibility size the size and the button drop underneath the
        // name, the same trade the onboarding screen's row makes: a name, a
        // sentence, a byte count and a 44 pt target have never fitted across a
        // phone at AX5, and the target is the one thing that must not shrink.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    modelTitle(descriptor)
                    HStack(spacing: 8) {
                        modelStatus(descriptor)
                        Spacer(minLength: 8)
                        modelAction(descriptor)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    modelTitle(descriptor)
                    Spacer(minLength: 8)
                    modelStatus(descriptor)
                    modelAction(descriptor)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func modelTitle(_ descriptor: ModelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.displayName)
            Text(descriptor.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isInstalledButNotLoaded(descriptor) {
                Text("Installed, but the engine could not load it. Everything works as though it were not there. Removing it and downloading it again usually fixes that.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// On disk, and yet not in the running engine.
    ///
    /// This state has been reachable and invisible: an optional model that fails
    /// to load is skipped and logged, because a pipeline without the enhancer or
    /// the occluder still swaps faces and failing the launch over one would be
    /// worse. But the row went on saying "installed", the toggle went on saying
    /// "Enhance detail", and the only difference the user could see was that the
    /// result never changed. The engine already publishes what it loaded, so the
    /// discrepancy is derivable — and the Web app has said exactly this since it
    /// grew a reduced-footprint preparation.
    ///
    /// Only ever true for an optional model: a required one that fails to load
    /// throws, and there is no engine to compare against.
    private func isInstalledButNotLoaded(_ descriptor: ModelDescriptor) -> Bool {
        // Before the engine is ready there is nothing better than the library to
        // go on, and "installed" is the honest answer there: it is what the next
        // preparation will try to load.
        guard manager.isInstalled(descriptor),
              let id = descriptor.modelID,
              let loaded = model.engine.loadedModels else { return false }
        return !loaded.contains(id)
    }

    private func modelStatus(_ descriptor: ModelDescriptor) -> some View {
        Text(statusText(for: descriptor))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// `.borderless` rather than the default: a `Form` row with a plain button
    /// in it turns the *whole row* into that button, which here would mean
    /// tapping a model's description deleted it.
    @ViewBuilder
    private func modelAction(_ descriptor: ModelDescriptor) -> some View {
        if manager.isInstalled(descriptor) {
            Button {
                pending = .one(descriptor)
            } label: {
                rowButtonLabel("Remove")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .accessibilityLabel("Remove \(descriptor.displayName)")
        } else {
            Button {
                manager.install([descriptor])
            } label: {
                rowButtonLabel("Download")
            }
            .buttonStyle(.borderless)
            .disabled(manager.isWorking || manager.isPreparingLibrary || isRemoving)
            .accessibilityLabel("Download \(descriptor.displayName)")
        }
    }

    /// The 44 pt target belongs inside the label; wrapped around the `Button` it
    /// would centre the button in a larger box rather than enlarge what the
    /// button accepts a tap on.
    private func rowButtonLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .frame(minHeight: 44)
            .contentShape(.rect)
    }

    private func statusText(for descriptor: ModelDescriptor) -> String {
        switch manager.states[descriptor.id] ?? .missing {
        case .installed:
            // Parallel to "not installed" below, and the distinction is the
            // point: the bytes are there, the stage is not.
            if isInstalledButNotLoaded(descriptor) {
                return String(localized: "\(formatBytes(descriptor.bytes)) · not loaded", bundle: .uiLanguage)
            }
            return formatBytes(descriptor.bytes)
        case .missing:
            return String(localized: "\(formatBytes(descriptor.bytes)) · not installed", bundle: .uiLanguage)
        case .downloading(let received, let total):
            return "\(Int(Double(received) / Double(max(total, 1)) * 100))%"
        case .verifying:
            return String(localized: "Verifying…", bundle: .uiLanguage)
        case .checking:
            return String(localized: "Checking…", bundle: .uiLanguage)
        case .failed:
            return String(localized: "Failed", bundle: .uiLanguage)
        }
    }

    // MARK: - Privacy

    /// What the app promises, and it has to stay true of the app as built.
    ///
    /// The second line used to say the model download was "the only thing the
    /// app uses the network for". That has been false since 1.1.0, when the
    /// launch-time version check was added, and the Check for Updates button
    /// below makes the contradiction visible on this one screen. The promise
    /// worth making is about media, not about packet counts, and it survives
    /// being stated accurately: the version check sends the app's own store id
    /// and nothing else, and swapping still needs no connection at all.
    private var privacySection: some View {
        Section {
            privacyLine("lock.shield",
                        "Every face is detected, encoded and swapped on this device. No photo, video or frame is ever uploaded.")
            privacyLine("wifi.slash",
                        "The network is used for the one‑time model download, and to ask the App Store for its version number. Swapping itself works with no connection at all.")
        } header: {
            Text("Privacy")
        }
    }

    // `LocalizedStringKey` rather than `String`: taking a `String` here would
    // silently opt these two sentences out of the string catalog, because the
    // literal at the call site would be typed as a plain `String` before `Text`
    // ever saw it.
    private func privacyLine(_ symbol: String, _ text: LocalizedStringKey) -> some View {
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

    /// The version this build is, and a way to find out whether it is the one
    /// the store is selling.
    ///
    /// The app already asks this once per launch and stays quiet unless the
    /// answer is "yes, there is something newer" — which is right for an
    /// unprompted check and useless to somebody who wants to know *now*, or who
    /// wants to confirm that the update they were told about actually
    /// installed. Silence answers both questions with the same nothing.
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: UpdateChecker.installedVersion)

            if isCheckingForUpdate {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the App Store…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await checkForUpdate() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Button {
                if let url = ReviewPrompt.rate(requestReview) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Rate Morphiqo", systemImage: "star")
            }

            // `ShareLink` here, where the studio shares a render through
            // `UIActivityViewController` by hand. That one has to know whether
            // the share actually completed, because a completed share counts
            // towards a review prompt, and `ShareLink` never reports back.
            // Nothing turns on the outcome of this one, so the plain version is
            // the right one.
            //
            // The link is the Universal Purchase record, not an iPhone-specific
            // page, so whoever opens it gets the build for the device they
            // opened it on — a Mac user sent this from an iPhone lands on the
            // Mac app. `subject` is verbatim because a product name is the same
            // in every language and does not belong in the string catalog.
            ShareLink(item: AppStoreLink.listing,
                      subject: Text(verbatim: "Morphiqo"),
                      message: Text("Face swapping for photos and video that runs entirely on your own device — nothing is ever uploaded.")) {
                Label("Share Morphiqo", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Ratings are how other people find Morphiqo. It takes one tap and you stay in the app. Checking for updates asks the App Store for its version number and nothing else — no identifier, no device details, and nothing about the media you have worked on.")
        }
    }

    private func checkForUpdate() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        let outcome = await UpdateChecker.fetch()
        isCheckingForUpdate = false
        updateOutcome = outcome
        isShowingUpdateResult = true
    }

    private var updateAlertTitle: String {
        switch updateOutcome {
        case .available:
            return String(localized: "A new version is available", bundle: .uiLanguage)
        case .current:
            return String(localized: "Morphiqo is up to date", bundle: .uiLanguage)
        // `.none` cannot reach the screen — the alert is only raised with an
        // outcome in hand — but a title is needed to type-check the property,
        // and the cautious one is the right default.
        case .unavailable, .none:
            return String(localized: "Could not check for updates", bundle: .uiLanguage)
        }
    }

    /// Both numbers in every case, because "which version am I on" and "which
    /// version is current" are the two questions the button is pressed to
    /// answer, and only one of them is on the row above.
    private func updateAlertMessage(for outcome: UpdateChecker.Outcome) -> String {
        switch outcome {
        case .available(let update):
            return String(localized: "You have \(UpdateChecker.installedVersion). Version \(update.version) is on the App Store.", bundle: .uiLanguage)
        case .current(let latest):
            return String(localized: "You have \(UpdateChecker.installedVersion), and the App Store has \(latest).", bundle: .uiLanguage)
        case .unavailable:
            return String(localized: "You have \(UpdateChecker.installedVersion). The App Store did not answer, so there is nothing to compare it against — check your connection and try again.", bundle: .uiLanguage)
        }
    }

    // MARK: - Actions

    /// A text button with an invisible 44 pt target, for the secondary actions
    /// that would look overbearing as pills.
    private func quietButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
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

    // MARK: - Confirmation

    private var confirmationTitle: String {
        switch pending {
        case .one(let descriptor):
            return String(localized: "Remove \(descriptor.displayName)?", bundle: .uiLanguage)
        case .optional:
            return String(localized: "Remove the optional models?", bundle: .uiLanguage)
        case .all, .none:
            return String(localized: "Remove all models?", bundle: .uiLanguage)
        }
    }

    /// Every one of these says what is freed and what stops working, because
    /// those are the only two things the answer turns on.
    private func confirmationMessage(for removal: Removal) -> String {
        switch removal {
        case .one(let descriptor) where descriptor.required:
            return String(localized: "This frees \(formatBytes(descriptor.bytes)). Morphiqo cannot swap a face again until it is downloaded, which needs a connection.", bundle: .uiLanguage)
        case .one(let descriptor):
            return String(localized: "This frees \(formatBytes(descriptor.bytes)). Swapping keeps working without it — the result is simply less refined.", bundle: .uiLanguage)
        case .optional:
            return String(localized: "This frees \(formatBytes(installedOptionalBytes)). Swapping keeps working; results are less sharp and tracking less steady.", bundle: .uiLanguage)
        case .all:
            return String(localized: "This frees \(formatBytes(manager.installedBytes)), the compiled graphs included. Morphiqo cannot swap a face again until they are downloaded, which needs a connection.", bundle: .uiLanguage)
        }
    }

    /// Unloads before deleting. A live session has its graphs memory-mapped,
    /// and deleting the files underneath it leaves it working from a file with
    /// no name — survivable, but there is no reason to find out. That order is
    /// why every removal comes through here rather than calling the manager
    /// directly, per-model removals included.
    private func remove(_ removal: Removal) async {
        guard canRemove else { return }
        isRemoving = true
        defer { isRemoving = false }

        await model.engine.unloadModels()
        switch removal {
        case .one(let descriptor):
            manager.remove(descriptor)
        case .optional:
            for descriptor in manager.optionalModels { manager.remove(descriptor) }
        case .all:
            manager.removeAll()
        }
        // Back up on whatever survived. Removing an optional model leaves the
        // app perfectly usable, and leaving the engine unloaded until the next
        // launch would be a far bigger price than the disk it just gave back.
        await model.restartEngineAfterModelRemoval()
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
