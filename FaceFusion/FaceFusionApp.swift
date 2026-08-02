//
//  FaceFusionApp.swift
//  FaceFusion
//
//  The process entry point: one model, one window, and the two pieces of
//  lifecycle that cannot live inside a view.
//
//  The delegate exists for one callback and no other reason. Model downloads
//  total about 900 MB and run on a background `URLSession`, which means the
//  system may finish them long after the app has been suspended or terminated,
//  then relaunch the app in the background to say so. That message arrives
//  through `UIApplicationDelegate` and has no SwiftUI equivalent, so a delegate
//  is kept purely to hand it to `Downloader`.
//
//  Everything else — routing between onboarding and the studio, the colour
//  scheme, the settings sheet, memory warnings — belongs to `RootView`, which
//  can see the environment and re-render. Putting any of it here would mean
//  reaching for the model from outside SwiftUI's observation, which is how a
//  screen ends up not updating.
//
//  The Mac build also started `--benchmark` and `--selftest` from here, because
//  a shell-launched binary does not reliably get a window. Neither mode exists
//  on iOS: there is no argv to read, and the benchmark is a button in Settings
//  where it belongs, since the answer it produces differs per device.
//

import SwiftUI
import UIKit
import os

/// Receives the one lifecycle message SwiftUI does not surface.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// A background download finished while the app was not running, so the
    /// system woke us to deal with it.
    ///
    /// `Downloader` owns the session and therefore owns the completion handler:
    /// it must be called only once the session has replayed every event it has
    /// queued, and calling it late — or not at all — is how an app loses its
    /// background execution allowance and the remaining models stop arriving.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        EngineLog.models.notice("Woken for background session \(identifier, privacy: .public)")
        Downloader.shared.handleEventsForBackgroundURLSession(completionHandler: completionHandler)
    }
}

@main
struct FaceFusionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    /// The whole app's state, owned by the scene rather than by a view so that
    /// a rebuild — a rotation, a Split View resize, a Photos picker coming and
    /// going — cannot restart the engine or drop a render in progress.
    @State private var model = AppModel()

    @State private var hasClearedStaleExports = false

    /// Set only when the App Store has something newer; see `UpdateChecker`.
    @State private var availableUpdate: UpdateChecker.Update?
    @State private var isShowingUpdate = false

    /// Points `Bundle.main` at the stored interface language before the first
    /// view exists.
    ///
    /// `Preferences` would do this the moment anything read it, but the first
    /// reader is `RootView.body` — by which point a `String(localized:)` on a
    /// launch path could already have answered in the system's language.
    init() {
        LocalizationOverride.apply(Preferences.shared.language)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Once per launch, off the main path: the result arrives long
                // after the first frame and nothing waits on it.
                .task {
                    guard let update = await UpdateChecker.check() else { return }
                    availableUpdate = update
                    isShowingUpdate = true
                }
                .alert("A new version is available",
                       isPresented: $isShowingUpdate,
                       presenting: availableUpdate) { update in
                    Button("Update") { UIApplication.shared.open(update.storeURL) }
                    Button("Not now", role: .cancel) { }
                } message: { update in
                    Text("Morphiqo \(update.version) is on the App Store. You have \(UpdateChecker.installedVersion).")
                }
        }
        // Renders are written to a temporary folder and only moved to Photos or
        // to Files when the user says so, so a crash or a force-quit leaves the
        // file behind. It is swept once per launch and not on every activation:
        // returning from the Photos picker is an activation too, and the file
        // the user is in the middle of saving lives in that folder.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !hasClearedStaleExports else { return }
            hasClearedStaleExports = true
            MediaStore.clearStaleOutputs()
        }
    }
}
