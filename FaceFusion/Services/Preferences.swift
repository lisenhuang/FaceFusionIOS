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
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
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

    // MARK: - Engine

    var compute: ComputePolicy {
        didSet { defaults.set(compute.rawValue, forKey: Key.compute) }
    }

    /// The last verdict from `EngineBenchmark`, kept so Settings can show what
    /// was measured on *this* device rather than making the user run it again
    /// to remember the answer.
    var benchmarkSummary: String? {
        didSet {
            if let benchmarkSummary {
                defaults.set(benchmarkSummary, forKey: Key.benchmarkSummary)
            } else {
                defaults.removeObject(forKey: Key.benchmarkSummary)
            }
        }
    }

    // MARK: - Swap settings

    var enhanceFace: Bool {
        didSet { defaults.set(enhanceFace, forKey: Key.enhanceFace) }
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

    // MARK: - Setup

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Registered rather than written, so a value the user has never touched
        // stays absent from the store and picks up a new default if one ever
        // ships — and so every `object(forKey:)` below has something to find.
        defaults.register(defaults: [
            Key.theme: AppTheme.system.rawValue,
            Key.compute: ComputePolicy.automatic.rawValue,
            Key.enhanceFace: true,
            Key.identityStrength: 0.5,
            Key.maskBlur: 0.3,
            Key.matchDistance: defaultFaceMatchDistance,
            Key.useHEVC: true,
            Key.savesToPhotos: true,
            Key.hasCompletedOnboarding: false
        ])

        // A stored raw value can be from a build that spelled the case
        // differently, so both enums fall back rather than trusting the store.
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        compute = ComputePolicy(rawValue: defaults.string(forKey: Key.compute) ?? "") ?? .automatic
        benchmarkSummary = defaults.string(forKey: Key.benchmarkSummary)

        enhanceFace = defaults.bool(forKey: Key.enhanceFace)
        identityStrength = defaults.double(forKey: Key.identityStrength)
        maskBlur = defaults.double(forKey: Key.maskBlur)
        matchDistance = defaults.double(forKey: Key.matchDistance)

        useHEVC = defaults.bool(forKey: Key.useHEVC)
        savesToPhotos = defaults.bool(forKey: Key.savesToPhotos)

        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    private enum Key {
        static let theme = "appearance.theme"
        static let compute = "engine.compute"
        static let benchmarkSummary = "engine.benchmarkSummary"
        static let enhanceFace = "swap.enhanceFace"
        static let identityStrength = "swap.identityStrength"
        static let maskBlur = "swap.maskBlur"
        static let matchDistance = "swap.matchDistance"
        static let useHEVC = "output.useHEVC"
        static let savesToPhotos = "output.savesToPhotos"
        static let hasCompletedOnboarding = "onboarding.completed"
    }
}
