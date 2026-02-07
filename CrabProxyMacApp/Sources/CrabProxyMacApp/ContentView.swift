import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ProxyViewModel
    @State private var animateBackground = false
    @State private var detailTab: DetailTab = .summary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: animateBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                header
                controlPanel
                trafficSplitView
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
            model.refreshMacSystemProxyStatus()
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animateBackground = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Crab Proxy Studio")
                    .font(.custom("Avenir Next Demi Bold", size: 34))
                    .foregroundStyle(.white)
                Text("Charles-style traffic inspector with Rust MITM core")
                    .font(.custom("Avenir Next", size: 14))
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Spacer()

            HStack(spacing: 10) {
                StatusBadge(isRunning: model.isRunning, text: model.statusText)
                IconActionButton(icon: "gearshape.fill", accessibilityLabel: "Open Settings") {
                    openWindow(id: "settings")
                }
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle(isOn: $model.inspectBodies) {
                    Text("Inspect Bodies")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .toggleStyle(.switch)
                .frame(width: 150)
                Spacer()
            }

            HStack(spacing: 10) {
                LabeledField(
                    title: "Filter",
                    placeholder: "Show only URLs containing...",
                    text: $model.visibleURLFilter
                )

                ActionButton(
                    title: "Start",
                    icon: "play.fill",
                    tint: Color(red: 0.14, green: 0.82, blue: 0.52)
                ) {
                    model.startProxy()
                }
                .disabled(model.isRunning)

                ActionButton(
                    title: "Stop",
                    icon: "stop.fill",
                    tint: Color(red: 0.93, green: 0.34, blue: 0.33)
                ) {
                    model.stopProxy()
                }
                .disabled(!model.isRunning)

                ActionButton(
                    title: "Clear",
                    icon: "trash.fill",
                    tint: Color(red: 0.34, green: 0.58, blue: 0.94)
                ) {
                    model.clearLogs()
                }
            }

            macSystemProxyQuickRow
        }
        .padding(16)
        .background(GlassCard())
    }

    private var macSystemProxyQuickRow: some View {
        HStack(spacing: 10) {
            Text("macOS Proxy")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.86))

            Text(model.macSystemProxyStateText)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)

            Text("(\(model.macSystemProxyServiceText))")
                .font(.custom("Avenir Next Medium", size: 11))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)

            Spacer()

            ActionButton(
                title: "Proxy On",
                icon: "network",
                tint: Color(red: 0.14, green: 0.82, blue: 0.52)
            ) {
                model.enableMacSystemProxy()
            }
            .disabled(model.isApplyingMacSystemProxy || model.macSystemProxyEnabled)

            ActionButton(
                title: "Proxy Off",
                icon: "xmark.circle.fill",
                tint: Color(red: 0.93, green: 0.34, blue: 0.33)
            ) {
                model.disableMacSystemProxy()
            }
            .disabled(model.isApplyingMacSystemProxy || !model.macSystemProxyEnabled)

            IconActionButton(icon: "arrow.clockwise", accessibilityLabel: "Refresh macOS proxy status") {
                model.refreshMacSystemProxyStatus()
            }
        }
    }

    private var trafficSplitView: some View {
        HSplitView {
            transactionsPanel
                .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)
            detailsPanel
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var transactionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Traffic")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(model.filteredLogs.count)")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.15)))
            }

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
            .overlay {
                if model.filteredLogs.isEmpty {
                    Text("No matching requests")
                        .font(.custom("Avenir Next Medium", size: 14))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
        .padding(14)
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detail")
                .font(.custom("Avenir Next Demi Bold", size: 18))
                .foregroundStyle(.white)

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
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
            }
        }
        .padding(14)
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
                ValuePill(text: entry.statusCode ?? "--", tint: Color(red: 0.34, green: 0.58, blue: 0.94))
                ValuePill(text: entry.event, tint: Color(red: 0.14, green: 0.82, blue: 0.52))
                Spacer()
                Text(formatLogTimeWithSeconds(entry.timestamp))
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(Color.white.opacity(0.65))
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
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.top, 4)

            CodeBlock(text: entry.rawLine, placeholder: "No raw log")
        }
    }

    private func headersDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
            CodeBlock(
                text: entry.requestHeaders,
                placeholder: "No captured request headers"
            )

            Text("Response Headers")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
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
                .foregroundStyle(Color.white.opacity(0.85))
            CodeBlock(
                text: entry.requestBodyPreview,
                placeholder: "No captured request body preview"
            )

            Text("Response Body")
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
            CodeBlock(
                text: entry.responseBodyPreview,
                placeholder: "No captured response body preview"
            )
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: ProxyViewModel

    var body: some View {
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
        .frame(minWidth: 1080, minHeight: 700)
    }
}

