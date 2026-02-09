import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ProxyViewModel
    @Binding var appearanceModeRawValue: String
    @AppStorage("CrabProxyMacApp.currentScreen") private var currentScreenRawValue = MainScreen.traffic.rawValue
    @AppStorage("CrabProxyMacApp.settingsTab") private var settingsTabRawValue = "General"
    @State private var animateBackground = false
    @State private var detailTab: DetailTab = .summary
    @State private var isTrafficListAtTop = true
    @Environment(\.colorScheme) private var colorScheme
    private let trafficTopAnchorID = "traffic-list-top-anchor"

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: animateBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                controlPanel
                displayedContent
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
            model.refreshMacSystemProxyStatus()
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animateBackground = true
            }
        }
        .background(
            WindowAccessor { window in
                configureMainWindowAppearance(window)
            }
        )
        .animation(.easeInOut(duration: 0.2), value: currentScreenRawValue)
        .tint(primaryTint)
    }

    private var primaryTint: Color {
        CrabTheme.primaryTint(for: colorScheme)
    }

    private var secondaryTint: Color {
        CrabTheme.secondaryTint(for: colorScheme)
    }

    private var destructiveTint: Color {
        CrabTheme.destructiveTint(for: colorScheme)
    }

    private var panelFill: Color {
        CrabTheme.panelFill(for: colorScheme)
    }

    private var panelStroke: Color {
        CrabTheme.panelStroke(for: colorScheme)
    }

    private var primaryText: Color {
        CrabTheme.primaryText(for: colorScheme)
    }

    private var secondaryText: Color {
        CrabTheme.secondaryText(for: colorScheme)
    }

    private var currentScreen: MainScreen {
        MainScreen(rawValue: currentScreenRawValue) ?? .traffic
    }

    private var displayedTrafficLogs: [ProxyLogEntry] {
        Array(model.filteredLogs.reversed())
    }

    @ViewBuilder
    private var displayedContent: some View {
        switch currentScreen {
        case .traffic:
            trafficSplitView
        case .settings:
            SettingsView(
                model: model,
                appearanceModeRawValue: $appearanceModeRawValue
            )
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Toggle(isOn: $model.inspectBodies) {
                    Text("Inspect Bodies")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .foregroundStyle(primaryText)
                }
                .toggleStyle(.switch)
                .frame(width: 150)

                Toggle(isOn: macProxyToggleBinding) {
                    Text("macOS Proxy")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .foregroundStyle(primaryText)
                }
                .toggleStyle(.switch)
                .frame(width: 150)
                .disabled(model.isApplyingMacSystemProxy || model.macSystemProxyStateText == "Unavailable")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let nextScreen: MainScreen = (currentScreen == .traffic) ? .settings : .traffic
                        currentScreenRawValue = nextScreen.rawValue
                    }
                } label: {
                    Image(systemName: currentScreen == .traffic ? "gearshape.fill" : "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(CrabTheme.softFill(for: colorScheme))
                                .overlay(
                                    Circle().stroke(panelStroke, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(currentScreen == .traffic ? "Open Settings" : "Back to Traffic")
                .help(currentScreen == .traffic ? "Open Settings" : "Back to Traffic")

                Spacer()

                ActionButton(
                    title: "Start",
                    icon: "play.fill",
                    tint: primaryTint
                ) {
                    model.startProxy()
                }
                .disabled(model.isRunning)

                ActionButton(
                    title: "Stop",
                    icon: "stop.fill",
                    tint: destructiveTint
                ) {
                    model.stopProxy()
                }
                .disabled(!model.isRunning)

                StatusBadge(isRunning: model.isRunning, text: model.statusText)
            }
        }
        .padding(16)
        .background(GlassCard())
    }

    private var macProxyToggleBinding: Binding<Bool> {
        Binding(
            get: { model.macSystemProxyEnabled },
            set: { enabled in
                if enabled {
                    model.enableMacSystemProxy()
                } else {
                    model.disableMacSystemProxy()
                }
            }
        )
    }

    private func configureMainWindowAppearance(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbar = nil
    }

    private var trafficSplitView: some View {
        HSplitView {
            transactionsPanel
                .frame(minWidth: 420, idealWidth: 620, maxWidth: 760, maxHeight: .infinity)
                .layoutPriority(1)
            detailsPanel
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(panelFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(panelStroke, lineWidth: 1)
                )
        )
    }

    private var transactionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Traffic")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(primaryText)
                Spacer()
                ActionButton(
                    title: "Clear",
                    icon: "trash.fill",
                    tint: secondaryTint
                ) {
                    model.clearLogs()
                }
                Text("\(model.filteredLogs.count)")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(CrabTheme.softFill(for: colorScheme)))
            }

            LabeledField(
                title: "Filter",
                placeholder: "Show only traffic URLs containing...",
                text: $model.visibleURLFilter
            )

            ScrollViewReader { scrollProxy in
                ZStack(alignment: .bottomTrailing) {
                    List(selection: $model.selectedLogID) {
                        TrafficListTopMarker(isAtTop: $isTrafficListAtTop)
                            .id(trafficTopAnchorID)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        ForEach(displayedTrafficLogs) { entry in
                            TransactionRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Add to Map Local") {
                                        model.stageMapLocalRule(from: entry)
                                        settingsTabRawValue = "Rules"
                                        currentScreenRawValue = MainScreen.settings.rawValue
                                    }
                                }
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isTrafficListAtTop && !displayedTrafficLogs.isEmpty {
                        ScrollToLatestButton {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                scrollProxy.scrollTo(trafficTopAnchorID, anchor: .top)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isTrafficListAtTop)
                .overlay {
                    if displayedTrafficLogs.isEmpty {
                        Text("No matching requests")
                            .font(.custom("Avenir Next Medium", size: 14))
                            .foregroundStyle(secondaryText)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detail")
                .font(.custom("Avenir Next Demi Bold", size: 18))
                .foregroundStyle(primaryText)

            if let entry = model.selectedLog {
                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    detailContent(for: entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text("Select a request from the left panel")
                    .font(.custom("Avenir Next Medium", size: 14))
                    .foregroundStyle(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func detailContent(for entry: ProxyLogEntry) -> some View {
        switch detailTab {
        case .summary:
            summaryDetail(entry)
        case .headers:
            headersDetail(entry)
        case .body:
            bodyDetail(entry)
        }
    }

    private func summaryDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MethodBadge(method: entry.method)
                ValuePill(text: entry.statusCode ?? "--", tint: secondaryTint)
                ValuePill(text: entry.event, tint: primaryTint)
                if entry.event == "tunnel" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryTint)
                        .help("Encrypted tunnel (not decrypted)")
                }
                Spacer()
                Text(formatLogTimeWithSeconds(entry.timestamp))
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(secondaryText)
            }

            DetailLine(title: "URL", value: entry.url)
            if let peer = entry.peer {
                DetailLine(title: "Peer", value: peer)
            }
            if let matcher = entry.mapLocalMatcher {
                DetailLine(title: "Map Local", value: matcher)
            }
            DetailLine(title: "Level", value: entry.levelLabel)

            Text("Raw Log")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.86))
                .padding(.top, 4)

            CodeBlock(
                text: formattedRawLog(entry.rawLine),
                placeholder: "No raw log",
                copyButtonLabel: "Copy Raw Log"
            )
        }
    }

    private func headersDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            HeaderBlock(
                text: entry.requestHeaders,
                placeholder: "No captured request headers"
            )

            Text("Response Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            HeaderBlock(
                text: entry.responseHeaders,
                placeholder: "No captured response headers"
            )
        }
    }

    private func bodyDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Body")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            BodyBlock(
                text: entry.requestBodyPreview,
                placeholder: "No captured request body preview"
            )

            Text("Response Body")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            BodyBlock(
                text: entry.responseBodyPreview,
                placeholder: "No captured response body preview"
            )
        }
    }

    private func formattedRawLog(_ rawLine: String) -> String {
        guard let marker = rawLine.range(of: "CRAB_JSON ") else {
            return rawLine
        }

        let prefix = rawLine[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = rawLine[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsonText.isEmpty, let data = jsonText.data(using: .utf8) else {
            return rawLine
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return rawLine
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            return rawLine
        }
        guard
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyJSON = String(data: prettyData, encoding: .utf8)
        else {
            return rawLine
        }

        if prefix.isEmpty {
            return "CRAB_JSON\n\(prettyJSON)"
        }
        return "\(prefix)\nCRAB_JSON\n\(prettyJSON)"
    }
}

private enum MainScreen: String {
    case traffic
    case settings
}

private struct TrafficListTopMarker: View {
    @Binding var isAtTop: Bool

    var body: some View {
        Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .onAppear {
                DispatchQueue.main.async {
                    isAtTop = true
                }
            }
            .onDisappear {
                DispatchQueue.main.async {
                    isAtTop = false
                }
            }
    }
}

private struct ScrollToLatestButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 11, weight: .bold))
                Text("Top")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
            }
            .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(CrabTheme.softFill(for: colorScheme))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Scroll to latest traffic")
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case headers = "Headers"
    case body = "Body"

    var id: String { rawValue }
}

private struct TransactionRow: View {
    let entry: ProxyLogEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                MethodBadge(method: entry.method)
                Text(entry.statusCode ?? "--")
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(CrabTheme.secondaryTint(for: colorScheme))
                Text(entry.event)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                if entry.event == "tunnel" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CrabTheme.secondaryTint(for: colorScheme))
                        .help("Encrypted tunnel (not decrypted)")
                }
                Spacer()
                Text(formatLogTimeWithSeconds(entry.timestamp))
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme).opacity(0.8))
            }

            Text(entry.url)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme).opacity(0.92))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private let logTimeWithSecondsFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func formatLogTimeWithSeconds(_ date: Date) -> String {
    logTimeWithSecondsFormatter.string(from: date)
}
