//
//  Layout.swift
//  FaceFusion
//
//  The three shapes the studio can take, and the handful of numbers every screen
//  agrees on.
//
//  The Mac version needed none of this. A window is never smaller than you make
//  it, so a 292 pt sidebar beside a canvas was the whole layout question and it
//  was answered once, in literals. Here the same workspace has to hold together
//  in a 320 pt Slide Over column, in a landscape strip barely 390 pt tall, and
//  across a 13" iPad — and it has to move between them mid-session, because a
//  rotation or a Split View drag is not a relaunch.
//
//  So the decision is made in one place and passed down as a value. Any view can
//  ask what shape it is in; no view guesses from a magic width.
//
//  Deciding on **size class** rather than on device is the point of the exercise.
//  `UIDevice` would say "iPad" for a Slide Over window narrower than any phone,
//  and "iPhone" for a Pro Max in landscape that is wider than a Split View pane.
//  The size class is the system already answering the only question that
//  matters: how much room is there, right now.
//

import SwiftUI

// MARK: - Shape

/// Which of the three shapes the studio takes.
///
/// Driven by size class rather than by device, because "iPad" is not a size:
/// a Slide Over window is 320 pt wide and must lay out like a phone, and a
/// Plus-sized phone in landscape is a regular width and can afford the sidebar.
enum StudioLayout {
    /// Regular width: controls left, canvas right (iPad, big phones landscape).
    case sidebar
    /// Compact width, compact height: canvas left, controls right (phone landscape).
    case sideBySide
    /// Compact width, regular height: canvas above, controls below (phone portrait).
    case stacked

    /// The one rule, written once.
    ///
    /// The size classes arrive as optionals because a view can be measured
    /// before it is in a window. `nil` is treated as compact rather than
    /// regular: the stacked shape works at every width, whereas the sidebar
    /// shape assumes room that may not be there, and being briefly too narrow is
    /// a much cheaper mistake than being briefly too wide.
    static func resolve(horizontal: UserInterfaceSizeClass?,
                        vertical: UserInterfaceSizeClass?) -> StudioLayout {
        if horizontal == .regular { return .sidebar }
        return vertical == .compact ? .sideBySide : .stacked
    }

    /// The natural width of the control column — an upper bound, not a promise.
    /// The studio clamps it against the space actually available, since a third
    /// of an iPad and two thirds of a Split View pane are the same 320 pt.
    /// Zero for `.stacked`, which has no column at all.
    var sidebarWidth: CGFloat {
        switch self {
        case .sidebar: return 320
        case .sideBySide: return 300
        case .stacked: return 0
        }
    }

    /// True when the controls live in a column of their own beside the canvas.
    var wantsSidebar: Bool { self != .stacked }
}

// MARK: - Metrics

/// The numbers that would otherwise be typed out in four files and drift apart
/// in three of them.
///
/// Deliberately few. This is not a design system; it is the short list of values
/// that have to agree for the app to look like one app — the radius shared by
/// cards, wells and the canvas, the inset shared by every edge, and the height
/// of a media well, which the studio and the well itself both need to know.
enum Metrics {
    /// Corner radius for cards, media wells and the canvas letterbox.
    static let corner: CGFloat = 14

    /// The standard edge inset, and the gap between neighbouring sections.
    static let gutter: CGFloat = 16

    /// The height of a media well's thumbnail area. Fixed rather than derived
    /// because a well that grows with its caption makes the two wells different
    /// heights, and two drop targets of different sizes read as two different
    /// kinds of control.
    static let wellHeight: CGFloat = 116

    /// The smallest a control may be and still be reliably hit with a finger.
    /// Apple's number, repeated here so it is a constant rather than a `44` that
    /// looks like a coincidence.
    static let tapTarget: CGFloat = 44
}

// MARK: - Adaptive stack

/// An `HStack` or a `VStack`, chosen by the caller.
///
/// It exists to stop the same row of controls being written out twice — once
/// side by side for the room, once stacked for a phone or for an accessibility
/// text size — because two copies of a row is exactly how one of them ends up
/// missing a button.
///
/// `AnyLayout` would also do this, and is the better tool when the axis has to
/// *animate* between the two. It never does here: the axis changes on a rotation
/// or a resize, which rebuilds the view anyway. The plain switch keeps each
/// branch an ordinary stack with ordinary behaviour.
@MainActor
struct AdaptiveStack<Content: View>: View {
    var axis: Axis
    /// Used when the axis is vertical.
    var horizontalAlignment: HorizontalAlignment = .leading
    /// Used when the axis is horizontal.
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch axis {
        case .horizontal:
            HStack(alignment: verticalAlignment, spacing: spacing, content: content)
        case .vertical:
            VStack(alignment: horizontalAlignment, spacing: spacing, content: content)
        }
    }
}
