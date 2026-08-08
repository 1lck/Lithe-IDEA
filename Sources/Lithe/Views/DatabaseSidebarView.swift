import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showsConnectionEditor = false
    @State private var editingProfile: DatabaseProfile?
    @State private var searchText = ""
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(LitheTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connections").font(.system(size: 12.5, weight: .semibold))
                    Text("Connections: \(model.databaseFeature.profiles.count)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                Spacer()
                Button { editingProfile = nil; newConnectionFolderID = nil; showsConnectionEditor = true } label: { Image(systemName: "plus") }
                    .litheIconButton().help("Add database connection")
                Button { editingFolder = nil; creatingFolderParentID = nil; showsFolderEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .litheIconButton().help("New Folder")
                Button { collapseAll() } label: { Image(systemName: "rectangle.compress.vertical") }
                    .litheIconButton().help("Collapse all")
                Button { Task { await model.databaseFeature.refreshTables() } } label: { Image(systemName: "arrow.clockwise") }
                    .litheIconButton().help("Refresh database objects")
            }
            .foregroundStyle(LitheTheme.primaryText).padding(.leading, 10).padding(.trailing, 5)
            .frame(height: 42)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                TextField("Search connections", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                Menu {
                    Button("All database types") { kindFilter = nil }
                    Divider()
                    ForEach(DatabaseKind.allCases, id: \.self) { kind in
                        Button {
                            kindFilter = kind
                        } label: {
                            Label {
                                Text(kind.displayName)
                            } icon: {
                                DatabaseBrandIcon(kind: kind, size: 13)
                            }
                        }
                    }
                } label: {
                    Image(systemName: kindFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Filter database type")
                Menu {
                    Picker("Sort connections", selection: $connectionSort) {
                        ForEach(DatabaseConnectionSort.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Sort connections")
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(LitheTheme.inputBackground.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.databaseFeature.profiles.isEmpty && model.databaseFeature.folders.isEmpty {
                        emptyConnections
                    } else {
                        connectionTree
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
            }
            if model.databaseFeature.isLoading { ProgressView().controlSize(.small).padding(8) }
            if let error = model.databaseFeature.errorMessage {
                DatabaseLocalization.error(error).font(.system(size: 10.5)).foregroundStyle(LitheTheme.error).padding(8).lineLimit(4)
            }
        }
        .sheet(isPresented: $showsConnectionEditor) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor, profile: editingProfile, defaultFolderID: newConnectionFolderID)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        }
        .sheet(isPresented: $showsFolderEditor) {
            DatabaseFolderEditor(isPresented: $showsFolderEditor, folder: editingFolder, parentID: creatingFolderParentID)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        }
        .alert("Remove folder?", isPresented: $showsFolderDeletionConfirmation, presenting: folderPendingDeletion) { folder in
            Button("Remove Folder", role: .destructive) {
                model.databaseFeature.removeFolder(folder)
                folderPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: { _ in
            Text("Removing this folder keeps its contents and moves them to the parent folder or root.")
        }
        .alert("Remove connection?", isPresented: $showsProfileDeletionConfirmation, presenting: profilePendingDeletion) { profile in
            Button("Remove Connection", role: .destructive) {
                model.databaseFeature.remove(profile)
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
                    if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
                    _ = await model.databaseFeature.flushRedisDatabase(confirmed: true)
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
            if case let .failure(error) = result { model.databaseFeature.errorMessage = error.localizedDescription }
            if let temporaryExportURL { try? FileManager.default.removeItem(at: temporaryExportURL) }
            temporaryExportURL = nil; exportDocument = nil
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [importFormat.contentType]) { result in
            importFile(result)
        }
        .onChange(of: model.databaseFeature.selectedProfileID) { _, selectedID in
            if let selectedID { expandedProfileIDs = [selectedID] }
        }
    }

    private var emptyConnections: some View {
        VStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .frame(width: 44, height: 44)
                .background(LitheTheme.accent.opacity(0.12))
                .clipShape(Circle())
            Text("No database connections")
                .font(.system(size: 11.5, weight: .semibold))
            Text("Add a connection to browse tables, run SQL, and manage data.")
                .font(.system(size: 10))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                editingProfile = nil
                newConnectionFolderID = nil
                showsConnectionEditor = true
            } label: {
                Label("Add database connection", systemImage: "plus")
            }
            .buttonStyle(LithePrimaryButtonStyle())
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.inputBackground.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var connectionTree: some View {
        let rootProfiles = unfiledProfiles
        let hasVisibleFolders = model.databaseFeature.folders.contains { folder in
            isFolderVisible(folder)
        }

        ForEach(rootFolders) { folder in
            if isFolderVisible(folder) {
                folderRow(folder)
            }
        }

        if !rootProfiles.isEmpty {
            Text("Unfiled connections")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(LitheTheme.tertiaryText)
                .textCase(.uppercase)
                .padding(.top, model.databaseFeature.folders.isEmpty ? 3 : 9)
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
                    .font(.system(size: 13, weight: .medium))
                Text("No connections match your search.")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(LitheTheme.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if model.databaseFeature.profiles.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 13, weight: .medium))
                Text("No database connections")
                    .font(.system(size: 10.5))
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
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .frame(width: 12)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LitheTheme.warning)
                            .frame(width: 15)
                        Text(folder.name)
                            .lineLimit(1)
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer(minLength: 4)
                        if totalCount > 0 {
                            Text("\(totalCount)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                    .padding(.leading, 7 + indent)
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 31)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .lithePointer()
                .litheRowHover(isActive: false)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(targetedFolderID == folder.id ? LitheTheme.accent.opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                Button(isExpanded ? "Collapse Folder" : "Expand Folder") {
                    if isExpanded { collapsedFolderIDs.insert(folder.id) }
                    else { collapsedFolderIDs.remove(folder.id) }
                }
                Button("New Connection") {
                    editingProfile = nil
                    newConnectionFolderID = folder.id
                    showsConnectionEditor = true
                }
                Button("New Subfolder") {
                    editingFolder = nil
                    creatingFolderParentID = folder.id
                    showsFolderEditor = true
                }
                Button("Rename Folder") {
                    editingFolder = folder
                    showsFolderEditor = true
                }
                Button("Remove Folder", role: .destructive) {
                    folderPendingDeletion = folder
                    showsFolderDeletionConfirmation = true
                }
            }
            .dropDestination(for: String.self) { items, _ in
                moveDroppedProfile(items, to: folder.id)
            } isTargeted: { targeted in
                targetedFolderID = targeted ? folder.id : nil
            }

            if isExpanded {
                ForEach(profiles) { profile in
                    profileRow(profile, indent: 21 + indent)
                }
                ForEach(childFolders(of: folder).filter(isFolderVisible)) { child in
                    folderRow(child, indent: indent + 14)
                }
            }
        })
    }

    private func profileRow(_ profile: DatabaseProfile, indent: CGFloat = 0) -> some View {
        let isExpanded = expandedProfileIDs.contains(profile.id)
        let isSelected = model.databaseFeature.selectedProfileID == profile.id

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Button {
                    toggleProfile(profile)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 18, height: 30)
                }
                .buttonStyle(.plain)
                .lithePointer()

                Button {
                    selectProfile(profile, expand: true)
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(profileColor(for: profile))
                            .frame(width: 3, height: 18)
                        DatabaseBrandIcon(kind: profile.kind, size: 15)
                        Text(profile.name)
                            .lineLimit(1)
                            .font(.system(size: 11.5, weight: .medium))
                        if profile.readOnly {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        if profile.productionProtection {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(LitheTheme.warning)
                        }
                        Spacer(minLength: 4)
                        Text(profile.kind.displayName)
                            .lineLimit(1)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                        connectionStatusIndicator(profile)
                    }
                    .padding(.trailing, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .lithePointer()
            }
            .padding(.leading, 4 + indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .litheRowHover(isActive: isSelected, activeBackground: profileColor(for: profile).opacity(0.12))
            .draggable(profile.id.uuidString)
            .contextMenu {
                connectionContextMenu(profile)
            }

            if isExpanded, isSelected {
                profileObjectTree(profile, indent: indent + 24)
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
                HStack(spacing: 6) {
                    Image(systemName: databaseExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 12)
                    Image(systemName: "cylinder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.warning)
                    Group {
                        if profile.database.isEmpty {
                            Text(profile.kind == .mongodb ? "admin" : "Default database")
                        } else {
                            Text(verbatim: profile.database)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, indent)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .lithePointer()
            .litheRowHover()
            .contextMenu {
                if profile.kind == .mongodb { mongoDatabaseContextMenu(profile) }
                else { databaseContextMenu(profile) }
            }

            if databaseExpanded {
                databaseObjects(for: profile, indent: indent + 18)
            }
        } else if profile.kind == .redis {
            sidebarLeaf(
                title: "Redis database",
                detail: profile.database.isEmpty ? "0" : profile.database,
                symbol: "square.stack.3d.up",
                count: model.databaseFeature.redisKeys.count,
                indent: indent
            )
            .contextMenu { redisDatabaseContextMenu(profile) }
        } else {
            sidebarLeaf(title: "Configurations", symbol: "doc.text", count: model.databaseFeature.nacosConfigs.count, indent: indent)
                .contextMenu { nacosContextMenu(profile) }
            sidebarLeaf(title: "Services", symbol: "network", count: model.databaseFeature.nacosServices.count, indent: indent)
                .contextMenu { nacosContextMenu(profile) }
        }
    }

    @ViewBuilder
    private func databaseObjects(for profile: DatabaseProfile, indent: CGFloat) -> some View {
        if profile.kind.supportsDataGrid {
            objectSectionHeader(kind: .tables, title: profile.kind == .mongodb ? "Collections" : "Tables", count: model.databaseFeature.tables.count, indent: indent)
                .contextMenu {
                    if profile.kind == .mongodb { Button("Refresh Collections") { refresh(profile) } }
                    else { tableGroupContextMenu(profile) }
                }
            if !collapsedObjectKinds.contains(.tables), model.databaseFeature.tables.isEmpty && !model.databaseFeature.isLoading {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.kind == .mongodb ? "No collections yet" : "No tables yet")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(profile.kind == .mongodb ? "Refresh this connection to load its collections." : "Refresh this connection to load its database objects.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LitheTheme.inputBackground.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, indent + 18)
                .padding(.trailing, 6)
                .padding(.top, 6)
            }
            if !collapsedObjectKinds.contains(.tables) {
                ForEach(model.databaseFeature.tables, id: \.self) { table in
                    let tableKey = "\(profile.id.uuidString)|\(table)"
                    let isExpanded = expandedTableKey == tableKey
                    Button {
                        expandedTableKey = isExpanded ? nil : tableKey
                        model.databaseFeature.selectedTable = table
                        Task { await model.databaseFeature.openTable(table) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(LitheTheme.tertiaryText)
                                .frame(width: 12)
                            Image(systemName: profile.kind == .mongodb ? "doc.on.doc" : "tablecells")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(LitheTheme.success)
                                .frame(width: 14)
                            Text(table)
                                .font(.system(size: 10.8, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, indent + 14)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .lithePointer()
                    .litheRowHover(isActive: model.databaseFeature.selectedTable == table)
                    .contextMenu {
                        if profile.kind == .mongodb { mongoCollectionContextMenu(profile, collection: table) }
                        else { tableContextMenu(profile, table: table) }
                    }

                    if isExpanded, model.databaseFeature.selectedTable == table {
                        if model.databaseFeature.isLoading {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.mini)
                                Text("Loading table metadata…")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                            }
                            .padding(.leading, indent + 48)
                            .frame(height: 24)
                        } else {
                            sidebarLeaf(title: profile.kind == .mongodb ? "Fields" : "Columns", symbol: "list.bullet.indent", count: model.databaseFeature.columns.count, indent: indent + 36, tint: LitheTheme.success)
                            sidebarLeaf(title: "Indexes", symbol: "key", count: model.databaseFeature.indexes.count, indent: indent + 36, tint: LitheTheme.warning)
                            if profile.kind != .mongodb {
                                sidebarLeaf(title: "Foreign Keys", symbol: "link", count: model.databaseFeature.foreignKeys.count, indent: indent + 36, tint: LitheTheme.accent)
                            }
                        }
                    }
                }
            }
            ForEach(profile.kind == .mongodb ? [] : DatabaseObjectKind.allCases.filter { $0 != .tables }, id: \.self) { kind in
                let entries = model.databaseFeature.objects[kind] ?? []
                if !entries.isEmpty {
                    DisclosureGroup {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, row in
                            Text(objectLabel(row))
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                                .padding(.leading, 34)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 23)
                        }
                    } label: {
                        Label {
                            HStack(spacing: 4) {
                                Text(LocalizedStringKey(kind.title))
                                Text("(\(entries.count))")
                            }
                        } icon: {
                            Image(systemName: kind.symbol)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    }
                    .padding(.leading, indent + 10)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func objectSectionHeader(kind: DatabaseObjectKind, title: LocalizedStringKey, count: Int, indent: CGFloat) -> some View {
        Button {
            if collapsedObjectKinds.contains(kind) { collapsedObjectKinds.remove(kind) }
            else { collapsedObjectKinds.insert(kind) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedObjectKinds.contains(kind) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 12)
                Image(systemName: kind.symbol)
                    .font(.system(size: 10))
                Text(title)
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(LitheTheme.badgeBackground)
                    .clipShape(Capsule())
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.vertical, 5)
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .lithePointer()
        .litheRowHover()
    }

    private func sidebarLeaf(
        title: LocalizedStringKey,
        detail: String? = nil,
        symbol: String,
        count: Int,
        indent: CGFloat,
        tint: Color = LitheTheme.secondaryText
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 10.5))
                .lineLimit(1)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
        .padding(.leading, indent)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
        .foregroundStyle(LitheTheme.secondaryText)
    }

    private func moveDroppedProfile(_ items: [String], to folderID: UUID?) -> Bool {
        guard let rawID = items.first, let profileID = UUID(uuidString: rawID),
              let profile = model.databaseFeature.profiles.first(where: { $0.id == profileID }) else {
            return false
        }
        model.databaseFeature.move(profile, toFolder: folderID)
        targetedFolderID = nil
        isUnfiledDropTarget = false
        return true
    }

    private var rootFolders: [DatabaseConnectionFolder] {
        model.databaseFeature.folders.filter { $0.parentID == nil }
    }

    private func childFolders(of folder: DatabaseConnectionFolder) -> [DatabaseConnectionFolder] {
        model.databaseFeature.folders.filter { $0.parentID == folder.id }
    }

    @ViewBuilder
    private func connectionContextMenu(_ profile: DatabaseProfile) -> some View {
        let status = model.databaseFeature.connectionStatus(for: profile)
        Button(status == .connected ? "Disconnect" : "Connect") {
            if status == .connected {
                model.databaseFeature.disconnect(profile)
            } else {
                selectProfile(profile, expand: true)
            }
        }
        .disabled(status == .connecting)
        if profile.kind.isSQLDatabase {
            Button("New Query") { openSQLQuery(profile) }
        }
        Button("Refresh") { refresh(profile) }
        Divider()
        Button("Copy Name") { copyToPasteboard(profile.name) }
        Button("Edit Connection") {
            editingProfile = profile
            newConnectionFolderID = nil
            showsConnectionEditor = true
        }
        Menu("Move to Folder") {
            Button("Move to root") { model.databaseFeature.move(profile, toFolder: nil) }
                .disabled(profile.folderID == nil)
            if !model.databaseFeature.folders.isEmpty {
                Divider()
                ForEach(model.databaseFeature.folders) { folder in
                    Button(folder.name) { model.databaseFeature.move(profile, toFolder: folder.id) }
                        .disabled(profile.folderID == folder.id)
                }
            }
            Divider()
            Button("New Folder") {
                editingFolder = nil
                creatingFolderParentID = nil
                showsFolderEditor = true
            }
        }
        Button("Duplicate Connection") { _ = model.databaseFeature.duplicate(profile) }
        Divider()
        Button("Remove Connection", role: .destructive) {
            profilePendingDeletion = profile
            showsProfileDeletionConfirmation = true
        }
    }

    private func refresh(_ profile: DatabaseProfile) {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            else if profile.kind.supportsDataGrid { await model.databaseFeature.refreshTables() }
            else if profile.kind == .redis { await model.databaseFeature.loadRedisKeys(pattern: "") }
            else { await model.databaseFeature.loadNacosConfigs(dataId: "", group: ""); await model.databaseFeature.loadNacosServices(serviceName: "", group: "") }
        }
    }

    private func openSQLQuery(_ profile: DatabaseProfile, sql: String = "") {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            model.databaseFeature.addSQLTab(sql: sql)
            model.databaseFeature.workspaceSection = .sql
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @ViewBuilder
    private func databaseContextMenu(_ profile: DatabaseProfile) -> some View {
        Button("New Query") { openSQLQuery(profile) }
        Button("New Table") {
            openSQLQuery(profile, sql: "CREATE TABLE new_table (\n    id INTEGER PRIMARY KEY\n);\n")
        }
        .disabled(profile.readOnly)
        if profile.kind != .sqlserver {
            Button("Import SQL Backup…") {
                Task {
                    if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
                    importFormat = .sql; pendingImportFormat = .sql; showsImporter = true
                }
            }
            .disabled(profile.readOnly)
            Button("Export Database as SQL…") { exportDatabase(profile) }
        }
        Divider()
        Button("Copy Name") { copyToPasteboard(profile.database.isEmpty ? "Default database" : profile.database) }
        Button("Refresh") { refresh(profile) }
    }

    @ViewBuilder
    private func mongoDatabaseContextMenu(_ profile: DatabaseProfile) -> some View {
        Button("Refresh Collections") { refresh(profile) }
        Button("Copy Name") { copyToPasteboard(profile.database.isEmpty ? "admin" : profile.database) }
    }

    @ViewBuilder
    private func mongoCollectionContextMenu(_ profile: DatabaseProfile, collection: String) -> some View {
        Button("View Documents") { openTable(profile, table: collection, section: .data) }
        Button("Copy Name") { copyToPasteboard(collection) }
        Divider()
        Button("Refresh") {
            Task {
                if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
                await model.databaseFeature.openTable(collection)
            }
        }
    }

    @ViewBuilder
    private func tableGroupContextMenu(_ profile: DatabaseProfile) -> some View {
        Button("New Table") { openSQLQuery(profile, sql: "CREATE TABLE new_table (\n    id INTEGER PRIMARY KEY\n);\n") }
            .disabled(profile.readOnly)
        Button("Refresh") { refresh(profile) }
    }

    @ViewBuilder
    private func redisDatabaseContextMenu(_ profile: DatabaseProfile) -> some View {
        Button("Refresh Keys") { refresh(profile) }
        Button("Set Database Alias") {
            editingProfile = profile
            newConnectionFolderID = nil
            showsConnectionEditor = true
        }
        Button("Clear Current Redis DB", role: .destructive) {
            pendingRedisProfile = profile
            showsRedisFlushConfirmation = true
        }
        .disabled(profile.readOnly)
    }

    @ViewBuilder
    private func nacosContextMenu(_ profile: DatabaseProfile) -> some View {
        Button("Refresh") { refresh(profile) }
        Button("Copy Name") { copyToPasteboard(profile.name) }
        Button("Edit Namespace") {
            editingProfile = profile
            newConnectionFolderID = nil
            showsConnectionEditor = true
        }
    }

    @ViewBuilder
    private func tableContextMenu(_ profile: DatabaseProfile, table: String) -> some View {
        Button("View Data") { openTable(profile, table: table, section: .data) }
        Button("New Query") {
            openTable(profile, table: table, section: .sql, sql: "SELECT * FROM \(quotedIdentifier(table, kind: profile.kind));\n")
        }
        Button("View Structure") { openTable(profile, table: table, section: .structure) }
        Button("Copy Name") { copyToPasteboard(table) }
        Divider()
        Menu("Export Data…") {
            Button("CSV") { exportTable(profile, table: table, format: .csv) }
            Button("JSON") { exportTable(profile, table: table, format: .json) }
        }
        Button("Import Data…") { beginImport(.csv, profile: profile, table: table) }
            .disabled(profile.readOnly)
        Divider()
        Button("Clear Table", role: .destructive) {
            pendingTableAction = DatabaseTableContextAction(profile: profile, table: table, kind: .clear)
            showsTableActionConfirmation = true
        }
        .disabled(profile.readOnly)
        Button("Delete Table", role: .destructive) {
            pendingTableAction = DatabaseTableContextAction(profile: profile, table: table, kind: .drop)
            showsTableActionConfirmation = true
        }
        .disabled(profile.readOnly)
        Divider()
        Button("Refresh") { refresh(profile) }
    }

    private func openTable(_ profile: DatabaseProfile, table: String, section: DatabaseWorkspaceSection, sql: String = "") {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            await model.databaseFeature.openTable(table)
            if !sql.isEmpty { model.databaseFeature.addSQLTab(sql: sql) }
            model.databaseFeature.workspaceSection = section
        }
    }

    private func executeTableAction(_ action: DatabaseTableContextAction) {
        pendingTableAction = nil
        let sql = action.kind == .clear
            ? "DELETE FROM \(quotedIdentifier(action.table, kind: action.profile.kind));"
            : "DROP TABLE \(quotedIdentifier(action.table, kind: action.profile.kind));"
        Task {
            if model.databaseFeature.selectedProfileID != action.profile.id { await model.databaseFeature.select(action.profile) }
            model.databaseFeature.addSQLTab(sql: sql)
            model.databaseFeature.workspaceSection = .sql
            guard let tabID = model.databaseFeature.selectedSQLTabID else { return }
            await model.databaseFeature.runSQL(in: tabID, confirmedRisk: true)
            if action.kind == .clear { await model.databaseFeature.openTable(action.table) }
            else { await model.databaseFeature.refreshTables() }
        }
    }

    private func beginImport(_ format: DatabaseTransferFormat, profile: DatabaseProfile, table: String?) {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            if let table { await model.databaseFeature.openTable(table) }
            importFormat = format
            pendingImportFormat = format
            showsImporter = true
        }
    }

    private func exportTable(_ profile: DatabaseProfile, table: String, format: DatabaseTransferFormat) {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            await model.databaseFeature.openTable(table)
            exportFormat = format
            guard let data = await model.databaseFeature.exportData(format: format) else { return }
            exportDocument = DatabaseTransferDocument(data: data)
            showsExporter = true
        }
    }

    private func exportDatabase(_ profile: DatabaseProfile) {
        Task {
            if model.databaseFeature.selectedProfileID != profile.id { await model.databaseFeature.select(profile) }
            exportFormat = .sql
            guard let url = await model.databaseFeature.exportDataFile(format: .sql) else { return }
            temporaryExportURL = url
            exportDocument = DatabaseTransferDocument(fileURL: url)
            showsExporter = true
        }
    }

    private var exportFilename: String {
        let base = model.databaseFeature.selectedProfile?.database.isEmpty == false ? model.databaseFeature.selectedProfile?.database ?? "database" : "database"
        return "\(base).\(exportFormat.rawValue)"
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let format = pendingImportFormat ?? importFormat
            if format == .sql {
                let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-import-\(UUID().uuidString).sql")
                try FileManager.default.copyItem(at: url, to: temporaryURL)
                pendingImportURL = temporaryURL
            } else {
                pendingImportData = try Data(contentsOf: url)
            }
            pendingImportFormat = format
            if format == .sql || model.databaseFeature.selectedProfile?.productionProtection == true {
                showsProtectedImportConfirmation = true
            } else {
                performPendingImport(confirmed: false)
            }
        } catch { model.databaseFeature.errorMessage = error.localizedDescription }
    }

    private func performPendingImport(confirmed: Bool) {
        guard let format = pendingImportFormat else { return }
        let data = pendingImportData
        let fileURL = pendingImportURL
        pendingImportData = nil; pendingImportURL = nil; pendingImportFormat = nil
        Task {
            if let fileURL {
                defer { try? FileManager.default.removeItem(at: fileURL) }
                _ = await model.databaseFeature.importDataFile(fileURL, format: format, confirmed: confirmed)
            } else if let data {
                _ = await model.databaseFeature.importData(data, format: format, confirmed: confirmed)
            }
        }
    }

    private func discardPendingImport() {
        if let pendingImportURL { try? FileManager.default.removeItem(at: pendingImportURL) }
        pendingImportData = nil; pendingImportURL = nil; pendingImportFormat = nil
    }

    private func quotedIdentifier(_ value: String, kind: DatabaseKind) -> String {
        if kind == .sqlserver { return "[\(value.replacingOccurrences(of: "]", with: "]]"))]" }
        let quote = (kind == .mysql || kind == .mariadb) ? "`" : "\""
        return "\(quote)\(value.replacingOccurrences(of: quote, with: quote + quote))\(quote)"
    }

    @ViewBuilder
    private func connectionStatusIndicator(_ profile: DatabaseProfile) -> some View {
        let status = model.databaseFeature.connectionStatus(for: profile)
        switch status {
        case .idle:
            Circle()
                .fill(LitheTheme.tertiaryText.opacity(0.42))
                .frame(width: 6, height: 6)
                .help("Not connected")
                .accessibilityLabel("Not connected")
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .tint(LitheTheme.accent)
                .frame(width: 12, height: 12)
                .help("Connecting")
                .accessibilityLabel("Connecting")
        case .connected:
            Circle()
                .fill(LitheTheme.success)
                .frame(width: 7, height: 7)
                .help("Connected")
                .accessibilityLabel("Connected")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LitheTheme.warning)
                .frame(width: 12, height: 12)
                .help("Connection failed")
                .accessibilityLabel("Connection failed")
        }
    }

    private func selectProfile(_ profile: DatabaseProfile, expand: Bool) {
        if expand { expandedProfileIDs = [profile.id] }
        Task { await model.databaseFeature.select(profile) }
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
        collapsedFolderIDs = Set(model.databaseFeature.folders.map(\.id))
        expandedProfileIDs.removeAll()
        collapsedObjectKinds = Set(DatabaseObjectKind.allCases)
        expandedTableKey = nil
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var unfiledProfiles: [DatabaseProfile] {
        sorted(model.databaseFeature.profiles.filter { profile in
            guard profile.folderID == nil || !model.databaseFeature.folders.contains(where: { $0.id == profile.folderID }) else {
                return false
            }
            return profileMatchesSearch(profile)
        })
    }

    private func allProfiles(in folder: DatabaseConnectionFolder) -> [DatabaseProfile] {
        model.databaseFeature.profiles.filter { $0.folderID == folder.id }
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

    private func profileColor(for profile: DatabaseProfile) -> Color {
        profile.colorHex.isEmpty ? LitheTheme.accent : Color(hex: profile.colorHex)
    }

    private func objectLabel(_ row: DatabaseRow) -> String {
        for key in ["table_name", "routine_name", "trigger_name", "sequence_name", "name", "TABLE_NAME", "ROUTINE_NAME", "TRIGGER_NAME", "SEQUENCE_NAME"] {
            if let value = row[key], case let .string(name) = value, !name.isEmpty { return name }
        }
        return row.keys.sorted().compactMap { key in
            guard let value = row[key] else { return nil }
            return "\(key): \(String(describing: value))"
        }.joined(separator: "  ")
    }
}

private enum DatabaseConnectionSort: String, CaseIterable, Identifiable {
    case name
    case databaseType
    case host

    var id: String { rawValue }

    var title: LocalizedStringKey {
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
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    let folder: DatabaseConnectionFolder?
    let parentID: UUID?
    @State private var name = ""
    @State private var validationMessage: String?

    init(isPresented: Binding<Bool>, folder: DatabaseConnectionFolder?, parentID: UUID? = nil) {
        _isPresented = isPresented
        self.folder = folder
        self.parentID = parentID
        _name = State(initialValue: folder?.name ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
                    .frame(width: 34, height: 34)
                    .background(LitheTheme.warning.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder == nil ? "New Folder" : "Rename Folder")
                        .font(.system(size: 15, weight: .semibold))
                    Text(folder == nil ? "Keep connections organized in the sidebar." : "Update the folder name without changing its connections.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            Form {
                TextField("Folder name", text: $name)
                    .onSubmit(save)
                if let validationMessage {
                    DatabaseLocalization.error(validationMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(LitheSecondaryButtonStyle())
                Button(folder == nil ? "Create folder" : "Save folder") { save() }
                    .buttonStyle(LithePrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(LitheTheme.toolHeader)
        }
        .frame(width: 390, height: 240)
        .background(LitheTheme.raised)
    }

    private func save() {
        let didSave: Bool
        if let folder {
            didSave = model.databaseFeature.renameFolder(folder, to: name)
        } else {
            didSave = model.databaseFeature.createFolder(name: name, parentID: parentID)
        }
        if didSave {
            isPresented = false
        } else {
            validationMessage = model.databaseFeature.errorMessage
        }
    }
}

struct DatabaseConnectionEditor: View {
    @EnvironmentObject private var model: AppModel
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
            HStack(spacing: 10) {
                DatabaseBrandIcon(kind: kind, size: 22)
                    .frame(width: 34, height: 34)
                    .background(LitheTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile == nil ? "Add Database Connection" : "Edit Database Connection")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Configure connection and safety options.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            Form {
                TextField("Name", text: $name)
                Picker("Database", selection: $kind) {
                    Text("MySQL").tag(DatabaseKind.mysql)
                    Text("MariaDB").tag(DatabaseKind.mariadb)
                    Text("PostgreSQL").tag(DatabaseKind.postgresql)
                    Text("SQLite").tag(DatabaseKind.sqlite)
                    Text("SQL Server").tag(DatabaseKind.sqlserver)
                    Text("MongoDB").tag(DatabaseKind.mongodb)
                    Text("Redis").tag(DatabaseKind.redis)
                    Text("Nacos").tag(DatabaseKind.nacos)
                }
                    .pickerStyle(.menu)
                if kind == .sqlite { TextField("Database file path", text: $path) }
                else {
                    TextField(kind == .mongodb ? "Host or MongoDB URI" : "Host", text: $host)
                    TextField("Port", text: $port)
                    TextField(kind == .nacos || kind == .mongodb ? "Username (optional)" : (kind == .redis ? "Username / ACL user (optional)" : "Username"), text: $username)
                    SecureField(profile == nil ? "Password" : "Password (leave blank to keep current)", text: $password)
                    if kind == .redis {
                        TextField("Redis database index", text: $database)
                        Text("Leave the database index at 0 for the standard Redis database.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    } else if kind == .nacos {
                        TextField("Namespace ID (optional)", text: $database)
                        TextField("API context path", text: $path)
                        Text("Use /nacos for a standard Nacos server, or / for a reverse proxy at its root.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        TextField("Database", text: $database)
                    }
                    Toggle("Use TLS", isOn: $ssl)
                }
                DisclosureGroup(isExpanded: $safetyExpanded) {
                    Picker("Folder", selection: $folderID) {
                        Text("No folder").tag(UUID?.none)
                        ForEach(model.databaseFeature.folders) { folder in
                            Text(folder.name).tag(UUID?.some(folder.id))
                        }
                    }
                    TextField("Color hex (optional)", text: $colorHex)
                    Toggle("Read-only connection", isOn: $readOnly)
                    Toggle("Production protection", isOn: $productionProtection)
                    if kind.supportsDataGrid {
                        Toggle("Mask sensitive fields", isOn: $maskSensitiveFields)
                        TextField("Sensitive column patterns", text: $sensitiveColumnPatterns)
                    }
                } label: {
                    Label("Safety", systemImage: "shield")
                }
                DisclosureGroup(isExpanded: $networkExpanded) {
                    if ssl {
                        TextField("TLS CA certificate path", text: $caCertificatePath)
                        TextField("TLS server name", text: $serverName)
                    }
                    Toggle("Use SSH tunnel", isOn: $usesSSHTunnel)
                    if usesSSHTunnel {
                        TextField("SSH host", text: $sshHost)
                        TextField("SSH port", text: $sshPort)
                        TextField("SSH username", text: $sshUsername)
                        TextField("SSH key path", text: $sshKeyPath)
                        TextField("SSH local port", text: $sshLocalPort)
                        TextField("Proxy URL (optional)", text: $proxyURL)
                    }
                } label: {
                    Label("Advanced network", systemImage: "network")
                }
            .padding(.top, 2)
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let error = model.databaseFeature.errorMessage { DatabaseLocalization.error(error).font(.system(size: 11)).foregroundStyle(LitheTheme.error).padding(.horizontal, 16) }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(LitheSecondaryButtonStyle())
                Button("Connect") { connect() }
                    .buttonStyle(LithePrimaryButtonStyle())
                    .disabled(name.isEmpty || (kind == .sqlite ? path.isEmpty : host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || model.databaseFeature.isLoading)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(LitheTheme.toolHeader)
        }
        .onChange(of: kind) { _, newKind in
            guard profile == nil else { return }
            switch newKind {
            case .mysql: port = "3306"; username = "root"; database = ""; path = ""
            case .mariadb: port = "3306"; username = "root"; database = ""; path = ""
            case .postgresql: port = "5432"; username = "postgres"; database = ""; path = ""
            case .sqlite: path = ""; database = ""
            case .sqlserver: port = "1433"; username = "sa"; database = "master"; path = ""
            case .mongodb: port = "27017"; username = ""; database = "admin"; path = ""
            case .redis: port = "6379"; username = ""; database = "0"; path = ""
            case .nacos: port = "8848"; username = "nacos"; database = ""; path = "/nacos"
            }
        }
        .frame(width: 500, height: kind == .sqlite ? 640 : (kind.supportsDataGrid ? 750 : 710)).background(LitheTheme.raised)
    }

    private func connect() {
        let candidate = DatabaseProfile(id: profile?.id ?? UUID(), name: name, kind: kind, host: host, port: UInt16(port) ?? 0, username: username, database: database, path: path, ssl: ssl, group: "", folderID: folderID, colorHex: colorHex, readOnly: readOnly, productionProtection: productionProtection, maskSensitiveFields: maskSensitiveFields, sensitiveColumnPatterns: sensitiveColumnPatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, caCertificatePath: ssl ? caCertificatePath : "", serverName: ssl ? serverName : "", sshHost: usesSSHTunnel ? sshHost : "", sshPort: usesSSHTunnel ? (UInt16(sshPort) ?? 22) : 0, sshUsername: usesSSHTunnel ? sshUsername : "", sshKeyPath: usesSSHTunnel ? sshKeyPath : "", sshLocalPort: usesSSHTunnel ? (UInt16(sshLocalPort) ?? 0) : 0, proxyURL: usesSSHTunnel ? proxyURL : "")
        Task {
            let saved = if profile == nil {
                await model.databaseFeature.add(candidate, password: password)
            } else {
                await model.databaseFeature.update(candidate, password: password.isEmpty ? nil : password)
            }
            if saved { isPresented = false }
        }
    }
}
