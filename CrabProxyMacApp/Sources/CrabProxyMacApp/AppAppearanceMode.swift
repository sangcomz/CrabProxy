import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static let uiOrder: [AppAppearanceMode] = [.light, .dark, .system]

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var symbolName: String {
        switch self {
        case .system:
            return "laptopcomputer"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}
