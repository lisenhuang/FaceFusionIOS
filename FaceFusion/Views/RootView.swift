//
//  RootView.swift
//  FaceFusion
//
//  Routes between first-run model installation and the studio, and owns the two
//  pieces of state that outlive whichever of them is on screen.
//
//  The Mac's `ContentView` did only the routing. Three more jobs land here on
//  iOS, and they land here rather than in `FaceFusionApp` because each of them
//  needs to see the environment or to re-render:
//
//  - The colour scheme. `Preferences` is an `@Observable` model rather than a
//    pile of `@AppStorage`, so the theme has to be *read in a body* for a change
//    to repaint anything. Read here, at the top, it repaints everything at once.
//  - The Settings sheet. It is presented from the root rather than from the
//    studio's toolbar because the studio is not permanent: removing the models
//    swaps it for the onboarding screen, and a sheet presented by a view that
//    disappears goes with it.
//  - Memory warnings. There is no SwiftUI equivalent of
//    `didReceiveMemoryWarning`, and the app has roughly 560 MB of weights
//    resident when it is working, so this is the notification that decides
//    whether the user loses the enhancer or loses the app.
//

import SwiftUI
import UIKit
import Combine

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model

    @State private var showsSettings = false

    /// Read through a property rather than inline so the dependency is obvious:
    /// touching `theme` inside `body` is what subscribes this view to it.
    private var preferences: Preferences { Preferences.shared }

    var body: some View {
        Group {
            if model.models.isReady {
                StudioView()
            } else {
                OnboardingView()
            }
        }
        .animation(.smooth(duration: 0.35), value: model.models.isReady)
        // Keyed on the *set* of loadable models, not on `isReady`. Nil until the
        // launch pass has finished deciding the library, so the engine is never
        // started under a pass that may still rename files and empty the compile
        // cache; and a set rather than a flag so that an optional model
        // downloaded or removed from Settings — which leaves `isReady` exactly
        // where it was — still brings the engine back on what is now on disk.
        .task(id: model.models.loadableModels) {
            await model.startEngineIfPossible()
        }
        .environment(\.presentSettings, { showsSettings = true })
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .preferredColorScheme(preferences.theme.colorScheme)
        // The other half of the language override. SwiftUI resolves every
        // `Text("literal")` against this, and reads it here in `body`, so
        // changing the picker in Settings retranslates the interface in place
        // rather than at the next launch.
        .environment(\.locale, preferences.language.locale)
        // Jetsam gives no second warning. Handing this straight to the model —
        // which drops the optional models and their Core ML graphs — costs the
        // user quality on the next frame instead of costing them the render.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.handleMemoryWarning()
        }
    }
}

// MARK: - Reaching Settings from anywhere

private struct PresentSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Opens the Settings sheet, wherever it happens to be hosted.
    ///
    /// The gear that triggers it lives in the studio's toolbar, but the sheet
    /// belongs to the root. Passing an *action* down is what keeps that split
    /// honest: the studio can ask for Settings without holding the presentation
    /// state, and nothing has to lift a `@State` out of a view that should not
    /// have had it in the first place.
    ///
    /// The default does nothing, so a view used outside `RootView` — a preview,
    /// most often — still compiles and still runs.
    var presentSettings: @MainActor () -> Void {
        get { self[PresentSettingsKey.self] }
        set { self[PresentSettingsKey.self] = newValue }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
