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
        }

        WindowGroup("Settings", id: "settings") {
            SettingsView(
                model: model,
                appearanceModeRawValue: $appearanceModeRawValue
            )
            .preferredColorScheme(appearanceMode.preferredColorScheme)
        }
        .defaultSize(width: 1080, height: 700)
    }
}
