import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case rules = "Rules"
    case device = "Mobile"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var model: ProxyViewModel
    @Binding var appearanceModeRawValue: String
    @AppStorage("CrabProxyMacApp.settingsTab") private var selectedTabRawValue = SettingsTab.general.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var selectedTab: SettingsTab {
        SettingsTab(rawValue: selectedTabRawValue) ?? .general
    }

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Spacer()

                Picker("Settings Tab", selection: selectedTabBinding) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(appearanceModeRawValue: $appearanceModeRawValue)
                case .rules:
                    RulesSettingsView(model: model)
                case .device:
                    DeviceSetupView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CrabTheme.panelFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                )
        )
        .tint(CrabTheme.primaryTint(for: colorScheme))
    }
}

struct GeneralSettingsView: View {
    @Binding var appearanceModeRawValue: String
    @Environment(\.colorScheme) private var colorScheme

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding<AppAppearanceMode>(
            get: { AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system },
            set: { appearanceModeRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("General")
                    .font(.custom("Avenir Next Demi Bold", size: 24))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                ThemeModeRow(selection: appearanceModeBinding)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ThemeModeRow: View {
    @Binding var selection: AppAppearanceMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Use light, dark, or match your system")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(AppAppearanceMode.uiOrder, id: \.id) { mode in
                    ThemeModeChip(
                        mode: mode,
                        isSelected: selection == mode
                    ) {
                        selection = mode
                    }
                }
            }
            .padding(4)
            .background(
                Capsule(style: .continuous)
                    .fill(CrabTheme.themePickerTrayFill(for: colorScheme))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(CrabTheme.inputStroke(for: colorScheme), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CrabTheme.themeCardFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CrabTheme.panelStroke(for: colorScheme), lineWidth: 1)
                )
        )
    }
}

private struct ThemeModeChip: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14, weight: .medium))
                Text(mode.title)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
            }
            .foregroundStyle(
                isSelected
                    ? CrabTheme.themeChipSelectedText(for: colorScheme)
                    : CrabTheme.secondaryText(for: colorScheme)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? CrabTheme.themeChipSelectedFill(for: colorScheme)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct RulesSettingsView: View {
    @ObservedObject var model: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rules Settings")
                    .font(.custom("Avenir Next Demi Bold", size: 24))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Allowlist / Map Local / Status Rewrite rules are applied when you press Start.")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                allowListSection
                mapLocalSection
                statusRewriteSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mobile Setup")
                    .font(.custom("Avenir Next Demi Bold", size: 24))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Use this page for mobile proxy IP and certificate portal.")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                proxySection
                certPortalSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
