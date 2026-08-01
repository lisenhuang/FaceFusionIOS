//
//  Components.swift
//  FaceFusion
//
//  The small shared vocabulary every screen draws from: one banner, one section
//  heading, one card, and the three formatters that turn engine numbers into
//  something a person reads.
//
//  These live together because they are exactly the pieces that drift. The
//  onboarding screen, the studio and settings all show byte counts and all group
//  controls into cards; if each defined its own, the app would slowly stop
//  looking like one app. On the Mac they were scattered — `formatBytes` sat at
//  the bottom of the onboarding file and `timecode` was duplicated privately in
//  two views — which is how one of the copies ended up unable to show an hour.
//
//  Nothing here knows about the pipeline, the models or the device. It is
//  deliberately the one view file with no dependencies, so it can be read and
//  changed without holding the rest of the app in mind.
//

import SwiftUI

// MARK: - Numbers people read

/// A file size as a person reads it — "12.7 MB", "340 MB".
///
/// The unit list is pinned to megabytes and gigabytes because every size this
/// app shows is a model file and the smallest of them is 12 MB. Left to choose
/// for itself the formatter produces "12,659,761 bytes" on one row and "0.01 GB"
/// on the next, and a download list whose numbers cannot be compared at a glance
/// is worse than one with no numbers at all.
func formatBytes(_ count: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: count)
}

/// A position on the timeline — "1:07".
///
/// Minutes are not wrapped into hours. The scrubber's two labels sit in narrow
/// fixed columns either side of the slider, and widening them for the rare clip
/// that runs past an hour would cost every clip that does not; "72:14" stays
/// legible in the space "1:12:14" would overflow. `formatDuration` is the one
/// that grows an hours field, because an export on a phone genuinely can take
/// one and "time remaining" has room.
func timecode(_ seconds: Double) -> String {
    let total = wholeSeconds(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// A length of time, for "2:14 left". Hours appear only when there are any.
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = wholeSeconds(seconds)
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Rounds to whole seconds, refusing the values that reach the UI while
/// something upstream is still settling.
///
/// This guard is not decoration. A time remaining divided by a frame rate that
/// is still zero is infinite, an `AVAsset` that has not finished loading reports
/// its duration as NaN, and `Int(Double.nan)` traps rather than returning
/// anything — so a label doing the obvious thing would crash the app on the
/// first frame of an export. The upper clamp is there for the same reason:
/// converting an enormous `Double` to `Int` also traps.
private func wholeSeconds(_ seconds: Double) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds.rounded(), 359_999))   // 99:59:59
}

// MARK: - Banner

/// A line of explanation the user did not ask for: a failure, or a fact they
/// need before pressing the button underneath.
///
/// Always full width and always above the thing it talks about, because an
/// error tucked beside a control is an error nobody reads. Text wraps rather
/// than truncating — the messages here are sentences, and a clipped sentence
/// about why a download was discarded helps no one.
struct Banner: View {
    enum Kind { case error, info }

    var kind: Kind
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? Color.orange : Color.secondary)
                .accessibilityLabel(kind == .error ? "Error" : "Note")
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((kind == .error ? Color.orange : Color.secondary).opacity(0.12),
                    in: .rect(cornerRadius: 12))
        // Combined so VoiceOver reads "Error, the download could not be
        // verified" as one utterance instead of stopping on a lone icon.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section heading

/// The heading above a group of controls — "Settings", "Models", "Appearance".
///
/// The caller passes sentence case and the upper-casing happens here, so
/// VoiceOver is handed a word rather than an acronym and a translator is handed
/// a sentence rather than shouting. Sized from `.caption`, so it grows with
/// Dynamic Type like everything under it.
struct SectionLabel: View {
    var text: String
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .kerning(0.6)
                .textCase(.uppercase)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

/// A group of controls set apart from the page behind it.
///
/// Material rather than a flat fill, so the card reads as a layer in both
/// schemes without either being spelled out: over a light background it frosts,
/// over a dark one it lifts. Deliberately no drop shadow — against a dark
/// background a shadow is invisible and against a light one it competes with
/// the material's own edge, whereas a hairline border is legible in both.
///
/// Nothing inside is given a fixed size. The card takes the width it is offered
/// and the height its content asks for, which is what keeps it working at
/// 320 pt in Slide Over and at the largest accessibility text size.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat
    var padding: CGFloat
    private let content: Content

    init(cornerRadius: CGFloat = 16,
         padding: CGFloat = 14,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(.quaternary, lineWidth: 1) }
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Models", systemImage: "square.stack.3d.up")

            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Face swapper").font(.callout.weight(.medium))
                    Text(formatBytes(277_680_829))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(timecode(67)) · \(formatDuration(3_754)) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Banner(kind: .error,
                   text: "The download did not match its checksum, so it was discarded.")
            Banner(kind: .info,
                   text: "Everything after the download runs on this device.")
        }
        .padding()
    }
}
