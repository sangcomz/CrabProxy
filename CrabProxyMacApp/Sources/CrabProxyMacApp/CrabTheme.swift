import SwiftUI

enum CrabTheme {
    static func primaryTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.93, green: 0.39, blue: 0.12)
        case .dark:
            return Color(red: 0.90, green: 0.49, blue: 0.21)
        @unknown default:
            return Color(red: 0.93, green: 0.39, blue: 0.12)
        }
    }

    static func secondaryTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.98, green: 0.66, blue: 0.25)
        case .dark:
            return Color(red: 0.82, green: 0.52, blue: 0.26)
        @unknown default:
            return Color(red: 0.98, green: 0.66, blue: 0.25)
        }
    }

    static func destructiveTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.82, green: 0.28, blue: 0.24)
        case .dark:
            return Color(red: 0.93, green: 0.34, blue: 0.33)
        @unknown default:
            return Color(red: 0.82, green: 0.28, blue: 0.24)
        }
    }

    static func warningTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.93, green: 0.57, blue: 0.17)
        case .dark:
            return Color(red: 0.94, green: 0.58, blue: 0.2)
        @unknown default:
            return Color(red: 0.93, green: 0.57, blue: 0.17)
        }
    }

    static func neutralTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.52, green: 0.42, blue: 0.36)
        case .dark:
            return Color(red: 0.52, green: 0.56, blue: 0.63)
        @unknown default:
            return Color(red: 0.52, green: 0.42, blue: 0.36)
        }
    }

    static func primaryText(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.21, green: 0.15, blue: 0.12)
        case .dark:
            return Color.white.opacity(0.95)
        @unknown default:
            return Color(red: 0.21, green: 0.15, blue: 0.12)
        }
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.38, green: 0.29, blue: 0.24).opacity(0.9)
        case .dark:
            return Color.white.opacity(0.72)
        @unknown default:
            return Color(red: 0.38, green: 0.29, blue: 0.24).opacity(0.9)
        }
    }

    static func glassFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.66)
        case .dark:
            return Color.white.opacity(0.09)
        @unknown default:
            return Color.white.opacity(0.66)
        }
    }

    static func panelFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.6)
        case .dark:
            return Color.black.opacity(0.24)
        @unknown default:
            return Color.white.opacity(0.6)
        }
    }

    static func panelStroke(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.9)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.white.opacity(0.9)
        }
    }

    static func softFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.68)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.white.opacity(0.68)
        }
    }

    static func inputFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.8)
        case .dark:
            return Color.black.opacity(0.22)
        @unknown default:
            return Color.white.opacity(0.8)
        }
    }

    static func inputStroke(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.92, green: 0.76, blue: 0.67).opacity(0.9)
        case .dark:
            return Color.white.opacity(0.15)
        @unknown default:
            return Color(red: 0.92, green: 0.76, blue: 0.67).opacity(0.9)
        }
    }

    static func ruleCardFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.74)
        case .dark:
            return Color.black.opacity(0.23)
        @unknown default:
            return Color.white.opacity(0.74)
        }
    }

    static func themeCardFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.76)
        case .dark:
            return Color.white.opacity(0.06)
        @unknown default:
            return Color.white.opacity(0.76)
        }
    }

    static func themePickerTrayFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.82)
        case .dark:
            return Color.black.opacity(0.28)
        @unknown default:
            return Color.white.opacity(0.82)
        }
    }

    static func themeChipSelectedFill(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return primaryTint(for: scheme)
        case .dark:
            return primaryTint(for: scheme).opacity(0.9)
        @unknown default:
            return primaryTint(for: scheme)
        }
    }

    static func themeChipSelectedText(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return .white
        case .dark:
            return Color.white.opacity(0.98)
        @unknown default:
            return .white
        }
    }

    static func backgroundGradient(for scheme: ColorScheme) -> [Color] {
        switch scheme {
        case .light:
            return [
                Color(red: 0.99, green: 0.93, blue: 0.88),
                Color(red: 0.99, green: 0.90, blue: 0.82),
                Color(red: 0.98, green: 0.86, blue: 0.74),
            ]
        case .dark:
            return [
                Color(red: 0.03, green: 0.09, blue: 0.16),
                Color(red: 0.05, green: 0.18, blue: 0.21),
                Color(red: 0.06, green: 0.16, blue: 0.11),
            ]
        @unknown default:
            return [
                Color(red: 0.99, green: 0.93, blue: 0.88),
                Color(red: 0.99, green: 0.90, blue: 0.82),
                Color(red: 0.98, green: 0.86, blue: 0.74),
            ]
        }
    }
}
