//
//  AppStoreLink.swift
//  FaceFusion
//
//  Morphiqo's App Store record, written down once.
//
//  The id was already spelled out twice — `UpdateChecker` looks the listing up
//  by it, `ReviewPrompt` falls back to the review form built from it — and the
//  Share button in Settings was about to add a third. Three literals that have
//  to agree, with nothing making them agree, is the kind of thing that stays
//  correct until the day the record changes.
//
//  One record covers every platform. Morphiqo is a Universal Purchase, so the
//  same id addresses the iPhone, iPad and Mac builds, and the Mac target keeps
//  a file identical to this one. That is why the shared link is a single URL
//  rather than one per platform: whoever opens it lands on the build for the
//  device they opened it on, and a Mac user sent a link by an iPhone user gets
//  the Mac app.
//
//  Not named `AppStore`: StoreKit already has a type by that name and this
//  module's own would shadow it, breaking `AppStore.sync()` in `StoreManager`.
//

import Foundation

enum AppStoreLink {

    /// The App Store record shared by every platform target.
    static let id = "6797135085"

    /// The listing, as somebody would be sent it.
    static let listing = URL(string: "https://apps.apple.com/app/id\(id)")!

    /// The listing, opened straight onto its review form. For when Apple's
    /// in-app sheet cannot be shown — see `ReviewPrompt.rate(_:)`.
    static let writeReview = URL(string: "https://apps.apple.com/app/id\(id)?action=write-review")!
}
