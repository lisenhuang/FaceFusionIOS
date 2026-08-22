//
//  Preferences.swift
//  FaceFusion
//
//  The handful of choices that should still be there next time the app opens.
//
//  The Mac build kept these on `AppModel` and let them evaporate on quit, which
//  is tolerable for a window you reopen in seconds and irritating on a phone
//  that kills the app whenever it needs the memory. So they live here, in
//  `UserDefaults`, and `AppModel` forwards to them under the same property
//  names the views already use.
//
//  Deliberately not `@AppStorage`: that is a property wrapper for a `View`, and
//  this is a model object several screens and the export loop read. An
//  `@Observable` class with a `didSet` per property does the same job, is
//  readable from anywhere, and keeps the persistence in one obvious place
//  rather than scattered across whichever view happened to declare it first.
//

import Foundation
import Observation
import SwiftUI

/// Whether the app follows the system's appearance or overrides it.
///
/// Worth offering rather than assuming: the canvas is near-black in both
/// schemes so the letterbox never competes with the image, and someone judging
/// skin tones in a swap will want the surrounding chrome to stay put rather
/// than flip at sunset.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "System", bundle: .uiLanguage)
        case .light:  return String(localized: "Light", bundle: .uiLanguage)
        case .dark:   return String(localized: "Dark", bundle: .uiLanguage)
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// `nil` means "do not override", which is what `.preferredColorScheme`
    /// wants for the system option.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
