import SwiftUI

enum CrabTheme {
  private struct ThemePalette {
    let primaryTint: Color
    let secondaryTint: Color
    let destructiveTint: Color
    let warningTint: Color
    let neutralTint: Color
    let primaryText: Color
    let secondaryText: Color
    let glassFill: Color
    let panelFill: Color
    let panelStroke: Color
    let softFill: Color
    let inputFill: Color
    let inputStroke: Color
    let ruleCardFill: Color
    let themeCardFill: Color
    let themePickerTrayFill: Color
    let themeChipSelectedFill: Color
    let themeChipSelectedText: Color
    let backgroundGradient: [Color]
  }

  private static let lightPalette = ThemePalette(
    primaryTint: Color(red: 0.93, green: 0.39, blue: 0.12),
    secondaryTint: Color(red: 0.98, green: 0.66, blue: 0.25),
    destructiveTint: Color(red: 0.82, green: 0.28, blue: 0.24),
    warningTint: Color(red: 0.93, green: 0.57, blue: 0.17),
    neutralTint: Color(red: 0.52, green: 0.42, blue: 0.36),
    primaryText: Color(red: 0.21, green: 0.15, blue: 0.12),
    secondaryText: Color(red: 0.38, green: 0.29, blue: 0.24).opacity(0.9),
    glassFill: Color.white.opacity(0.66),
    panelFill: Color.white.opacity(0.6),
    panelStroke: Color.white.opacity(0.9),
    softFill: Color.white.opacity(0.68),
    inputFill: Color.white.opacity(0.8),
    inputStroke: Color(red: 0.92, green: 0.76, blue: 0.67).opacity(0.9),
    ruleCardFill: Color.white.opacity(0.74),
    themeCardFill: Color.white.opacity(0.76),
    themePickerTrayFill: Color.white.opacity(0.82),
    themeChipSelectedFill: Color(red: 0.93, green: 0.39, blue: 0.12),
    themeChipSelectedText: .white,
    backgroundGradient: [
      Color(red: 0.99, green: 0.93, blue: 0.88),
      Color(red: 0.99, green: 0.90, blue: 0.82),
      Color(red: 0.98, green: 0.86, blue: 0.74),
    ]
  )

  private static let darkPalette = ThemePalette(
    primaryTint: Color(red: 0.90, green: 0.49, blue: 0.21),
    secondaryTint: Color(red: 0.82, green: 0.52, blue: 0.26),
    destructiveTint: Color(red: 0.93, green: 0.34, blue: 0.33),
    warningTint: Color(red: 0.94, green: 0.58, blue: 0.2),
    neutralTint: Color(red: 0.52, green: 0.56, blue: 0.63),
    primaryText: Color.white.opacity(0.95),
    secondaryText: Color.white.opacity(0.72),
    glassFill: Color.white.opacity(0.09),
    panelFill: Color.black.opacity(0.24),
    panelStroke: Color.white.opacity(0.12),
    softFill: Color.white.opacity(0.12),
    inputFill: Color.black.opacity(0.22),
    inputStroke: Color.white.opacity(0.15),
    ruleCardFill: Color.black.opacity(0.23),
    themeCardFill: Color.white.opacity(0.06),
    themePickerTrayFill: Color.black.opacity(0.28),
    themeChipSelectedFill: Color(red: 0.90, green: 0.49, blue: 0.21).opacity(0.9),
    themeChipSelectedText: Color.white.opacity(0.98),
    backgroundGradient: [
      Color(red: 0.03, green: 0.09, blue: 0.16),
      Color(red: 0.05, green: 0.18, blue: 0.21),
      Color(red: 0.06, green: 0.16, blue: 0.11),
    ]
  )

  private static func palette(for scheme: ColorScheme) -> ThemePalette {
    switch scheme {
    case .dark:
      return darkPalette
    case .light:
      return lightPalette
    @unknown default:
      return lightPalette
    }
  }

  static func primaryTint(for scheme: ColorScheme) -> Color {
    palette(for: scheme).primaryTint
  }

  static func secondaryTint(for scheme: ColorScheme) -> Color {
    palette(for: scheme).secondaryTint
  }

  static func destructiveTint(for scheme: ColorScheme) -> Color {
    palette(for: scheme).destructiveTint
  }

  static func warningTint(for scheme: ColorScheme) -> Color {
    palette(for: scheme).warningTint
  }

  static func neutralTint(for scheme: ColorScheme) -> Color {
    palette(for: scheme).neutralTint
  }

  static func primaryText(for scheme: ColorScheme) -> Color {
    palette(for: scheme).primaryText
  }

  static func secondaryText(for scheme: ColorScheme) -> Color {
    palette(for: scheme).secondaryText
  }

  static func glassFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).glassFill
  }

  static func panelFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).panelFill
  }

  static func panelStroke(for scheme: ColorScheme) -> Color {
    palette(for: scheme).panelStroke
  }

  static func softFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).softFill
  }

  static func inputFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).inputFill
  }

  static func inputStroke(for scheme: ColorScheme) -> Color {
    palette(for: scheme).inputStroke
  }

  static func ruleCardFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).ruleCardFill
  }

  static func themeCardFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).themeCardFill
  }

  static func themePickerTrayFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).themePickerTrayFill
  }

  static func themeChipSelectedFill(for scheme: ColorScheme) -> Color {
    palette(for: scheme).themeChipSelectedFill
  }

  static func themeChipSelectedText(for scheme: ColorScheme) -> Color {
    palette(for: scheme).themeChipSelectedText
  }

  static func backgroundGradient(for scheme: ColorScheme) -> [Color] {
    palette(for: scheme).backgroundGradient
  }

  static func statusCodeColor(for code: String?, scheme: ColorScheme) -> Color {
    guard let code, let value = Int(code) else {
      return secondaryText(for: scheme)
    }

    switch value {
    case 100..<200:
      return neutralTint(for: scheme)
    case 200..<300:
      return scheme == .dark
        ? Color(red: 0.35, green: 0.84, blue: 0.53)
        : Color(red: 0.12, green: 0.63, blue: 0.29)
    case 300..<400:
      return scheme == .dark
        ? Color(red: 0.41, green: 0.69, blue: 0.97)
        : Color(red: 0.12, green: 0.46, blue: 0.84)
    case 400..<500:
      return warningTint(for: scheme)
    case 500..<600:
      return destructiveTint(for: scheme)
    default:
      return secondaryText(for: scheme)
    }
  }
}