struct RulesSettingsView: View {
    @ObservedObject var model: ProxyViewModel

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: true)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rules Settings")
                        .font(.custom("Avenir Next Demi Bold", size: 28))
                        .foregroundStyle(.white)

                    Text("Allowlist / Map Local / Status Rewrite rules are applied when you press Start.")
                        .font(.custom("Avenir Next Medium", size: 13))
                        .foregroundStyle(Color.white.opacity(0.72))

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
                    .foregroundStyle(.white)
                Spacer()
                Button("Add Rule") {
                    model.addAllowRule()
                }
            }

            Text("Examples: *.* (all), naver.com, api.naver.com/v1, /graphql")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(Color.white.opacity(0.68))

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
                            .fill(Color.black.opacity(0.23))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                    .foregroundStyle(.white)
                Spacer()
                Button("Add Rule") {
                    model.addMapLocalRule()
                }
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
                            .fill(Color.black.opacity(0.23))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                    .foregroundStyle(.white)
                Spacer()
                Button("Add Rule") {
                    model.addStatusRewriteRule()
                }
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
                            .foregroundStyle(Color.white.opacity(0.8))
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
                            .fill(Color.black.opacity(0.23))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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

    var body: some View {
        ZStack {
            ProxyBackground(animateBackground: true)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Device Setup")
                        .font(.custom("Avenir Next Demi Bold", size: 28))
                        .foregroundStyle(.white)

                    Text("Use this page for mobile proxy IP and certificate portal.")
                        .font(.custom("Avenir Next Medium", size: 13))
                        .foregroundStyle(Color.white.opacity(0.74))

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
                .foregroundStyle(.white)

            Text("Set this as proxy server on iOS/Android.")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(Color.white.opacity(0.76))

            if let endpoint = model.mobileProxyEndpoint {
                CopyValueRow(title: "Use on iOS/Android", value: endpoint)
            } else {
                Text("No LAN IPv4 found. Check Wi-Fi/LAN connection.")
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(14)
        .background(GlassCard())
    }

    private var certPortalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Certificate Portal")
                .font(.custom("Avenir Next Demi Bold", size: 18))
                .foregroundStyle(.white)

            Text("Open this URL from phone browser after proxy is configured.")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(Color.white.opacity(0.76))

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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                MethodBadge(method: entry.method)
                Text(entry.statusCode ?? "--")
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(Color(red: 0.68, green: 0.89, blue: 1.0))
                Text(entry.event)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text(formatLogTimeWithSeconds(entry.timestamp))
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Text(entry.url)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct CodeBlock: View {
    let text: String?
    let placeholder: String

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
                        ? Color(red: 0.88, green: 0.93, blue: 0.96)
                        : Color.white.opacity(0.5)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.27))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private struct CopyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.custom("Avenir Next Demi Bold", size: 11))
            .foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                )
        )
    }
}

private struct MethodBadge: View {
    let method: String

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
            return Color(red: 0.17, green: 0.64, blue: 0.93)
        case "POST":
            return Color(red: 0.16, green: 0.75, blue: 0.54)
        case "PUT", "PATCH":
            return Color(red: 0.94, green: 0.58, blue: 0.2)
        case "DELETE":
            return Color(red: 0.9, green: 0.33, blue: 0.32)
        default:
            return Color(red: 0.52, green: 0.56, blue: 0.63)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.custom("Menlo", size: 11))
                .foregroundStyle(Color.white.opacity(0.9))
                .textSelection(.enabled)
        }
    }
}

private struct EmptyRuleHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Medium", size: 13))
            .foregroundStyle(Color.white.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

private struct ProxyBackground: View {
    let animateBackground: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.09, blue: 0.16),
                    Color(red: 0.05, green: 0.18, blue: 0.21),
                    Color(red: 0.06, green: 0.16, blue: 0.11),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.14, green: 0.82, blue: 0.52).opacity(0.23))
                .frame(width: 420, height: 420)
                .blur(radius: 40)
                .offset(x: animateBackground ? 220 : 130, y: -180)

            Circle()
                .fill(Color(red: 0.34, green: 0.58, blue: 0.94).opacity(0.2))
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

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 52, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.custom("Avenir Next Medium", size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
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

private struct IconActionButton: View {
    let icon: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct StatusBadge: View {
    let isRunning: Bool
    let text: String

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
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.12)))
    }
}

private struct GlassCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
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
