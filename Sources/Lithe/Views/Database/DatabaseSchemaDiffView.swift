import AppKit
import SwiftUI
import LitheDatabaseModule

struct DatabaseSchemaDiffView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var diff: DatabaseSchemaDiffResult?
    @State private var isComparing = false
    @State private var showsMigrationConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Source", selection: $sourceID) {
                    Text("Source connection").tag(Optional<UUID>.none)
                    ForEach(model.databaseFeature.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: 220)

                Image(systemName: "arrow.right")
                    .foregroundStyle(LitheTheme.secondaryText)

                Picker("Target", selection: $targetID) {
                    Text("Target connection").tag(Optional<UUID>.none)
                    ForEach(model.databaseFeature.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: 220)

                Button { compare() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .litheIconButton()
                    .help("Compare database schemas")
                    .disabled(sourceID == nil || targetID == nil || sourceID == targetID || isComparing)

                if isComparing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if let diff {
                diffContent(diff)
            } else {
                LitheUnavailableView(
                    "No Schema Comparison",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Choose two connections to inspect structural differences.")
                )
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .background(LitheTheme.editor)
        .onAppear(perform: setDefaults)
        .alert("Apply schema migration?", isPresented: $showsMigrationConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Create Recovery Point and Apply", role: .destructive) { applyMigration() }
        } message: {
            Text("The target connection will be backed up first. Destructive changes may remove tables, columns, indexes, or constraints.")
        }
    }

    @ViewBuilder
    private func diffContent(_ diff: DatabaseSchemaDiffResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(diff.source.profileName) -> \(diff.target.profileName)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Changes: \(diff.items.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Button { copyMigrationSQL(diff) } label: { Image(systemName: "doc.on.doc") }
                    .litheIconButton()
                    .help("Copy migration SQL")
                    .disabled(diff.items.isEmpty)
                Button { requestMigration(diff) } label: { Label("Apply", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(diff.items.isEmpty || model.databaseFeature.isLoading)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if diff.items.isEmpty {
                LitheUnavailableView("Schemas Match", systemImage: "checkmark.circle", description: Text("No structural changes are required."))
                    .foregroundStyle(LitheTheme.success)
            } else {
                List(diff.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: item.isDestructive ? "exclamationmark.triangle.fill" : "arrow.right.circle")
                                .foregroundStyle(item.isDestructive ? LitheTheme.warning : LitheTheme.accent)
                            Text(LocalizedStringKey(item.kind.title)).font(.system(size: 11.5, weight: .semibold))
                            Text(item.table).font(.system(size: 11.5, design: .monospaced))
                            Spacer()
                            DatabaseLocalization.schemaDiffDetail(item).font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
                        }
                        Text(item.sql)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private func setDefaults() {
        guard model.databaseFeature.profiles.count >= 2 else { return }
        if sourceID == nil { sourceID = model.databaseFeature.profiles[0].id }
        if targetID == nil { targetID = model.databaseFeature.profiles[1].id }
    }

    private func compare() {
        guard let sourceID, let targetID, sourceID != targetID else { return }
        isComparing = true
        Task {
            let source = await model.databaseFeature.loadSchemaSnapshot(profileID: sourceID)
            let target = await model.databaseFeature.loadSchemaSnapshot(profileID: targetID)
            if let source, let target { diff = DatabaseSchemaDiffEngine.compare(source: source, target: target) }
            isComparing = false
        }
    }

    private func requestMigration(_ diff: DatabaseSchemaDiffResult) {
        if diff.requiresConfirmation {
            showsMigrationConfirmation = true
        } else {
            applyMigration()
        }
    }

    private func applyMigration() {
        guard let diff, let targetID else { return }
        Task {
            if await model.databaseFeature.applySchemaMigration(diff, targetProfileID: targetID, confirmed: true) {
                let source = await model.databaseFeature.loadSchemaSnapshot(profileID: diff.source.profileID)
                let target = await model.databaseFeature.loadSchemaSnapshot(profileID: diff.target.profileID)
                if let source, let target { self.diff = DatabaseSchemaDiffEngine.compare(source: source, target: target) }
            }
        }
    }

    private func copyMigrationSQL(_ diff: DatabaseSchemaDiffResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff.migrationSQL, forType: .string)
    }
}
