import AppKit
import SwiftUI

@main
struct CrabProxyMacApp: App {
    @StateObject private var model = ProxyViewModel()
    @AppStorage("CrabProxyMacApp.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage("CrabProxyMacApp.currentScreen") private var currentScreenRawValue = "traffic"
    @AppStorage("CrabProxyMacApp.settingsTab") private var settingsTabRawValue = "General"
    @State private var didInitializeLaunchState = false
    @State private var didHandleAppTermination = false

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var throttleToggleBinding: Binding<Bool> {
        Binding(
            get: { model.throttleEnabled },
            set: { enabled in
                model.throttleEnabled = enabled
            }
        )
    }

    var body: some Scene {
        Window("Crab Proxy", id: "main") {
            ContentView(
                model: model,
                appearanceModeRawValue: $appearanceModeRawValue
            )
                .onAppear {
                    initializeLaunchStateIfNeeded()
                    applyAppAppearance()
                }
                .onChange(of: appearanceModeRawValue) { _, _ in
                    applyAppAppearance()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    handleAppWillTerminate()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Button(model.isCaptureEnabled ? "Stop Capture" : "Start Capture") {
                    if model.isCaptureEnabled {
                        model.stopCapture()
                    } else {
                        model.startCapture()
                    }
                }

                Toggle("Enable Throttle", isOn: throttleToggleBinding)

                Divider()

                Button("Open Crab Proxy") {
                    openMainWindow()
                }

                Button("Open Settings") {
                    openSettings()
                    openMainWindow()
                }

                Divider()

                Button("Quit Crab Proxy") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 220, alignment: .leading)
        } label: {
            Image(nsImage: CrabStatusBarIcon.templateImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: 19, height: 19)
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

    @MainActor
    private func initializeLaunchStateIfNeeded() {
        guard !didInitializeLaunchState else { return }
        didInitializeLaunchState = true
        settingsTabRawValue = "General"
        currentScreenRawValue = "traffic"
        model.clearLogs(showStatus: false)
        model.ensureProxyRuntimeReadyInBypassMode()
    }

    @MainActor
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private func handleAppWillTerminate() {
        guard !didHandleAppTermination else { return }
        didHandleAppTermination = true
        model.shutdownForAppTermination()
    }
}

private enum CrabStatusBarIcon {
    static let templateImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawCrab()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func drawCrab() {
        NSColor.black.setStroke()

        // Outer claw shell (top and bottom) with open mouth on right side.
        let outer = NSBezierPath()
        outer.lineWidth = 1.35
        outer.lineJoinStyle = .round
        outer.lineCapStyle = .round
        outer.move(to: NSPoint(x: 2.8, y: 5.9))
        outer.curve(
            to: NSPoint(x: 15.9, y: 13.2),
            controlPoint1: NSPoint(x: 3.3, y: 12.1),
            controlPoint2: NSPoint(x: 11.9, y: 15.9)
        )
        outer.curve(
            to: NSPoint(x: 14.2, y: 10.8),
            controlPoint1: NSPoint(x: 16.8, y: 12.6),
            controlPoint2: NSPoint(x: 15.5, y: 11.6)
        )
        outer.move(to: NSPoint(x: 15.0, y: 7.0))
        outer.curve(
            to: NSPoint(x: 2.8, y: 5.9),
            controlPoint1: NSPoint(x: 12.3, y: 1.9),
            controlPoint2: NSPoint(x: 5.5, y: 2.3)
        )
        outer.stroke()

        let leftBulge = NSBezierPath()
        leftBulge.lineWidth = 1.35
        leftBulge.lineCapStyle = .round
        leftBulge.appendArc(
            withCenter: NSPoint(x: 2.9, y: 5.6),
            radius: 1.1,
            startAngle: 92,
            endAngle: 330,
            clockwise: true
        )
        leftBulge.stroke()

        // Inner pincer with teeth-like contour.
        let inner = NSBezierPath()
        inner.lineWidth = 1.2
        inner.lineJoinStyle = .round
        inner.lineCapStyle = .round
        inner.move(to: NSPoint(x: 8.8, y: 8.8))
        inner.curve(
            to: NSPoint(x: 13.8, y: 9.9),
            controlPoint1: NSPoint(x: 10.2, y: 10.1),
            controlPoint2: NSPoint(x: 12.2, y: 10.2)
        )
        inner.line(to: NSPoint(x: 13.0, y: 9.1))
        inner.line(to: NSPoint(x: 12.3, y: 8.8))
        inner.line(to: NSPoint(x: 11.7, y: 8.4))
        inner.line(to: NSPoint(x: 11.0, y: 8.7))
        inner.line(to: NSPoint(x: 10.4, y: 8.2))
        inner.line(to: NSPoint(x: 9.8, y: 8.5))
        inner.line(to: NSPoint(x: 9.1, y: 8.0))
        inner.line(to: NSPoint(x: 8.8, y: 7.5))
        inner.stroke()

        let hook = NSBezierPath()
        hook.lineWidth = 1.2
        hook.lineCapStyle = .round
        hook.move(to: NSPoint(x: 9.0, y: 7.7))
        hook.curve(
            to: NSPoint(x: 9.3, y: 5.7),
            controlPoint1: NSPoint(x: 8.7, y: 7.0),
            controlPoint2: NSPoint(x: 8.9, y: 6.2)
        )
        hook.stroke()
    }
}
