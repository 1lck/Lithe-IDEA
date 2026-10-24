import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LitheDatabaseModule

private struct DatabaseTableContextAction {
    enum Kind { case clear, drop }
    let profile: DatabaseProfile
    let table: String
    let kind: Kind

    var title: LocalizedStringKey { kind == .clear ? "Clear Table" : "Delete Table" }
    var message: LocalizedStringKey {
        kind == .clear ? "All rows in this table will be deleted." : "This table and all of its data will be permanently deleted."
    }
}

private struct DatabaseTreePath: Hashable {
    let profileID: UUID
    let database: String

    init(_ profile: DatabaseProfile) {
        profileID = profile.id
        database = profile.database
    }
}

private enum DatabaseTreeSelection: Hashable {
    case folder(UUID)
    case connection(UUID)
    case database(DatabaseTreePath)
    case table(DatabaseTreeTableKey)
    case objects(DatabaseTreePath, DatabaseObjectKind)
}

private enum DatabaseFolderMoveTarget {
    case connection(UUID)
    case folder(UUID)
}

struct DatabaseSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var treeSelection: DatabaseTreeSelection?
    @State private var showsConnectionEditor = false
    @State private var editingProfile: DatabaseProfile?
    @State private var connectionEditorPresentationID = UUID()
    @State private var searchText = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    /// Folders start expanded, while this set records the user's explicit
    /// collapsed state. Keeping the negative state avoids refreshes reopening
    /// folders behind the user's back.
    @State private var collapsedFolderIDs: Set<UUID> = []
    @State private var collapsedObjectKinds: [DatabaseTreePath: Set<DatabaseObjectKind>] = [:]
    @State private var expandedProfileIDs: Set<UUID> = []
    @State private var databaseScopeProfileID: UUID?
    @State private var databaseScopeSelection: [String]?
    @State private var hoveredScopeProfileID: UUID?
    @State private var collapsedDatabaseProfileIDs: Set<UUID> = []
    @State private var expandedDatabasePaths: Set<DatabaseTreePath> = []
    @State private var expandedTableKeys: Set<DatabaseTreeTableKey> = []
    @State private var targetedFolderID: UUID?
    @State private var isRootDropTarget = false
    @State private var kindFilter: DatabaseKind?
    @State private var connectionSort = DatabaseConnectionSort.name
    @State private var showsFolderEditor = false
    @State private var showsFolderDestination = false
    @State private var folderMoveTarget: DatabaseFolderMoveTarget?
    @State private var editingFolder: DatabaseConnectionFolder?
    @State private var creatingFolderParentID: UUID?
    @State private var newConnectionFolderID: UUID?
    @State private var newConnectionKind: DatabaseKind = .mysql
    @State private var folderPendingDeletion: DatabaseConnectionFolder?
    @State private var showsFolderDeletionConfirmation = false
    @State private var profilePendingDeletion: DatabaseProfile?
    @State private var showsProfileDeletionConfirmation = false
    @State private var exportDocument: DatabaseTransferDocument?
    @State private var temporaryExportURL: URL?
    @State private var exportFormat = DatabaseTransferFormat.csv
    @State private var importFormat = DatabaseTransferFormat.csv
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var pendingImportData: Data?
    @State private var pendingImportURL: URL?
    @State private var pendingImportFormat: DatabaseTransferFormat?
    @State private var showsProtectedImportConfirmation = false
    @State private var pendingTableAction: DatabaseTableContextAction?
    @State private var showsTableActionConfirmation = false
    @State private var pendingRedisProfile: DatabaseProfile?
    @State private var showsRedisFlushConfirmation = false
    @State private var showsDBXImporter = false
    @State private var showsDBXImportSheet = false
    @State private var dbxImportData: Data?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Database") {
                LitheSidebarHideButton(title: "Database") {
                    model.workbenchFeature.setVisibility(.database, isVisible: false)
                }
            }
            LitheToolWindowHeaderDivider()
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        LitheMenu { newMenuItems } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/add.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                                .overlay {
                                    // IDEA ActionButtonLook.paintDownArrow offsets the 16pt overlay by (1, 1).
                                    LitheIDEAIcon(resourcePath: "expui/general/dropdown.svg",
                                        size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                                        .offset(x: 1, y: 1).allowsHitTesting(false)
                                }
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("New"))
                            .accessibilityLabel("New")
                        Button { presentFolderEditor() } label: {
                            LitheIDEAIcon(resourcePath: "expui/actions/newFolder.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("New Folder"))
                            .accessibilityLabel("New Folder")
                        Button { showsDBXImporter = true } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/import.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("Import connections from DBX"))
                            .accessibilityLabel("Import connections from DBX")
                        Button { collapseAll() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/collapseAll.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("Collapse all"))
                            .accessibilityLabel("Collapse all")
                        Button { refreshSelection() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/refresh.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton(isEnabled: canRefreshSelection)
                            .workbenchHoverHelp(Text("Refresh selected structure"))
                            .accessibilityLabel("Refresh selected structure")
                        Button {
                            if let profile = feature.selectedProfile { openSQLQuery(profile) }
                        } label: {
                            LitheIDEAIcon(resourcePath: "expui/fileTypes/shell.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton(isEnabled: feature.selectedProfile?.kind.isSQLDatabase == true)
                            .workbenchHoverHelp(Text("New Query"))
                            .accessibilityLabel("New Query")
                        Button {
                            feature.workspaceSection = .history
                            model.openDatabaseWorkspace()
                        } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/history.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("SQL History"))
                            .accessibilityLabel("SQL History")
                        Button { model.openDatabaseWorkspace(overview: true) } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/previewVertically.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton().workbenchHoverHelp(Text("Database Overview"))
                        .accessibilityLabel("Database Overview")
                        Button { searchFocused = false; showsSearch.toggle(); searchText = "" } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/search.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                        .buttonStyle(LitheIconButtonStyle(
                            size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: showsSearch
                        ))
                        .workbenchHoverHelp(Text("Search connections"))
                        .accessibilityLabel("Search connections")
                    }
                }
                HStack(spacing: 2) {
                    LitheMenu {
                        LitheContextMenuItem.action("All database types", checked: kindFilter == nil) { kindFilter = nil }
                        LitheContextMenuItem.separator
                        for kind in DatabaseKind.allCases {
                            LitheContextMenuItem.action(
                                kind.displayName, icon: AnyView(DatabaseBrandIcon(kind: kind, size: 16)), checked: kindFilter == kind
                            ) {
                                kindFilter = kind
                            }
                        }
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/filter.svg",
                                      size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                    }
                    .buttonStyle(LitheIconButtonStyle(
                        size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: kindFilter != nil
                    ))
                    .workbenchHoverHelp(Text("Filter database type"))
                    .accessibilityLabel("Filter database type")

                    LitheMenu {
                        for mode in DatabaseConnectionSort.allCases {
                            LitheContextMenuItem.action(mode.menuTitle, checked: mode == connectionSort) {
                                connectionSort = mode
                            }
                        }
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/sortBy.svg",
                                      size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .workbenchHoverHelp(Text("Sort connections"))
                    .accessibilityLabel("Sort connections")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 10)

            if showsSearch {
                LitheSearchField("Search connections", text: $searchText, focus: $searchFocused)
                    .onExitCommand { showsSearch = false; searchText = "" }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }

            if feature.profiles.isEmpty && feature.folders.isEmpty {
                emptyConnections
                    .contentShape(Rectangle())
                    .litheContextMenu { panelContextMenu }
            } else {
                LitheTreeList(nodes: connectionNodes, selection: Binding(
                    get: { treeSelection.map(treeNodeID) },
                    set: { if $0 == nil { treeSelection = nil } }
                ))
                .litheContextMenu { panelContextMenu }
                .dropDestination(for: String.self) { items, _ in
                    moveDroppedProfile(items, to: nil)
                } isTargeted: { isRootDropTarget = $0 }
                .background(isRootDropTarget ? LitheTheme.accent.opacity(0.18) : .clear)
            }
            if feature.isLoading { ProgressView().controlSize(.small).padding(8) }
        }
        .workbenchHoverTooltipScope()
        .background(LitheCenteredPopup(isPresented: $showsConnectionEditor, dialogTitle: String(localized: editingProfile == nil ? "Add Database Connection" : "Edit Database Connection"), resizesToContent: true) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor, profile: editingProfile, defaultFolderID: newConnectionFolderID, defaultKind: newConnectionKind)
                .id(connectionEditorPresentationID)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        })
        .background(LitheCenteredPopup(isPresented: $showsFolderEditor, focusFirstTextField: true, resizesToContent: true) {
            DatabaseFolderEditor(isPresented: $showsFolderEditor, folder: editingFolder, parentID: creatingFolderParentID, moveTarget: folderMoveTarget) {
                if let target = folderMoveTarget {
                    switch target {
                    case .connection(let id): revealFolder(feature.profiles.first(where: { $0.id == id })?.folderID)
                    case .folder(let id): revealFolder(feature.folders.first(where: { $0.id == id })?.parentID)
                    }
                } else { revealFolder(creatingFolderParentID) }
                folderMoveTarget = nil
            }
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        })
        .background(LitheCenteredPopup(isPresented: $showsDBXImportSheet, dialogTitle: String(localized: "Import Connections from DBX")) {
            if let dbxImportData {
                DatabaseDBXImportSheet(isPresented: $showsDBXImportSheet, data: dbxImportData)
                    .environment(\.locale, model.settings.language.locale)
                    .id(model.settings.language)
            }
        })
        .onChange(of: showsDBXImportSheet) { shown in
            if !shown { dbxImportData = nil }
        }
        .background(LitheDropdownPopover(centersMenu: true, isPresented: $showsFolderDestination, items: folderDestinationItems) { EmptyView() }
            .environment(\.locale, model.settings.language.locale))
        .alert("Remove folder?", isPresented: $showsFolderDeletionConfirmation, presenting: folderPendingDeletion) { folder in
            Button("Remove Folder", role: .destructive) {
                feature.removeFolder(folder)
                folderPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: { _ in
            Text("Removing this folder keeps its contents and moves them to the parent folder or root.")
        }
        .alert("Remove connection?", isPresented: $showsProfileDeletionConfirmation, presenting: profilePendingDeletion) { profile in
            Button("Remove Connection", role: .destructive) {
                model.removeDatabaseConnection(profile)
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { profilePendingDeletion = nil }
        } message: { profile in
            Text("Remove \(profile.name)? Its saved password, history, and backup schedule will also be removed.")
        }
        .confirmationDialog("Confirm table action", isPresented: $showsTableActionConfirmation, presenting: pendingTableAction) { action in
            Button(action.title, role: .destructive) { executeTableAction(action) }
            Button("Cancel", role: .cancel) { pendingTableAction = nil }
        } message: { action in
            Text(action.message)
        }
        .confirmationDialog("Clear Redis database?", isPresented: $showsRedisFlushConfirmation, presenting: pendingRedisProfile) { profile in
            Button("Clear Current Redis DB", role: .destructive) {
                pendingRedisProfile = nil
                Task {
                    guard await feature.selectDatabaseContext(profile) else { return }
                    _ = await feature.flushRedisDatabase(confirmed: true)
                }
            }
            Button("Cancel", role: .cancel) { pendingRedisProfile = nil }
        } message: { _ in
            Text("All keys in the current Redis database will be permanently deleted.")
        }
        .confirmationDialog("Confirm Database Import", isPresented: $showsProtectedImportConfirmation, titleVisibility: .visible) {
            Button("Import and Modify Database", role: .destructive) { performPendingImport(confirmed: true) }
            Button("Cancel", role: .cancel) { discardPendingImport() }
        } message: {
            Text("Restoring a SQL backup or importing into a protected connection can modify database data. A recovery snapshot will be created first.")
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: exportFormat.contentType, defaultFilename: exportFilename) { result in
            if case let .failure(error) = result { feature.errorMessage = error.localizedDescription }
            if let temporaryExportURL { feature.removeTemporaryFile(temporaryExportURL) }
            temporaryExportURL = nil; exportDocument = nil
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [importFormat.contentType]) { result in
            importFile(result)
        }
        .fileImporter(isPresented: $showsDBXImporter, allowedContentTypes: [.json]) { result in
            importDBXFile(result)
        }
        .onChange(of: feature.selectedProfileID) { selectedID in
            if let selectedID, treeSelection != .connection(selectedID) {
                expandedProfileIDs.insert(selectedID)
            }
        }
    }

    private func importDBXFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            dbxImportData = try feature.readImportData(from: url)
            showsDBXImportSheet = true
        } catch {
            feature.errorMessage = error.localizedDescription
        }
    }

    private var emptyConnections: some View {
        GeometryReader { geometry in
            // IDEA Community c7f91397 StatusText places empty text above center.
            Text("No database connections")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.searchFieldPlaceholder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 3)
        }
    }

    private var newMenuItems: [LitheContextMenuItem] {
        let folderID: UUID? = if case .folder(let id) = treeSelection { id } else { nil }
        return [
            .action("Query Console", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/fileTypes/shell.svg",
                size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true)),
                isEnabled: feature.selectedProfile?.kind.isSQLDatabase == true) {
                    if let profile = feature.selectedProfile { openSQLQuery(profile) }
                },
            .submenu("Data Source", icon: AnyView(LitheIDEAIcon(resourcePath: "database/expui/dbms@20x20.svg",
                size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true)), items: DatabaseKind.allCases.map { kind in
                .action(kind.displayName, localizesTitle: false,
                    icon: AnyView(DatabaseBrandIcon(kind: kind, size: LitheDropdownMetrics.iconSize))) {
                    presentConnectionEditor(defaultFolderID: folderID, defaultKind: kind)
                }
            }),
            .action("Folder", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/nodes/folder.svg",
                size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true))) {
                presentFolderEditor(parentID: folderID)
            },
            .separator,
            .action("Import Data Sources…", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/import.svg",
                size: LitheDropdownMetrics.iconSize, preservesOriginalColors: true))) { showsDBXImporter = true }
        ]
    }

    private var panelContextMenu: [LitheContextMenuItem] {
        [
            .submenu("New", items: newMenuItems),
            .action("Import connections from DBX") { showsDBXImporter = true },
            .separator,
            .action("Refresh selected structure", isEnabled: canRefreshSelection) { refreshSelection() },
            .action("Collapse all", isEnabled: !feature.profiles.isEmpty || !feature.folders.isEmpty) { collapseAll() }
        ]
    }

    private func treeNodeID(_ selection: DatabaseTreeSelection) -> String {
        switch selection {
        case .folder(let id): return "folder:\(id)"
        case .connection(let id): return "profile:\(id)"
        case .database(let path): return "database:\(path.profileID):\(path.database)"
        case .table(let key): return "table:\(key.profileID):\(key.database):\(key.table)"
        case .objects(let path, let kind): return "objects:\(path.profileID):\(path.database):\(kind.rawValue)"
        }
    }

    private var connectionNodes: [LitheTreeListNode] {
        var nodes = rootFolders.filter(isFolderVisible).map(folderNode)
        nodes += unfiledProfiles.map(profileNode)
        if nodes.isEmpty && (!searchQuery.isEmpty || kindFilter != nil) {
            nodes.append(LitheTreeListNode(id: "no-matches", isSelectable: false) {
                Text("No connections match your search.").foregroundStyle(LitheTheme.tertiaryText)
            })
        }
        return nodes
    }

    private func folderNode(_ folder: DatabaseConnectionFolder) -> LitheTreeListNode {
        let expanded = !searchQuery.isEmpty || !collapsedFolderIDs.contains(folder.id)
        let count = recursiveProfileCount(in: folder)
        return LitheTreeListNode(
            id: treeNodeID(.folder(folder.id)), isExpanded: expanded,
            disclosureLabel: "\(expanded ? String(localized: "Collapse Folder") : String(localized: "Expand Folder")) \(folder.name)",
            accessibilityTitle: folder.name,
            onExpansion: { value in if value != expanded { toggleFolder(folder) } },
            onSelect: { treeSelection = .folder(folder.id) },
            menu: {
                [
                    .action(expanded ? "Collapse Folder" : "Expand Folder") { toggleFolder(folder) },
                    .action("New Connection") { presentConnectionEditor(defaultFolderID: folder.id) },
                    .action("New Subfolder") { presentFolderEditor(parentID: folder.id) },
                    .action("Rename Folder") { presentFolderEditor(folder: folder) },
                    .submenu("Move", items: [
                        .action("To Folder…") { presentFolderMove(.folder(folder.id)) },
                        .action("To Top Level", isEnabled: folder.parentID != nil) {
                            feature.moveFolder(folder.id, toParent: nil)
                        }
                    ]),
                    .action("Remove Folder", role: .destructive) {
                        folderPendingDeletion = folder
                        showsFolderDeletionConfirmation = true
                    }
                ]
            }
        ) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                LitheIcon(kind: .folder, size: LitheTheme.Metrics.treeIconSize)
                Text(folder.name).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").foregroundStyle(LitheTheme.tertiaryText) }
            }
            .contentShape(Rectangle())
            .background(targetedFolderID == folder.id ? LitheTheme.accent.opacity(0.18) : .clear)
            .dropDestination(for: String.self) { items, _ in moveDroppedProfile(items, to: folder.id) }
                isTargeted: { targetedFolderID = $0 ? folder.id : nil }
        } children: {
            visibleProfiles(in: folder).map(profileNode)
                + childFolders(of: folder).filter(isFolderVisible).map(folderNode)
        }
    }

    private func profileNode(_ profile: DatabaseProfile) -> LitheTreeListNode {
        let expanded = expandedProfileIDs.contains(profile.id)
        let tree = feature.databaseTrees[profile.id]
        return LitheTreeListNode(
            id: treeNodeID(.connection(profile.id)), isExpanded: expanded,
            disclosureLabel: String(localized: expanded ? "Collapse connection" : "Expand connection"),
            accessibilityTitle: profile.name,
            onExpansion: { value in if value != expanded { toggleProfile(profile) } },
            onSelect: { treeSelection = .connection(profile.id) },
            onClick: { selectProfile(profile, expand: false) },
            menu: { connectionContextMenu(profile) }
        ) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                DatabaseBrandIcon(kind: profile.kind, size: LitheTheme.Tree.iconSize)
                    .overlay(alignment: .bottomTrailing) { connectionStatusIndicator(profile) }
                Text(profile.name).lineLimit(1)
                if profile.productionProtection {
                    Image(systemName: "shield.fill")
                        .font(LitheTheme.uiFont(size: 8)).foregroundStyle(LitheTheme.warning)
                }
                if (profile.kind == .mysql || profile.kind == .mariadb), let tree,
                   tree.state == .ready || !tree.names.isEmpty {
                    scopeButton(profile, names: tree.names)
                }
            }
            .draggable(profile.id.uuidString)
            .task(id: expanded) {
                if expanded && (profile.kind == .mysql || profile.kind == .mariadb) {
                    await feature.loadDatabaseTree(for: profile.id)
                }
            }
        } children: {
            if profile.kind == .mysql || profile.kind == .mariadb {
                return mysqlDatabaseNodes(profile)
            }
            return feature.selectedProfileID == profile.id ? profileObjectNodes(profile) : []
        }
    }

    private func scopeButton(_ profile: DatabaseProfile, names: [String]) -> some View {
        let selected = feature.visibleDatabaseNames(for: profile.id).count
        return Button {
            treeSelection = .connection(profile.id)
            if databaseScopeProfileID == profile.id { applyDatabaseScope(for: profile.id) }
            else {
                databaseScopeSelection = profile.visibleDatabases
                databaseScopeProfileID = profile.id
            }
        } label: {
            Text(verbatim: " \(selected) of \(names.count) ")
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .frame(height: LitheTheme.Tree.rowHeight)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 3)
                    let hovered = hoveredScopeProfileID == profile.id
                    shape.fill(hovered ? LitheTheme.toolbarHoverBackground : .clear)
                        .overlay(shape.stroke(hovered ? .clear : LitheTheme.toolbarHoverBackground, lineWidth: 1))
                }
        }
        .buttonStyle(.litheNoPress)
        .fixedSize()
        .accessibilityLabel("Select databases")
        .accessibilityValue(Text(verbatim: "\(selected) of \(names.count)"))
        .accessibilityIdentifier("database-schema-scope")
        .onHover { hoveredScopeProfileID = $0 ? profile.id : nil }
        .lithePointer()
        .litheDropdown(isPresented: Binding(
            get: { databaseScopeProfileID == profile.id },
            set: { databaseScopeProfileID = $0 ? profile.id : nil }
        ), searchOnTyping: true, onAccept: { applyDatabaseScope(for: profile.id) }) {
            DatabaseSchemaSelector(profileID: profile.id, names: names, selection: $databaseScopeSelection) {
                applyDatabaseScope(for: profile.id)
            }
            .environmentObject(feature)
            .environment(\.locale, model.settings.language.locale)
        }
    }

    private func applyDatabaseScope(for profileID: UUID) {
        if feature.setVisibleDatabases(databaseScopeSelection, for: profileID) { databaseScopeProfileID = nil }
    }

    private func mysqlDatabaseNodes(_ profile: DatabaseProfile) -> [LitheTreeListNode] {
        let tree = feature.databaseTrees[profile.id] ?? DatabaseConnectionTree()
        var nodes = statusNodes(tree.state, id: "profile:\(profile.id):status") {
            Task { await feature.loadDatabaseTree(for: profile.id, force: true) }
        }
        nodes += feature.visibleDatabaseNames(for: profile.id).map { database in
            databaseNode(databaseProfile(profile, database: database), snapshot: tree.databases[database])
        }
        if tree.state == .ready && tree.names.isEmpty {
            nodes.append(LitheTreeListNode(id: "profile:\(profile.id):empty", isSelectable: false) {
                Text("No accessible databases").foregroundStyle(LitheTheme.Tree.secondaryText)
            })
        } else if tree.state == .ready && feature.visibleDatabaseNames(for: profile.id).isEmpty {
            nodes.append(LitheTreeListNode(id: "profile:\(profile.id):none-selected", isSelectable: false) {
                Text("No schemas selected")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .accessibilityIdentifier("database-no-schemas-selected")
            })
        }
        return nodes
    }

    private func databaseProfile(_ profile: DatabaseProfile, database: String) -> DatabaseProfile {
        var target = profile
        target.database = database
        return target
    }

    private func databaseNode(_ profile: DatabaseProfile, snapshot: DatabaseTreeDatabase? = nil) -> LitheTreeListNode {
        let path = DatabaseTreePath(profile)
        let expanded = profile.kind == .mysql || profile.kind == .mariadb
            ? expandedDatabasePaths.contains(path) : !collapsedDatabaseProfileIDs.contains(profile.id)
        return LitheTreeListNode(
            id: treeNodeID(.database(path)), isExpanded: expanded,
            disclosureLabel: "\(String(localized: expanded ? "Collapse database" : "Expand database")) \(profile.database.isEmpty ? (profile.kind == .mongodb ? "admin" : String(localized: "Default database")) : profile.database)",
            accessibilityTitle: profile.database.isEmpty
                ? (profile.kind == .mongodb ? "admin" : String(localized: "Default database")) : profile.database,
            onExpansion: { value in if value != expanded { toggleDatabase(profile) } },
            onSelect: { treeSelection = .database(path) },
            menu: { profile.kind == .mongodb ? mongoDatabaseContextMenu(profile) : databaseContextMenu(profile) }
        ) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                LitheIDEAIcon(resourcePath: "database/expui/schema.svg", size: LitheTheme.Tree.iconSize,
                              preservesOriginalColors: true)
                if profile.database.isEmpty { Text(profile.kind == .mongodb ? "admin" : "Default database") }
                else { Text(verbatim: profile.database) }
            }
            .task(id: expanded) {
                if expanded && (profile.kind == .mysql || profile.kind == .mariadb) {
                    await feature.loadDatabaseTree(profile.database, for: profile.id)
                }
            }
        } children: {
            if profile.kind == .mysql || profile.kind == .mariadb {
                let current = snapshot ?? DatabaseTreeDatabase()
                var nodes = statusNodes(current.state, id: "\(treeNodeID(.database(path))):status") {
                    Task { await feature.loadDatabaseTree(profile.database, for: profile.id, force: true) }
                }
                if current.state == .ready || !current.tables.isEmpty || !current.objects.isEmpty {
                    nodes += databaseObjectNodes(profile, snapshot: current)
                }
                return nodes
            }
            return databaseObjectNodes(profile)
        }
    }

    private func profileObjectNodes(_ profile: DatabaseProfile) -> [LitheTreeListNode] {
        if profile.kind.supportsDataGrid { return [databaseNode(profile)] }
        let prefix = "profile:\(profile.id)"
        if profile.kind == .redis {
            return [LitheTreeListNode(id: prefix + ":redis", menu: { redisDatabaseContextMenu(profile) }) {
                sidebarLeaf(title: "Redis database", detail: profile.database.isEmpty ? "0" : profile.database,
                            symbol: "", count: feature.redisKeys.count, indent: 0)
            }]
        }
        return [
            LitheTreeListNode(id: prefix + ":configs", menu: { nacosContextMenu(profile) }) {
                sidebarLeaf(title: "Configurations", symbol: "", count: feature.nacosConfigs.count, indent: 0)
            },
            LitheTreeListNode(id: prefix + ":services", menu: { nacosContextMenu(profile) }) {
                sidebarLeaf(title: "Services", symbol: "", count: feature.nacosServices.count, indent: 0)
            }
        ]
    }

    private func databaseObjectNodes(_ profile: DatabaseProfile, snapshot: DatabaseTreeDatabase? = nil) -> [LitheTreeListNode] {
        let tables = snapshot?.tables ?? feature.tables
        let objects = snapshot?.objects ?? feature.objects
        let loading = snapshot.map { $0.state == .loading } ?? feature.isLoading
        var nodes = [objectSectionNode(.tables, profile: profile, count: tables.count) {
            if tables.isEmpty && !loading {
                return [LitheTreeListNode(id: "\(profile.id):\(profile.database):empty-tables", isSelectable: false) {
                    Text(profile.kind == .mongodb ? "No collections yet" : "No tables yet")
                        .foregroundStyle(LitheTheme.Tree.secondaryText)
                }]
            }
            return tables.map { tableNode(profile, table: $0) }
        }]
        if profile.kind != .mongodb {
            for kind in DatabaseObjectKind.allCases where kind != .tables {
                let entries = objects[kind] ?? []
                if !entries.isEmpty {
                    nodes.append(objectSectionNode(kind, profile: profile, count: entries.count) {
                        entries.enumerated().map { index, row in
                            LitheTreeListNode(id: "\(profile.id):\(profile.database):\(kind.rawValue):\(index)") {
                                Text(objectLabel(row)).lineLimit(1)
                            }
                        }
                    })
                }
            }
        }
        return nodes
    }

    private func objectSectionNode(_ kind: DatabaseObjectKind, profile: DatabaseProfile, count: Int,
                                   children: @escaping () -> [LitheTreeListNode]) -> LitheTreeListNode {
        let path = DatabaseTreePath(profile)
        let expanded = !(collapsedObjectKinds[path] ?? []).contains(kind)
        return LitheTreeListNode(
            id: treeNodeID(.objects(path, kind)), isExpanded: expanded,
            disclosureLabel: "\(String(localized: expanded ? "Collapse" : "Expand")) \(kind.title)",
            accessibilityTitle: kind == .tables && profile.kind == .mongodb
                ? String(localized: "Collections") : kind.title,
            onExpansion: { value in if value != expanded { toggleObjectSection(kind, profile: profile) } },
            onSelect: { treeSelection = .objects(path, kind) },
            menu: {
                if kind == .tables {
                    return profile.kind == .mongodb
                        ? [.action("Refresh Collections") { refresh(profile) }] : tableGroupContextMenu(profile)
                }
                return []
            }, content: {
            sidebarLeaf(title: LocalizedStringKey(kind == .tables && profile.kind == .mongodb ? "Collections" : kind.title),
                        symbol: "database/expui/objectGroup.svg", count: count, indent: 0)
            }, children: children
        )
    }

    private func tableNode(_ profile: DatabaseProfile, table: String) -> LitheTreeListNode {
        let key = DatabaseTreeTableKey(profileID: profile.id, database: profile.database, table: table)
        let expanded = expandedTableKeys.contains(key)
        return LitheTreeListNode(
            id: treeNodeID(.table(key)), isExpanded: expanded, activatesOnDoubleClick: true,
            disclosureLabel: "\(String(localized: expanded ? "Collapse table" : "Expand table")) \(table)",
            accessibilityTitle: table,
            onExpansion: { value in
                if value { expandedTableKeys.insert(key) }
                else {
                    expandedTableKeys.remove(key)
                    feature.cancelTableTreeLoad(key)
                }
            },
            onSelect: { treeSelection = .table(key) },
            onActivate: { openTable(profile, table: table, section: .data) },
            menu: {
                profile.kind == .mongodb
                    ? mongoCollectionContextMenu(profile, collection: table) : tableContextMenu(profile, table: table)
            }
        ) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                LitheIDEAIcon(resourcePath: profile.kind == .mongodb
                    ? "database/expui/collection.svg" : "database/expui/table.svg",
                    size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                Text(table).lineLimit(1)
            }
            .accessibilityAction(named: Text("Open")) { openTable(profile, table: table, section: .data) }
            .task(id: expanded) {
                if expanded { await feature.loadTableTree(key) }
            }
        } children: {
            let metadata = feature.tableTrees[key] ?? DatabaseTreeTable()
            var nodes = statusNodes(metadata.state, id: "\(treeNodeID(.table(key))):status") {
                Task { await feature.loadTableTree(key, force: true) }
            }
            if metadata.state == .ready {
                nodes.append(LitheTreeListNode(id: "\(treeNodeID(.table(key))):columns") {
                    sidebarLeaf(title: profile.kind == .mongodb ? "Fields" : "Columns",
                                symbol: "database/expui/column.svg", count: metadata.columns.count, indent: 0)
                })
                nodes.append(LitheTreeListNode(id: "\(treeNodeID(.table(key))):indexes") {
                    sidebarLeaf(title: "Indexes", symbol: "database/expui/goldKey.svg",
                                count: metadata.indexes.count, indent: 0)
                })
                if profile.kind != .mongodb {
                    nodes.append(LitheTreeListNode(id: "\(treeNodeID(.table(key))):foreign-keys") {
                        sidebarLeaf(title: "Foreign Keys", symbol: "database/expui/blueKey.svg",
                                    count: metadata.foreignKeys.count, indent: 0)
                    })
                }
            }
            return nodes
        }
    }

    private func statusNodes(_ state: DatabaseTreeLoadState, id: String, retry: @escaping () -> Void) -> [LitheTreeListNode] {
        switch state {
        case .ready: return []
        case .idle, .loading:
            return [LitheTreeListNode(id: id, isSelectable: false) {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                }
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .accessibilityLabel("Loading…")
            }]
        case .failed(let message):
            return [LitheTreeListNode(id: id, onClick: retry) {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Tree.iconSize)
                    Text("Retry")
                }
                .help(message)
                .accessibilityLabel(Text(verbatim: message))
            }]
        }
    }

    private func toggleFolder(_ folder: DatabaseConnectionFolder) {
        collapsedFolderIDs.formSymmetricDifference([folder.id])
    }

    private func toggleDatabase(_ profile: DatabaseProfile) {
        if profile.kind == .mysql || profile.kind == .mariadb {
            let path = DatabaseTreePath(profile)
            expandedDatabasePaths.formSymmetricDifference([path])
            if !expandedDatabasePaths.contains(path) {
                feature.cancelDatabaseTreeLoad(for: profile.id, database: profile.database)
            }
        } else {
            collapsedDatabaseProfileIDs.formSymmetricDifference([profile.id])
        }
    }

    private func toggleObjectSection(_ kind: DatabaseObjectKind, profile: DatabaseProfile) {
        let path = DatabaseTreePath(profile)
        collapsedObjectKinds[path, default: []].formSymmetricDifference([kind])
        if kind == .tables && collapsedObjectKinds[path]?.contains(kind) == true {
            for key in expandedTableKeys where key.profileID == profile.id && key.database == profile.database {
                feature.cancelTableTreeLoad(key)
            }
        }
    }

    private func sidebarLeaf(
        title: LocalizedStringKey,
        detail: String? = nil,
        symbol: String,
        count: Int,
        indent: CGFloat,
        tint: Color = LitheTheme.secondaryText
    ) -> some View {
        HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if symbol.hasSuffix(".svg") {
                LitheIDEAIcon(resourcePath: symbol, size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
            } else {
                Color.clear.frame(width: LitheTheme.Tree.iconSize, height: LitheTheme.Tree.iconSize)
            }
            Text(title)
                .font(LitheTheme.uiFont(size: 13))
                .lineLimit(1)
            if let detail {
                Text(verbatim: detail)
                    .font(LitheTheme.uiFont(size: 13))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count)")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
        .padding(.leading, indent)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .foregroundStyle(LitheTheme.secondaryText)
    }

    private func moveDroppedProfile(_ items: [String], to folderID: UUID?) -> Bool {
        guard let rawID = items.first, let profileID = UUID(uuidString: rawID),
              let profile = feature.profiles.first(where: { $0.id == profileID }) else {
            return false
        }
        guard feature.move(profile, toFolder: folderID) else { return false }
        targetedFolderID = nil
        isRootDropTarget = false
        return true
    }

    private var rootFolders: [DatabaseConnectionFolder] {
        feature.folders.filter { $0.parentID == nil }
    }

    private func childFolders(of folder: DatabaseConnectionFolder) -> [DatabaseConnectionFolder] {
        feature.folders.filter { $0.parentID == folder.id }
    }

    private func connectionContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        let status = feature.connectionStatus(for: profile)
        items.append(.action(status == .connected ? "Disconnect" : "Connect", isEnabled: !(status == .connecting), action: {
            if status == .connected {
                expandedProfileIDs.remove(profile.id)
                expandedDatabasePaths = expandedDatabasePaths.filter { $0.profileID != profile.id }
                feature.disconnect(profile)
            } else {
                selectProfile(profile, expand: true)
            }
        }))
        if profile.kind.isSQLDatabase {
            items.append(.action("New Query", action: { openSQLQuery(profile) }))
        }
        items.append(.action("Refresh", action: { refresh(profile) }))
        if profile.kind == .mysql || profile.kind == .mariadb {
            items.append(.submenu("Diagnostics", items: [
                .action("Force Refresh") {
                    Task { await feature.refreshDatabaseTree(for: profile.id, force: true) }
                }
            ]))
        }
        items.append(.separator)
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.name) }))
        items.append(.action("Edit Connection", action: {
            presentConnectionEditor(profile: profile)
        }))
        items.append(.submenu("Move", items: [
            .action("To Folder…") { presentFolderMove(.connection(profile.id)) },
            .action("To Top Level", isEnabled: profile.folderID != nil) { feature.move(profile, toFolder: nil) }
        ]))
        items.append(.action("Duplicate Connection", action: { _ = feature.duplicate(profile) }))
        items.append(.separator)
        items.append(.action("Remove Connection", role: .destructive, action: {
            profilePendingDeletion = profile
            showsProfileDeletionConfirmation = true
        }))
        return items
    }

    private func presentFolderEditor(folder: DatabaseConnectionFolder? = nil, parentID: UUID? = nil, moving target: DatabaseFolderMoveTarget? = nil) {
        editingFolder = folder
        creatingFolderParentID = parentID
        folderMoveTarget = target
        showsFolderEditor = true
    }

    private func presentFolderMove(_ target: DatabaseFolderMoveTarget) {
        folderMoveTarget = target
        if feature.folders.isEmpty { presentFolderEditor(moving: target) }
        else { showsFolderDestination = true }
    }

    private func folderPath(_ folder: DatabaseConnectionFolder) -> String {
        // ponytail: Ancestors scan the small saved folder list; index IDs if large trees make menu construction slow.
        var names = [folder.name], parent = folder.parentID, visited: Set<UUID> = [folder.id]
        while let id = parent, visited.insert(id).inserted, let ancestor = feature.folders.first(where: { $0.id == id }) {
            names.insert(ancestor.name, at: 0)
            parent = ancestor.parentID
        }
        return names.joined(separator: "/")
    }

    private func revealFolder(_ id: UUID?) {
        var cursor = id, visited: Set<UUID> = []
        while let id = cursor, visited.insert(id).inserted {
            collapsedFolderIDs.remove(id)
            cursor = feature.folders.first(where: { $0.id == id })?.parentID
        }
    }

    private func moveToFolder(_ destination: UUID?) {
        let moved: Bool
        switch folderMoveTarget {
        case .connection(let id):
            guard let profile = feature.profiles.first(where: { $0.id == id }) else { return }
            moved = feature.move(profile, toFolder: destination)
        case .folder(let id): moved = feature.moveFolder(id, toParent: destination)
        case nil: return
        }
        if moved {
            revealFolder(destination)
            showsFolderDestination = false
            folderMoveTarget = nil
        }
    }

    private var folderDestinationItems: [LitheContextMenuItem] {
        let destinations = feature.folders.filter { folder in
            if case .folder(let id) = folderMoveTarget { return feature.canMoveFolder(id, toParent: folder.id) }
            return true
        }.sorted { folderPath($0).localizedStandardCompare(folderPath($1)) == .orderedAscending }
        let canMoveToRoot: Bool
        if case .folder(let id) = folderMoveTarget { canMoveToRoot = feature.canMoveFolder(id, toParent: nil) }
        else { canMoveToRoot = true }
        return [.heading("Move to Folder", centered: true),
                .action("To Top Level", isEnabled: canMoveToRoot) { moveToFolder(nil) }, .separator]
            + destinations.map { folder in
                .action(folderPath(folder), localizesTitle: false) { moveToFolder(folder.id) }
            }
            + [.separator, .action("New Folder…") {
                let target = folderMoveTarget
                showsFolderDestination = false
                presentFolderEditor(moving: target)
            }]
    }

    private func refresh(_ profile: DatabaseProfile) {
        Task {
            if profile.kind == .mysql || profile.kind == .mariadb {
                await feature.refreshDatabaseTree(for: profile.id)
            } else {
                await feature.refresh(profile)
            }
        }
    }

    private func refreshDatabase(_ profile: DatabaseProfile) {
        Task {
            if profile.kind == .mysql || profile.kind == .mariadb {
                await feature.refreshDatabaseTree(for: profile.id, database: profile.database)
            } else {
                await feature.refresh(profile)
            }
        }
    }

    private var canRefreshSelection: Bool {
        if case .folder = treeSelection { return false }
        return treeSelection != nil || feature.selectedProfile != nil
    }

    private func refreshSelection() {
        switch treeSelection {
        case .connection(let id):
            if let profile = feature.profiles.first(where: { $0.id == id }) { refresh(profile) }
        case .database(let path), .objects(let path, _):
            if let profile = feature.profiles.first(where: { $0.id == path.profileID }) {
                refreshDatabase(databaseProfile(profile, database: path.database))
            }
        case .table(let key):
            Task { await feature.loadTableTree(key, force: true) }
        case .folder: break
        case nil:
            if let profile = feature.selectedProfile { refresh(profile) }
        }
    }

    private func openSQLQuery(_ profile: DatabaseProfile, sql: String = "") {
        Task {
            guard await feature.selectDatabaseContext(profile), model.databaseFeatureIfActive === feature else { return }
            model.openDatabaseQuery(profileID: profile.id, sql: sql)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func databaseContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("New Query", action: { openSQLQuery(profile) }))
        items.append(.action("New Table", isEnabled: !(profile.readOnly), action: {
            openSQLQuery(profile, sql: "CREATE TABLE new_table (\n    id INTEGER PRIMARY KEY\n);\n")
        }))
        if profile.kind != .sqlserver {
            items.append(.action("Import SQL Backup…", isEnabled: !(profile.readOnly), action: {
                Task {
                    guard await feature.selectDatabaseContext(profile) else { return }
                    importFormat = .sql; pendingImportFormat = .sql; showsImporter = true
                }
            }))
            items.append(.action("Export Database as SQL…", action: { exportDatabase(profile) }))
        }
        items.append(.separator)
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.database.isEmpty ? "Default database" : profile.database) }))
        items.append(.action("Refresh", action: { refreshDatabase(profile) }))
        return items
    }

    private func mongoDatabaseContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Refresh Collections", action: { refreshDatabase(profile) }))
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.database.isEmpty ? "admin" : profile.database) }))
        return items
    }

    private func mongoCollectionContextMenu(_ profile: DatabaseProfile, collection: String) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("View Documents", action: { openTable(profile, table: collection, section: .data) }))
        items.append(.action("Copy Name", action: { copyToPasteboard(collection) }))
        items.append(.separator)
        items.append(.action("Refresh", action: {
            Task {
                guard await feature.selectDatabaseContext(profile) else { return }
                await feature.openTable(collection)
            }
        }))
        return items
    }

    private func tableGroupContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("New Table", isEnabled: !(profile.readOnly), action: { openSQLQuery(profile, sql: "CREATE TABLE new_table (\n    id INTEGER PRIMARY KEY\n);\n") }))
        items.append(.action("Refresh", action: { refreshDatabase(profile) }))
        return items
    }

    private func redisDatabaseContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Refresh Keys", action: { refresh(profile) }))
        items.append(.action("Set Database Alias", action: {
            presentConnectionEditor(profile: profile)
        }))
        items.append(.action("Clear Current Redis DB", role: .destructive, isEnabled: !(profile.readOnly), action: {
            pendingRedisProfile = profile
            showsRedisFlushConfirmation = true
        }))
        return items
    }

    private func nacosContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Refresh", action: { refresh(profile) }))
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.name) }))
        items.append(.action("Edit Namespace", action: {
            presentConnectionEditor(profile: profile)
        }))
        return items
    }

    private func presentConnectionEditor(
        profile: DatabaseProfile? = nil,
        defaultFolderID: UUID? = nil,
        defaultKind: DatabaseKind = .mysql
    ) {
        editingProfile = profile
        newConnectionKind = defaultKind
        newConnectionFolderID = defaultFolderID
        connectionEditorPresentationID = UUID()
        showsConnectionEditor = true
    }

    private func tableContextMenu(_ profile: DatabaseProfile, table: String) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = [
            .action("View Data") { openTable(profile, table: table, section: .data) },
            .action("New Query") {
                openTable(profile, table: table, section: .sql, sql: "SELECT * FROM \(quotedIdentifier(table, kind: profile.kind));\n")
            },
            .action("View Structure") { openTable(profile, table: table, section: .structure) },
            .action("Copy Name") { copyToPasteboard(table) },
            .separator,
            .submenu("Export Data…", items: [
                .action("CSV") { exportTable(profile, table: table, format: .csv) },
                .action("JSON") { exportTable(profile, table: table, format: .json) }
            ])
        ]
        items.append(.action("Import Data…", isEnabled: !(profile.readOnly), action: { beginImport(.csv, profile: profile, table: table) }))
        items.append(.separator)
        items.append(.action("Clear Table", role: .destructive, isEnabled: !(profile.readOnly), action: {
            pendingTableAction = DatabaseTableContextAction(profile: profile, table: table, kind: .clear)
            showsTableActionConfirmation = true
        }))
        items.append(.action("Delete Table", role: .destructive, isEnabled: !(profile.readOnly), action: {
            pendingTableAction = DatabaseTableContextAction(profile: profile, table: table, kind: .drop)
            showsTableActionConfirmation = true
        }))
        items.append(.separator)
        items.append(.action("Refresh", action: {
            Task { await feature.loadTableTree(DatabaseTreeTableKey(profileID: profile.id, database: profile.database, table: table), force: true) }
        }))
        return items
    }

    private func openTable(_ profile: DatabaseProfile, table: String, section: DatabaseWorkspaceSection, sql: String = "") {
        treeSelection = .table(DatabaseTreeTableKey(profileID: profile.id, database: profile.database, table: table))
        Task {
            guard await feature.selectDatabaseContext(profile), model.databaseFeatureIfActive === feature else { return }
            if section == .sql {
                model.openDatabaseQuery(profileID: profile.id, sql: sql)
            } else {
                model.selectDatabaseWorkspace(profileID: profile.id, table: table)
                guard feature.selectedProfileID == profile.id else { return }
                feature.workspaceSection = section
            }
        }
    }

    private func executeTableAction(_ action: DatabaseTableContextAction) {
        pendingTableAction = nil
        let sql = action.kind == .clear
            ? "DELETE FROM \(quotedIdentifier(action.table, kind: action.profile.kind));"
            : "DROP TABLE \(quotedIdentifier(action.table, kind: action.profile.kind));"
        Task {
            guard await feature.selectDatabaseContext(action.profile), model.databaseFeatureIfActive === feature else { return }
            model.openDatabaseQuery(profileID: action.profile.id, sql: sql)
            guard feature.selectedProfileID == action.profile.id, let tabID = feature.selectedSQLTabID else { return }
            model.showToolWindow(.databaseServices)
            await feature.runSQL(in: tabID, confirmedRisk: true)
            guard model.databaseFeatureIfActive === feature, feature.selectedProfileID == action.profile.id else { return }
            if action.kind == .clear { await feature.openTable(action.table) }
            else { await feature.refreshTables() }
        }
    }

    private func beginImport(_ format: DatabaseTransferFormat, profile: DatabaseProfile, table: String?) {
        Task {
            guard await feature.selectDatabaseContext(profile) else { return }
            if let table { await feature.openTable(table) }
            importFormat = format
            pendingImportFormat = format
            showsImporter = true
        }
    }

    private func exportTable(_ profile: DatabaseProfile, table: String, format: DatabaseTransferFormat) {
        Task {
            guard await feature.selectDatabaseContext(profile) else { return }
            await feature.openTable(table)
            exportFormat = format
            guard let data = await feature.exportData(format: format) else { return }
            exportDocument = DatabaseTransferDocument(data: data)
            showsExporter = true
        }
    }

    private func exportDatabase(_ profile: DatabaseProfile) {
        Task {
            guard await feature.selectDatabaseContext(profile) else { return }
            exportFormat = .sql
            guard let url = await feature.exportDataFile(format: .sql) else { return }
            temporaryExportURL = url
            exportDocument = DatabaseTransferDocument(fileURL: url)
            showsExporter = true
        }
    }

    private var exportFilename: String {
        let base = feature.selectedProfile?.database.isEmpty == false ? feature.selectedProfile?.database ?? "database" : "database"
        return "\(base).\(exportFormat.rawValue)"
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let format = pendingImportFormat ?? importFormat
            if format == .sql {
                let temporaryURL = try feature.prepareImportFile(from: url)
                pendingImportURL = temporaryURL
            } else {
                pendingImportData = try feature.readImportData(from: url)
            }
            pendingImportFormat = format
            if format == .sql || feature.selectedProfile?.productionProtection == true {
                showsProtectedImportConfirmation = true
            } else {
                performPendingImport(confirmed: false)
            }
        } catch { feature.errorMessage = error.localizedDescription }
    }

    private func performPendingImport(confirmed: Bool) {
        guard let format = pendingImportFormat else { return }
        let data = pendingImportData
        let fileURL = pendingImportURL
        pendingImportData = nil; pendingImportURL = nil; pendingImportFormat = nil
        Task {
            if let fileURL {
                defer { feature.removeTemporaryFile(fileURL) }
                _ = await feature.importDataFile(fileURL, format: format, confirmed: confirmed)
            } else if let data {
                _ = await feature.importData(data, format: format, confirmed: confirmed)
            }
        }
    }

    private func discardPendingImport() {
        if let pendingImportURL { feature.removeTemporaryFile(pendingImportURL) }
        pendingImportData = nil; pendingImportURL = nil; pendingImportFormat = nil
    }

    private func quotedIdentifier(_ value: String, kind: DatabaseKind) -> String {
        if kind == .sqlserver { return "[\(value.replacingOccurrences(of: "]", with: "]]"))]" }
        let quote = (kind == .mysql || kind == .mariadb) ? "`" : "\""
        return "\(quote)\(value.replacingOccurrences(of: quote, with: quote + quote))\(quote)"
    }

    @ViewBuilder
    private func connectionStatusIndicator(_ profile: DatabaseProfile) -> some View {
        let status = feature.connectionStatus(for: profile)
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .tint(LitheTheme.accent)
                .frame(width: 5, height: 5)
                .help("Connecting")
                .accessibilityLabel("Connecting")
        case .connected:
            Circle()
                .fill(LitheTheme.success)
                .saturation(1.25)
                .frame(width: 5, height: 5)
                .help("Connected")
                .accessibilityLabel("Connected")
        case .failed:
            Circle()
                .fill(LitheTheme.error)
                .saturation(1.25)
                .frame(width: 5, height: 5)
                .help("Connection failed")
                .accessibilityLabel("Connection failed")
        }
    }

    private func selectProfile(_ profile: DatabaseProfile, expand: Bool) {
        treeSelection = .connection(profile.id)
        if expand {
            expandedProfileIDs.insert(profile.id)
        }
        model.selectDatabaseWorkspace(profileID: profile.id, refresh: feature.selectedProfileID != profile.id)
    }

    private func toggleProfile(_ profile: DatabaseProfile) {
        if expandedProfileIDs.contains(profile.id) {
            expandedProfileIDs.remove(profile.id)
            feature.cancelDatabaseTreeLoad(for: profile.id)
        } else {
            expandedProfileIDs.insert(profile.id)
            if profile.kind != .mysql && profile.kind != .mariadb {
                selectProfile(profile, expand: true)
            }
        }
    }

    private func collapseAll() {
        for id in expandedProfileIDs { feature.cancelDatabaseTreeLoad(for: id) }
        collapsedFolderIDs = Set(feature.folders.map(\.id))
        expandedProfileIDs.removeAll()
        collapsedObjectKinds.removeAll()
        expandedDatabasePaths.removeAll()
        expandedTableKeys.removeAll()
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var unfiledProfiles: [DatabaseProfile] {
        sorted(feature.profiles.filter { profile in
            guard profile.folderID == nil || !feature.folders.contains(where: { $0.id == profile.folderID }) else {
                return false
            }
            return profileMatchesSearch(profile)
        })
    }

    private func allProfiles(in folder: DatabaseConnectionFolder) -> [DatabaseProfile] {
        feature.profiles.filter { $0.folderID == folder.id }
    }

    private func recursiveProfileCount(in folder: DatabaseConnectionFolder) -> Int {
        allProfiles(in: folder).count + childFolders(of: folder).reduce(0) { count, child in
            count + recursiveProfileCount(in: child)
        }
    }

    private func visibleProfiles(in folder: DatabaseConnectionFolder) -> [DatabaseProfile] {
        let profiles = allProfiles(in: folder)
        if searchQuery.isEmpty { return sorted(profiles.filter(profileMatchesSearch)) }
        if folder.name.lowercased().contains(searchQuery) { return sorted(profiles.filter(matchesKindFilter)) }
        return sorted(profiles.filter(profileMatchesSearch))
    }

    private func isFolderVisible(_ folder: DatabaseConnectionFolder) -> Bool {
        (searchQuery.isEmpty && kindFilter == nil)
            || folder.name.lowercased().contains(searchQuery)
            || !visibleProfiles(in: folder).isEmpty
            || childFolders(of: folder).contains(where: isFolderVisible)
    }

    private func profileMatchesSearch(_ profile: DatabaseProfile) -> Bool {
        guard matchesKindFilter(profile) else { return false }
        guard !searchQuery.isEmpty else { return true }
        let searchableText = [profile.name, profile.kind.displayName, profile.host, profile.database, profile.path]
            .joined(separator: " ")
            .lowercased()
        return searchableText.contains(searchQuery)
    }

    private func matchesKindFilter(_ profile: DatabaseProfile) -> Bool {
        kindFilter == nil || profile.kind == kindFilter
    }

    private func sorted(_ profiles: [DatabaseProfile]) -> [DatabaseProfile] {
        profiles.sorted { lhs, rhs in
            switch connectionSort {
            case .name:
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .databaseType:
                if lhs.kind.displayName == rhs.kind.displayName {
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                } else {
                    lhs.kind.displayName < rhs.kind.displayName
                }
            case .host:
                if lhs.host == rhs.host {
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                } else {
                    lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
                }
            }
        }
    }

    private func objectLabel(_ row: DatabaseRow) -> String {
        for key in ["table_name", "routine_name", "trigger_name", "sequence_name", "name", "TABLE_NAME", "ROUTINE_NAME", "TRIGGER_NAME", "SEQUENCE_NAME"] {
            if let value = row[key], case let .string(name) = value, !name.isEmpty { return name }
        }
        return row.keys.sorted().compactMap { key in
            guard let value = row[key] else { return nil }
            return "\(key): \(value.displayText)"
        }.joined(separator: "  ")
    }
}

