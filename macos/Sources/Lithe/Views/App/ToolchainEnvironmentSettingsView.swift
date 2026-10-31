import LitheModuleAPI
import SwiftUI

/// Presents the feature snapshot. Nothing here launches a tool, queries a provider or writes a file.
struct ToolchainEnvironmentSettingsView: View {
    @ObservedObject var feature: ToolchainSettingsFeatureModel
    var onOpenPlugins: () -> Void
    @State private var directoryWidth: CGFloat = 210
    @State private var collapsedDirectoryIDs = Set<String>()
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let snapshot = feature.snapshot, !snapshot.directories.isEmpty {
                // A project with only its root needs no directory tree.
                if snapshot.directories.count > 1 {
                    LitheSplitPaneView(
                        axis: .horizontal, placement: .leading,
                        defaultSize: directoryWidth, minimum: 150, maximum: 300,
                        flexibleMinimum: 340,
                        idealSize: CGSize(width: 666, height: 617),
                        clipsSizedPane: true,
                        onCommit: { directoryWidth = $0 },
                        sized: { directoryTree(snapshot) },
                        flexible: { detail(snapshot) }
                    )
                } else {
                    detail(snapshot)
                }
            } else if feature.snapshot == nil, feature.isLoading {
                Color.clear
            } else {
                ToolchainSettingsEmptyState(feature: feature, openPlugins: onOpenPlugins, refresh: refresh)
            }
        }
        .background(LitheTheme.settingsPage)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onDisappear { refreshTask?.cancel(); refreshTask = nil }
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await feature.load(workspace: feature.workspaceURL) }
    }

    private func directoryTree(_ snapshot: ToolchainSettingsSnapshot) -> some View {
        let pinned = Set(snapshot.tools.compactMap(\.pin?.directory))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LitheInfoTip.labelSpacing) {
                Text("Directories")
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .lineLimit(1)
                LitheInfoTip("Lists the project root and each directory with its own version file or fixed version. A fixed version also applies to the directories below it.")
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 36)
            Rectangle().fill(LitheTheme.settingsCardDivider).frame(height: 1)
            LitheTreeList(
                visibleDirectories(snapshot), id: \.id,
                selection: Binding(get: { feature.selectedDirectoryID }, set: { if let id = $0 { feature.selectDirectory(id) } }),
                hierarchy: { directory in
                    .init(depth: directory.depth, isBranch: hasChildren(directory, in: snapshot),
                          isExpanded: !collapsedDirectoryIDs.contains(directory.id))
                },
                onExpansion: { directory, expanded in
                    if expanded { collapsedDirectoryIDs.remove(directory.id) }
                    else { collapsedDirectoryIDs.insert(directory.id) }
                }
            ) { directory in
                HStack(spacing: 6) {
                    LitheIDEAIcon(resourcePath: "nodes/folder.svg", size: 15, fallbackSystemImage: "folder", preservesOriginalColors: true)
                    Text(verbatim: directory.title)
                        .font(LitheTheme.uiFont(size: 12, weight: directory.id == "." ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if pinned.contains(directory.id) {
                        ToolchainSettingsTag("Fixed", kind: .project)
                    }
                }
                .padding(.vertical, 3)
            }
            .accessibilityIdentifier("toolchain-directory-list")
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(LitheTheme.settingsCard)
    }

    private func visibleDirectories(_ snapshot: ToolchainSettingsSnapshot) -> [ToolchainSettingsSnapshot.Directory] {
        var hiddenBelow: Int?
        return snapshot.directories.filter { directory in
            if let depth = hiddenBelow, directory.depth > depth { return false }
            hiddenBelow = nil
            if collapsedDirectoryIDs.contains(directory.id) { hiddenBelow = directory.depth }
            return true
        }
    }

    private func hasChildren(_ directory: ToolchainSettingsSnapshot.Directory, in snapshot: ToolchainSettingsSnapshot) -> Bool {
        guard let index = snapshot.directories.firstIndex(where: { $0.id == directory.id }),
              snapshot.directories.indices.contains(index + 1) else { return false }
        return snapshot.directories[index + 1].depth > directory.depth
    }

    private func detail(_ snapshot: ToolchainSettingsSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ToolchainSettingsSnapshotNotice(feature: feature)
                if let directory = feature.selectedDirectory {
                    directoryGroup(directory, in: snapshot)
                }
                toolsGroup(snapshot)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(LitheTheme.settingsPage)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("environment-detail-viewport")
    }

    private func directoryGroup(
        _ directory: ToolchainSettingsSnapshot.Directory, in snapshot: ToolchainSettingsSnapshot
    ) -> some View {
        let tools = feature.tools
        let pinned = tools.filter { $0.pin != nil }
        let path = ToolchainSettingsText.abbreviated(
            snapshot.workspaceURL.map { directory.id == "." ? $0.path : $0.appendingPathComponent(directory.id).path }
                ?? directory.id
        )
        let parentHasFiles = ToolchainSettingsText.ancestors(of: directory.id).contains { id in
            snapshot.directories.first { $0.id == id }?.versionFiles.isEmpty == false
        }
        return ToolchainSettingsGroup(directory.id == "." ? Text("Project root directory") : Text(verbatim: directory.id)) {
            ToolchainSettingsLine("Path") {
                Text(verbatim: path)
                    .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            }
            ToolchainSettingsLine("Version files", info: "Files declared by enabled version managers that exist in this directory. A directory without its own uses the nearest parent's.") {
                ForEach(directory.versionFiles, id: \.path) { file in
                    HStack(spacing: 5) {
                        LitheSettingsPill(verbatim: ToolchainSettingsText.relative(file.path, to: directory.id), kind: .value, wraps: true)
                        Text(verbatim: snapshot.providers.filter { file.providerIDs.contains($0.id) }.map(\.title).joined(separator: ", "))
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                if directory.versionFiles.isEmpty {
                    (parentHasFiles ? Text("None; uses the parent directory's") : Text("None"))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            ToolchainSettingsLine("Fixed", info: "Fixed versions are saved on this computer in .lithe/toolchains/local.json and also apply to the directories below. This page reads them without changing the file.") {
                ForEach(pinned, id: \.identity) { tool in
                    if let pin = tool.pin {
                        if pin.directory == directory.id {
                            LitheSettingsPill(verbatim: tool.displayName + " " + pin.version, kind: .value, wraps: true)
                        } else {
                            HStack(spacing: 5) {
                                LitheSettingsPill(verbatim: tool.displayName + " " + pin.version, wraps: true)
                                Text("From \(ToolchainSettingsText.directory(pin.directory))")
                                    .font(LitheTheme.uiFont(size: 11))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if pinned.isEmpty {
                    Text("Not pinned").foregroundStyle(LitheTheme.tertiaryText)
                }
            }
        }
    }

    private func toolsGroup(_ snapshot: ToolchainSettingsSnapshot) -> some View {
        let tools = feature.tools
        return ToolchainSettingsGroup(Text("Tools"), accessory: {
            LitheInfoTip("Each tool uses the first source that has a value: a fixed version, then project version files, then global defaults, then automatic discovery. Version managers are not queried yet, so the versions that version files and global defaults ask for are not shown.")
            Spacer(minLength: 8)
            Button(action: refresh) {
                HStack(spacing: 4) {
                    if feature.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
                    }
                    Text("Refresh")
                }
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .disabled(feature.isLoading)
        }) {
            if tools.isEmpty {
                HStack(spacing: 10) {
                    Text("No enabled plugin defines tools.")
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Plugins", action: onOpenPlugins).buttonStyle(LitheActionButtonStyle())
                }
                .font(LitheTheme.uiFont(size: 12))
                .frame(minHeight: 36)
            } else {
                ForEach(tools, id: \.identity) { tool in
                    ToolchainToolRow(
                        tool: tool,
                        providers: snapshot.providers.filter { $0.tools.contains(tool.id) },
                        isExpanded: feature.expandedToolIDs.contains(tool.id),
                        toggle: { feature.toggleExpanded(tool.id) },
                        openPlugins: onOpenPlugins
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-tools-section")
    }
}

/// One tool in the selected directory: the first source with a value on one line,
/// all four sources and the definition when expanded.
private struct ToolchainToolRow: View {
    let tool: ToolchainSettingsSnapshot.Tool
    /// Providers that declare this tool.
    let providers: [ToolchainSettingsSnapshot.Provider]
    let isExpanded: Bool
    let toggle: () -> Void
    let openPlugins: () -> Void

    private static let indent: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolchainEdgeLayout(minimumLeadingWidth: 240, trailingIndent: Self.indent) {
                HStack(spacing: 10) {
                    nameButton
                    summary.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                badge
            }
            .frame(minHeight: 32)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolchain-tool-header:" + tool.id)
            if isExpanded {
                ToolchainStepGridLayout(minimumColumnWidth: 150, spacing: 8) {
                    pinnedStep
                    projectStep
                    globalStep
                    automaticStep
                }
                .padding(.leading, Self.indent)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toolchain-resolution:" + tool.id)
                VStack(alignment: .leading, spacing: 2) {
                    ToolchainSettingsMetaLine("Version managers") {
                        if providers.isEmpty {
                            Text("None").foregroundStyle(LitheTheme.tertiaryText)
                        }
                        ForEach(providers) { LitheSettingsPill(verbatim: $0.title, wraps: true) }
                    }
                    ToolchainSettingsMetaLine("Definition", info: "This row comes from the tool definition of an enabled plugin. Lithe has no built-in tools.") {
                        LitheSettingsPill(verbatim: tool.pluginName, wraps: true)
                        Text(verbatim: tool.pluginID + " · " + tool.id)
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Open Plugins", action: openPlugins)
                            .buttonStyle(.litheNoPress)
                            .foregroundStyle(LitheTheme.accent)
                    }
                }
                .padding(.leading, Self.indent)
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var nameButton: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                LitheTreeDisclosureIcon(isExpanded: isExpanded)
                ToolchainSettingsIcon(name: tool.displayName, key: tool.pluginID + ":" + tool.id, token: tool.iconName)
                Text(verbatim: tool.displayName)
                    .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .accessibilityLabel(Text(verbatim: tool.displayName))
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }

    /// The highest-priority fact, in the order the steps below list them.
    @ViewBuilder private var summary: some View {
        if let pin = tool.pin {
            HStack(spacing: 6) {
                LitheSettingsPill(verbatim: pin.version, kind: .value)
                monospaced(ToolchainSettingsText.abbreviated(pin.home), size: 11, color: LitheTheme.tertiaryText)
            }
        } else if let file = tool.versionFiles.first {
            // "Version not queried" stays in the expanded step, so a narrow row only truncates the path.
            monospaced(file.path, size: 11.5, color: LitheTheme.primaryText)
        } else if let candidate = tool.candidate {
            monospaced(ToolchainSettingsText.abbreviated(candidate.executable), size: 11.5, color: LitheTheme.secondaryText)
        } else {
            Text("Not found")
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    @ViewBuilder private var badge: some View {
        if let pin = tool.pin {
            if pin.directory == tool.directoryID {
                LitheSettingsPill("Fixed", kind: .project)
            } else {
                LitheSettingsPill("Fixed in parent")
            }
        } else if !tool.versionFiles.isEmpty {
            LitheSettingsPill("Version file", kind: .project)
        } else if let candidate = tool.candidate {
            LitheSettingsPill(verbatim: ToolchainSettingsText.origin(candidate.origin))
        }
    }

    private var firstMatch: Int? {
        if tool.pin != nil { return 1 }
        if !tool.versionFiles.isEmpty { return 2 }
        if tool.candidate != nil { return 4 }
        return nil
    }

    private var pinnedStep: some View {
        ToolchainResolutionStep(
            number: 1, title: "Fixed",
            info: "A version saved for this directory on this computer. It applies first, also in the directories below.",
            isFirstMatch: firstMatch == 1, hasFact: tool.pin != nil
        ) {
            if let pin = tool.pin {
                Text(verbatim: pin.version)
                    .font(LitheTheme.uiFont(size: 12, weight: .medium, design: .monospaced))
                monospaced(ToolchainSettingsText.abbreviated(pin.home), size: 10.5, color: LitheTheme.secondaryText, truncation: .head)
                if pin.directory != tool.directoryID {
                    Text("From \(ToolchainSettingsText.directory(pin.directory))")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Text("Saved, not verified").font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.tertiaryText)
            } else {
                Text("None").foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-step:" + tool.id + ":pinned")
    }

    private var projectStep: some View {
        ToolchainResolutionStep(
            number: 2, title: "Project requirements",
            info: "Version files in this directory or its parents, watched by the version managers of this tool. The versions they ask for are not queried yet.",
            isFirstMatch: firstMatch == 2, hasFact: !tool.versionFiles.isEmpty
        ) {
            if tool.versionFiles.isEmpty {
                Text("No version file").foregroundStyle(LitheTheme.tertiaryText)
            } else {
                ForEach(tool.versionFiles, id: \.path) { file in
                    HStack(spacing: 4) {
                        if let title = providers.first(where: { file.providerIDs.contains($0.id) })?.title {
                            ToolchainSettingsTag(verbatim: title)
                        }
                        monospaced(file.path, size: 11, color: LitheTheme.primaryText, truncation: .head)
                    }
                }
                Text("Version not queried").font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-step:" + tool.id + ":project")
    }

    private var globalStep: some View {
        ToolchainResolutionStep(
            number: 3, title: "Global defaults",
            info: "The version a version manager uses outside any project. Version managers are not queried yet.",
            isFirstMatch: false, hasFact: false
        ) {
            Text("Not queried").foregroundStyle(LitheTheme.tertiaryText)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-step:" + tool.id + ":global")
    }

    private var automaticStep: some View {
        ToolchainResolutionStep(
            number: 4, title: "Automatic discovery",
            info: "The first executable found through the variables and commands this tool's plugin declares, using the login shell's PATH. Its version is not checked.",
            isFirstMatch: firstMatch == 4, hasFact: tool.candidate != nil
        ) {
            if let candidate = tool.candidate {
                ToolchainSettingsTag(verbatim: ToolchainSettingsText.origin(candidate.origin))
                monospaced(ToolchainSettingsText.abbreviated(candidate.executable), size: 11, color: LitheTheme.primaryText, truncation: .head)
                Text("Version not verified").font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.tertiaryText)
            } else {
                Text("Not found").foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-step:" + tool.id + ":automatic")
    }

    /// Step cards are narrow, so they cut from the front to keep the file or executable name.
    private func monospaced(_ text: String, size: CGFloat, color: Color, truncation: Text.TruncationMode = .middle) -> some View {
        Text(verbatim: text)
            .font(LitheTheme.uiFont(size: size, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(truncation)
            .textSelection(.enabled)
            .help(text)
    }
}

/// One source in the order a tool is resolved. The first source with a value is outlined;
/// sources without one are dimmed rather than hidden, so the order stays readable.
private struct ToolchainResolutionStep<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let info: LocalizedStringKey
    let isFirstMatch: Bool
    let hasFact: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(verbatim: String(number))
                    .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                    .foregroundStyle(isFirstMatch ? LitheTheme.accent : LitheTheme.secondaryText)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isFirstMatch ? LitheTheme.accent.opacity(0.14) : LitheTheme.settingsPill))
                Text(title)
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                LitheInfoTip(info)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) { content }
                .font(LitheTheme.uiFont(size: 11.5))
                .padding(.leading, 21)
        }
        .padding(EdgeInsets(top: 8, leading: 9, bottom: 9, trailing: 9))
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFirstMatch ? LitheTheme.accent.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFirstMatch ? LitheTheme.accent.opacity(0.45) : LitheTheme.settingsCardDivider, lineWidth: 1)
        )
        // The mark sits on the border, so it never takes the title's width in a narrow column.
        .overlay(alignment: .topTrailing) {
            if isFirstMatch {
                Text("First match")
                    .font(LitheTheme.uiFont(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(LitheTheme.accent))
                    .offset(x: -8, y: -7)
            }
        }
        .opacity(hasFact ? 1 : 0.6)
    }
}

// MARK: - Shared by both toolchain settings pages

/// A settings section whose title is any `Text`, so a directory path is shown verbatim
/// instead of being looked up as a localization key.
struct ToolchainSettingsGroup<Accessory: View, Content: View>: View {
    private let title: Text
    private let accessory: Accessory
    private let content: Content

    init(_ title: Text, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: LitheInfoTip.labelSpacing) {
                title
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                accessory
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            LitheSettingsCard { content }
        }
        .font(LitheTheme.settingsFont)
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ToolchainSettingsGroup where Accessory == EmptyView {
    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A compact card line: a short label with an optional ⓘ, then values that wrap as chips.
struct ToolchainSettingsLine<Content: View>: View {
    private let title: Text
    private let info: LocalizedStringKey?
    private let content: Content

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(Text(title), info: info, content: content)
    }

    init(verbatim title: String, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(Text(verbatim: title), info: info, content: content)
    }

    private init(_ title: Text, info: LocalizedStringKey?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: LitheInfoTip.labelSpacing) {
                title.lineLimit(1)
                if let info { LitheInfoTip(info) }
            }
            .frame(minWidth: 0, idealWidth: 120, maxWidth: 120, alignment: .leading)
            .padding(.top, 1)
            LitheChipFlowLayout(spacing: 6, clampsToWidth: true) { content }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(LitheTheme.uiFont(size: 12))
        .frame(minHeight: 30)
    }
}

/// A secondary line under an expanded row, in smaller type than a card line.
struct ToolchainSettingsMetaLine<Content: View>: View {
    private let title: LocalizedStringKey
    private let info: LocalizedStringKey?
    private let content: Content

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: LitheInfoTip.labelSpacing) {
                Text(title).lineLimit(1)
                if let info { LitheInfoTip(info) }
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(width: 108, alignment: .leading)
            .padding(.top, 2)
            LitheChipFlowLayout(spacing: 6, clampsToWidth: true) { content }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(LitheTheme.uiFont(size: 11.5))
        .frame(minHeight: 22)
    }
}

/// The small square-cornered label that names where a value comes from.
struct ToolchainSettingsTag: View {
    private let title: Text
    private let kind: LitheSettingsPill.Kind

    init(_ title: LocalizedStringKey, kind: LitheSettingsPill.Kind = .neutral) {
        self.title = Text(title)
        self.kind = kind
    }

    init(verbatim title: String, kind: LitheSettingsPill.Kind = .neutral) {
        self.title = Text(verbatim: title)
        self.kind = kind
    }

    var body: some View {
        title
            .font(LitheTheme.uiFont(size: 10, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(background))
    }

    private var foreground: Color {
        switch kind {
        case .neutral: LitheTheme.settingsPillText
        case .project: LitheTheme.settingsProjectPillText
        case .effect: LitheTheme.settingsEffectPillText
        case .value: LitheTheme.settingsValuePillText
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: LitheTheme.settingsPill
        case .project: LitheTheme.settingsProjectPill
        case .effect: LitheTheme.settingsEffectPill
        case .value: LitheTheme.settingsValuePill
        }
    }
}

/// A plugin-declared host icon, or the plugin-style letter avatar when there is none.
struct ToolchainSettingsIcon: View {
    let name: String
    /// Stable key for the avatar color.
    let key: String
    let token: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let path = token.flatMap({ WorkbenchContributionIcon.Asset.hostPaths[$0] }) {
                LitheIDEAIcon(resourcePath: path, size: size, fallbackSystemImage: "puzzlepiece.extension", preservesOriginalColors: true)
            } else {
                ProjectAvatarBadge(name: name, colorIndex: ProjectIdentityAppearance.colorIndex(forKey: key),
                                   size: size, text: PluginMarketplacePresentation.avatarText(for: name))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ToolchainSettingsText {
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// A workspace-relative directory as a reader names it.
    static func directory(_ id: String) -> String {
        id == "." ? L10n.string("the project root") : id
    }

    static func relative(_ path: String, to directory: String) -> String {
        directory == "." ? path : String(path.dropFirst(directory.count + 1))
    }

    /// Parents of a workspace-relative directory, nearest first, ending with the root.
    static func ancestors(of id: String) -> [String] {
        guard id != "." else { return [] }
        var parts = id.split(separator: "/").dropLast()
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
        return result + ["."]
    }

    static func origin(_ origin: ToolchainSettingsSnapshot.Candidate.Origin) -> String {
        switch origin {
        case .path: "PATH"
        case let .variable(name): "$" + name
        }
    }
}

/// Leading content with trailing badges on the same line while the leading part keeps
/// `minimumLeadingWidth`; on a narrower line the badges move under it.
struct ToolchainEdgeLayout: Layout {
    var minimumLeadingWidth: CGFloat = 220
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 4
    var trailingIndent: CGFloat = 0

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        let offset = max(0, (bounds.height - arrangement.size.height) / 2)
        for (index, frame) in arrangement.frames.enumerated() where subviews.indices.contains(index) {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + offset + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
        guard let leading = subviews.first else { return Arrangement(frames: [], size: .zero) }
        guard subviews.count > 1 else {
            let size = leading.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let line = CGSize(width: width ?? size.width, height: size.height)
            return Arrangement(frames: [CGRect(origin: .zero, size: line)], size: line)
        }
        let ideal = leading.sizeThatFits(.unspecified)
        let badge = subviews[1].sizeThatFits(.unspecified)
        let room = (width ?? .infinity) - badge.width - spacing
        if room >= min(ideal.width, minimumLeadingWidth) {
            let lineWidth = width ?? ideal.width + spacing + badge.width
            let leadingWidth = width == nil ? ideal.width : room
            let size = width == nil ? ideal : leading.sizeThatFits(ProposedViewSize(width: room, height: nil))
            let height = max(size.height, badge.height)
            return Arrangement(frames: [
                CGRect(x: 0, y: (height - size.height) / 2, width: leadingWidth, height: size.height),
                CGRect(x: lineWidth - badge.width, y: (height - badge.height) / 2, width: badge.width, height: badge.height)
            ], size: CGSize(width: lineWidth, height: height))
        }
        let lineWidth = width ?? ideal.width
        let size = leading.sizeThatFits(ProposedViewSize(width: lineWidth, height: nil))
        let badgeWidth = min(badge.width, max(0, lineWidth - trailingIndent))
        let badgeHeight = subviews[1].sizeThatFits(ProposedViewSize(width: badgeWidth, height: nil)).height
        return Arrangement(frames: [
            CGRect(x: 0, y: 0, width: lineWidth, height: size.height),
            CGRect(x: trailingIndent, y: size.height + lineSpacing, width: badgeWidth, height: badgeHeight)
        ], size: CGSize(width: lineWidth, height: size.height + lineSpacing + badgeHeight))
    }
}

/// Equal columns for the resolution steps: as many as fit, reduced to a divisor of the
/// count so no row is left half empty; every step in a row is as tall as the tallest.
struct ToolchainStepGridLayout: Layout {
    var minimumColumnWidth: CGFloat = 150
    var spacing: CGFloat = 8

    private struct Grid {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = grid(width: proposal.width, subviews: subviews)
        let columns = CGFloat(grid.columns)
        let width = proposal.width ?? grid.columnWidth * columns + spacing * max(columns - 1, 0)
        let height = grid.rowHeights.reduce(0, +) + spacing * CGFloat(max(grid.rowHeights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in grid.rowHeights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard subviews.indices.contains(index) else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.columnWidth + spacing), y: y),
                    proposal: ProposedViewSize(width: grid.columnWidth, height: height)
                )
            }
            y += height + spacing
        }
    }

    private func grid(width: CGFloat?, subviews: Subviews) -> Grid {
        let count = subviews.count
        guard count > 0 else { return Grid(columns: 1, columnWidth: 0, rowHeights: []) }
        let columns: Int
        let columnWidth: CGFloat
        if let width, width.isFinite {
            let fitting = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
            columns = (1...min(fitting, count)).last(where: { count.isMultiple(of: $0) }) ?? 1
            columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        } else {
            columns = count
            columnWidth = max(minimumColumnWidth, subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
        }
        let rowHeights = stride(from: 0, to: count, by: columns).map { start in
            subviews[start..<min(start + columns, count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
        return Grid(columns: columns, columnWidth: columnWidth, rowHeights: rowHeights)
    }
}

/// Load errors and loader diagnostics, above whichever content the page shows.
struct ToolchainSettingsSnapshotNotice: View {
    @ObservedObject var feature: ToolchainSettingsFeatureModel

    var body: some View {
        if feature.loadError != nil || !feature.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if let error = feature.loadError {
                    line(color: LitheTheme.error) {
                        Text("The environment snapshot could not be read. Refresh to try again.")
                        if let reason = (error as? LocalizedError)?.errorDescription {
                            Text(verbatim: reason).foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }
                ForEach(Array(feature.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    line(color: LitheTheme.settingsNoticeText) { Text(verbatim: diagnostic) }
                }
            }
            .font(LitheTheme.uiFont(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LitheTheme.settingsNoticeBackground))
            .padding(.bottom, 14)
        }
    }

    private func line<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(LitheTheme.uiFont(size: 11))
            VStack(alignment: .leading, spacing: 2) { content() }
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}

/// Shown when there is no project directory to inspect: no project, a remote one, or a failed read.
struct ToolchainSettingsEmptyState: View {
    @ObservedObject var feature: ToolchainSettingsFeatureModel
    var openPlugins: () -> Void
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolchainSettingsSnapshotNotice(feature: feature)
            if feature.loadError != nil {
                Button("Refresh", action: refresh)
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(feature.isLoading)
            } else if feature.workspaceURL == nil {
                LitheSettingsCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No project environment is available.")
                                .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                            Text("Open a project and enable a plugin that defines tools to inspect its environment.")
                                .font(LitheTheme.uiFont(size: 11.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Open Plugins", action: openPlugins).buttonStyle(LitheActionButtonStyle())
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
