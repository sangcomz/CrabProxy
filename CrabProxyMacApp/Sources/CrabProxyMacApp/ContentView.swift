import AppKit
import SwiftUI

struct ContentView: View {
    private enum TrafficScope: Equatable {
        case all
        case domain(String)
        case app(String)
    }

    @ObservedObject var model: ProxyViewModel
    @Binding var appearanceModeRawValue: String
    @AppStorage("CrabProxyMacApp.currentScreen") private var currentScreenRawValue = MainScreen.traffic.rawValue
    @AppStorage("CrabProxyMacApp.settingsTab") private var settingsTabRawValue = "General"
    @AppStorage("CrabProxyMacApp.pinnedDomains.v1") private var pinnedDomainsRawValue = ""
    @State private var animateBackground = false
    @State private var detailTab: DetailTab = .summary
    @State private var isTrafficListAtTop = true
    @State private var selectedDomain: String?
    @State private var selectedClientApp: String?
    @State private var activeTrafficScope: TrafficScope = .all
    @State private var pinnedDomains: Set<String> = []
    @State private var pinnedSectionExpanded = true
    @State private var appsSectionExpanded = true
    @State private var domainsSectionExpanded = true
    @State private var selectedClientFilter: ClientLabelFilter = .all
    @FocusState private var isFilterFieldFocused: Bool
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
            pinnedDomains = decodePinnedDomains(from: pinnedDomainsRawValue)
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animateBackground = true
            }
        }
        .onChange(of: groupedDomains.map(\.domain)) { _, domains in
            if let selectedDomain, !domains.contains(selectedDomain) {
                self.selectedDomain = nil
                if case .domain = activeTrafficScope {
                    activeTrafficScope = .all
                }
            }
        }
        .onChange(of: groupedClientApps.map(\.label)) { _, labels in
            if let selectedClientApp, !labels.contains(selectedClientApp) {
                self.selectedClientApp = nil
                if case .app = activeTrafficScope {
                    activeTrafficScope = .all
                }
            }
        }
        .onChange(of: pinnedDomains) { _, domains in
            pinnedDomainsRawValue = encodePinnedDomains(domains)
        }
        .background(
            WindowAccessor { window in
                configureMainWindowAppearance(window)
            }
        )
        .animation(.easeInOut(duration: 0.2), value: currentScreenRawValue)
        .tint(primaryTint)
        .overlay(alignment: .topLeading) {
            keyboardShortcutTriggers
        }
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

    private var platformScopedLogs: [ProxyLogEntry] {
        model.filteredLogs.filter { entry in
            selectedClientFilter.matches(entry.clientPlatform)
        }
    }

    private var scopedLogs: [ProxyLogEntry] {
        switch activeTrafficScope {
        case .all:
            return platformScopedLogs
        case .domain(let domain):
            return filteredLogs(forDomain: domain, in: platformScopedLogs)
        case .app(let app):
            return platformScopedLogs.filter { canonicalClientAppLabel($0.clientApp) == app }
        }
    }

    private var displayedTrafficLogs: [ProxyLogEntry] {
        Array(scopedLogs.reversed())
    }

    private var groupedClientApps: [ClientAppGroup] {
        let grouped = Dictionary(grouping: platformScopedLogs) { entry in
            canonicalClientAppLabel(entry.clientApp)
        }
        return grouped
            .map { label, entries in
                ClientAppGroup(label: label, count: entries.count)
            }
            .sorted {
                let order = $0.label.localizedCaseInsensitiveCompare($1.label)
                if order == .orderedSame {
                    return $0.label < $1.label
                }
                return order == .orderedAscending
            }
    }

    private var groupedDomains: [ProxyViewModel.DomainGroup] {
        let grouped = Dictionary(grouping: platformScopedLogs) { entry in
            domainName(from: entry.url)
        }
        return grouped
            .map { domain, entries in
                ProxyViewModel.DomainGroup(
                    domain: domain,
                    count: entries.count,
                    hasMacOS: entries.contains { $0.clientPlatform == .macOS },
                    hasMobile: entries.contains { $0.clientPlatform == .mobile }
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.domain < $1.domain
                }
                return $0.count > $1.count
            }
    }

    private var pinnedDomainGroups: [ProxyViewModel.DomainGroup] {
        groupedDomains.filter { pinnedDomains.contains($0.domain) }
    }

    private var unpinnedDomainGroups: [ProxyViewModel.DomainGroup] {
        groupedDomains.filter { !pinnedDomains.contains($0.domain) }
    }

    private var allDomainHasMacOS: Bool {
        platformScopedLogs.contains { $0.clientPlatform == .macOS }
    }

    private var allDomainHasMobile: Bool {
        platformScopedLogs.contains { $0.clientPlatform == .mobile }
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
            domainsPanel
                .frame(minWidth: 220, idealWidth: 320, maxWidth: 620, maxHeight: .infinity)
                .layoutPriority(1)
            transactionsPanel
                .frame(minWidth: 320, idealWidth: 500, maxWidth: 900, maxHeight: .infinity)
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

    private var domainsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActionButton(
                    title: "Clear",
                    icon: "trash.fill",
                    tint: secondaryTint
                ) {
                    model.clearLogs()
                }
                Spacer(minLength: 0)
            }

            TextField("Show only traffic URLs containing...", text: $model.visibleURLFilter)
                .focused($isFilterFieldFocused)
                .font(.custom("Avenir Next Medium", size: 12))
                .textFieldStyle(.plain)
                .foregroundStyle(primaryText)
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
            clientFilterChips

            List {
                Button {
                    selectedDomain = nil
                    selectedClientApp = nil
                    activeTrafficScope = .all
                } label: {
                    DomainRow(
                        title: "All Traffic",
                        count: platformScopedLogs.count,
                        hasMacOS: allDomainHasMacOS,
                        hasMobile: allDomainHasMobile,
                        isSelected: activeTrafficScope == .all,
                        isPinned: false
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)

                DisclosureGroup(isExpanded: $pinnedSectionExpanded) {
                    if pinnedDomainGroups.isEmpty {
                        SidebarHintRow(text: "No pinned domains")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(pinnedDomainGroups) { group in
                            domainSelectionRow(group: group, isPinned: true)
                        }
                    }
                }
                label: {
                    SidebarSectionLabel(title: "Pinned", symbol: "pin.fill", count: pinnedDomainGroups.count)
                }
                .listRowBackground(Color.clear)

                DisclosureGroup(isExpanded: $appsSectionExpanded) {
                    if groupedClientApps.isEmpty {
                        SidebarHintRow(text: "No apps identified")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(groupedClientApps) { group in
                            appSelectionRow(
                                title: group.label,
                                count: group.count,
                                appLabel: group.label
                            )
                        }
                    }
                }
                label: {
                    SidebarSectionLabel(title: "Apps", symbol: "app.fill", count: groupedClientApps.count)
                }
                .listRowBackground(Color.clear)

                DisclosureGroup(isExpanded: $domainsSectionExpanded) {
                    if unpinnedDomainGroups.isEmpty {
                        SidebarHintRow(text: "No domains captured")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(unpinnedDomainGroups) { group in
                            domainSelectionRow(group: group, isPinned: false)
                        }
                    }
                }
                label: {
                    SidebarSectionLabel(title: "Domains", symbol: "globe", count: groupedDomains.count)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func domainSelectionRow(group: ProxyViewModel.DomainGroup, isPinned: Bool) -> some View {
        Button {
            selectedDomain = group.domain
            selectedClientApp = nil
            activeTrafficScope = .domain(group.domain)
        } label: {
            DomainRow(
                title: group.domain,
                count: group.count,
                hasMacOS: group.hasMacOS,
                hasMobile: group.hasMobile,
                isSelected: activeTrafficScope == .domain(group.domain),
                isPinned: isPinned
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button(isPinned ? "Unpin Domain" : "Pin Domain") {
                togglePin(for: group.domain)
            }
        }
    }

    @ViewBuilder
    private func appSelectionRow(title: String, count: Int, appLabel: String) -> some View {
        Button {
            selectedClientApp = appLabel
            selectedDomain = nil
            activeTrafficScope = .app(appLabel)
        } label: {
            AppRow(
                title: title,
                count: count,
                isSelected: activeTrafficScope == .app(appLabel)
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    private func togglePin(for domain: String) {
        if pinnedDomains.contains(domain) {
            pinnedDomains.remove(domain)
        } else {
            pinnedDomains.insert(domain)
        }
    }

    private func decodePinnedDomains(from rawValue: String) -> Set<String> {
        Set(
            rawValue
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func encodePinnedDomains(_ domains: Set<String>) -> String {
        domains.sorted().joined(separator: "\n")
    }

    private var clientFilterChips: some View {
        HStack(spacing: 6) {
            ForEach(ClientLabelFilter.allCases) { filter in
                Button {
                    selectedClientFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(
                            selectedClientFilter == filter
                                ? Color.white.opacity(0.95)
                                : primaryText.opacity(0.9)
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    selectedClientFilter == filter
                                        ? primaryTint.opacity(0.92)
                                        : CrabTheme.softFill(for: colorScheme)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(
                                            selectedClientFilter == filter
                                                ? primaryTint.opacity(0.95)
                                                : panelStroke,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func filteredLogs(forDomain domain: String?, in entries: [ProxyLogEntry]) -> [ProxyLogEntry] {
        guard let domain else { return entries }
        return entries.filter { domainName(from: $0.url) == domain }
    }

    private func normalizedClientAppLabel(_ raw: String?) -> String {
        normalizedClientAppDisplayLabel(raw)
    }

    private func canonicalClientAppLabel(_ raw: String?) -> String {
        canonicalClientAppDisplayLabel(raw)
    }

    private func domainName(from urlString: String) -> String {
        if let host = URLComponents(string: urlString)?.host, !host.isEmpty {
            return host.lowercased()
        }
        return "(unknown)"
    }

    private var transactionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusFilterChips

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
                                    Button("Replay") {
                                        model.replay(entryID: entry.id)
                                    }
                                    Divider()
                                    Button("Add to Allowlist") {
                                        model.stageAllowRule(from: entry)
                                        settingsTabRawValue = "Rules"
                                        currentScreenRawValue = MainScreen.settings.rawValue
                                    }
                                    Divider()
                                    Button("Add to Map Local") {
                                        model.stageMapLocalRule(from: entry)
                                        settingsTabRawValue = "Rules"
                                        currentScreenRawValue = MainScreen.settings.rawValue
                                    }
                                    Button("Add to Map Remote") {
                                        model.stageMapRemoteRule(from: entry)
                                        settingsTabRawValue = "Rules"
                                        currentScreenRawValue = MainScreen.settings.rawValue
                                    }
                                    Button("Add to Rewrite") {
                                        model.stageStatusRewriteRule(from: entry)
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
            if let entry = model.selectedLog {
                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Group {
                    if detailTab == .headers || detailTab == .body {
                        detailContent(for: entry)
                    } else {
                        ScrollView {
                            detailContent(for: entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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
        case .query:
            queryDetail(entry)
        }
    }

    private func summaryDetail(_ entry: ProxyLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MethodBadge(method: entry.method)
                ValuePill(text: entry.statusCode ?? "--", tint: statusCodeTint(entry.statusCode))
                ValuePill(text: entry.event, tint: primaryTint)
                if let durationText = formattedDuration(entry.durationMs) {
                    ValuePill(text: durationText, tint: secondaryTint)
                }
                if let sizeText = formattedByteCount(entry.responseSizeBytes) {
                    ValuePill(text: sizeText, tint: secondaryText)
                }
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
            if let matcher = entry.mapRemoteMatcher {
                if let target = entry.mapRemoteTarget {
                    DetailLine(title: "Map Remote", value: "\(matcher) -> \(target)")
                } else {
                    DetailLine(title: "Map Remote", value: matcher)
                }
            }
            if let app = entry.clientApp {
                DetailLine(title: "App", value: canonicalClientAppDisplayLabel(app))
            }
            if let platform = entry.clientPlatform {
                DetailLine(title: "Client", value: platform.rawValue)
            }
            if let durationText = formattedDuration(entry.durationMs) {
                DetailLine(title: "Duration", value: durationText)
            }
            if let sizeText = formattedByteCount(entry.responseSizeBytes) {
                DetailLine(title: "Response Size", value: sizeText)
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
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Request Headers")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(primaryText.opacity(0.9))
                HeaderBlock(
                    text: entry.requestHeaders,
                    placeholder: "No captured request headers"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Response Headers")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(primaryText.opacity(0.9))
                HeaderBlock(
                    text: entry.responseHeaders,
                    placeholder: "No captured response headers"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bodyDetail(_ entry: ProxyLogEntry) -> some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Request Body")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(primaryText.opacity(0.9))
                BodyBlock(
                    text: entry.requestBodyPreview,
                    placeholder: "No captured request body preview"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Response Body")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(primaryText.opacity(0.9))
                BodyBlock(
                    text: entry.responseBodyPreview,
                    placeholder: "No captured response body preview"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func queryDetail(_ entry: ProxyLogEntry) -> some View {
        let items = queryItems(from: entry.url)
        return VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("No query parameters")
                    .font(.custom("Avenir Next Medium", size: 13))
                    .foregroundStyle(secondaryText)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    CopyValueRow(
                        title: item.name,
                        value: item.value ?? "<empty>"
                    )
                }
            }
        }
    }

    private func queryItems(from urlString: String) -> [URLQueryItem] {
        guard let components = URLComponents(string: urlString) else { return [] }
        return components.queryItems ?? []
    }

    private func statusCodeTint(_ code: String?) -> Color {
        CrabTheme.statusCodeColor(for: code, scheme: colorScheme)
    }

    private var statusFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                StatusFilterChip(
                    title: "All",
                    isActive: model.statusCodeFilter.isEmpty,
                    tint: secondaryText
                ) {
                    model.statusCodeFilter.removeAll()
                }

                ForEach(ProxyViewModel.StatusCodeCategory.allCases) { category in
                    StatusFilterChip(
                        title: category.rawValue,
                        isActive: model.statusCodeFilter.contains(category),
                        tint: statusFilterTint(for: category)
                    ) {
                        if model.statusCodeFilter.contains(category) {
                            model.statusCodeFilter.remove(category)
                        } else {
                            model.statusCodeFilter.insert(category)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func statusFilterTint(for category: ProxyViewModel.StatusCodeCategory) -> Color {
        switch category {
        case .info:
            return CrabTheme.statusCodeColor(for: "100", scheme: colorScheme)
        case .success:
            return CrabTheme.statusCodeColor(for: "200", scheme: colorScheme)
        case .redirect:
            return CrabTheme.statusCodeColor(for: "300", scheme: colorScheme)
        case .clientError:
            return CrabTheme.statusCodeColor(for: "400", scheme: colorScheme)
        case .serverError:
            return CrabTheme.statusCodeColor(for: "500", scheme: colorScheme)
        }
    }

    private func focusFilterField() {
        if currentScreen != .traffic {
            currentScreenRawValue = MainScreen.traffic.rawValue
        }
        DispatchQueue.main.async {
            isFilterFieldFocused = true
        }
    }

    private func toggleProxyRunState() {
        if model.isRunning {
            model.stopProxy()
        } else {
            model.startProxy()
        }
    }

    private var keyboardShortcutTriggers: some View {
        VStack(spacing: 0) {
            Button("Focus Filter") {
                focusFilterField()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Clear Traffic Logs") {
                model.clearLogs()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Button("Toggle Proxy") {
                toggleProxyRunState()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .clipped()
        .opacity(0.001)
        .accessibilityHidden(true)
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

private enum ClientLabelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case macOS = "macOS"
    case mobile = "Mobile"

    var id: String { rawValue }

    func matches(_ platform: ClientPlatform?) -> Bool {
        switch self {
        case .all:
            return true
        case .macOS:
            return platform == .macOS
        case .mobile:
            return platform == .mobile
        }
    }
}

private struct ClientAppGroup: Identifiable, Hashable {
    let label: String
    let count: Int

    var id: String { label }
}

private struct AppRow: View {
    let title: String
    let count: Int
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var appIcon: NSImage {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("LAN ") {
            return NSImage(systemSymbolName: "network", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "circle.grid.cross.fill", accessibilityDescription: nil)
                ?? NSImage()
        }
        if trimmed.caseInsensitiveCompare("Unknown App") == .orderedSame {
            return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "circle.grid.cross.fill", accessibilityDescription: nil)
                ?? NSImage()
        }

        let candidates = lookupCandidates(from: trimmed)
        if let fromRunning = iconFromRunningApps(candidates) {
            return fromRunning
        }

        return NSImage(systemSymbolName: "circle.grid.cross.fill", accessibilityDescription: nil) ?? NSImage()
    }

    private func iconFromRunningApps(_ candidates: [String]) -> NSImage? {
        let running = NSWorkspace.shared.runningApplications
        for candidate in candidates {
            let needle = candidate.lowercased()
            if needle.isEmpty { continue }

            if let exact = running.first(where: {
                guard let name = $0.localizedName else { return false }
                return name.caseInsensitiveCompare(candidate) == .orderedSame
            }), let icon = exact.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                return icon
            }

            if let fuzzy = running.first(where: {
                guard let name = $0.localizedName?.lowercased() else { return false }
                return name.contains(needle) || needle.contains(name)
            }), let icon = fuzzy.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                return icon
            }
        }
        return nil
    }

    private func lookupCandidates(from label: String) -> [String] {
        var out: [String] = []

        func push(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !out.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                out.append(trimmed)
            }
        }

        push(label)
        var base = label
        if let range = base.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        push(base)

        for suffix in [" Helper", "Helper", " Service"] {
            if base.lowercased().hasSuffix(suffix.lowercased()) {
                base = String(base.dropLast(suffix.count))
                push(base)
            }
        }

        if base.caseInsensitiveCompare("Code") == .orderedSame {
            push("Visual Studio Code")
        }

        return out
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(
                    isSelected
                        ? CrabTheme.primaryText(for: colorScheme)
                        : CrabTheme.primaryText(for: colorScheme).opacity(0.86)
                )
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.custom("Menlo", size: 10))
                .foregroundStyle(
                    isSelected
                        ? CrabTheme.primaryText(for: colorScheme).opacity(0.95)
                        : CrabTheme.secondaryText(for: colorScheme)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? CrabTheme.secondaryTint(for: colorScheme).opacity(0.2)
                                : CrabTheme.softFill(for: colorScheme)
                        )
                )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
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
            .foregroundStyle(
                CrabTheme.primaryText(for: colorScheme)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        CrabTheme.softFill(for: colorScheme)
                    )
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
    case query = "Query"

    var id: String { rawValue }
}

private struct StatusFilterChip: View {
    let title: String
    let isActive: Bool
    let tint: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11))
                .foregroundStyle(
                    isActive
                        ? Color.white.opacity(0.95)
                        : CrabTheme.primaryText(for: colorScheme).opacity(0.9)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isActive
                                ? tint.opacity(0.92)
                                : CrabTheme.softFill(for: colorScheme)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    isActive
                                        ? tint.opacity(0.95)
                                        : CrabTheme.panelStroke(for: colorScheme),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarSectionLabel: View {
    let title: String
    let symbol: String
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(CrabTheme.primaryText(for: colorScheme))
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.custom("Menlo", size: 10))
                .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(CrabTheme.softFill(for: colorScheme))
                )
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarHintRow: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.custom("Avenir Next Medium", size: 11))
            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            .padding(.vertical, 4)
    }
}

private struct DomainRow: View {
    let title: String
    let count: Int
    let hasMacOS: Bool
    let hasMobile: Bool
    let isSelected: Bool
    let isPinned: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(
                    isSelected
                        ? CrabTheme.primaryText(for: colorScheme)
                        : CrabTheme.primaryText(for: colorScheme).opacity(0.86)
                )
                .lineLimit(1)

            if hasMacOS {
                platformBadge(title: "macOS")
            }
            if hasMobile {
                platformBadge(title: "Mobile")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            }

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.custom("Menlo", size: 10))
                .foregroundStyle(
                    isSelected
                        ? CrabTheme.primaryText(for: colorScheme).opacity(0.95)
                        : CrabTheme.secondaryText(for: colorScheme)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? CrabTheme.primaryTint(for: colorScheme).opacity(0.18)
                                : CrabTheme.softFill(for: colorScheme)
                        )
                )
        }
        .padding(.vertical, 4)
    }

    private func platformBadge(title: String) -> some View {
        Text(title)
            .font(.custom("Avenir Next Demi Bold", size: 9))
            .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(CrabTheme.softFill(for: colorScheme))
            )
    }
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
                    .foregroundStyle(CrabTheme.statusCodeColor(for: entry.statusCode, scheme: colorScheme))
                Text(entry.event)
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                if let platform = entry.clientPlatform {
                    Text(platform.rawValue)
                        .font(.custom("Avenir Next Demi Bold", size: 10))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme).opacity(0.9))
                }
                if let app = entry.clientApp {
                    Text(canonicalClientAppDisplayLabel(app))
                        .font(.custom("Avenir Next Demi Bold", size: 10))
                        .foregroundStyle(CrabTheme.secondaryTint(for: colorScheme))
                        .lineLimit(1)
                }
                if let durationText = formattedDuration(entry.durationMs) {
                    Text(durationText)
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(CrabTheme.secondaryTint(for: colorScheme))
                }
                if let sizeText = formattedByteCount(entry.responseSizeBytes) {
                    Text(sizeText)
                        .font(.custom("Menlo", size: 10))
                        .foregroundStyle(CrabTheme.secondaryText(for: colorScheme))
                }
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

private func formattedDuration(_ durationMs: Double?) -> String? {
    guard let durationMs, durationMs >= 0 else { return nil }
    if durationMs < 1 {
        return String(format: "%.2fms", durationMs)
    }
    if durationMs < 1_000 {
        return String(format: "%.0fms", durationMs)
    }
    return String(format: "%.2fs", durationMs / 1_000)
}

private func formattedByteCount(_ bytes: Int64?) -> String? {
    guard let bytes, bytes >= 0 else { return nil }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.includesCount = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func normalizedClientAppDisplayLabel(_ raw: String?) -> String {
    if let raw {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return "Unknown App"
}

private func canonicalClientAppDisplayLabel(_ raw: String?) -> String {
    let normalized = normalizedClientAppDisplayLabel(raw)
    if normalized.hasPrefix("LAN ") || normalized == "Unknown App" {
        return normalized
    }

    var value = normalized
    if let range = value.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
        value.removeSubrange(range)
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)

    for suffix in [" Helper", "Helper", " Service"] {
        if value.lowercased().hasSuffix(suffix.lowercased()) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    if value.caseInsensitiveCompare("Code") == .orderedSame {
        return "Visual Studio Code"
    }

    return value.isEmpty ? normalized : value
}