@Observable
final class Preferences {

    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Appearance

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    /// The interface language, or `.system` to follow the device.
    ///
    /// The `didSet` does more than persist: `String(localized:)` reads from
    /// `Bundle.main` rather than from SwiftUI's environment, so the override has
    /// to be re-pointed here for the next error message to come back in the
    /// language the user just picked.
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            LocalizationOverride.apply(language)
        }
    }

    // MARK: - Engine

    var compute: ComputePolicy {
        didSet { defaults.set(compute.rawValue, forKey: Key.compute) }
    }

    // MARK: - Swap settings

    var enhanceFace: Bool {
        didSet { defaults.set(enhanceFace, forKey: Key.enhanceFace) }
    }

    var maskOcclusion: Bool {
        didSet { defaults.set(maskOcclusion, forKey: Key.maskOcclusion) }
    }

    var identityStrength: Double {
        didSet { defaults.set(identityStrength, forKey: Key.identityStrength) }
    }

    var maskBlur: Double {
        didSet { defaults.set(maskBlur, forKey: Key.maskBlur) }
    }

    var matchDistance: Double {
        didSet { defaults.set(matchDistance, forKey: Key.matchDistance) }
    }

    var closeUpDetail: CloseUpDetail {
        didSet { defaults.set(closeUpDetail.rawValue, forKey: Key.closeUpDetail) }
    }

    // MARK: - Output

    var useHEVC: Bool {
        didSet { defaults.set(useHEVC, forKey: Key.useHEVC) }
    }

    var savesToPhotos: Bool {
        didSet { defaults.set(savesToPhotos, forKey: Key.savesToPhotos) }
    }

    // MARK: - First run

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Asking for a review

    /// How many saves and shares have genuinely succeeded, over the life of the
    /// install. `ReviewPrompt` is the only thing that reads it.
    ///
    /// Kept here rather than in memory because the number it has to survive is
    /// an app relaunch: someone who exports one video a week is exactly the user
    /// worth asking, and a count that resets on quit would never reach them.
    var successfulSaveCount: Int {
        didSet { defaults.set(successfulSaveCount, forKey: Key.successfulSaveCount) }
    }

    /// The marketing version that last put the review prompt on screen, or an
    /// empty string if none has.
    ///
    /// The version rather than a `Bool`, so an update re-arms the ask exactly
    /// once instead of either never asking again or asking on every save.
    /// When this app last asked the system for a review, most recent last, as
    /// seconds since 1970.
    ///
    /// The system allows three requests per person per year and will not say
    /// how many are left — or whether any given one was shown. Only this app
    /// can request a review of this app, so our own calls are the closest thing
    /// to that counter anyone outside the system can hold. It exists for the
    /// Settings button, which must not be a control that silently does nothing.
    var reviewRequestDates: [Double] {
        didSet { defaults.set(reviewRequestDates, forKey: Key.reviewRequestDates) }
    }

    var lastReviewPromptVersion: String {
        didSet { defaults.set(lastReviewPromptVersion, forKey: Key.lastReviewPromptVersion) }
    }

    // MARK: - Setup

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Registered rather than written, so a value the user has never touched
        // stays absent from the store and picks up a new default if one ever
        // ships — and so every `object(forKey:)` below has something to find.
        defaults.register(defaults: [
            Key.theme: AppTheme.system.rawValue,
            Key.language: AppLanguage.system.rawValue,
            Key.compute: ComputePolicy.automatic.rawValue,
            Key.enhanceFace: true,
            Key.maskOcclusion: true,
            Key.identityStrength: 0.5,
            Key.maskBlur: 0.3,
            Key.matchDistance: defaultFaceMatchDistance,
            Key.closeUpDetail: CloseUpDetail.high.rawValue,
            Key.useHEVC: true,
            Key.savesToPhotos: true,
            Key.hasCompletedOnboarding: false,
            Key.successfulSaveCount: 0,
            Key.lastReviewPromptVersion: "",
            Key.reviewRequestDates: [Double]()
        ])

        // A stored raw value can be from a build that spelled the case
        // differently, so both enums fall back rather than trusting the store.
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        compute = ComputePolicy(rawValue: defaults.string(forKey: Key.compute) ?? "") ?? .automatic

        enhanceFace = defaults.bool(forKey: Key.enhanceFace)
        maskOcclusion = defaults.bool(forKey: Key.maskOcclusion)
        identityStrength = defaults.double(forKey: Key.identityStrength)
        maskBlur = defaults.double(forKey: Key.maskBlur)
        matchDistance = defaults.double(forKey: Key.matchDistance)

        // Absent on every device upgrading from an older build, which is why it
        // is registered above rather than written: the registration answers with
        // `.high`, the intended default, instead of the empty string a missing
        // key would otherwise give. Falls back for the same reason `theme` and
        // `compute` do — a raw value stored by a build that spelled a case
        // differently must not decode to nothing.
        closeUpDetail = CloseUpDetail(rawValue: defaults.string(forKey: Key.closeUpDetail) ?? "")
            ?? .high

        useHEVC = defaults.bool(forKey: Key.useHEVC)
        savesToPhotos = defaults.bool(forKey: Key.savesToPhotos)

        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)

        // Both keys are new in this version, so on a device upgrading from an
        // older build they are absent and the registered defaults answer: no
        // saves counted yet, and no version has asked. That is the same state a
        // fresh install starts in, which is the intent — an existing user gets
        // the first ask after their next three successful saves, not on the
        // first one because a missing key read as zero by accident.
        successfulSaveCount = defaults.integer(forKey: Key.successfulSaveCount)
        lastReviewPromptVersion = defaults.string(forKey: Key.lastReviewPromptVersion) ?? ""
        reviewRequestDates = defaults.array(forKey: Key.reviewRequestDates) as? [Double] ?? []

        // `didSet` does not run during initialisation, so the stored choice has
        // to be pushed into the bundle override by hand. Doing it here rather
        // than at the first call site means the very first error message of the
        // session is already in the right language.
        LocalizationOverride.apply(language)
    }

    private enum Key {
        static let theme = "appearance.theme"
        static let language = "appearance.language"
        static let compute = "engine.compute"
        // "engine.benchmarkSummary" was written by builds up to 1.9.0 and is
        // no longer read. Retired, not reused: never give this name a new
        // meaning, because an older install still has the old value.
        static let enhanceFace = "swap.enhanceFace"
        static let maskOcclusion = "swap.maskOcclusion"
        static let identityStrength = "swap.identityStrength"
        static let maskBlur = "swap.maskBlur"
        static let matchDistance = "swap.matchDistance"
        static let closeUpDetail = "swap.closeUpDetail"
        static let useHEVC = "output.useHEVC"
        static let savesToPhotos = "output.savesToPhotos"
        static let hasCompletedOnboarding = "onboarding.completed"
        static let successfulSaveCount = "review.successfulSaveCount"
        static let lastReviewPromptVersion = "review.lastPromptedVersion"
        static let reviewRequestDates = "review.requestDates"
    }
}
