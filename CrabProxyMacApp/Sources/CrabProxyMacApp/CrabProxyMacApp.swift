import AppKit
import SwiftUI

@main
struct CrabProxyMacApp: App {
    @StateObject private var model = ProxyViewModel()
    @AppStorage("CrabProxyMacApp.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup("Crab Proxy") {
            ContentView(model: model)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onAppear {
                    applyAppAppearance()
                }
                .onChange(of: appearanceModeRawValue) { _, _ in
                    applyAppAppearance()
                }
        }

        WindowGroup("Settings", id: "settings") {
            SettingsView(
                model: model,
                appearanceModeRawValue: $appearanceModeRawValue
            )
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            .onAppear {
                applyAppAppearance()
            }
            .onChange(of: appearanceModeRawValue) { _, _ in
                applyAppAppearance()
            }
        }
        .defaultSize(width: 1080, height: 700)
    }

    @MainActor
    private func applyAppAppearance() {
        let forcedAppearance: NSAppearance?
        switch appearanceMode {
        case .system:
            forcedAppearance = nil
        case .light:
            forcedAppearance = NSAppearance(named: .aqua)
        case .dark:
            forcedAppearance = NSAppearance(named: .darkAqua)
        }

        NSApp.appearance = forcedAppearance
        for window in NSApp.windows {
            window.appearance = forcedAppearance
        }
    }
}
