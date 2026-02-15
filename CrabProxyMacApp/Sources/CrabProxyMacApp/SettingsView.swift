import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case rules = "Rules"
    case device = "Mobile"
    case advanced = "Advanced"

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
                .frame(width: 460)
            }

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(model: model, appearanceModeRawValue: $appearanceModeRawValue)
                case .advanced:
                    AdvancedSettingsView(model: model)
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
    @ObservedObject var model: ProxyViewModel
    @Binding var appearanceModeRawValue: String
    @Environment(\.colorScheme) private var colorScheme

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !version.isEmpty && !build.isEmpty:
            return version == build ? version : "\(version) (\(build))"
        case let (.some(version), _):
            return version.isEmpty ? "Unknown" : version
        case let (_, .some(build)):
            return build.isEmpty ? "Unknown" : build
        default:
            return "Unknown"
        }
    }

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

                CACertRow(model: model)
                ThemeModeRow(selection: appearanceModeBinding)
                AppVersionRow(version: appVersionText)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AppVersionRow: View {
    let version: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Version")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Installed app version")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }

            Spacer(minLength: 12)

            Text(version)
                .font(.custom("Menlo", size: 13))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
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

private struct CACertRow: View {
    @ObservedObject var model: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CA Certificate")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text(model.caCertInstalledInKeychain
                     ? "Trusted in System Keychain"
                     : "Not installed. HTTPS inspection requires a trusted CA.")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }

            Spacer(minLength: 12)

            if model.caCertInstalledInKeychain {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))
                    Text("Trusted")
                        .font(.custom("Avenir Next Demi Bold", size: 13))
                        .foregroundStyle(CrabTheme.primaryTint(for: colorScheme))

                    Button("Remove") {
                        model.removeCACertFromKeychain()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstallingCACert)
                }
            } else {
                Button {
                    model.installCACertToKeychain()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("Install & Trust")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstallingCACert || model.caCertPath.isEmpty)
            }
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
        .onAppear {
            model.refreshCACertKeychainStatus()
        }
    }
}

private struct AdvancedSettingsView: View {
    @ObservedObject var model: ProxyViewModel
    @State private var showTransparentProxy = false
    @Environment(\.colorScheme) private var colorScheme

