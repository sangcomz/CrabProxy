import SwiftUI

@main
struct CrabProxyMacApp: App {
    @StateObject private var model = ProxyViewModel()

    var body: some Scene {
        WindowGroup("Crab Proxy") {
            ContentView(model: model)
        }

        WindowGroup("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 1080, height: 700)
    }
}
