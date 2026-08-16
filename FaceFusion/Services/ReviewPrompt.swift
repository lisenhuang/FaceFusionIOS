//
//  ReviewPrompt.swift
//  FaceFusion
//
//  When — and far more often, when not — to ask for an App Store review.
//
//  Apple's prompt is a request, not a display. The system allows at most three
//  of them per person per year, decides on its own whether any particular one
//  appears, and never says which way it went. That is what makes the obvious
//  version — ask after every save — actively harmful rather than merely eager:
//  the year's allowance drains invisibly on people who are mid-flow, and by the
//  time someone has used the app enough to have an opinion worth hearing there
//  is nothing left to spend on them.
//
//  So the rules live here, once, instead of at each place a save can succeed.
//  There are already two of those on this platform and they would drift. The
//  view layer's whole part is handing over the environment's `requestReview`
//  action; whether that action is ever reached is decided below.
//
//  Two things this deliberately is not. It never opens the App Store — the
//  prompt is Apple's own sheet, presented over the app, and the user stays where
//  they were. And it is never reachable from a control the user pressed: the
//  Human Interface Guidelines require the ask to follow a moment that already
//  went well, which is exactly why the callers are save and share successes and
//  why there is no "Rate us" button anywhere to add one.
//

import Foundation
import StoreKit
import SwiftUI

@MainActor
enum ReviewPrompt {

    /// Successful saves and shares before the first ask.
    ///
    /// Three, because the first is the app proving it works at all and the
    /// second is the user checking that was not luck. Someone on their third
    /// finished render has formed the opinion the prompt would be asking about;
    /// someone on their first has not, and asking them costs the same.
    private static let successesBeforeAsking = 3

    /// A beat between the success message and the sheet.
    ///
    /// Without it the two arrive together, and the prompt reads as part of the
    /// save rather than as a separate question about the app. On the automatic
    /// save path it would also land while the result bar is still coming in.
    private static let settle = Duration.seconds(1.5)

    /// Records one save or share that actually landed, and answers whether this
    /// is a moment worth asking at.
    ///
    /// Only ever call it from a success. An error, a share the user backed out
    /// of and the "already in your photo library" no-op are all moments the user
    /// got nothing from, and an ask spent on one of those is an ask spent on a
    /// bad mood.
    static func noteSuccess() -> Bool {
        let preferences = Preferences.shared
        preferences.successfulSaveCount += 1

        guard preferences.successfulSaveCount >= successesBeforeAsking else { return false }

        // One ask per version, rather than one ask ever. An update earns a
        // second chance with someone who ignored the first; without this, every
        // save after the third would ask again and walk straight into the yearly
        // cap.
        return preferences.lastReviewPromptVersion != currentVersion
    }

    /// Presents Apple's prompt, and marks this version's ask as spent.
    ///
    /// The version is written *before* the action runs rather than after. The
    /// system never tells us whether it put anything on screen, so "we asked" is
    /// the only fact we have; treating a silent refusal as though it had not
    /// happened would keep asking on every subsequent save.
    static func present(_ request: RequestReviewAction) async {
        try? await Task.sleep(for: settle)
        // The caller ties this to the view's lifetime, so a user who left the
        // screen during the pause is no longer at the successful moment the
        // prompt was meant to follow.
        guard !Task.isCancelled else { return }

        // Asked again rather than taken on trust from the caller. The token the
        // studio watches lives on the model and outlives the studio, and the
        // studio is not permanent — removing a required model swaps it for the
        // download screen, and fetching that model again brings it back with the
        // token exactly where it was. The task keyed to that token then runs a
        // second time on a version that has already asked. Without this line
        // that is a second one of the year's three, spent on nothing.
        guard Preferences.shared.lastReviewPromptVersion != currentVersion else { return }

        Preferences.shared.lastReviewPromptVersion = currentVersion
        request()
    }

    /// The marketing version, which is what the store listing calls this build.
    ///
    /// The fallback only matters if the Info dictionary is unreadable, and even
    /// then comparing it against itself still yields one ask rather than one per
    /// save.
    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
