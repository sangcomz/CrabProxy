import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ProxyViewModel
    @State private var animateBackground = false
    @State private var detailTab: DetailTab = .summary
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: animateBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                controlPanel
                trafficSplitView
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
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape.fill")
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
                .accessibilityLabel("Open Settings")
                .help("Open Settings")

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

            List(selection: $model.selectedLogID) {
                ForEach(model.filteredLogs) { entry in
                    TransactionRow(entry: entry)
                        .tag(entry.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.filteredLogs.isEmpty {
                    Text("No matching requests")
                        .font(.custom("Avenir Next Medium", size: 14))
                        .foregroundStyle(secondaryText)
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

            CodeBlock(text: entry.rawLine, placeholder: "No raw log")
        }
    }

    private func headersDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            CodeBlock(
                text: entry.requestHeaders,
                placeholder: "No captured request headers"
            )

            Text("Response Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            CodeBlock(
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
            CodeBlock(
                text: entry.requestBodyPreview,
                placeholder: "No captured request body preview"
            )

            Text("Response Body")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(primaryText.opacity(0.9))
            CodeBlock(
                text: entry.responseBodyPreview,
                placeholder: "No captured response body preview"
            )
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ProxyViewModel
    @Binding var appearanceModeRawValue: String
    @Environment(\.colorScheme) private var colorScheme

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding<AppAppearanceMode>(
            get: { AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system },
            set: { appearanceModeRawValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("Appearance")
                    .font(.custom("Avenir Next Demi Bold", size: 14))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Picker("Appearance", selection: appearanceModeBinding) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()
            }
            .padding(14)
            .background(GlassCard())

            TabView {
                RulesSettingsView(model: model)
                    .tabItem {
                        Label("Rules", systemImage: "slider.horizontal.3")
                    }

                DeviceSetupView(model: model)
                    .tabItem {
                        Label("Device", systemImage: "iphone.and.arrow.forward")
                    }
            }
        }
        .tint(CrabTheme.primaryTint(for: colorScheme))
        .padding(16)
        .frame(minWidth: 1080, minHeight: 700)
    }
}

struct RulesSettingsView: View {
    @ObservedObject var model: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: true)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rules Settings")
                        .font(.custom("Avenir Next Demi Bold", size: 28))
                        .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                    Text("Allowlist / Map Local / Status Rewrite rules are applied when you press Start.")
                        .font(.custom("Avenir Next Medium", size: 13))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                    allowListSection
                    mapLocalSection
                    statusRewriteSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    private var allowListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Allowlist")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Button("Add Rule") {
                    model.addAllowRule()
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            Text("Examples: *.* (all), naver.com, api.naver.com/v1, /graphql")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

            if model.allowRules.isEmpty {
                EmptyRuleHint(text: "No allowlist rule. Empty means allow all traffic.")
            } else {
                ForEach($model.allowRules) { $rule in
                    HStack(spacing: 8) {
                        TextField("Allowed URL pattern", text: $rule.matcher)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            model.removeAllowRule(rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CrabTheme.ruleCardFill(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                            )
                    )
                }
            }
        }
        .padding(14)
        .background(GlassCard())
    }

    private var mapLocalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Map Local")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Button("Add Rule") {
                    model.addMapLocalRule()
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if model.mapLocalRules.isEmpty {
                EmptyRuleHint(text: "No map-local rule yet")
            } else {
                ForEach($model.mapLocalRules) { $rule in
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Match URL prefix", text: $rule.matcher)
                                .textFieldStyle(.roundedBorder)
                            Picker("Source", selection: $rule.sourceType) {
                                ForEach(RuleSourceType.allCases) { source in
                                    Text(source.rawValue).tag(source)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 130)
                            TextField("Status", text: $rule.statusCode)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Button {
                                model.removeMapLocalRule(rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }

                        TextField(
                            rule.sourceType == .file ? "Local file path" : "Inline text body",
                            text: $rule.sourceValue
                        )
                        .textFieldStyle(.roundedBorder)

                        TextField("Content-Type (optional)", text: $rule.contentType)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CrabTheme.ruleCardFill(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                            )
                    )
                }
            }
        }
        .padding(14)
        .background(GlassCard())
    }

    private var statusRewriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status Rewrite")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Button("Add Rule") {
                    model.addStatusRewriteRule()
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if model.statusRewriteRules.isEmpty {
                EmptyRuleHint(text: "No status-rewrite rule yet")
            } else {
                ForEach($model.statusRewriteRules) { $rule in
                    HStack(spacing: 8) {
                        TextField("Match URL prefix", text: $rule.matcher)
                            .textFieldStyle(.roundedBorder)
                        TextField("From (optional)", text: $rule.fromStatusCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Text("→")
                            .foregroundStyle(CrabTheme.primaryText(for: colorScheme).opacity(0.85))
                        TextField("To", text: $rule.toStatusCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Button {
                            model.removeStatusRewriteRule(rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CrabTheme.ruleCardFill(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                            )
                    )
                }
            }
        }
        .padding(14)
        .background(GlassCard())
    }
}

struct DeviceSetupView: View {
    @ObservedObject var model: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: true)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Device Setup")
                        .font(.custom("Avenir Next Demi Bold", size: 28))
                        .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                    Text("Use this page for mobile proxy IP and certificate portal.")
                        .font(.custom("Avenir Next Medium", size: 13))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                    proxySection
                    certPortalSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phone Proxy Address")
                .font(.custom("Avenir Next Demi Bold", size: 18))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

            Text("Set this as proxy server on iOS/Android.")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

            if let endpoint = model.mobileProxyEndpoint {
                CopyValueRow(title: "Use on iOS/Android", value: endpoint)
            } else {
                Text("No LAN IPv4 found. Check Wi-Fi/LAN connection.")
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }
        }
        .padding(14)
        .background(GlassCard())
    }

    private var certPortalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Certificate Portal")
                .font(.custom("Avenir Next Demi Bold", size: 18))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

            Text("Open this URL from phone browser after proxy is configured.")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

            CopyValueRow(title: "Portal", value: model.certPortalURL)
        }
        .padding(14)
        .background(GlassCard())
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