private struct DatabaseDBXImportSheet: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Binding var isPresented: Bool
    @FocusState private var passphraseFocused: Bool

    let data: Data
    @State private var passphrase = ""
    @State private var plan: DatabaseDBXImportPlan?
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var isReading = false

    private let service = DatabaseDBXImportService()
    private var isEncrypted: Bool { service.isEncrypted(data) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Connections are saved without testing them. Passwords are stored in Keychain.")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            Group {
                if let plan {
                    preview(plan)
                } else {
                    unlockView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                if plan != nil {
                    Text("\(selectedIDs.count) connections selected")
                        .font(LitheTheme.uiFont(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if let plan {
                    Button("Import Selected") {
                        let count = feature.importDBXConnections(plan: plan, selectedIDs: selectedIDs)
                        if count > 0 { isPresented = false }
                    }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(LitheCommitDialogStyle.background)
        }
        .frame(width: 680, height: 560)
        .background(LitheCommitDialogStyle.background)
        .foregroundStyle(LitheTheme.primaryText)
        .onAppear {
            if !isEncrypted { readFile() }
        }
        .onDisappear { passphrase = "" }
    }

    private var unlockView: some View {
        VStack(spacing: 14) {
            Spacer()
            LitheIDEAIcon(resourcePath: isEncrypted ? "expui/general/locked.svg" : "expui/general/import.svg", size: 16, preservesOriginalColors: true)
            Text(isEncrypted ? "Encrypted DBX Export" : "Reading DBX Export")
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
            if isEncrypted {
                Text("Enter the password used when this connection file was exported from DBX.")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                SecureField("DBX export password", text: $passphrase)
                    .focused($passphraseFocused)
                    .modifier(LitheCommitDialogInputStyle(focused: passphraseFocused))
                    .frame(width: 320)
                    .onSubmit(readFile)
            }
            if let errorMessage {
                DatabaseLocalization.text(errorMessage)
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if isReading {
                ProgressView("Reading connection configuration…")
                    .controlSize(.small)
            } else if isEncrypted {
                Button("Read DBX Export") { readFile() }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .disabled(passphrase.isEmpty)
            }
            Spacer()
        }
        .padding(24)
    }

    private func preview(_ plan: DatabaseDBXImportPlan) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                summaryValue(plan.importableCount, label: "Ready")
                summaryValue(plan.duplicateCount, label: "Duplicates")
                summaryValue(plan.unsupportedCount, label: "Unsupported")
                summaryValue(plan.folders.count, label: "Folders")
                Spacer()
                if plan.wasEncrypted {
                    Text("Passwords decrypted")
                        .font(LitheTheme.uiFont(size: 10, weight: .medium))
                        .foregroundStyle(LitheTheme.success)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(LitheTheme.inputBackground.opacity(0.55))

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(plan.candidates) { candidate in
                        candidateRow(candidate)
                    }
                    if !plan.unsupportedTypes.isEmpty {
                        LitheBanner(status: .warning) {
                            Text("Unsupported DBX database types").litheBannerTitle()
                            Text(plan.unsupportedTypes.sorted(by: { $0.key < $1.key }).map { "\($0.key) × \($0.value)" }.joined(separator: ", "))
                                .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func summaryValue(_ value: Int, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(LitheTheme.uiFont(size: 13, weight: .semibold, design: .monospaced))
            Text(label).font(LitheTheme.uiFont(size: 9.5)).foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    private func candidateRow(_ candidate: DatabaseDBXImportCandidate) -> some View {
        let isSelected = selectedIDs.contains(candidate.id)
        return Button {
            guard !candidate.isDuplicate else { return }
            if isSelected { selectedIDs.remove(candidate.id) }
            else { selectedIDs.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                LitheIDEAIcon(resourcePath: candidate.isDuplicate ? "commit/checkBoxDisabled.svg" : (isSelected ? "commit/checkBoxSelected.svg" : "commit/checkBox.svg"), size: 16, preservesOriginalColors: true)
                    .frame(width: 18)
                DatabaseBrandIcon(kind: candidate.profile.kind, size: 18)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(candidate.profile.name)
                            .font(LitheTheme.uiFont(size: 13))
                            .lineLimit(1)
                        if candidate.isDuplicate {
                            Text("Duplicate")
                                .font(LitheTheme.uiFont(size: 9, weight: .medium))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        } else if !candidate.warnings.isEmpty {
                            Text("Review")
                                .font(LitheTheme.uiFont(size: 9, weight: .medium))
                                .foregroundStyle(LitheTheme.warning)
                        }
                    }
                    Text(candidateSubtitle(candidate.profile))
                        .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    ForEach(candidate.warnings, id: \.self) { warning in
                        DatabaseLocalization.text(warning)
                            .font(LitheTheme.uiFont(size: 9.5))
                            .foregroundStyle(LitheTheme.warning)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(candidate.profile.kind.displayName)
                    .font(LitheTheme.uiFont(size: 9.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(candidate.isDuplicate)
        .litheRowHover(isActive: isSelected, activeBackground: LitheTheme.subtleSelection,
                       hoverBackground: candidate.isDuplicate ? .clear : LitheTheme.hoverBackground)
    }

    private func candidateSubtitle(_ profile: DatabaseProfile) -> String {
        if profile.kind == .sqlite { return profile.path }
        let endpoint = profile.port > 0 ? "\(profile.host):\(profile.port)" : profile.host
        return profile.username.isEmpty ? endpoint : "\(profile.username) @ \(endpoint)"
    }

    private func readFile() {
        guard !isReading else { return }
        isReading = true
        errorMessage = nil
        let data = data
        let passphrase = isEncrypted ? passphrase : nil
        let profiles = feature.profiles
        Task {
            do {
                let parsed = try await Task.detached {
                    try service.parse(data: data, passphrase: passphrase, existingProfiles: profiles)
                }.value
                plan = parsed
                selectedIDs = Set(parsed.candidates.filter { !$0.isDuplicate }.map(\.id))
                self.passphrase = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isReading = false
        }
    }
}

private enum DatabaseConnectionSort: String, CaseIterable, Identifiable {
    case name
    case databaseType
    case host

    var id: String { rawValue }

    var title: LocalizedStringKey { LocalizedStringKey(menuTitle) }
    var menuTitle: String {
        switch self {
        case .name: "Name"
        case .databaseType: "Database type"
        case .host: "Host"
        }
    }
}

private extension DatabaseObjectKind {
    var title: String {
        switch self {
        case .tables: "Tables"
        case .views: "Views"
        case .routines: "Routines"
        case .triggers: "Triggers"
        case .sequences: "Sequences"
        }
    }

    var symbol: String {
        switch self {
        case .tables: "tablecells"
        case .views: "eye"
        case .routines: "function"
        case .triggers: "bolt"
        case .sequences: "list.number"
        }
    }
}

private extension DatabaseKind {
    var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .nacos: "Nacos"
        }
    }

    var symbolName: String {
        switch self {
        case .mysql: "cylinder.fill"
        case .mariadb: "cylinder.fill"
        case .postgresql: "cylinder.split.1x2.fill"
        case .sqlite: "externaldrive.fill"
        case .sqlserver: "server.rack"
        case .mongodb: "leaf.fill"
        case .redis: "square.stack.3d.up.fill"
        case .nacos: "slider.horizontal.3"
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private struct DatabaseSchemaSelector: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    let profileID: UUID
    let names: [String]
    @Binding var selection: [String]?
    let onApply: () -> Void
    @State private var query = ""
    @State private var selectedRow: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    Task { await feature.loadDatabaseTree(for: profileID, force: true) }
                } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                }
                .litheToolbarIconButton()
                .accessibilityLabel("Refresh")
                .workbenchHoverHelp(Text("Refresh"))
            }
            .padding(.horizontal, LitheDropdownMetrics.popupPadding)
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            // Keep the native editor mounted for the shared host's type-to-search/IME routing.
            LitheSearchField("Search databases", text: $query, focus: $searchFocused)
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .frame(height: searchFocused || !query.isEmpty ? LitheTheme.Tree.rowHeight : 0)
                .clipped()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    schemaRow(title: Text("All schemas"), name: nil, isOn: selection == nil) {
                        selection = selection == nil ? [] : nil
                    }
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        .padding(.leading, LitheTheme.Tree.indent)
                    ForEach(names.filter { query.isEmpty || $0.localizedStandardContains(query) }, id: \.self) { name in
                        schemaRow(title: Text(verbatim: name), name: name, isOn: selection?.contains(name) ?? true) {
                            toggleSchema(name)
                        }
                    }
                }
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .padding(.vertical, LitheTheme.Tree.verticalInset)
            }
            .litheScrollViewChrome()
            // Use the shared tall-list viewport; the popup host bounds it to the available screen.
            .frame(height: LitheDropdownMetrics.historyViewportHeight)
            Text("Press Enter or click outside the list to apply")
                // Community Popup.Advertiser: regular UI font minus 1pt, 8/12 insets.
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.Tree.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .padding(.vertical, LitheDropdownMetrics.itemHorizontalPadding)
                .background(LitheTheme.popupBackground)
        }
        .background(LitheTheme.sidebar)
        .frame(width: LitheDropdownMetrics.maximumWidth)
        .environment(\.lithePointingHandCursorEnabled, false)
        .onSubmit(onApply)
        .litheDropdownKeyHandler { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.keyCode == 36 || event.keyCode == 76 else { return false }
            onApply()
            return true
        }
    }

    private func schemaRow(title: Text, name: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
        LitheTreeCheckbox(state: isOn ? .on : .off, accessibilityTitle: "", title: title) {
            selectedRow = name ?? ""
            action()
        }
        .padding(.leading, LitheTheme.Tree.indent)
        .background(selectedRow == (name ?? "") ? LitheTheme.Tree.focusedSelection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius))
    }

    private func toggleSchema(_ name: String) {
        var selected = Set(selection ?? names)
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        selection = names.filter { selected.contains($0) }
    }
}

private struct DatabaseFolderEditor: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Binding var isPresented: Bool
    let folder: DatabaseConnectionFolder?
    let parentID: UUID?
    let moveTarget: DatabaseFolderMoveTarget?
    let onSaved: () -> Void
    @State private var validationMessage: String?

    var body: some View {
        LitheNamePopup(title: folder == nil ? "New Folder" : "Rename Folder", initialName: folder?.name ?? "",
                       validationMessage: validationMessage, onSubmit: save, onCancel: { isPresented = false })
    }

    private func save(_ name: String) {
        let didSave: Bool
        if let folder { didSave = feature.renameFolder(folder, to: name) }
        else {
            switch moveTarget {
            case .connection(let id): didSave = feature.createFolder(name: name, parentID: parentID, movingProfileID: id)
            case .folder(let id): didSave = feature.createFolder(name: name, parentID: parentID, movingFolderID: id)
            case nil: didSave = feature.createFolder(name: name, parentID: parentID)
            }
        }
        if didSave { isPresented = false; onSaved() }
        else { validationMessage = feature.errorMessage }
    }
}

/// Content layout follows the supplied Database Tools reference; that plugin is not in Community.
/// Community c7f91397 supplies BalloonImpl geometry and LafManagerImpl's locale-aware fonts.
struct DatabaseConnectionResultView: View {
    @Environment(\.locale) private var locale
    let summary: String
    let pointerX: CGFloat
    var onCopy: () -> Void = {}
    @State private var copyHovered = false

    private func font(bold: Bool = false) -> Font {
        // LafManagerImpl.shouldFallbackToSystemFont: CJK uses the macOS LaF (Helvetica Neue, 13).
        let cjk = ["zh", "ja", "ko"].contains(locale.language.languageCode?.identifier ?? "")
        return .custom(cjk ? (bold ? "HelveticaNeue-Bold" : "HelveticaNeue") : (bold ? "Inter-Bold" : "Inter-Regular"), size: 13)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Connection successful")
                    .font(font(bold: true))
                    .foregroundStyle(LitheTheme.DatabaseConnectionResult.success)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    onCopy()
                }
                .buttonStyle(.litheNoPress)
                .foregroundStyle(LitheTheme.accent)
                .lithePointer()
                .underline(copyHovered)
                .onHover { copyHovered = $0 }
            }
            Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(font())
        .foregroundStyle(LitheTheme.DatabaseConnectionResult.foreground)
        .padding(16)
        .frame(width: 728, alignment: .leading)
        .padding(.bottom, 10)
        .background(DatabaseConnectionResultOutline(pointerX: pointerX).fill(LitheTheme.DatabaseConnectionResult.background))
        .overlay(DatabaseConnectionResultOutline(pointerX: pointerX).stroke(LitheTheme.DatabaseConnectionResult.border, lineWidth: 1).allowsHitTesting(false))
    }
}

/// BalloonImpl: non-dialog ARC=4, TOPBOTTOM_POINTER_WIDTH=14, TOPBOTTOM_POINTER_LENGTH=10.
private struct DatabaseConnectionResultOutline: Shape {
    let pointerX: CGFloat

    func path(in bounds: CGRect) -> Path {
        // BalloonImpl.Shaper uses integer edges, with the far edge at size - 1.
        // A half-point inset instead makes the outer stroke heavier on the pixel grid.
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - 1, height: bounds.height - 1)
        let bottom = rect.maxY - 10
        let x = min(max(pointerX, rect.minX + 11), rect.maxX - 11)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 4), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: bottom - 4))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 4, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
            path.addLine(to: CGPoint(x: x + 7, y: bottom))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x - 7, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX + 4, y: bottom))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - 4), control: CGPoint(x: rect.minX, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 4))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 4, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

