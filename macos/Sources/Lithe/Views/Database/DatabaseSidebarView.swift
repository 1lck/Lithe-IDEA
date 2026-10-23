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
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var treeActive = false
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
                HStack(spacing: 2) {
                    LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: 16,
                                  fallbackSystemImage: "magnifyingglass", preservesOriginalColors: true)
                    LitheSearchTextField("Search connections", text: $searchText)
                        .focused($searchFocused)
                        .onExitCommand { showsSearch = false; searchText = "" }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/closeSmall.svg", size: 16,
                                          fallbackSystemImage: "xmark", preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .padding(.leading, 1)
                        .workbenchHoverHelp(Text("Clear search"))
                        .accessibilityLabel("Clear search")
                    }
                }
                .litheSearchField(isFocused: searchFocused)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }

            if feature.profiles.isEmpty && feature.folders.isEmpty {
                emptyConnections
                    .contentShape(Rectangle())
                    .litheContextMenu { panelContextMenu }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            LazyVStack(alignment: .leading, spacing: 1) { connectionTree }
                                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                                .padding(.top, LitheTheme.Tree.verticalInset)
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .litheContextMenu { panelContextMenu }
                                .dropDestination(for: String.self) { items, _ in
                                    moveDroppedProfile(items, to: nil)
                                } isTargeted: { targeted in
                                    isRootDropTarget = targeted
                                }
                                .background(isRootDropTarget ? LitheTheme.accent.opacity(0.18) : .clear)
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    .background(LitheToolWindowActivityTracker(isActive: $treeActive))
                }
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

    @ViewBuilder
    private var connectionTree: some View {
        let rootProfiles = unfiledProfiles
        let hasVisibleFolders = feature.folders.contains { folder in
            isFolderVisible(folder)
        }

        ForEach(rootFolders) { folder in
            if isFolderVisible(folder) {
                folderRow(folder)
            }
        }

        if !rootProfiles.isEmpty {
            ForEach(rootProfiles) { profile in
                profileRow(profile)
            }
        } else if (!searchQuery.isEmpty || kindFilter != nil) && !hasVisibleFolders {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                Text("No connections match your search.")
                    .font(LitheTheme.uiFont(size: 10.5))
            }
            .foregroundStyle(LitheTheme.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if feature.profiles.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                Text("No database connections")
                    .font(LitheTheme.uiFont(size: 10.5))
            }
            .foregroundStyle(LitheTheme.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private func folderRow(_ folder: DatabaseConnectionFolder, indent: CGFloat = 0) -> AnyView {
        let profiles = visibleProfiles(in: folder)
        let isExpanded = !searchQuery.isEmpty || !collapsedFolderIDs.contains(folder.id)
        let totalCount = recursiveProfileCount(in: folder)

        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button { toggleFolder(folder) } label: {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(verbatim: "\(String(localized: isExpanded ? "Collapse Folder" : "Expand Folder")) \(folder.name)"))
                Button { treeSelection = .folder(folder.id) } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        LitheIcon(kind: .folder, size: LitheTheme.Metrics.treeIconSize)
                        Text(folder.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if totalCount > 0 {
                            Text("\(totalCount)").foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggleFolder(folder) })
                .accessibilityLabel(Text(verbatim: folder.name))
            }
            .padding(.leading, indent)
            .padding(.trailing, 3)
            .litheTreeRow(isSelected: treeSelection == .folder(folder.id), isFocused: treeActive && controlActiveState == .key)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(targetedFolderID == folder.id ? LitheTheme.accent.opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .litheContextMenu {
                var items: [LitheContextMenuItem] = []
                items.append(.action(isExpanded ? "Collapse Folder" : "Expand Folder", action: {
                    toggleFolder(folder)
                }))
                items.append(.action("New Connection", action: {
                    presentConnectionEditor(defaultFolderID: folder.id)
                }))
                items.append(.action("New Subfolder", action: {
                    presentFolderEditor(parentID: folder.id)
                }))
                items.append(.action("Rename Folder", action: {
                    presentFolderEditor(folder: folder)
                }))
                items.append(.submenu("Move", items: [
                    .action("To Folder…") { presentFolderMove(.folder(folder.id)) },
                    .action("To Top Level", isEnabled: folder.parentID != nil) { feature.moveFolder(folder.id, toParent: nil) }
                ]))
                items.append(.action("Remove Folder", role: .destructive, action: {
                    folderPendingDeletion = folder
                    showsFolderDeletionConfirmation = true
                }))
                return items
            }
            .dropDestination(for: String.self) { items, _ in
                moveDroppedProfile(items, to: folder.id)
            } isTargeted: { targeted in
                targetedFolderID = targeted ? folder.id : nil
            }

            if isExpanded {
                ForEach(profiles) { profile in
                    profileRow(profile, indent: LitheTheme.Tree.indent + indent)
                }
                ForEach(childFolders(of: folder).filter(isFolderVisible)) { child in
                    folderRow(child, indent: indent + LitheTheme.Tree.indent)
                }
            }
        })
    }

    private func profileRow(_ profile: DatabaseProfile, indent: CGFloat = 0) -> some View {
        let isExpanded = expandedProfileIDs.contains(profile.id)
        let isSelected = feature.selectedProfileID == profile.id

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button {
                    toggleProfile(profile)
                } label: {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(isExpanded ? "Collapse connection" : "Expand connection"))

                Button {
                    selectProfile(profile, expand: false)
                } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        DatabaseBrandIcon(kind: profile.kind, size: LitheTheme.Tree.iconSize)
                            .overlay(alignment: .bottomTrailing) {
                                connectionStatusIndicator(profile)
                            }
                        Text(profile.name)
                            .lineLimit(1)
                            .font(LitheTheme.uiFont(size: 13))
                        if profile.productionProtection {
                            Image(systemName: "shield.fill")
                                .font(LitheTheme.uiFont(size: 8))
                                .foregroundStyle(LitheTheme.warning)
                        }
                    }
                    .frame(height: LitheTheme.Tree.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    toggleProfile(profile)
                })
                .layoutPriority(1)
                .contentShape(Rectangle())
                if (profile.kind == .mysql || profile.kind == .mariadb),
                   let tree = feature.databaseTrees[profile.id], tree.state == .ready || !tree.names.isEmpty {
                    let selected = feature.visibleDatabaseNames(for: profile.id).count
                    Button {
                        treeSelection = .connection(profile.id)
                        if databaseScopeProfileID == profile.id { applyDatabaseScope(for: profile.id) }
                        else {
                            databaseScopeSelection = profile.visibleDatabases
                            databaseScopeProfileID = profile.id
                        }
                    } label: {
                        // This is a selected/available count, never the localized ordinal "%lld of %lld".
                        Text(verbatim: " \(selected) of \(tree.names.count) ")
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.Tree.secondaryText)
                            .frame(height: LitheTheme.Tree.rowHeight)
                            .background {
                                // IDEA SimpleColoredComponent.drawClickableFrag: 1/2 insets, arc diameter 6.
                                let shape = RoundedRectangle(cornerRadius: 3)
                                let hovered = hoveredScopeProfileID == profile.id
                                    && !(treeSelection == .connection(profile.id) && treeActive && controlActiveState == .key)
                                shape.fill(hovered ? LitheTheme.toolbarHoverBackground : .clear)
                                    .overlay(shape.stroke(hovered ? .clear : LitheTheme.toolbarHoverBackground, lineWidth: 1))
                                    .padding(.horizontal, 1).padding(.vertical, 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .fixedSize()
                    .accessibilityLabel("Select databases")
                    .accessibilityValue(Text(verbatim: "\(selected) of \(tree.names.count)"))
                    .accessibilityIdentifier("database-schema-scope")
                    // IDEA separates the connection name with an en space at the normal 13pt tree font.
                    .padding(.leading, 13 / 2 - LitheTheme.Tree.iconTextGap)
                    .onHover { hoveredScopeProfileID = $0 ? profile.id : nil }
                    .lithePointer()
                    .litheDropdown(isPresented: Binding(
                        get: { databaseScopeProfileID == profile.id },
                        set: { databaseScopeProfileID = $0 ? profile.id : nil }
                    ), searchOnTyping: true, onAccept: {
                        applyDatabaseScope(for: profile.id)
                    }) {
                        DatabaseSchemaSelector(profileID: profile.id, names: tree.names, selection: $databaseScopeSelection) {
                            applyDatabaseScope(for: profile.id)
                        }
                        .environmentObject(feature)
                        .environment(\.locale, model.settings.language.locale)
                    }
                }
                Button {
                    selectProfile(profile, expand: false)
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggleProfile(profile) })
                .accessibilityHidden(true)
            }
            .padding(.trailing, 9)
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .litheTreeRow(isSelected: treeSelection == .connection(profile.id), isFocused: treeActive && controlActiveState == .key)
            .draggable(profile.id.uuidString)
            .litheContextMenu { connectionContextMenu(profile) }

            if isExpanded {
                if profile.kind == .mysql || profile.kind == .mariadb {
                    mysqlDatabaseTree(profile, indent: indent + LitheTheme.Tree.indent)
                        .task(id: profile) { await feature.loadDatabaseTree(for: profile.id) }
                } else if isSelected {
                    profileObjectTree(profile, indent: indent + LitheTheme.Tree.indent)
                }
            }
        }
    }

    private func applyDatabaseScope(for profileID: UUID) {
        if feature.setVisibleDatabases(databaseScopeSelection, for: profileID) { databaseScopeProfileID = nil }
    }

    @ViewBuilder
    private func mysqlDatabaseTree(_ profile: DatabaseProfile, indent: CGFloat) -> some View {
        let tree = feature.databaseTrees[profile.id] ?? DatabaseConnectionTree()
        treeLoadStatus(tree.state, indent: indent) {
            Task { await feature.loadDatabaseTree(for: profile.id, force: true) }
        }
        ForEach(feature.visibleDatabaseNames(for: profile.id), id: \.self) { database in
            let target = databaseProfile(profile, database: database)
            let path = DatabaseTreePath(target)
            let isExpanded = expandedDatabasePaths.contains(path)
            let snapshot = tree.databases[database] ?? DatabaseTreeDatabase()
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button {
                    toggleDatabase(target)
                } label: {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                        .frame(width: LitheTheme.Tree.disclosureSlot)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(verbatim: "\(String(localized: isExpanded ? "Collapse database" : "Expand database")) \(database)"))
                Button {
                    treeSelection = .database(path)
                } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        LitheIDEAIcon(resourcePath: "database/expui/schema.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                        Text(verbatim: database).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggleDatabase(target) })
            }
            .font(LitheTheme.uiFont(size: 13))
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
            .litheTreeRow(isSelected: treeSelection == .database(path),
                          isFocused: treeActive && controlActiveState == .key)
            .litheContextMenu { databaseContextMenu(target) }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    treeLoadStatus(snapshot.state, indent: indent + LitheTheme.Tree.indent) {
                        Task { await feature.loadDatabaseTree(database, for: profile.id, force: true) }
                    }
                    if snapshot.state == .ready || !snapshot.tables.isEmpty || !snapshot.objects.isEmpty {
                        databaseObjects(for: target, indent: indent + LitheTheme.Tree.indent, snapshot: snapshot)
                    }
                }
                .task(id: profile) { await feature.loadDatabaseTree(database, for: profile.id) }
            }
        }
        if tree.state == .ready, tree.names.isEmpty {
            Text("No accessible databases")
                .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.Tree.secondaryText)
                .padding(.leading, indent).frame(height: LitheTheme.Tree.rowHeight)
        } else if tree.state == .ready, feature.visibleDatabaseNames(for: profile.id).isEmpty {
            Text("No schemas selected")
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.Tree.secondaryText)
                .padding(.leading, indent + LitheTheme.Tree.indent).frame(height: LitheTheme.Tree.rowHeight)
                .accessibilityIdentifier("database-no-schemas-selected")
        }
    }

    @ViewBuilder
    private func treeLoadStatus(_ state: DatabaseTreeLoadState, indent: CGFloat, retry: @escaping () -> Void) -> some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
            }
            .font(LitheTheme.uiFont(size: 13)).foregroundStyle(LitheTheme.Tree.secondaryText)
            .padding(.leading, indent).frame(height: LitheTheme.Tree.rowHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Loading…"))
        case .failed(let message):
            Button(action: retry) {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Tree.iconSize)
                    Text("Retry").lineLimit(1)
                }
                .padding(.leading, indent).frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress).litheTreeRow().help(message)
            .accessibilityLabel(Text(message))
        case .ready:
            EmptyView()
        }
    }

    private func databaseProfile(_ profile: DatabaseProfile, database: String) -> DatabaseProfile {
        var target = profile
        target.database = database
        return target
    }

    @ViewBuilder
    private func profileObjectTree(_ profile: DatabaseProfile, indent: CGFloat) -> some View {
        if profile.kind.supportsDataGrid {
            let databaseExpanded = !collapsedDatabaseProfileIDs.contains(profile.id)
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button { toggleDatabase(profile) } label: {
                    LitheIDEAIcon(resourcePath: databaseExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(verbatim: "\(String(localized: databaseExpanded ? "Collapse database" : "Expand database")) \(profile.database.isEmpty ? (profile.kind == .mongodb ? "admin" : String(localized: "Default database")) : profile.database)"))
                Button { treeSelection = .database(DatabaseTreePath(profile)) } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        LitheIDEAIcon(resourcePath: "database/expui/schema.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                        Group {
                            if profile.database.isEmpty { Text(profile.kind == .mongodb ? "admin" : "Default database") }
                            else { Text(verbatim: profile.database) }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .simultaneousGesture(TapGesture(count: 2).onEnded { toggleDatabase(profile) })
            }
            .font(LitheTheme.uiFont(size: 13))
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .litheTreeRow(isSelected: treeSelection == .database(DatabaseTreePath(profile)), isFocused: treeActive && controlActiveState == .key)
            .litheContextMenu {
                var items: [LitheContextMenuItem] = []
                if profile.kind == .mongodb { items.append(contentsOf: mongoDatabaseContextMenu(profile)) }
                else { items.append(contentsOf: databaseContextMenu(profile)) }
                return items
            }

            if databaseExpanded {
                databaseObjects(for: profile, indent: indent + LitheTheme.Tree.indent)
            }
        } else if profile.kind == .redis {
            sidebarLeaf(
                title: "Redis database",
                detail: profile.database.isEmpty ? "0" : profile.database,
                symbol: "square.stack.3d.up",
                count: feature.redisKeys.count,
                indent: indent
            )
            .litheContextMenu { redisDatabaseContextMenu(profile) }
        } else {
            sidebarLeaf(title: "Configurations", symbol: "doc.text", count: feature.nacosConfigs.count, indent: indent)
                .litheContextMenu { nacosContextMenu(profile) }
            sidebarLeaf(title: "Services", symbol: "network", count: feature.nacosServices.count, indent: indent)
                .litheContextMenu { nacosContextMenu(profile) }
        }
    }

    @ViewBuilder
    private func databaseObjects(for profile: DatabaseProfile, indent: CGFloat, snapshot: DatabaseTreeDatabase? = nil) -> some View {
        let path = DatabaseTreePath(profile)
        let collapsed = collapsedObjectKinds[path] ?? []
        let tables = snapshot?.tables ?? feature.tables
        let objects = snapshot?.objects ?? feature.objects
        let isLoading = snapshot.map { $0.state == .loading } ?? feature.isLoading
        if profile.kind.supportsDataGrid {
            objectSectionHeader(kind: .tables, title: profile.kind == .mongodb ? "Collections" : "Tables", profile: profile, count: tables.count, indent: indent)
                .litheContextMenu {
                    var items: [LitheContextMenuItem] = []
                    if profile.kind == .mongodb { items.append(.action("Refresh Collections", action: { refresh(profile) })) }
                    else { items.append(contentsOf: tableGroupContextMenu(profile)) }
                    return items
                }
            if !collapsed.contains(.tables), tables.isEmpty && !isLoading {
                Text(profile.kind == .mongodb ? "No collections yet" : "No tables yet")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .padding(.leading, indent + LitheTheme.Tree.indent)
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
            }
            if !collapsed.contains(.tables) {
                ForEach(tables, id: \.self) { table in
                    let tableKey = DatabaseTreeTableKey(profileID: profile.id, database: profile.database, table: table)
                    let isExpanded = expandedTableKeys.contains(tableKey)
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        Button {
                            if isExpanded { expandedTableKeys.remove(tableKey) }
                            else { expandedTableKeys.insert(tableKey) }
                        } label: {
                            LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                                .foregroundStyle(LitheTheme.tertiaryText)
                                .frame(width: LitheTheme.Tree.disclosureSlot)
                        }
                        .buttonStyle(.litheNoPress)
                        .accessibilityLabel(Text(verbatim: "\(String(localized: isExpanded ? "Collapse table" : "Expand table")) \(table)"))
                        Button {
                            treeSelection = .table(tableKey)
                        } label: {
                            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                                LitheIDEAIcon(resourcePath: profile.kind == .mongodb ? "database/expui/collection.svg" : "database/expui/table.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                                Text(table).font(LitheTheme.uiFont(size: 13)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.litheNoPress)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            openTable(profile, table: table, section: .data)
                        })
                        .accessibilityAction(named: Text("Open")) {
                            openTable(profile, table: table, section: .data)
                        }
                    }
                    .padding(.leading, indent + LitheTheme.Tree.indent)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .litheTreeRow(isSelected: treeSelection == .table(tableKey),
                                  isFocused: treeActive && controlActiveState == .key)
                    .litheContextMenu {
                        var items: [LitheContextMenuItem] = []
                        if profile.kind == .mongodb { items.append(contentsOf: mongoCollectionContextMenu(profile, collection: table)) }
                        else { items.append(contentsOf: tableContextMenu(profile, table: table)) }
                        return items
                    }

                    if isExpanded {
                        let metadata = feature.tableTrees[tableKey] ?? DatabaseTreeTable()
                        VStack(alignment: .leading, spacing: 0) {
                            treeLoadStatus(metadata.state, indent: indent + LitheTheme.Tree.indent * 2) {
                                Task { await feature.loadTableTree(tableKey, force: true) }
                            }
                            if metadata.state == .ready {
                                sidebarLeaf(title: profile.kind == .mongodb ? "Fields" : "Columns", symbol: "database/expui/column.svg", count: metadata.columns.count, indent: indent + LitheTheme.Tree.indent * 2)
                                sidebarLeaf(title: "Indexes", symbol: "database/expui/goldKey.svg", count: metadata.indexes.count, indent: indent + LitheTheme.Tree.indent * 2)
                                if profile.kind != .mongodb {
                                    sidebarLeaf(title: "Foreign Keys", symbol: "database/expui/blueKey.svg", count: metadata.foreignKeys.count, indent: indent + LitheTheme.Tree.indent * 2)
                                }
                            }
                        }
                        .task(id: feature.tableTrees[tableKey]?.requestID) { await feature.loadTableTree(tableKey) }
                    }
                }
            }
            ForEach(profile.kind == .mongodb ? [] : DatabaseObjectKind.allCases.filter { $0 != .tables }, id: \.self) { kind in
                let entries = objects[kind] ?? []
                if !entries.isEmpty {
                    objectSectionHeader(kind: kind, title: LocalizedStringKey(kind.title), profile: profile, count: entries.count, indent: indent)
                    if !collapsed.contains(kind) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, row in
                            Text(objectLabel(row)).font(LitheTheme.uiFont(size: 13)).lineLimit(1)
                                .padding(.leading, indent + LitheTheme.Tree.indent)
                                .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                                .litheTreeRow()
                        }
                    }
                }
            }
        }
    }

    private func objectSectionHeader(kind: DatabaseObjectKind, title: LocalizedStringKey, profile: DatabaseProfile, count: Int, indent: CGFloat) -> some View {
        let path = DatabaseTreePath(profile)
        let collapsed = collapsedObjectKinds[path] ?? []
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            Button { toggleObjectSection(kind, profile: profile) } label: {
                LitheIDEAIcon(resourcePath: !collapsed.contains(kind) ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                    .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel((collapsed.contains(kind) ? Text("Expand") : Text("Collapse")) + Text(" ") + Text(title))
            Button { treeSelection = .objects(path, kind) } label: {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheIDEAIcon(resourcePath: "database/expui/objectGroup.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                    Text(title).foregroundStyle(LitheTheme.Tree.text)
                    Spacer(minLength: 0)
                    Text("\(count)").monospacedDigit().foregroundStyle(LitheTheme.Tree.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .simultaneousGesture(TapGesture(count: 2).onEnded { toggleObjectSection(kind, profile: profile) })
            .accessibilityLabel(Text(title))
        }
        .font(LitheTheme.uiFont(size: 13))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .litheTreeRow(isSelected: treeSelection == .objects(path, kind), isFocused: treeActive && controlActiveState == .key)
    }

    private func toggleFolder(_ folder: DatabaseConnectionFolder) {
        collapsedFolderIDs.formSymmetricDifference([folder.id])
    }

    private func toggleDatabase(_ profile: DatabaseProfile) {
        if profile.kind == .mysql || profile.kind == .mariadb {
            let path = DatabaseTreePath(profile)
            expandedDatabasePaths.formSymmetricDifference([path])
            if expandedDatabasePaths.contains(path) {
                Task { await feature.loadDatabaseTree(profile.database, for: profile.id) }
            }
        } else {
            collapsedDatabaseProfileIDs.formSymmetricDifference([profile.id])
        }
    }

    private func toggleObjectSection(_ kind: DatabaseObjectKind, profile: DatabaseProfile) {
        collapsedObjectKinds[DatabaseTreePath(profile), default: []].formSymmetricDifference([kind])
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
            if profile.kind == .mysql || profile.kind == .mariadb {
                Task { await feature.loadDatabaseTree(for: profile.id) }
            }
        }
        model.selectDatabaseWorkspace(profileID: profile.id, refresh: feature.selectedProfileID != profile.id)
    }

    private func toggleProfile(_ profile: DatabaseProfile) {
        if expandedProfileIDs.contains(profile.id) {
            expandedProfileIDs.remove(profile.id)
        } else {
            expandedProfileIDs.insert(profile.id)
            if profile.kind == .mysql || profile.kind == .mariadb {
                Task { await feature.loadDatabaseTree(for: profile.id) }
            } else {
                selectProfile(profile, expand: true)
            }
        }
    }

    private func collapseAll() {
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
            LitheSearchTextField("Search databases", text: $query)
                .focused($searchFocused)
                .litheSearchField(isFocused: searchFocused)
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
                            var selected = Set(selection ?? names)
                            if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
                            selection = names.filter { selected.contains($0) }
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
        // CheckboxTree hides the root but reserves its handle, using the shared tree indent.
        .padding(.leading, LitheTheme.Tree.indent)
        .litheTreeRow(isSelected: selectedRow == (name ?? ""), isFocused: true)
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
    @FocusState private var focusedField: String?

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
                        TextField("", text: Binding(get: { connectionName }, set: { name = $0; usesDefaultName = false }))
                            .accessibilityLabel("Name")
                            .focused($focusedField, equals: "name")
                            .litheSettingsTextField()
                            .frame(maxWidth: .infinity)
                    }
            }.padding(16)
            HStack(spacing: 6) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button { focusedField = nil; section = item } label: {
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
                                    TextField("", text: $path)
                                        .accessibilityLabel("Database file path")
                                        .focused($focusedField, equals: "path")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                GridRow {
                                    Text(kind == .mongodb ? "Host or MongoDB URI" : "Host")
                                        .frame(width: 140, alignment: .leading)
                                    HStack(spacing: 12) {
                                        TextField("", text: $host)
                                            .accessibilityLabel(kind == .mongodb ? "Host or MongoDB URI" : "Host")
                                            .focused($focusedField, equals: "host")
                                            .litheSettingsTextField()
                                            .frame(maxWidth: .infinity)
                                        Text("Port").frame(width: 42, alignment: .trailing)
                                        TextField("", text: $port)
                                            .accessibilityLabel("Port")
                                            .focused($focusedField, equals: "port")
                                            .litheSettingsTextField()
                                            .frame(width: 140)
                                    }
                                }
                                GridRow {
                                    Text(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                        .frame(width: 140, alignment: .leading)
                                    HStack(spacing: 12) {
                                        TextField("", text: $username)
                                            .accessibilityLabel(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                            .focused($focusedField, equals: "username")
                                            .litheSettingsTextField()
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
                                        SecureField("", text: $password)
                                            .accessibilityLabel("Password")
                                            .focused($focusedField, equals: "password")
                                            .litheSettingsTextField()
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
                                        TextField("", text: $database)
                                            .accessibilityLabel("Redis database index")
                                            .focused($focusedField, equals: "database")
                                            .litheSettingsTextField()
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
                                        TextField("", text: $database)
                                            .accessibilityLabel("Namespace ID (optional)")
                                            .focused($focusedField, equals: "database")
                                            .litheSettingsTextField()
                                            .frame(maxWidth: .infinity)
                                    }
                                    GridRow {
                                        Text("API context path")
                                            .frame(width: 140, alignment: .leading)
                                        TextField("", text: $path)
                                            .accessibilityLabel("API context path")
                                            .focused($focusedField, equals: "path")
                                            .litheSettingsTextField()
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
                                        TextField("", text: $database)
                                            .accessibilityLabel("Database name")
                                            .focused($focusedField, equals: "database")
                                            .litheSettingsTextField()
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
                                    TextField("", text: $caCertificatePath)
                                        .accessibilityLabel("TLS CA certificate path")
                                        .focused($focusedField, equals: "caCertificatePath")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("TLS server name")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $serverName)
                                        .accessibilityLabel("TLS server name")
                                        .focused($focusedField, equals: "serverName")
                                        .litheSettingsTextField()
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
                                    TextField("", text: $sshHost)
                                        .accessibilityLabel("SSH host")
                                        .focused($focusedField, equals: "sshHost")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH port")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshPort)
                                        .accessibilityLabel("SSH port")
                                        .focused($focusedField, equals: "sshPort")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH username")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshUsername)
                                        .accessibilityLabel("SSH username")
                                        .focused($focusedField, equals: "sshUsername")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH key path")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshKeyPath)
                                        .accessibilityLabel("SSH key path")
                                        .focused($focusedField, equals: "sshKeyPath")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH local port")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshLocalPort)
                                        .accessibilityLabel("SSH local port")
                                        .focused($focusedField, equals: "sshLocalPort")
                                        .litheSettingsTextField()
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("Proxy URL (optional)")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $proxyURL)
                                        .accessibilityLabel("Proxy URL (optional)")
                                        .focused($focusedField, equals: "proxyURL")
                                        .litheSettingsTextField()
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
                                TextField("", text: $colorHex)
                                    .accessibilityLabel("Color hex (optional)")
                                    .focused($focusedField, equals: "colorHex")
                                    .litheSettingsTextField()
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
                                    TextField("", text: $sensitiveColumnPatterns)
                                        .accessibilityLabel("Sensitive column patterns")
                                        .focused($focusedField, equals: "sensitiveColumnPatterns")
                                        .litheSettingsTextField()
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
        .task { focusedField = "name" }
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