private struct CodeBlock: View {
    let text: String?
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    private var renderedText: String {
        guard let text, !text.isEmpty else { return placeholder }
        return text
    }

    private var hasContent: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(renderedText)
                .textSelection(.enabled)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(
                    hasContent
                        ? CrabTheme.primaryText(for: colorScheme).opacity(0.92)
                        : CrabTheme.secondaryText(for: colorScheme)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CrabTheme.inputFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                )
        )
    }
}

private struct CopyValueRow: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CrabTheme.inputFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                )
        )
    }
}

private struct MethodBadge: View {
    let method: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(method)
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(methodTint)
            )
    }

    private var methodTint: Color {
        switch method {
        case "GET":
            return CrabTheme.secondaryTint(for: colorScheme)
        case "POST":
            return CrabTheme.primaryTint(for: colorScheme)
        case "PUT", "PATCH":
            return CrabTheme.warningTint(for: colorScheme)
        case "DELETE":
            return CrabTheme.destructiveTint(for: colorScheme)
        default:
            return CrabTheme.neutralTint(for: colorScheme)
        }
    }
}

private struct ValuePill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.85))
            )
    }
}

private struct DetailLine: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
        }
    }
}

private struct EmptyRuleHint: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Medium", size: 13))
            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

private struct ProxyBackground: View {
    let animateBackground: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: CrabTheme.backgroundGradient(for: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(CrabTheme.primaryTint(for: colorScheme).opacity(colorScheme == .light ? 0.24 : 0.23))
                .frame(width: 420, height: 420)
                .blur(radius: 40)
                .offset(x: animateBackground ? 220 : 130, y: -180)

            Circle()
                .fill(CrabTheme.secondaryTint(for: colorScheme).opacity(colorScheme == .light ? 0.2 : 0.18))
                .frame(width: 500, height: 500)
                .blur(radius: 48)
                .offset(x: animateBackground ? -280 : -120, y: 250)
        }
    }
}

private struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .frame(width: 52, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.custom("Avenir Next Medium", size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CrabTheme.inputFill(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                        )
                )
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct StatusBadge: View {
    let isRunning: Bool
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.gray.opacity(0.6))
                .frame(width: 8, height: 8)
                .shadow(color: isRunning ? Color.green.opacity(0.7) : .clear, radius: 8)
            Text(text)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(CrabTheme.softFill(for: colorScheme)))
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

private struct GlassCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(CrabTheme.glassFill(for: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
            )
    }
}

private enum CrabTheme {
    static func primaryTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.93, green: 0.39, blue: 0.12)
        case .dark:
            return Color(red: 0.14, green: 0.82, blue: 0.52)
        @unknown default:
            return Color(red: 0.93, green: 0.39, blue: 0.12)
        }
    }

    static func secondaryTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color(red: 0.98, green: 0.66, blue: 0.25)
        case .dark:
            return Color(red: 0.34, green: 0.58, blue: 0.94)
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

private let logTimeWithSecondsFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func formatLogTimeWithSeconds(_ date: Date) -> String {
    logTimeWithSecondsFormatter.string(from: date)
}