    private var transparentProxyBinding: Binding<Bool> {
        Binding(
            get: { model.transparentProxyEnabled },
            set: { enabled in
                if enabled {
                    model.enableTransparentProxy()
                } else {
                    model.disableTransparentProxy()
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Advanced")
                    .font(.custom("Avenir Next Demi Bold", size: 24))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                InspectBodiesAdvancedRow(isInspectBodiesEnabled: $model.inspectBodies)

                TransparentProxyAdvancedRow(
                    isExpanded: $showTransparentProxy,
                    isTransparentEnabled: transparentProxyBinding,
                    isApplyingTransparentProxy: model.isApplyingTransparentProxy,
                    transparentStateText: model.transparentProxyStateText
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InspectBodiesAdvancedRow: View {
    @Binding var isInspectBodiesEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Inspect Bodies")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Capture request and response body previews for debugging. Default is ON.")
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isInspectBodiesEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
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

private struct TransparentProxyAdvancedRow: View {
    @Binding var isExpanded: Bool
    @Binding var isTransparentEnabled: Bool
    let isApplyingTransparentProxy: Bool
    let transparentStateText: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transparent Proxy")
                            .font(.custom("Avenir Next Demi Bold", size: 20))
                            .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                        Text("Capture traffic from clients that do not use manual proxy settings.")
                            .font(.custom("Avenir Next Medium", size: 12))
                            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle Transparent Proxy Details")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $isTransparentEnabled) {
                        Text("Enable Transparent Proxy")
                            .font(.custom("Avenir Next Demi Bold", size: 13))
                            .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                    }
                    .toggleStyle(.switch)
                    .disabled(isApplyingTransparentProxy)

                    HStack(spacing: 8) {
                        Text("Status")
                            .font(.custom("Avenir Next Demi Bold", size: 11))
                            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                        Text(transparentStateText)
                            .font(.custom("Menlo", size: 11))
                            .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                    }

                    Text("For apps/devices that ignore manual proxy settings. Uses pf and requires admin authentication.")
                        .font(.custom("Avenir Next Medium", size: 12))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                }
                .padding(.top, 12)
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
    private struct MapLocalEditorState: Identifiable {
        let id = UUID()
        let editingRuleID: UUID?
    }

    private struct StatusRewriteEditorState: Identifiable {
        let id = UUID()
        let editingRuleID: UUID?
    }

    @ObservedObject var model: ProxyViewModel
    @State private var draftAllowRules: [AllowRuleInput] = []
    @State private var draftMapLocalRules: [MapLocalRuleInput] = []
    @State private var draftStatusRewriteRules: [StatusRewriteRuleInput] = []
    @State private var mapLocalEditorState: MapLocalEditorState?
    @State private var statusRewriteEditorState: StatusRewriteEditorState?
    @State private var didInitializeDrafts = false
    @Environment(\.colorScheme) private var colorScheme

    private var hasUnsavedChanges: Bool {
        draftAllowRules != model.allowRules
            || draftMapLocalRules != model.mapLocalRules
            || draftStatusRewriteRules != model.statusRewriteRules
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rules Settings")
                    .font(.custom("Avenir Next Demi Bold", size: 24))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))

                Text("Allowlist / Map Local / Status Rewrite rules are applied immediately when you press Save Changes.")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                HStack(spacing: 10) {
                    if hasUnsavedChanges {
                        Text("Unsaved changes")
                            .font(.custom("Avenir Next Demi Bold", size: 12))
                            .foregroundStyle(CrabTheme.warningTint(for: colorScheme))
                    }

                    Spacer()

                    Button("Discard") {
                        loadDraftsFromModel(force: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasUnsavedChanges)

                    Button("Save Changes") {
                        saveDraftRules()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges)
                }

                allowListSection
                mapLocalSection
                statusRewriteSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadDraftsFromModel(force: !didInitializeDrafts)
            consumeStagedAllowRuleIfNeeded()
            consumeStagedMapLocalRuleIfNeeded()
        }
        .onChange(of: model.allowRules) { _, _ in
            loadDraftsFromModel(force: false)
        }
        .onChange(of: model.mapLocalRules) { _, _ in
            loadDraftsFromModel(force: false)
        }
        .onChange(of: model.statusRewriteRules) { _, _ in
            loadDraftsFromModel(force: false)
        }
        .sheet(item: $mapLocalEditorState) { editorState in
            MapLocalRuleEditorSheet(
                initialRule: mapLocalRuleForEditor(editorState.editingRuleID),
                onSave: { editedRule in
                    saveMapLocalRule(editedRule, editingRuleID: editorState.editingRuleID)
                    mapLocalEditorState = nil
                },
                onDelete: {
                    deleteMapLocalRule(editorState.editingRuleID)
                    mapLocalEditorState = nil
                },
                allowDelete: editorState.editingRuleID != nil,
                onPickFile: {
                    pickMapLocalSourceFile()
                }
            )
        }
        .sheet(item: $statusRewriteEditorState) { editorState in
            StatusRewriteRuleEditorSheet(
                initialRule: statusRewriteRuleForEditor(editorState.editingRuleID),
                onSave: { editedRule in
                    saveStatusRewriteRule(editedRule, editingRuleID: editorState.editingRuleID)
                    statusRewriteEditorState = nil
                },
                onDelete: {
                    deleteStatusRewriteRule(editorState.editingRuleID)
                    statusRewriteEditorState = nil
                },
                allowDelete: editorState.editingRuleID != nil
            )
        }
    }

    private var allowListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Allowlist (SSL Proxying)")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Button("Add Rule") {
                    draftAllowRules.append(AllowRuleInput())
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            Text("Examples: *.* (all), naver.com, api.naver.com/v1, /graphql")
                .font(.custom("Avenir Next Medium", size: 12))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

            if draftAllowRules.isEmpty {
                EmptyRuleHint(text: "No allowlist rule. HTTPS is tunneled until a host is added.")
            } else {
                ForEach($draftAllowRules) { $rule in
                    HStack(spacing: 8) {
                        TextField("Allowed URL pattern", text: $rule.matcher)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            draftAllowRules.removeAll { $0.id == rule.id }
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
                    mapLocalEditorState = MapLocalEditorState(editingRuleID: nil)
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if draftMapLocalRules.isEmpty {
                EmptyRuleHint(text: "No map-local rule yet")
            } else {
                ForEach($draftMapLocalRules) { $rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $rule.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.matcher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty URL)" : rule.matcher)
                                .font(.custom("Menlo", size: 12))
                                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text("Status \(rule.statusCode.isEmpty ? "200" : rule.statusCode) • \(rule.sourceType.rawValue)")
                                .font(.custom("Avenir Next Medium", size: 11))
                                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Edit") {
                            mapLocalEditorState = MapLocalEditorState(editingRuleID: rule.id)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            draftMapLocalRules.removeAll { $0.id == rule.id }
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

    private var statusRewriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status Rewrite")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Button("Add Rule") {
                    statusRewriteEditorState = StatusRewriteEditorState(editingRuleID: nil)
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if draftStatusRewriteRules.isEmpty {
                EmptyRuleHint(text: "No status-rewrite rule yet")
            } else {
                ForEach($draftStatusRewriteRules) { $rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $rule.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.matcher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty URL)" : rule.matcher)
                                .font(.custom("Menlo", size: 12))
                                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text("From \(rule.fromStatusCode.isEmpty ? "*" : rule.fromStatusCode) → \(rule.toStatusCode.isEmpty ? "200" : rule.toStatusCode)")
                                .font(.custom("Avenir Next Medium", size: 11))
                                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Edit") {
                            statusRewriteEditorState = StatusRewriteEditorState(editingRuleID: rule.id)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            draftStatusRewriteRules.removeAll { $0.id == rule.id }
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

    private func loadDraftsFromModel(force: Bool) {
        if !force && didInitializeDrafts && hasUnsavedChanges {
            return
        }
        draftAllowRules = model.allowRules
        draftMapLocalRules = model.mapLocalRules
        draftStatusRewriteRules = model.statusRewriteRules
        if force {
            mapLocalEditorState = nil
            statusRewriteEditorState = nil
        }
        didInitializeDrafts = true
    }

    private func saveDraftRules() {
        // Commit any in-progress text composition before reading draft values.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let originalAllowCount = draftAllowRules.count
        model.saveRules(
            allowRules: draftAllowRules,
            mapLocalRules: draftMapLocalRules,
            statusRewriteRules: draftStatusRewriteRules
        )
        if model.allowRules.count > originalAllowCount {
            draftAllowRules = model.allowRules
        }
        loadDraftsFromModel(force: true)
    }

    private func consumeStagedAllowRuleIfNeeded() {
        guard let staged = model.consumeStagedAllowRule() else { return }
        let matcher = staged.matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matcher.isEmpty else { return }
        let normalized = matcher.lowercased()
        let alreadyExists = draftAllowRules.contains {
            $0.matcher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
        if !alreadyExists {
            draftAllowRules.append(AllowRuleInput(matcher: matcher))
        }
    }

    private func consumeStagedMapLocalRuleIfNeeded() {
        guard let staged = model.consumeStagedMapLocalRule() else { return }
        let alreadyExists = draftMapLocalRules.contains {
            $0.matcher == staged.matcher
                && $0.isEnabled == staged.isEnabled
                && $0.sourceType == staged.sourceType
                && $0.sourceValue == staged.sourceValue
                && $0.statusCode == staged.statusCode
                && $0.contentType == staged.contentType
        }
        if !alreadyExists {
            draftMapLocalRules.append(staged)
            mapLocalEditorState = MapLocalEditorState(editingRuleID: staged.id)
        }
    }

    private func mapLocalRuleForEditor(_ editingRuleID: UUID?) -> MapLocalRuleInput {
        guard let editingRuleID else {
            return MapLocalRuleInput()
        }
        return draftMapLocalRules.first(where: { $0.id == editingRuleID }) ?? MapLocalRuleInput()
    }

    private func saveMapLocalRule(_ rule: MapLocalRuleInput, editingRuleID: UUID?) {
        if let editingRuleID,
           let index = draftMapLocalRules.firstIndex(where: { $0.id == editingRuleID })
        {
            draftMapLocalRules[index] = rule
            return
        }
        draftMapLocalRules.append(rule)
    }

    private func deleteMapLocalRule(_ editingRuleID: UUID?) {
        guard let editingRuleID else { return }
        draftMapLocalRules.removeAll { $0.id == editingRuleID }
    }

    private func statusRewriteRuleForEditor(_ editingRuleID: UUID?) -> StatusRewriteRuleInput {
        guard let editingRuleID else {
            return StatusRewriteRuleInput()
        }
        return draftStatusRewriteRules.first(where: { $0.id == editingRuleID }) ?? StatusRewriteRuleInput()
    }

    private func saveStatusRewriteRule(_ rule: StatusRewriteRuleInput, editingRuleID: UUID?) {
        if let editingRuleID,
           let index = draftStatusRewriteRules.firstIndex(where: { $0.id == editingRuleID })
        {
            draftStatusRewriteRules[index] = rule
            return
        }
        draftStatusRewriteRules.append(rule)
    }

    private func deleteStatusRewriteRule(_ editingRuleID: UUID?) {
        guard let editingRuleID else { return }
        draftStatusRewriteRules.removeAll { $0.id == editingRuleID }
    }

    private func pickMapLocalSourceFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Select local response file"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private struct MapLocalRuleEditorSheet: View {
    let onSave: (MapLocalRuleInput) -> Void
    let onDelete: () -> Void
    let allowDelete: Bool
    let onPickFile: () -> String?

    @State private var draftRule: MapLocalRuleInput
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        initialRule: MapLocalRuleInput,
        onSave: @escaping (MapLocalRuleInput) -> Void,
        onDelete: @escaping () -> Void,
        allowDelete: Bool,
        onPickFile: @escaping () -> String?
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.allowDelete = allowDelete
        self.onPickFile = onPickFile
        _draftRule = State(initialValue: initialRule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(allowDelete ? "Edit Map Local Rule" : "New Map Local Rule")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Toggle("Enabled", isOn: $draftRule.isEnabled)
                    .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                TextField("Match URL prefix", text: $draftRule.matcher)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    TextField("200", text: $draftRule.statusCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Source")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    Picker("", selection: $draftRule.sourceType) {
                        ForEach(RuleSourceType.allCases) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draftRule.sourceType == .file ? "Local File" : "Inline Text")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    TextField(
                        draftRule.sourceType == .file ? "Local file path" : "Inline text body",
                        text: $draftRule.sourceValue
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if draftRule.sourceType == .file {
                    Button("Choose File…") {
                        if let selected = onPickFile() {
                            draftRule.sourceValue = selected
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Content-Type")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                TextField("Optional (e.g. application/json)", text: $draftRule.contentType)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 0)

            HStack {
                if allowDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    onSave(draftRule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 360, alignment: .topLeading)
    }
}

private struct StatusRewriteRuleEditorSheet: View {
    let onSave: (StatusRewriteRuleInput) -> Void
    let onDelete: () -> Void
    let allowDelete: Bool

    @State private var draftRule: StatusRewriteRuleInput
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(
        initialRule: StatusRewriteRuleInput,
        onSave: @escaping (StatusRewriteRuleInput) -> Void,
        onDelete: @escaping () -> Void,
        allowDelete: Bool
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.allowDelete = allowDelete
        _draftRule = State(initialValue: initialRule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(allowDelete ? "Edit Status Rewrite Rule" : "New Status Rewrite Rule")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                Spacer()
                Toggle("Enabled", isOn: $draftRule.isEnabled)
                    .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                TextField("Match URL prefix", text: $draftRule.matcher)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From (optional)")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    TextField("e.g. 200", text: $draftRule.fromStatusCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                Text("→")
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                    .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text("To")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                    TextField("e.g. 503", text: $draftRule.toStatusCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if allowDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    onSave(draftRule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 260, alignment: .topLeading)
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
