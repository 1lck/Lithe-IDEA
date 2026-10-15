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

struct DatabaseSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var treeActive = false
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
    @State private var collapsedObjectKinds: Set<DatabaseObjectKind> = []
    @State private var expandedProfileIDs: Set<UUID> = []
    @State private var collapsedDatabaseProfileIDs: Set<UUID> = []
    @State private var expandedTableKey: String?
    @State private var targetedFolderID: UUID?
    @State private var isUnfiledDropTarget = false
    @State private var kindFilter: DatabaseKind?
    @State private var connectionSort = DatabaseConnectionSort.name
    @State private var showsFolderEditor = false
    @State private var editingFolder: DatabaseConnectionFolder?
    @State private var creatingFolderParentID: UUID?
    @State private var newConnectionFolderID: UUID?
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
                        Button { presentConnectionEditor() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/add.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton().workbenchHoverHelp(Text("Add database connection"))
                            .accessibilityLabel("Add database connection")
                        Button { editingFolder = nil; creatingFolderParentID = nil; showsFolderEditor = true } label: {
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
                        Button { refreshSelectedConnection() } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/refresh.svg",
                                size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton(isEnabled: feature.selectedProfile != nil)
                            .workbenchHoverHelp(Text("Refresh connection structure"))
                            .accessibilityLabel("Refresh connection structure")
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        connectionTree
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                    .padding(.vertical, LitheTheme.Tree.verticalInset)
                }
                .background(LitheToolWindowActivityTracker(isActive: $treeActive))
            }
            if feature.isLoading { ProgressView().controlSize(.small).padding(8) }
        }
        .workbenchHoverTooltipScope()
        .background(LitheCenteredPopup(isPresented: $showsConnectionEditor, dialogTitle: String(localized: editingProfile == nil ? "Add Database Connection" : "Edit Database Connection")) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor, profile: editingProfile, defaultFolderID: newConnectionFolderID)
                .id(connectionEditorPresentationID)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        })
        .background(LitheCenteredPopup(isPresented: $showsFolderEditor, dialogTitle: String(localized: editingFolder == nil ? "New Folder" : "Rename Folder")) {
            DatabaseFolderEditor(isPresented: $showsFolderEditor, folder: editingFolder, parentID: creatingFolderParentID)
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
                    if feature.selectedProfileID != profile.id { await feature.select(profile) }
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
            if let selectedID { expandedProfileIDs = [selectedID] }
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
            Text("Unfiled connections")
                .font(LitheTheme.uiFont(size: 9.5, weight: .semibold))
                .foregroundStyle(LitheTheme.tertiaryText)
                .textCase(.uppercase)
                .padding(.top, feature.folders.isEmpty ? 3 : 9)
                .padding(.horizontal, 9)
                .dropDestination(for: String.self) { items, _ in
                    moveDroppedProfile(items, to: nil)
                } isTargeted: { targeted in
                    isUnfiledDropTarget = targeted
                }
                .background(isUnfiledDropTarget ? LitheTheme.accent.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
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
            HStack(spacing: 1) {
                Button {
                    if collapsedFolderIDs.contains(folder.id) {
                        collapsedFolderIDs.remove(folder.id)
                    } else {
                        collapsedFolderIDs.insert(folder.id)
                    }
                } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .frame(width: LitheTheme.Tree.disclosureSlot)
                        LitheIcon(kind: .folder, size: LitheTheme.Metrics.treeIconSize)
                        Text(folder.name)
                            .lineLimit(1)
                            .font(LitheTheme.uiFont(size: 13))
                        Spacer(minLength: 4)
                        if totalCount > 0 {
                            Text("\(totalCount)")
                                .font(LitheTheme.uiFont(size: 13))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                    .padding(.leading, indent)
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: LitheTheme.Tree.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .litheTreeRow()

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(targetedFolderID == folder.id ? LitheTheme.accent.opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .litheContextMenu {
                var items: [LitheContextMenuItem] = []
                items.append(.action(isExpanded ? "Collapse Folder" : "Expand Folder", action: {
                    if isExpanded { collapsedFolderIDs.insert(folder.id) }
                    else { collapsedFolderIDs.remove(folder.id) }
                }))
                items.append(.action("New Connection", action: {
                    presentConnectionEditor(defaultFolderID: folder.id)
                }))
                items.append(.action("New Subfolder", action: {
                    editingFolder = nil
                    creatingFolderParentID = folder.id
                    showsFolderEditor = true
                }))
                items.append(.action("Rename Folder", action: {
                    editingFolder = folder
                    showsFolderEditor = true
                }))
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
                    selectProfile(profile, expand: true)
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
                        Spacer(minLength: 4)
                    }
                    .padding(.trailing, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: LitheTheme.Tree.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .litheTreeRow(isSelected: isSelected, isFocused: treeActive && controlActiveState == .key)
            .draggable(profile.id.uuidString)
            .litheContextMenu { connectionContextMenu(profile) }

            if isExpanded, isSelected {
                profileObjectTree(profile, indent: indent + LitheTheme.Tree.indent)
            }
        }
    }

    @ViewBuilder
    private func profileObjectTree(_ profile: DatabaseProfile, indent: CGFloat) -> some View {
        if profile.kind.supportsDataGrid {
            let databaseExpanded = !collapsedDatabaseProfileIDs.contains(profile.id)
            Button {
                if databaseExpanded { collapsedDatabaseProfileIDs.insert(profile.id) }
                else { collapsedDatabaseProfileIDs.remove(profile.id) }
            } label: {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheIDEAIcon(resourcePath: databaseExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: LitheTheme.Tree.disclosureSlot)
                    LitheIDEAIcon(resourcePath: "database/expui/schema.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                    Group {
                        if profile.database.isEmpty {
                            Text(profile.kind == .mongodb ? "admin" : "Default database")
                        } else {
                            Text(verbatim: profile.database)
                        }
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, indent)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .litheTreeRow()
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
    private func databaseObjects(for profile: DatabaseProfile, indent: CGFloat) -> some View {
        if profile.kind.supportsDataGrid {
            objectSectionHeader(kind: .tables, title: profile.kind == .mongodb ? "Collections" : "Tables", count: feature.tables.count, indent: indent)
                .litheContextMenu {
                    var items: [LitheContextMenuItem] = []
                    if profile.kind == .mongodb { items.append(.action("Refresh Collections", action: { refresh(profile) })) }
                    else { items.append(contentsOf: tableGroupContextMenu(profile)) }
                    return items
                }
            if !collapsedObjectKinds.contains(.tables), feature.tables.isEmpty && !feature.isLoading {
                Text(profile.kind == .mongodb ? "No collections yet" : "No tables yet")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
                    .padding(.leading, indent + LitheTheme.Tree.indent)
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
            }
            if !collapsedObjectKinds.contains(.tables) {
                ForEach(feature.tables, id: \.self) { table in
                    let tableKey = "\(profile.id.uuidString)|\(table)"
                    let isExpanded = expandedTableKey == tableKey
                    Button {
                        expandedTableKey = isExpanded ? nil : tableKey
                        openTable(profile, table: table, section: .data)
                    } label: {
                        HStack(spacing: LitheTheme.Tree.iconTextGap) {
                            LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                                .foregroundStyle(LitheTheme.tertiaryText)
                                .frame(width: LitheTheme.Tree.disclosureSlot)
                            if profile.kind == .mongodb {
                                LitheIDEAIcon(resourcePath: "database/expui/collection.svg", size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                                    .frame(width: LitheTheme.Tree.iconSize)
                            } else {
                                LitheIDEAIcon(resourcePath: "database/expui/table.svg", size: LitheTheme.Tree.iconSize,
                                              preservesOriginalColors: true)
                            }
                            Text(table)
                                .font(LitheTheme.uiFont(size: 13))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, indent + 14)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .litheTreeRow(isSelected: feature.selectedTable == table,
                                  isFocused: treeActive && controlActiveState == .key)
                    .litheContextMenu {
                        var items: [LitheContextMenuItem] = []
                        if profile.kind == .mongodb { items.append(contentsOf: mongoCollectionContextMenu(profile, collection: table)) }
                        else { items.append(contentsOf: tableContextMenu(profile, table: table)) }
                        return items
                    }

                    if isExpanded, feature.selectedTable == table {
                        if feature.isLoading {
                            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                                ProgressView().controlSize(.mini)
                                Text("Loading table metadata…")
                                    .font(LitheTheme.uiFont(size: 13))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                            }
                            .padding(.leading, indent + 48)
                            .frame(height: 24)
                        } else {
                            sidebarLeaf(title: profile.kind == .mongodb ? "Fields" : "Columns", symbol: "expui/nodes/dataTables.svg", count: feature.columns.count, indent: indent + 36, tint: LitheTheme.success)
                            sidebarLeaf(title: "Indexes", symbol: "database/expui/goldKey.svg", count: feature.indexes.count, indent: indent + 36, tint: LitheTheme.warning)
                            if profile.kind != .mongodb {
                                sidebarLeaf(title: "Foreign Keys", symbol: "database/expui/blueKey.svg", count: feature.foreignKeys.count, indent: indent + 36, tint: LitheTheme.accent)
                            }
                        }
                    }
                }
            }
            ForEach(profile.kind == .mongodb ? [] : DatabaseObjectKind.allCases.filter { $0 != .tables }, id: \.self) { kind in
                let entries = feature.objects[kind] ?? []
                if !entries.isEmpty {
                    objectSectionHeader(kind: kind, title: LocalizedStringKey(kind.title), count: entries.count, indent: indent)
                    if !collapsedObjectKinds.contains(kind) {
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

    private func objectSectionHeader(kind: DatabaseObjectKind, title: LocalizedStringKey, count: Int, indent: CGFloat) -> some View {
        Button {
            if collapsedObjectKinds.contains(kind) { collapsedObjectKinds.remove(kind) }
            else { collapsedObjectKinds.insert(kind) }
        } label: {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                LitheIDEAIcon(resourcePath: !collapsedObjectKinds.contains(kind) ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg", size: LitheTheme.Tree.iconSize)
                    .frame(width: LitheTheme.Tree.disclosureSlot)
                LitheIDEAIcon(resourcePath: "database/expui/objectGroup.svg", size: LitheTheme.Tree.iconSize,
                              preservesOriginalColors: true)
                Text(title)
                    .foregroundStyle(LitheTheme.Tree.text)
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(LitheTheme.Tree.secondaryText)
            }
            .font(LitheTheme.uiFont(size: 13))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .litheTreeRow()
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
        feature.move(profile, toFolder: folderID)
        targetedFolderID = nil
        isUnfiledDropTarget = false
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
                feature.disconnect(profile)
            } else {
                selectProfile(profile, expand: true)
            }
        }))
        if profile.kind.isSQLDatabase {
            items.append(.action("New Query", action: { openSQLQuery(profile) }))
        }
        items.append(.action("Refresh", action: { refresh(profile) }))
        items.append(.separator)
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.name) }))
        items.append(.action("Edit Connection", action: {
            presentConnectionEditor(profile: profile)
        }))
        items.append(.submenu("Move to Folder", items: {
            var submenuItems: [LitheContextMenuItem] = []
            submenuItems.append(.action("Move to root", isEnabled: !(profile.folderID == nil), action: { feature.move(profile, toFolder: nil) }))
            if !feature.folders.isEmpty {
                submenuItems.append(.separator)
                for folder in feature.folders {
                    submenuItems.append(.action(folder.name, isEnabled: !(profile.folderID == folder.id), action: { feature.move(profile, toFolder: folder.id) }))
                }
            }
            submenuItems.append(.separator)
            submenuItems.append(.action("New Folder", action: {
                editingFolder = nil
                creatingFolderParentID = nil
                showsFolderEditor = true
            }))
            return submenuItems
        }()))
        items.append(.action("Duplicate Connection", action: { _ = feature.duplicate(profile) }))
        items.append(.separator)
        items.append(.action("Remove Connection", role: .destructive, action: {
            profilePendingDeletion = profile
            showsProfileDeletionConfirmation = true
        }))
        return items
    }

    private func refresh(_ profile: DatabaseProfile) {
        Task { await feature.refresh(profile) }
    }

    private func refreshSelectedConnection() {
        guard let profile = feature.selectedProfile else { return }
        refresh(profile)
    }

    private func openSQLQuery(_ profile: DatabaseProfile, sql: String = "") {
        model.openDatabaseQuery(profileID: profile.id, sql: sql)
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
                    if feature.selectedProfileID != profile.id { await feature.select(profile) }
                    importFormat = .sql; pendingImportFormat = .sql; showsImporter = true
                }
            }))
            items.append(.action("Export Database as SQL…", action: { exportDatabase(profile) }))
        }
        items.append(.separator)
        items.append(.action("Copy Name", action: { copyToPasteboard(profile.database.isEmpty ? "Default database" : profile.database) }))
        items.append(.action("Refresh", action: { refresh(profile) }))
        return items
    }

    private func mongoDatabaseContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("Refresh Collections", action: { refresh(profile) }))
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
                if feature.selectedProfileID != profile.id { await feature.select(profile) }
                await feature.openTable(collection)
            }
        }))
        return items
    }

    private func tableGroupContextMenu(_ profile: DatabaseProfile) -> [LitheContextMenuItem] {
        var items: [LitheContextMenuItem] = []
        items.append(.action("New Table", isEnabled: !(profile.readOnly), action: { openSQLQuery(profile, sql: "CREATE TABLE new_table (\n    id INTEGER PRIMARY KEY\n);\n") }))
        items.append(.action("Refresh", action: { refresh(profile) }))
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
        defaultFolderID: UUID? = nil
    ) {
        editingProfile = profile
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
        items.append(.action("Refresh", action: { refresh(profile) }))
        return items
    }

    private func openTable(_ profile: DatabaseProfile, table: String, section: DatabaseWorkspaceSection, sql: String = "") {
        if section == .sql {
            model.openDatabaseQuery(profileID: profile.id, sql: sql)
        } else {
            model.selectDatabaseWorkspace(profileID: profile.id, table: table)
            guard model.databaseFeatureIfActive === feature, feature.selectedProfileID == profile.id else { return }
            feature.workspaceSection = section
        }
    }

    private func executeTableAction(_ action: DatabaseTableContextAction) {
        pendingTableAction = nil
        let sql = action.kind == .clear
            ? "DELETE FROM \(quotedIdentifier(action.table, kind: action.profile.kind));"
            : "DROP TABLE \(quotedIdentifier(action.table, kind: action.profile.kind));"
        model.openDatabaseQuery(profileID: action.profile.id, sql: sql)
        guard model.databaseFeatureIfActive === feature, feature.selectedProfileID == action.profile.id else { return }
        guard let tabID = feature.selectedSQLTabID else { return }
        model.showToolWindow(.databaseServices)
        Task {
            guard model.databaseFeatureIfActive === feature, feature.selectedProfileID == action.profile.id else { return }
            await feature.runSQL(in: tabID, confirmedRisk: true)
            guard model.databaseFeatureIfActive === feature, feature.selectedProfileID == action.profile.id else { return }
            if action.kind == .clear { await feature.openTable(action.table) }
            else { await feature.refreshTables() }
        }
    }

    private func beginImport(_ format: DatabaseTransferFormat, profile: DatabaseProfile, table: String?) {
        Task {
            if feature.selectedProfileID != profile.id { await feature.select(profile) }
            if let table { await feature.openTable(table) }
            importFormat = format
            pendingImportFormat = format
            showsImporter = true
        }
    }

    private func exportTable(_ profile: DatabaseProfile, table: String, format: DatabaseTransferFormat) {
        Task {
            if feature.selectedProfileID != profile.id { await feature.select(profile) }
            await feature.openTable(table)
            exportFormat = format
            guard let data = await feature.exportData(format: format) else { return }
            exportDocument = DatabaseTransferDocument(data: data)
            showsExporter = true
        }
    }

    private func exportDatabase(_ profile: DatabaseProfile) {
        Task {
            if feature.selectedProfileID != profile.id { await feature.select(profile) }
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
        if expand { expandedProfileIDs = [profile.id] }
        model.selectDatabaseWorkspace(profileID: profile.id, refresh: true)
    }

    private func toggleProfile(_ profile: DatabaseProfile) {
        if expandedProfileIDs.contains(profile.id) {
            expandedProfileIDs.remove(profile.id)
        } else {
            expandedProfileIDs.insert(profile.id)
            selectProfile(profile, expand: true)
        }
    }

    private func collapseAll() {
        collapsedFolderIDs = Set(feature.folders.map(\.id))
        expandedProfileIDs.removeAll()
        collapsedObjectKinds = Set(DatabaseObjectKind.allCases)
        expandedTableKey = nil
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
            HStack {
                if plan != nil {
                    Text("\(selectedIDs.count) connections selected")
                        .font(LitheTheme.uiFont(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(LitheCommitDialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if let plan {
                    Button("Import Selected") {
                        let count = feature.importDBXConnections(plan: plan, selectedIDs: selectedIDs)
                        if count > 0 { isPresented = false }
                    }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
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
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
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

private struct DatabaseFolderEditor: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Binding var isPresented: Bool
    let folder: DatabaseConnectionFolder?
    let parentID: UUID?
    @State private var name = ""
    @State private var validationMessage: String?
    @FocusState private var nameFocused: Bool

    init(isPresented: Binding<Bool>, folder: DatabaseConnectionFolder?, parentID: UUID? = nil) {
        _isPresented = isPresented
        self.folder = folder
        self.parentID = parentID
        _name = State(initialValue: folder?.name ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(folder == nil ? "Keep connections organized in the sidebar." : "Update the folder name without changing its connections.")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent {
                        TextField("", text: $name)
                            .accessibilityLabel("Folder name")
                            .focused($nameFocused)
                            .modifier(LitheCommitDialogInputStyle(focused: nameFocused))
                            .frame(width: 200)
                    } label: {
                        Text("Folder name")
                            .frame(width: 150, alignment: .leading)
                    }
                        .onSubmit(save)
                    if let validationMessage {
                        DatabaseLocalization.error(validationMessage)
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(LitheTheme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(LitheCommitDialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(folder == nil ? "Create folder" : "Save folder") { save() }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(LitheCommitDialogStyle.background)
        }
        .task { nameFocused = true }
        .frame(width: 390, height: 240)
        .background(LitheCommitDialogStyle.background)
    }

    private func save() {
        let didSave: Bool
        if let folder {
            didSave = feature.renameFolder(folder, to: name)
        } else {
            didSave = feature.createFolder(name: name, parentID: parentID)
        }
        if didSave {
            isPresented = false
        } else {
            validationMessage = feature.errorMessage
        }
    }
}

struct DatabaseConnectionEditor: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var kind = DatabaseKind.mysql
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var username = "root"
    @State private var password = ""
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
    @State private var safetyExpanded = false
    @State private var networkExpanded = false
    @State private var usesSSHTunnel = false
    @State private var hasSavedPassword = false
    @State private var isConnecting = false
    @FocusState private var focusedField: String?

    private let profile: DatabaseProfile?

    init(isPresented: Binding<Bool>, profile: DatabaseProfile? = nil, defaultFolderID: UUID? = nil) {
        _isPresented = isPresented
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _kind = State(initialValue: profile?.kind ?? .mysql)
        _host = State(initialValue: profile?.host ?? "127.0.0.1")
        _port = State(initialValue: String(profile?.port ?? 3306))
        _username = State(initialValue: profile?.username ?? "root")
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
            Text("Configure connection and safety options.")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Name")
                            .frame(width: 140, alignment: .leading)
                        TextField("", text: $name)
                            .accessibilityLabel("Name")
                            .focused($focusedField, equals: "name")
                            .modifier(LitheCommitDialogInputStyle(focused: focusedField == "name"))
                            .frame(maxWidth: .infinity)
                    }
                    GridRow {
                        Text("Engine")
                            .frame(width: 140, alignment: .leading)
                        LitheSettingsSelect(selection: $kind, options: DatabaseKind.allCases, width: 496, accessibilityLabel: "Engine", title: { $0.displayName })
                    }

                    if kind == .sqlite {
                        GridRow {
                            Text("Database file path")
                                .frame(width: 140, alignment: .leading)
                            TextField("", text: $path)
                                .accessibilityLabel("Database file path")
                                .focused($focusedField, equals: "path")
                                .modifier(LitheCommitDialogInputStyle(focused: focusedField == "path"))
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
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "host"))
                                    .frame(maxWidth: .infinity)
                                Text("Port")
                                TextField("", text: $port)
                                    .accessibilityLabel("Port")
                                    .focused($focusedField, equals: "port")
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "port"))
                                    .frame(width: 90)
                            }
                        }
                        GridRow {
                            Text(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                .frame(width: 140, alignment: .leading)
                            TextField("", text: $username)
                                .accessibilityLabel(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"))
                                .focused($focusedField, equals: "username")
                                .modifier(LitheCommitDialogInputStyle(focused: focusedField == "username"))
                                .frame(maxWidth: .infinity)
                        }
                        GridRow {
                            Text(profile == nil ? "Password" : (hasSavedPassword ? "Password (leave blank to keep current)" : "Password (no saved password)"))
                                .frame(width: 140, alignment: .leading)
                            SecureField("", text: $password)
                                .accessibilityLabel("Password")
                                .focused($focusedField, equals: "password")
                                .modifier(LitheCommitDialogInputStyle(focused: focusedField == "password"))
                                .frame(maxWidth: .infinity)
                        }
                        if kind == .redis {
                            GridRow {
                                Text("Redis database index")
                                    .frame(width: 140, alignment: .leading)
                                TextField("", text: $database)
                                    .accessibilityLabel("Redis database index")
                                    .focused($focusedField, equals: "database")
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "database"))
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
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "database"))
                                    .frame(maxWidth: .infinity)
                            }
                            GridRow {
                                Text("API context path")
                                    .frame(width: 140, alignment: .leading)
                                TextField("", text: $path)
                                    .accessibilityLabel("API context path")
                                    .focused($focusedField, equals: "path")
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "path"))
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
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "database"))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        GridRow {
                            Text("Use TLS")
                                .frame(width: 140, alignment: .leading)
                            Toggle("Use TLS", isOn: $ssl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    DisclosureGroup(isExpanded: $safetyExpanded) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Folder")
                                    .frame(width: 140, alignment: .leading)
                                LitheSettingsSelect(selection: $folderID, options: [UUID?.none] + feature.folders.map { Optional($0.id) }, width: 496, accessibilityLabel: "Folder", title: { id in feature.folders.first { $0.id == id }?.name ?? String(localized: "No folder") })
                            }
                            GridRow {
                                Text("Color hex (optional)")
                                    .frame(width: 140, alignment: .leading)
                                TextField("", text: $colorHex)
                                    .accessibilityLabel("Color hex (optional)")
                                    .focused($focusedField, equals: "colorHex")
                                    .modifier(LitheCommitDialogInputStyle(focused: focusedField == "colorHex"))
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
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sensitiveColumnPatterns"))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    } label: {
                        Text("Safety")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { safetyExpanded.toggle() }
                    }
                    DisclosureGroup(isExpanded: $networkExpanded) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            if ssl {
                                GridRow {
                                    Text("TLS CA certificate path")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $caCertificatePath)
                                        .accessibilityLabel("TLS CA certificate path")
                                        .focused($focusedField, equals: "caCertificatePath")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "caCertificatePath"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("TLS server name")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $serverName)
                                        .accessibilityLabel("TLS server name")
                                        .focused($focusedField, equals: "serverName")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "serverName"))
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
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sshHost"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH port")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshPort)
                                        .accessibilityLabel("SSH port")
                                        .focused($focusedField, equals: "sshPort")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sshPort"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH username")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshUsername)
                                        .accessibilityLabel("SSH username")
                                        .focused($focusedField, equals: "sshUsername")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sshUsername"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH key path")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshKeyPath)
                                        .accessibilityLabel("SSH key path")
                                        .focused($focusedField, equals: "sshKeyPath")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sshKeyPath"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("SSH local port")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $sshLocalPort)
                                        .accessibilityLabel("SSH local port")
                                        .focused($focusedField, equals: "sshLocalPort")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "sshLocalPort"))
                                        .frame(maxWidth: .infinity)
                                }
                                GridRow {
                                    Text("Proxy URL (optional)")
                                        .frame(width: 140, alignment: .leading)
                                    TextField("", text: $proxyURL)
                                        .accessibilityLabel("Proxy URL (optional)")
                                        .focused($focusedField, equals: "proxyURL")
                                        .modifier(LitheCommitDialogInputStyle(focused: focusedField == "proxyURL"))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    } label: {
                        Text("Advanced network")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { networkExpanded.toggle() }
                    }
                .padding(.top, 2)
                }
                .padding(16)
            }
            if let error = feature.errorMessage { DatabaseLocalization.error(error).font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.error).padding(.horizontal, 16) }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancel() }
                    .buttonStyle(LitheCommitDialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    connect()
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().controlSize(.small) }
                        Text(isConnecting ? "Connecting…" : "Connect")
                    }
                }
                    .buttonStyle(LitheCommitDialogButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (kind == .sqlite ? path.isEmpty : host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || redisDatabaseValidationMessage != nil || isConnecting)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(LitheCommitDialogStyle.background)
        }
        .onChange(of: kind) { newKind in
            guard profile == nil else { return }
            switch newKind {
            case .mysql: port = "3306"; username = "root"; database = ""; path = ""
            case .mariadb: port = "3306"; username = "root"; database = ""; path = ""
            case .postgresql: port = "5432"; username = "postgres"; database = ""; path = ""
            case .sqlite: path = ""; database = ""
            case .sqlserver: port = "1433"; username = "sa"; database = "master"; path = ""
            case .mongodb: port = "27017"; username = ""; database = "admin"; path = ""
            case .redis: port = "6379"; username = ""; database = "0"; path = ""
            case .nacos: port = "8848"; username = ""; database = ""; path = "/nacos"
            }
        }
        .task { focusedField = "name" }
        .onAppear {
            feature.errorMessage = nil
            if let profile {
                hasSavedPassword = feature.hasSavedPassword(for: profile)
            }
        }
        .onDisappear { feature.errorMessage = nil }
        .frame(width: 680, height: safetyExpanded || networkExpanded ? 640 : (kind == .sqlite ? 360 : (kind == .nacos ? 580 : 520))).background(LitheCommitDialogStyle.background)
    }

    private func cancel() {
        feature.errorMessage = nil
        isPresented = false
    }

    private func connect() {
        guard !isConnecting else { return }
        if let redisDatabaseValidationMessage {
            feature.errorMessage = redisDatabaseValidationMessage
            return
        }
        let candidate = DatabaseProfile(id: profile?.id ?? UUID(), name: name, kind: kind, host: host, port: UInt16(port) ?? 0, username: username, database: database, path: path, ssl: ssl, group: "", folderID: folderID, colorHex: colorHex, readOnly: readOnly, productionProtection: productionProtection, maskSensitiveFields: maskSensitiveFields, sensitiveColumnPatterns: sensitiveColumnPatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, caCertificatePath: ssl ? caCertificatePath : "", serverName: ssl ? serverName : "", sshHost: usesSSHTunnel ? sshHost : "", sshPort: usesSSHTunnel ? (UInt16(sshPort) ?? 22) : 0, sshUsername: usesSSHTunnel ? sshUsername : "", sshKeyPath: usesSSHTunnel ? sshKeyPath : "", sshLocalPort: usesSSHTunnel ? (UInt16(sshLocalPort) ?? 0) : 0, proxyURL: usesSSHTunnel ? proxyURL : "")
        isConnecting = true
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
