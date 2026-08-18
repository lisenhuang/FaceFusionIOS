//
//  Localization.swift
//  Morphiqo
//
//  Which language the interface speaks, and the machinery that lets an in-app
//  choice override the system's.
//
//  The default path needs no code at all. The app ships `en`, `de`, `es`, `fr`,
//  `it`, `ja`, `ko`, `pt-BR`, `zh-Hans` and `zh-Hant`, with `en` as the
//  development region, so iOS already resolves the right one: a Korean phone
//  gets Korean, a German phone gets German, and a phone set to a language the
//  app does not speak falls back to English. Regional variants resolve to the
//  language they belong to, which is why one `es` covers Spain and Latin America
//  alike and `pt-BR` also answers a phone set to European Portuguese.
//  `zh-Hant` exists purely so that a Traditional Chinese device lands on
//  Simplified rather than on English; its `.lproj` is a copy of `zh-Hans`. That
//  mirroring also fixes the app's *name* on the Home Screen, which SpringBoard
//  resolves long before any of this code runs.
//
//  Overriding that choice from inside the app is the part that needs work, and
//  it needs doing twice, because two unrelated mechanisms resolve strings:
//
//  - `Text("literal")`, and every other SwiftUI view taking a
//    `LocalizedStringKey`, resolves through the environment's `\.locale`.
//    `RootView` and `SettingsView` set it, which covers most of the interface.
//  - `String(localized:)` — the status messages `AppModel` assigns, every
//    `LocalizedError.errorDescription`, every `displayName` on an enum — does
//    not see the environment. It reads from a `Bundle`, defaulting to
//    `Bundle.main`, which answers in the *system* language. So every one of
//    those call sites passes `bundle: .uiLanguage` instead.
//
//  Passing the bundle at each call site is tedious next to swapping
//  `Bundle.main`'s class with `object_setClass`, which is the usual trick. That
//  was tried first and does not work here: `String(localized:)` does not route
//  through `Bundle.localizedString(forKey:value:table:)`, so a subclass
//  overriding it is never consulted. The symptom was specific and worth
//  recording — with the environment locale set to Japanese and the class
//  swapped, the onboarding screen's own text turned Japanese while every model
//  name and description beside it stayed English, because those come from
//  `ModelID.displayName`. An explicit `bundle:` argument fixes exactly that, and
//  Xcode's string extractor still recognises the call, which a hand-rolled
//  wrapper function would not.
//

import Foundation
import SwiftUI
import os

/// The languages the interface ships in, plus "follow the system".
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"
    case japanese = "ja"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case brazilianPortuguese = "pt-BR"

    var id: String { rawValue }

    /// Endonyms: each language written the way its own speakers write it.
    ///
    /// Deliberately *not* translated. Someone who has landed in a language they
    /// cannot read is the exact person who needs this menu, and "日本語" is
    /// legible to them in a way that a Korean rendering of "Japanese" is not.
    /// Only "System" follows the current language, because it is the one row
    /// that describes a behaviour rather than naming a language.
    var label: String {
        switch self {
        case .system:             return String(localized: "System", bundle: .uiLanguage)
        case .english:            return "English"
        case .simplifiedChinese:  return "简体中文"
        case .korean:             return "한국어"
        case .japanese:           return "日本語"
        case .german:             return "Deutsch"
        case .spanish:            return "Español"
        case .french:             return "Français"
        case .italian:            return "Italiano"
        case .brazilianPortuguese: return "Português"
        }
    }

    /// The `.lproj` this choice forces, or `nil` to leave iOS's own resolution
    /// alone.
    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    /// The locale to hand SwiftUI's environment.
    ///
    /// `autoupdatingCurrent` for the system case rather than a fixed locale, so
    /// that dates and numbers keep following the device's region even when the
    /// interface language does not come from it.
    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }
}

// MARK: - Making the choice stick outside SwiftUI

/// Holds the `.lproj` that `String(localized:)` should read from.
///
/// Not thread-confined: a `LocalizedError` has its `errorDescription` read on
/// whichever queue the failure happened on, so the selected bundle lives behind
/// a lock rather than on the main actor.
enum LocalizationOverride {

    /// The bundle to answer from, or `nil` when the app is following the system
    /// and `Bundle.main`'s own resolution is already the right one.
    private static let selected = OSAllocatedUnfairLock<Bundle?>(uncheckedState: nil)

    /// Points subsequent lookups at `language`.
    ///
    /// A language whose `.lproj` is missing from the bundle resolves to `nil`,
    /// which falls back to `Bundle.main` — the interface stays in the system
    /// language rather than showing raw keys.
    static func apply(_ language: AppLanguage) {
        let bundle = language.localeIdentifier
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
        selected.withLock { $0 = bundle }
        EngineLog.app.notice(
            "UI language: \(language.localeIdentifier ?? "system", privacy: .public)")
    }

    static var current: Bundle? {
        selected.withLock { $0 }
    }
}

extension Bundle {
    /// The bundle every `String(localized:)` in this app reads from, so that it
    /// answers in the language the user picked rather than the system's.
    ///
    /// `.main` when the app is following the system, which is also the right
    /// answer for a language the override could not resolve.
    static var uiLanguage: Bundle {
        LocalizationOverride.current ?? .main
    }
}
