import AppKit
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
    @State private var draftAllowRules: [AllowRuleInput] = []
    @State private var draftMapLocalRules: [MapLocalRuleInput] = []
    @State private var expandedMapLocalRuleIDs: Set<UUID> = []
    @State private var draftStatusRewriteRules: [StatusRewriteRuleInput] = []
    @State private var expandedStatusRewriteRuleIDs: Set<UUID> = []
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
                    let newRule = MapLocalRuleInput()
                    draftMapLocalRules.append(newRule)
                    expandedMapLocalRuleIDs.insert(newRule.id)
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if draftMapLocalRules.isEmpty {
                EmptyRuleHint(text: "No map-local rule yet")
            } else {
                ForEach($draftMapLocalRules) { $rule in
                    if expandedMapLocalRuleIDs.contains(rule.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                Toggle("Enabled", isOn: $rule.isEnabled)
                                    .toggleStyle(.checkbox)
                                    .font(.custom("Avenir Next Medium", size: 12))
                                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                Spacer()
                                Button("Collapse") {
                                    expandedMapLocalRuleIDs.remove(rule.id)
                                }
                                .buttonStyle(.bordered)
                            }

                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("URL")
                                        .font(.custom("Avenir Next Demi Bold", size: 11))
                                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                                    TextField("Match URL prefix", text: $rule.matcher)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Status")
                                        .font(.custom("Avenir Next Demi Bold", size: 11))
                                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                                    TextField("200", text: $rule.statusCode)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 110)
                                }
                                .frame(width: 110, alignment: .leading)
                            }

                            HStack(alignment: .bottom, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Source")
                                        .font(.custom("Avenir Next Demi Bold", size: 11))
                                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))

                                    Picker("", selection: $rule.sourceType) {
                                        ForEach(RuleSourceType.allCases) { source in
                                            Text(source.rawValue).tag(source)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(minWidth: 86, idealWidth: 92, maxWidth: 98, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.sourceType == .file ? "Local File" : "Inline Text")
                                        .font(.custom("Avenir Next Demi Bold", size: 11))
                                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                    TextField(
                                        rule.sourceType == .file ? "Local file path" : "Inline text body",
                                        text: $rule.sourceValue
                                    )
                                    .textFieldStyle(.roundedBorder)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if rule.sourceType == .file {
                                    Button("Choose File…") {
                                        if let selected = pickMapLocalSourceFile() {
                                            rule.sourceValue = selected
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(width: 150, alignment: .leading)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Content-Type")
                                    .font(.custom("Avenir Next Demi Bold", size: 11))
                                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                TextField("Optional (e.g. application/json)", text: $rule.contentType)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button(role: .destructive) {
                                draftMapLocalRules.removeAll { $0.id == rule.id }
                                expandedMapLocalRuleIDs.remove(rule.id)
                            } label: {
                                Label("Delete Rule", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .help("Delete this map-local rule")
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
                    } else {
                        HStack(spacing: 10) {
                            Toggle("", isOn: $rule.isEnabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Text(rule.matcher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty URL)" : rule.matcher)
                                .font(.custom("Menlo", size: 12))
                                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Edit") {
                                expandedMapLocalRuleIDs.insert(rule.id)
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
                    let newRule = StatusRewriteRuleInput()
                    draftStatusRewriteRules.append(newRule)
                    expandedStatusRewriteRuleIDs.insert(newRule.id)
                }
                .tint(CrabTheme.primaryTint(for: colorScheme))
            }

            if draftStatusRewriteRules.isEmpty {
                EmptyRuleHint(text: "No status-rewrite rule yet")
            } else {
                ForEach($draftStatusRewriteRules) { $rule in
                    if expandedStatusRewriteRuleIDs.contains(rule.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                Toggle("Enabled", isOn: $rule.isEnabled)
                                    .toggleStyle(.checkbox)
                                    .font(.custom("Avenir Next Medium", size: 12))
                                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                                Spacer()
                                Button("Collapse") {
                                    expandedStatusRewriteRuleIDs.remove(rule.id)
                                }
                                .buttonStyle(.bordered)
                            }

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
                            }

                            Button(role: .destructive) {
                                draftStatusRewriteRules.removeAll { $0.id == rule.id }
                                expandedStatusRewriteRuleIDs.remove(rule.id)
                            } label: {
                                Label("Delete Rule", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
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
                    } else {
                        HStack(spacing: 10) {
                            Toggle("", isOn: $rule.isEnabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Text(rule.matcher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty URL)" : rule.matcher)
                                .font(.custom("Menlo", size: 12))
                                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Edit") {
                                expandedStatusRewriteRuleIDs.insert(rule.id)
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
            expandedMapLocalRuleIDs.removeAll()
            expandedStatusRewriteRuleIDs.removeAll()
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
            expandedMapLocalRuleIDs.insert(staged.id)
        }
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
