import AppKit
import SwiftUI

@main
struct CrabProxyMacApp: App {
    @StateObject private var model = ProxyViewModel()
    @AppStorage("CrabProxyMacApp.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage("CrabProxyMacApp.currentScreen") private var currentScreenRawValue = "traffic"
    @AppStorage("CrabProxyMacApp.settingsTab") private var settingsTabRawValue = "General"

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup("Crab Proxy") {
            ContentView(
                model: model,
                appearanceModeRawValue: $appearanceModeRawValue
            )
                .onAppear {
                    applyAppAppearance()
                }
                .onChange(of: appearanceModeRawValue) { _, _ in
                    applyAppAppearance()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
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

    @MainActor
    private func openSettings() {
        settingsTabRawValue = "General"
        currentScreenRawValue = "settings"
    }
}
