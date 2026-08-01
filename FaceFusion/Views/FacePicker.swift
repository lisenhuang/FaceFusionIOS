//
//  FacePicker.swift
//  FaceFusion
//
//  The list of people in the target, with a checkbox each.
//
//  This is the whole of the *Choose* mode's interface, and the reason that mode
//  exists: faces are re-detected independently on every frame and numbered
//  left to right within it, so "the second face" stops naming the same person
//  the moment two people cross. Ticking a thumbnail names an identity instead,
//  which is the only thing that survives a cut, a crossing, or the subject
//  walking across frame.
//
//  The Mac laid this out for a pointer: 62 pt thumbnails and 9 pt captions,
//  which a mouse can hit exactly and a finger cannot. Every control here is
//  therefore at least 44 pt in both directions, and the chips scale with the
//  text size rather than staying fixed while the labels under them grow — an
//  accessibility size otherwise produces a wall of captions with postage stamps
//  above them. The wording is unchanged apart from "click" becoming "tap",
//  because the captions were written to explain a genuinely subtle feature and
//  rewriting them would only make them worse.
//

import SwiftUI

struct FacePicker: View {
    @Environment(AppModel.self) private var model

    /// The thumbnails grow with Dynamic Type. They are the tap target as well
    /// as the picture, so someone who has asked for larger text is also
    /// someone for whom a bigger target is the point.
    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 72

    /// Adaptive rather than a fixed column count: this view sits in a 320 pt
    /// sidebar on a phone, a 300 pt one in Slide Over, and the full width of an
    /// iPad's stacked layout, and a count that suited one would waste the rest.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: chipSize, maximum: chipSize + 28), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isScanning {
                scanning
            } else if model.people.isEmpty {
                empty
            } else {
                grid
                summary
                matchSlider
            }
        }
    }

    // MARK: - States

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProgressView(value: model.scanProgress?.fraction ?? 0)
                Button {
                    model.cancelScan()
                } label: {
                    // Sized from inside the label, which is the only place it
                    // counts: a `.frame` wrapped around a `Button` moves the
                    // button within a larger box rather than enlarging what
                    // the button will accept a tap on.
                    Text("Stop").frame(minWidth: 44, minHeight: 30)
                }
                .buttonStyle(.bordered)
            }
            Text(scanCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Read as one utterance, and re-read as it changes: the frame
                // count is the only signal that a long scan is still moving.
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var scanCaption: String {
        guard let progress = model.scanProgress else { return "Looking…" }
        let found = progress.peopleFound
        let people = found == 1 ? "1 person" : "\(found) people"
        return "Frame \(progress.framesScanned) of \(progress.totalFrames) · \(people) so far"
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.hasScanned
                 ? "No faces found in the target."
                 : (model.targetIsImage
                    ? "Look for the faces in this photo."
                    : "Look through the video for the people in it, then tick the ones to replace."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.scanTargetForPeople()
            } label: {
                Label(model.hasScanned ? "Look again" : "Find faces",
                      systemImage: "person.crop.rectangle.stack")
                    .font(.callout)
                    .frame(minHeight: 30)
            }
            .buttonStyle(.bordered)
            .disabled(model.targetURL == nil)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            // Enumerated so a chip can announce itself as "person 2" without
            // reading out the scanner's internal id, which is an allocation
            // order and means nothing to anyone.
            ForEach(Array(model.people.enumerated()), id: \.element.id) { ordinal, person in
                FaceChip(person: person,
                         ordinal: ordinal + 1,
                         size: chipSize,
                         isChecked: model.checkedPeople.contains(person.id),
                         caption: caption(for: person)) {
                    model.togglePerson(person.id)
                }
            }
        }
    }

    /// When someone is on screen. Useless for a photo, and for a person who
    /// appears in a single sampled frame there is no span to state.
    private func caption(for person: FaceScanner.Person) -> String? {
        guard !model.targetIsImage, person.lastSeen > person.firstSeen + 0.5 else { return nil }
        return "\(timecode(person.firstSeen))–\(timecode(person.lastSeen))"
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(model.checkedPeople.isEmpty
                                 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                quietButton(model.checkedPeople.count == model.people.count ? "None" : "All") {
                    if model.checkedPeople.count == model.people.count {
                        model.uncheckEveryPerson()
                    } else {
                        model.checkEveryPerson()
                    }
                }
                quietButton("Look again") { model.scanTargetForPeople() }
                Spacer(minLength: 0)
            }

            Text("Missing someone? Tap their face in the preview to add them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionSummary: String {
        let checked = model.checkedPeople.count
        guard checked > 0 else { return "No one selected — nothing will be replaced." }
        return "Replacing \(checked) of \(model.people.count)."
    }

    /// The Mac's `.link` button style, which does not exist here.
    ///
    /// Plain tinted text with an invisible 44 pt target around it: a bordered
    /// pill for two words would compete with the primary actions above, but a
    /// bare word small enough not to compete is also small enough to miss.
    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var matchSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Match strictness").font(.callout)
                Spacer(minLength: 0)
            }
            // Inverted: the engine works in distance, where larger is looser,
            // but "drag right for stricter" is the only direction a slider
            // labelled strictness can go.
            Slider(value: Binding(get: { 1.1 - model.matchDistance },
                                  set: { model.matchDistance = 1.1 - $0 }),
                   in: 0.3 ... 0.9) { editing in
                if !editing { Task { await model.applyMatchDistance() } }
            }
            .accessibilityLabel("Match strictness")

            Text("Lower if someone is missed when they turn away; raise if the wrong person gets replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One face

private struct FaceChip: View {
    var person: FaceScanner.Person
    var ordinal: Int
    var size: CGFloat
    var isChecked: Bool
    var caption: String?
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail = person.thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.32, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: size, height: size)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                          lineWidth: isChecked ? 2.5 : 1)
                    }
                    // Unchecked faces are dimmed rather than hidden: they are
                    // still the answer to "who else is in this video".
                    .opacity(isChecked ? 1 : 0.55)

                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white,
                                         isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.35)))
                        .padding(4)
                }

                if let caption {
                    Text(caption)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: isChecked)
        // The tick is a picture of a state, so VoiceOver is told the state
        // instead — with the Mac's own wording for what ticking one means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "Person \(ordinal), on screen \($0)" } ?? "Person \(ordinal)")
        .accessibilityValue(isChecked ? "Will be replaced" : "Will be left alone")
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    FacePicker()
        .environment(AppModel())
        .padding()
        .frame(maxWidth: 320)
}