struct DatabaseConnectionEditor: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Environment(\.locale) private var locale
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var usesDefaultName = true
    @State private var kind = DatabaseKind.mysql
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var username = ""
    @State private var password = ""
    @State private var passwordPersistence: DatabasePasswordPersistence = .forever
    @State private var database = ""
    @State private var path = ""
    @State private var ssl = false
    @State private var folderID: UUID?
    @State private var colorHex = ""
    @State private var readOnly = false
    @State private var productionProtection = false
    @State private var maskSensitiveFields = false
    @State private var sensitiveColumnPatterns = "password, secret, token, api_key"
    @State private var caCertificatePath = ""
    @State private var serverName = ""
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUsername = ""
    @State private var sshKeyPath = ""
    @State private var sshLocalPort = ""
    @State private var proxyURL = ""
    private enum Section: String, CaseIterable { case general = "General", network = "SSH / TLS", safety = "Safety and Labels" }
    @State private var section: Section = .general
    @State private var draftID = UUID()
    @State private var testTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var showsTestResult = false
    @State private var testDurationMilliseconds = 0
    @State private var testError: String?
    @State private var usesSSHTunnel = false
    @State private var hasSavedPassword = false
    @State private var isConnecting = false
    @FocusState private var nameFocused: Bool

    private let profile: DatabaseProfile?

    init(isPresented: Binding<Bool>, profile: DatabaseProfile? = nil, defaultFolderID: UUID? = nil, defaultKind: DatabaseKind = .mysql) {
        _isPresented = isPresented
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _usesDefaultName = State(initialValue: profile == nil)
        _kind = State(initialValue: profile?.kind ?? defaultKind)
        _host = State(initialValue: profile?.host ?? "127.0.0.1")
        _port = State(initialValue: String(profile?.port ?? 3306))
        _passwordPersistence = State(initialValue: profile?.passwordPersistence ?? .forever)
        _username = State(initialValue: profile?.username ?? "")
        _database = State(initialValue: profile?.database ?? "")
        _path = State(initialValue: profile?.path ?? "")
        _ssl = State(initialValue: profile?.ssl ?? false)
        _folderID = State(initialValue: profile?.folderID ?? defaultFolderID)
        _colorHex = State(initialValue: profile?.colorHex ?? "")
        _readOnly = State(initialValue: profile?.readOnly ?? false)
        _productionProtection = State(initialValue: profile?.productionProtection ?? false)
        _maskSensitiveFields = State(initialValue: profile?.maskSensitiveFields ?? false)
        _sensitiveColumnPatterns = State(initialValue: profile?.sensitiveColumnPatterns.joined(separator: ", ") ?? "password, secret, token, api_key")
        _caCertificatePath = State(initialValue: profile?.caCertificatePath ?? "")
        _serverName = State(initialValue: profile?.serverName ?? "")
        _sshHost = State(initialValue: profile?.sshHost ?? "")
        _sshPort = State(initialValue: String(profile?.sshPort ?? 22))
        _sshUsername = State(initialValue: profile?.sshUsername ?? "")
        _sshKeyPath = State(initialValue: profile?.sshKeyPath ?? "")
        _sshLocalPort = State(initialValue: profile?.sshLocalPort == 0 ? "" : String(profile?.sshLocalPort ?? 0))
        _proxyURL = State(initialValue: profile?.proxyURL ?? "")
        _usesSSHTunnel = State(initialValue: !(profile?.sshHost ?? "").isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Name")
                            .frame(width: 140, alignment: .leading)
                        LitheTextField("", text: Binding(get: { connectionName }, set: { name = $0; usesDefaultName = false }), focus: $nameFocused)
                            .accessibilityLabel("Name")
                            .frame(maxWidth: .infinity)
                    }
            }.padding(16)
            HStack(spacing: 6) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button { nameFocused = false; section = item } label: {
                        Text(LocalizedStringKey(item.rawValue)).font(LitheTheme.uiFont(size: 13)).padding(.horizontal, 10)
                    }
                    .buttonStyle(.litheNoPress)
                    .modifier(LitheToolWindowTabStyle(isSelected: section == item, isActive: true))
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            ScrollView {
                Group {
                    switch section {
                    case .general:
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Engine")
                                    .frame(width: 140, alignment: .leading)
                                LitheSettingsSelect(selection: $kind, options: DatabaseKind.allCases, width: 576, accessibilityLabel: "Engine", title: { $0.displayName })
                            }

                            if kind == .sqlite {
                                GridRow {
                                    Text("Database file path")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $path)
                                        .accessibilityLabel("Database file path")
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                GridRow {
                                    Text(kind == .mongodb ? "Host or MongoDB URI" : "Host")
                                        .frame(width: 140, alignment: .leading)
                                    HStack(spacing: 12) {
                                        LitheTextField("", text: $host)
                                            .accessibilityLabel(kind == .mongodb ? "Host or MongoDB URI" : "Host")
                                            .frame(maxWidth: .infinity)
                                        Text("Port").frame(width: 42, alignment: .trailing)
                                        LitheTextField("", text: $port)
                                            .accessibilityLabel("Port")
                                            .frame(width: 140)
                                    }
                                }
                                GridRow {
                                    Text(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                        .frame(width: 140, alignment: .leading)
                                    HStack(spacing: 12) {
                                        LitheTextField("", text: $username)
                                            .accessibilityLabel(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                            .frame(maxWidth: .infinity)
                                        HStack(spacing: 12) {
                                            Text("Port").frame(width: 42, alignment: .trailing)
                                            Color.clear.frame(width: 140, height: SettingsSelectMetrics.controlHeight)
                                        }.hidden().accessibilityHidden(true)
                                    }
                                }
                                GridRow {
                                    Text(profile == nil ? "Password" : (hasSavedPassword ? "Password (leave blank to keep current)" : "Password (no saved password)"))
                                        .frame(width: 140, alignment: .leading)
                                    HStack(spacing: 12) {
                                        LitheTextField("", text: $password, secure: true)
                                            .accessibilityLabel("Password")
                                            .frame(maxWidth: .infinity)
                                        HStack(spacing: 12) {
                                            Text("Save:").frame(width: 42, alignment: .trailing)
                                            LitheSettingsSelect(selection: $passwordPersistence, options: DatabasePasswordPersistence.allCases, width: 140, accessibilityLabel: "Save password", title: {
                                                let key = $0 == .forever ? "Forever" : "Until restart"
                                                return AppLanguage(rawValue: locale.identifier)?.localizedString(key) ?? key
                                            })
                                        }
                                    }
                                }
                                if kind == .redis {
                                    GridRow {
                                        Text("Redis database index")
                                            .frame(width: 140, alignment: .leading)
                                        LitheTextField("", text: $database)
                                            .accessibilityLabel("Redis database index")
                                            .frame(maxWidth: .infinity)
                                    }
                                        .onChange(of: database) { value in
                                            let digitsOnly = value.filter(\.isNumber)
                                            if digitsOnly != value { database = digitsOnly }
                                        }
                                    if let redisDatabaseValidationMessage {
                                        GridRow {
                                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                            Text(redisDatabaseValidationMessage)
                                                .font(LitheTheme.uiFont(size: 10.5))
                                                .foregroundStyle(LitheTheme.error)
                                                .gridCellUnsizedAxes(.horizontal)
                                        }
                                    }
                                    GridRow {
                                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                        Text("Leave the database index at 0 for the standard Redis database.")
                                            .font(LitheTheme.uiFont(size: 10.5))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                            .gridCellUnsizedAxes(.horizontal)
                                    }
                                } else if kind == .nacos {
                                    GridRow {
                                        Text("Namespace ID (optional)")
                                            .frame(width: 140, alignment: .leading)
                                        LitheTextField("", text: $database)
                                            .accessibilityLabel("Namespace ID (optional)")
                                            .frame(maxWidth: .infinity)
                                    }
                                    GridRow {
                                        Text("API context path")
                                            .frame(width: 140, alignment: .leading)
                                        LitheTextField("", text: $path)
                                            .accessibilityLabel("API context path")
                                            .frame(maxWidth: .infinity)
                                    }
                                    GridRow {
                                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                        Text("Use /nacos for a standard Nacos server, or / for a reverse proxy at its root.")
                                            .font(LitheTheme.uiFont(size: 10.5))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                            .gridCellUnsizedAxes(.horizontal)
                                    }
                                } else {
                                    GridRow {
                                        Text("Database name")
                                            .frame(width: 140, alignment: .leading)
                                        LitheTextField("", text: $database)
                                            .accessibilityLabel("Database name")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    case .network:
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            if kind != .sqlite {
                                GridRow {
                                    Text("Use TLS")
                                        .frame(width: 140, alignment: .leading)
                                    Toggle("Use TLS", isOn: $ssl)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                            }
                            if ssl {
                                GridRow {
                                    Text("TLS CA certificate path")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $caCertificatePath)
                                        .accessibilityLabel("TLS CA certificate path")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("TLS server name")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $serverName)
                                        .accessibilityLabel("TLS server name")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            GridRow {
                                Text("Use SSH tunnel")
                                    .frame(width: 140, alignment: .leading)
                                Toggle("Use SSH tunnel", isOn: $usesSSHTunnel)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            if usesSSHTunnel {
                                GridRow {
                                    Text("SSH host")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sshHost)
                                        .accessibilityLabel("SSH host")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH port")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sshPort)
                                        .accessibilityLabel("SSH port")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH username")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sshUsername)
                                        .accessibilityLabel("SSH username")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH key path")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sshKeyPath)
                                        .accessibilityLabel("SSH key path")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH local port")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sshLocalPort)
                                        .accessibilityLabel("SSH local port")
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("Proxy URL (optional)")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $proxyURL)
                                        .accessibilityLabel("Proxy URL (optional)")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    case .safety:
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Folder")
                                    .frame(width: 140, alignment: .leading)
                                LitheSettingsSelect(selection: $folderID, options: [UUID?.none] + feature.folders.map { Optional($0.id) }, width: 576, accessibilityLabel: "Folder", title: { id in feature.folders.first { $0.id == id }?.name ?? String(localized: "No folder") })
                            }
                            GridRow {
                                Text("Color hex (optional)")
                                    .frame(width: 140, alignment: .leading)
                                LitheTextField("", text: $colorHex)
                                    .accessibilityLabel("Color hex (optional)")
                                    .frame(maxWidth: .infinity)
                            }
                            GridRow {
                                Text("Read-only connection")
                                    .frame(width: 140, alignment: .leading)
                                Toggle("Read-only connection", isOn: $readOnly)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            GridRow {
                                Text("Production protection")
                                    .frame(width: 140, alignment: .leading)
                                Toggle("Production protection", isOn: $productionProtection)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            if kind.supportsDataGrid {
                                GridRow {
                                    Text("Mask sensitive fields")
                                        .frame(width: 140, alignment: .leading)
                                    Toggle("Mask sensitive fields", isOn: $maskSensitiveFields)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                                GridRow {
                                    Text("Sensitive column patterns")
                                        .frame(width: 140, alignment: .leading)
                                    LitheTextField("", text: $sensitiveColumnPatterns)
                                        .accessibilityLabel("Sensitive column patterns")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            if let error = feature.errorMessage { DatabaseLocalization.error(error).font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.error).padding(.horizontal, 16) }
            if isTesting || testError != nil {
                HStack {
                    if let testError { DatabaseLocalization.error(testError).foregroundStyle(LitheTheme.error) }
                    else { Text("Testing connection…").foregroundStyle(LitheTheme.secondaryText) }
                    Spacer(minLength: 0)
                }.font(LitheTheme.uiFont(size: 11)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    Button("Test Connection") { testConnection() }
                        .buttonStyle(LitheBannerActionStyle(linkColor: LitheTheme.accent))
                        .disabled(!canTestConnection || isTesting || isConnecting)
                    if testSucceeded {
                        Button { showsTestResult.toggle() } label: {
                            HStack(spacing: 6) {
                                LitheIDEAIcon(resourcePath: "expui/general/greenCheckmark.svg", size: 16, preservesOriginalColors: true)
                                Text(kind.displayName).foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                        .buttonStyle(.litheNoPress)
                        .accessibilityLabel("Connection test result")
                    }
                }
                    .overlay {
                        if showsTestResult {
                            GeometryReader { anchor in
                                // Community BalloonPopupBuilderImpl defaults to a 500ms alpha animation.
                                LitheDropdownPopover(opensUpward: true, contentProvidesSurface: true, fadeInDuration: 0.5, isPresented: $showsTestResult) {
                                    DatabaseConnectionResultView(summary: connectionTestSummary, pointerX: anchor.size.width / 2, onCopy: { showsTestResult = false })
                                }
                            }
                        }
                    }
                Spacer()
                Button("Cancel") { cancel() }
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    connect()
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isConnecting ? "Connecting…" : "Connect")
                    }
                }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canTestConnection || isConnecting || isTesting)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(LitheCommitDialogStyle.background)
        }
        .onChange(of: kind) { newKind in
            guard profile == nil else { return }
            applyNewConnectionDefaults(kind)
        }
        .task { nameFocused = true }
        .onAppear {
            feature.errorMessage = nil
            if let profile {
                hasSavedPassword = feature.hasSavedPassword(for: profile)
            } else {
                applyNewConnectionDefaults(kind)
            }
        }
        .onChange(of: candidate) { _ in cancelConnectionTest() }
        .onChange(of: password) { _ in cancelConnectionTest() }
        .onDisappear { cancelConnectionTest(); feature.errorMessage = nil }
        .frame(width: 760, height: 580).background(LitheCommitDialogStyle.background)
    }

    private func applyNewConnectionDefaults(_ kind: DatabaseKind) {
        switch kind {
        case .mysql: port = "3306"; username = ""; database = ""; path = ""
        case .mariadb: port = "3306"; username = ""; database = ""; path = ""
        case .postgresql: port = "5432"; username = ""; database = ""; path = ""
        case .sqlite: path = ""; database = ""
        case .sqlserver: port = "1433"; username = ""; database = "master"; path = ""
        case .mongodb: port = "27017"; username = ""; database = "admin"; path = ""
        case .redis: port = "6379"; username = ""; database = "0"; path = ""
        case .nacos: port = "8848"; username = ""; database = ""; path = "/nacos"
        }
    }

    private var connectionName: String {
        usesDefaultName ? Self.defaultConnectionName(kind: kind, host: host, database: database, path: path) : name
    }

    static func defaultConnectionName(kind: DatabaseKind, host: String, database: String, path: String) -> String {
        if kind == .sqlite {
            let file = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            return file.isEmpty ? kind.displayName : file
        }
        var hostname = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // MongoDB accepts a URI in Host. Never copy URI credentials or query parameters into a display name.
        if hostname.contains("://") { hostname = URLComponents(string: hostname)?.host ?? "" }
        guard !hostname.isEmpty else { return kind.displayName }
        return "\(database.trimmingCharacters(in: .whitespacesAndNewlines))@\(hostname)"
    }

    private var candidate: DatabaseProfile {
        var candidate = DatabaseProfile(id: profile?.id ?? draftID, name: connectionName, kind: kind, host: host, port: UInt16(port) ?? 0, username: username, database: database, path: path, ssl: ssl, group: "", folderID: folderID, colorHex: colorHex, readOnly: readOnly, productionProtection: productionProtection, maskSensitiveFields: maskSensitiveFields, sensitiveColumnPatterns: sensitiveColumnPatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, caCertificatePath: ssl ? caCertificatePath : "", serverName: ssl ? serverName : "", sshHost: usesSSHTunnel ? sshHost : "", sshPort: usesSSHTunnel ? (UInt16(sshPort) ?? 22) : 0, sshUsername: usesSSHTunnel ? sshUsername : "", sshKeyPath: usesSSHTunnel ? sshKeyPath : "", sshLocalPort: usesSSHTunnel ? (UInt16(sshLocalPort) ?? 0) : 0, proxyURL: usesSSHTunnel ? proxyURL : "")
        candidate.passwordPersistence = passwordPersistence
        candidate.visibleDatabases = profile?.visibleDatabases
        return candidate
    }

    private var canTestConnection: Bool {
        (kind == .sqlite ? !path.isEmpty : !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && redisDatabaseValidationMessage == nil
    }

    private var connectionTestSummary: String {
        "DBMS: \(kind.displayName)\n\n" + String(format: AppLanguage(rawValue: locale.identifier)?.localizedString("Connection test duration: %lld ms") ?? String(localized: "Connection test duration: %lld ms", locale: locale), locale: locale, Int64(testDurationMilliseconds))
    }

    private func cancelConnectionTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testSucceeded = false
        showsTestResult = false
        testError = nil
    }

    private func testConnection() {
        guard canTestConnection, !isTesting, !isConnecting else { return }
        cancelConnectionTest()
        isTesting = true
        let candidate = candidate
        let testPassword: String? = profile != nil && password.isEmpty ? nil : password
        let started = ContinuousClock.now
        testTask = Task {
            do {
                try await feature.testConnection(candidate, password: testPassword)
                guard !Task.isCancelled else { return }
                let elapsed = started.duration(to: .now).components
                testDurationMilliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
                testSucceeded = true
                showsTestResult = true
            } catch {
                guard !Task.isCancelled else { return }
                testError = error.localizedDescription
            }
            isTesting = false
            testTask = nil
        }
    }

    private func cancel() {
        feature.errorMessage = nil
        isPresented = false
    }

    private func connect() {
        guard !isConnecting, !isTesting else { return }
        if let redisDatabaseValidationMessage {
            feature.errorMessage = redisDatabaseValidationMessage
            return
        }
        isConnecting = true
        let candidate = candidate
        let password = password
        Task {
            defer { isConnecting = false }
            let saved = if profile == nil {
                await feature.add(candidate, password: password)
            } else {
                await feature.update(candidate, password: password.isEmpty ? nil : password)
            }
            if saved { isPresented = false }
        }
    }

    private var redisDatabaseValidationMessage: String? {
        guard kind == .redis else { return nil }
        let value = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || UInt32(value) != nil else {
            return "Redis database index must be between 0 and 4294967295."
        }
        return nil
    }
}
