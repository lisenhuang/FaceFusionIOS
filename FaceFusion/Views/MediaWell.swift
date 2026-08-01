//
//  MediaWell.swift
//  FaceFusion
//
//  The two places media comes into the app: the source face, and the target
//  video or photo.
//
//  On the Mac a well was a button that opened a panel and a rectangle that took
//  a drop. Neither survives the move. There is no open panel here, and — more to
//  the point — the file a person wants is usually not in Files at all: it is in
//  Photos, which is a database rather than a folder, and reaching it through a
//  file picker is not possible. So the well becomes a menu with both doors on
//  it, Photos and Files, and Remove once there is something to remove. Drag and
//  drop stays: on an iPad running alongside Photos or Files it is still the
//  fastest way in, and it costs one modifier.
//
//  The visual language is carried over unchanged — dashed border while empty,
//  thumbnail fill when full, caption underneath — because that is what the
//  reference established for "this slot wants a file" and there is no reason a
//  touch screen should say it differently.
//
//  The one thing that has no Mac equivalent is the security scope. A file chosen
//  through the document picker is readable only between
//  `startAccessingSecurityScopedResource` and its matching stop, and the app
//  needs it for as long as the well holds it — through the swap, and through an
//  export that may run for ten minutes. So the scope is held here, alongside the
//  URL it belongs to, and released only when that URL is replaced or removed.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaWell<Thumbnail: View>: View {
    var title: String
    var systemImage: String
    var hint: String
    var isFilled: Bool
    var caption: String?
    /// What Files is allowed to offer. The Photos filter is derived from the
    /// same list, so the two doors cannot end up disagreeing about what this
    /// well accepts.
    var accepted: [UTType]
    var onPickFile: (URL) -> Void
    var onPickPhoto: (PhotosPickerItem) -> Void
    var onClear: () -> Void
    /// Drops land in `onPickFile` unless the caller wants them treated apart —
    /// the studio's window-wide drop has to decide which slot a photo belongs
    /// in, a well does not.
    var onDrop: ((URL) -> Void)?
    @ViewBuilder var thumbnail: () -> Thumbnail

    @State private var isTargeted = false
    @State private var isChoosingPhoto = false
    @State private var isChoosingFile = false
    @State private var photoItem: PhotosPickerItem?
    /// The security-scoped URL currently held open, if any.
    @State private var scopedURL: URL?
    @State private var importError: String?

    /// Grows with Dynamic Type, so the hint inside an empty well still fits at
    /// the largest accessibility sizes instead of being clipped by a number
    /// chosen for the default one.
    @ScaledMetric(relativeTo: .body) private var wellHeight: CGFloat = Metrics.wellHeight

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            well
            if let importError {
                Text(importError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .photosPicker(isPresented: $isChoosingPhoto,
                      selection: $photoItem,
                      matching: photoFilter)
        .fileImporter(isPresented: $isChoosingFile,
                      allowedContentTypes: accepted) { result in
            switch result {
            case .success(let url):
                adopt(url)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            // Cleared straight away so that choosing the same photo twice — after
            // removing it, say — still counts as a change and fires again.
            photoItem = nil
            importError = nil
            onPickPhoto(item)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(title)
            Spacer(minLength: 0)
            if isFilled {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.tertiary)
                        // The glyph is small by design; the tappable area is not.
                        // Anything under 44 pt is a miss waiting to happen.
                        .frame(width: 44, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
    }

    // MARK: - The well

    private var well: some View {
        Menu {
            Button {
                importError = nil
                isChoosingPhoto = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                importError = nil
                isChoosingFile = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            if isFilled {
                Divider()
                Button(role: .destructive, action: clear) {
                    Label("Remove", systemImage: "trash")
                }
            }
        } label: {
            wellFace
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(caption ?? (isFilled ? "Chosen" : "Empty"))
        .accessibilityHint(isFilled ? "Change or remove this." : "Choose from Photos or Files.")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importError = nil
            if let onDrop {
                onDrop(url)
            } else {
                adopt(url)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.smooth(duration: 0.12)) { isTargeted = targeted }
        }
    }

    private var wellFace: some View {
        ZStack {
            shape.fill(.quaternary.opacity(isTargeted ? 0.6 : 0.28))

            if isFilled {
                // `Color.clear` accepts whatever the ZStack proposes, which pins
                // the overlay to the well's bounds. Without it a `.fill` image
                // reports its full natural size, the ZStack grows to match, and
                // the thumbnail spills over its neighbours.
                Color.clear
                    .overlay { thumbnail() }
                    .clipShape(shape)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.light))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }

            // Dashed while empty, solid once filled: the border is what says
            // whether this slot is still asking for something.
            shape.strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                               style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                                  dash: isFilled ? [] : [5, 4]))
        }
        // A minimum rather than a fixed height: at the largest text sizes the
        // hint needs three lines and a well that refused to grow would cut the
        // last one off.
        .frame(minHeight: wellHeight)
        .contentShape(.rect)
    }

    // MARK: - Picking

    /// What Photos should show, derived from the same list Files is given.
    private var photoFilter: PHPickerFilter {
        let wantsMovies = accepted.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        let wantsImages = accepted.contains { $0.conforms(to: .image) }
        switch (wantsImages, wantsMovies) {
        case (true, true): return .any(of: [.images, .videos])
        case (false, true): return .videos
        default: return .images
        }
    }

    /// Takes ownership of a file URL, opening its security scope if it has one.
    ///
    /// The previous scope is closed first and only then is the new one recorded,
    /// so a well that is refilled a dozen times does not leak a dozen open
    /// scopes. Nothing closes the scope on disappear: a well disappears whenever
    /// the layout changes between the stacked and sidebar shapes, and revoking
    /// access to the user's video because they rotated the device would fail the
    /// export with a permissions error that makes no sense at all.
    private func adopt(_ url: URL) {
        importError = nil
        if url.startAccessingSecurityScopedResource() {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
        }
        onPickFile(url)
    }

    private func clear() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        importError = nil
        onClear()
    }
}
