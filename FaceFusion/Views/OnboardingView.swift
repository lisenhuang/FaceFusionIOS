//
//  OnboardingView.swift
//  FaceFusion
//
//  First run: explain what is about to be downloaded, then download it.
//
//  This is the only moment the app needs a network connection, so it says so
//  plainly rather than leaving the user to wonder. On a phone that promise is
//  worth more than it was on a Mac — the whole reason to run a face swapper
//  locally is that nothing about the faces leaves the device — so the screen
//  states the size, recommends Wi‑Fi, and says outright that this is the only
//  time the network is used.
//
//  Everything is inside a `ScrollView` with no fixed heights, because this
//  screen has to survive a 320 pt phone held sideways, where the header alone
//  is most of the window, and an accessibility text size, where a single model
//  row is taller than a phone in landscape.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var includeOptional = true

    private var manager: ModelManager { model.models }

    private var selectedModels: [ModelDescriptor] {
        includeOptional ? (manager.manifest?.models ?? []) : manager.requiredModels
    }

    private var downloadSize: Int64 { manager.downloadSize(for: selectedModels) }

    /// Roomy on an iPad, tight on a phone. A fixed 40 pt gutter costs an eighth
    /// of the width in Slide Over, which is exactly where there is none to lose.
    private var gutter: CGFloat { horizontalSizeClass == .regular ? 40 : 20 }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                if let error = manager.lastError {
                    Banner(kind: .error, text: error)
                }

                modelList

                optionsAndAction

                disclosure
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, gutter)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 78, height: 78)
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .padding(.bottom, 4)
            .accessibilityHidden(true)

            Text("Set up Morphiqo")
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("The app needs its AI models before it can run. This is a one‑time download — afterwards face swapping works entirely on this device, with no internet connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Withheld while the library is being checked. A user who already
            // has every model is a second away from being told they need none
            // of it, and "About 903 MB to fetch" in the meantime is alarming
            // and wrong.
            if downloadSize > 0, !manager.isPreparingLibrary {
                Text("About \(formatBytes(downloadSize)) to fetch. Wi‑Fi is recommended.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(manager.manifest?.models ?? []) { descriptor in
                ModelRow(descriptor: descriptor,
                         state: manager.states[descriptor.id] ?? .missing,
                         included: descriptor.required || includeOptional)
                if descriptor.id != manager.manifest?.models.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var optionsAndAction: some View {
        VStack(spacing: 18) {
            Toggle(isOn: $includeOptional) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include quality extras")
                    Text("Sharper results and steadier tracking. You can add these later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(manager.isWorking || manager.isPreparingLibrary)

            if manager.isPreparingLibrary {
                // Seconds, on an update that has 900 MB to hash and rename, and
                // an unexplained wait in front of a Download button is how a
                // user ends up downloading what they already have.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the models already on this device…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if manager.isWorking {
                VStack(spacing: 10) {
                    ProgressView(value: Double(manager.sessionReceived),
                                 total: Double(max(manager.sessionTotal, 1)))
                        .accessibilityLabel("Download progress")

                    // Wraps to two lines rather than truncating: at an
                    // accessibility size "339.2 MB of 903.4 MB" and a Cancel
                    // button do not fit across a phone.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            transferred
                            Spacer(minLength: 8)
                            cancelButton
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            transferred
                            cancelButton
                        }
                    }

                    Text("The download carries on if you leave the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    manager.install(selectedModels)
                } label: {
                    Text(downloadSize > 0
                         ? "Download \(formatBytes(downloadSize))"
                         : "Continue")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedModels.isEmpty)
            }
        }
    }

    private var transferred: some View {
        Text("\(formatBytes(manager.sessionReceived)) of \(formatBytes(manager.sessionTotal))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// The Mac's `.link` style, which iOS does not have, plus the 44 pt target
    /// it needs. The frame goes *inside* the label: wrapping one around a
    /// `Button` centres the button in a larger box instead of enlarging the
    /// area the button will accept a tap on.
    private var cancelButton: some View {
        Button(role: .cancel) {
            manager.cancel()
        } label: {
            Text("Cancel")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Every file is verified against a checksum before use, and anything that does not match is discarded.")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            Label {
                Text("This download is the only time the app uses the network. Afterwards it works entirely offline, and no photo or video ever leaves the device.")
            } icon: {
                Image(systemName: "lock.shield")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Row

private struct ModelRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let descriptor: ModelDescriptor
    let state: ModelInstallState
    let included: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A fixed symbol size, not just a fixed frame. `.frame(width:)`
            // constrains the layout slot but does not scale or clip the glyph,
            // and the symbol otherwise inherits `.body` — around 53 pt at AX5 —
            // so it would be drawn centred and overhanging the 20 pt slot in
            // both directions, colliding with the model name on one side and
            // spilling past the card's border on the other.
            statusIcon
                .font(.system(size: 17))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            // At a normal text size the status sits on the right, where it can
            // be scanned down the column; at an accessibility size there is no
            // room beside a wrapped model name, so it drops underneath.
            //
            // Decided from the text size rather than by `ViewThatFits`, which
            // would get this wrong: the description under each name is a full
            // sentence, so the horizontal candidate's *ideal* width is the
            // sentence unwrapped and it would never be chosen, at any text
            // size, on any device.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    title
                    trailing
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    trailing
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(included ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }

    /// The name is the *function* — "Face Enhancer", not the weight file it is
    /// loaded from. Nothing a user reads names a model or says where it came
    /// from, and `ModelDescriptor.displayName` is what guarantees that even for
    /// a manifest entry this build does not recognise.
    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(descriptor.displayName)
                    .font(.callout.weight(.medium))
                if !descriptor.required {
                    Text("Optional")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            Text(descriptor.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .downloading, .verifying, .checking:
            ProgressView().controlSize(.small)
        case .missing:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .downloading(let received, let total):
            Text("\(Int(Double(received) / Double(max(total, 1)) * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Verifying…").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .installed:
            Text("Installed").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Failed").font(.caption).foregroundStyle(.orange)
        case .missing:
            Text(formatBytes(descriptor.bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppModel())
}
