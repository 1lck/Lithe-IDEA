import SwiftUI
import LitheDatabaseModule

struct RedisWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pattern = "*"
    @State private var stringDraft = ""
    @State private var hashDraft = "{}"
    @State private var ttlDraft = ""
    @State private var renameDraft = ""
    @State private var pendingAction: RedisPendingAction?
    @State private var showsWriteConfirmation = false

    private var feature: DatabaseFeatureModel { model.databaseFeature }
    private var profile: DatabaseProfile? { feature.selectedProfile }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 0) {
                keyBrowser
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 350)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                keyDetail
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .task(id: feature.selectedProfileID) {
            await feature.loadRedisKeys(pattern: pattern)
        }
        .onChange(of: feature.redisIncludeSize) { _ in
            Task { await feature.loadRedisKeys(pattern: pattern) }
        }
        .onChange(of: feature.redisSelectedKey) { detail in
            guard let detail else {
                stringDraft = ""; hashDraft = "{}"; ttlDraft = ""; renameDraft = ""
                return
            }
            stringDraft = detail.stringValue ?? ""
            ttlDraft = detail.ttl >= 0 ? String(detail.ttl) : "-1"
            renameDraft = detail.key
            let dictionary = Dictionary(uniqueKeysWithValues: detail.hashEntries.map { ($0.field, $0.value) })
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                hashDraft = text
            } else {
                hashDraft = "{}"
            }
        }
        .alert("Confirm Redis change", isPresented: $showsWriteConfirmation, presenting: pendingAction) { _ in
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button("Continue", role: .destructive) {
                if let pendingAction { execute(pendingAction, confirmed: true) }
                pendingAction = nil
            }
        } message: { action in
            if profile?.productionProtection == true {
                Text("This connection has production protection enabled. Confirm the Redis change before it is sent.")
            } else if case .deleteKey = action {
                Text("Deleting a Redis key cannot be undone.")
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.86, green: 0.22, blue: 0.20))
                .frame(width: 28, height: 28)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Redis Key Browser").font(.system(size: 12.5, weight: .semibold))
                Text("Incremental SCAN only — no full keyspace load")
                    .font(.system(size: 9.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            if let profile {
                Text("DB \(profile.database.isEmpty ? "0" : profile.database)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(LitheTheme.inputBackground)
                    .clipShape(Capsule())
            }
            Toggle("Estimate size", isOn: Binding(
                get: { feature.redisIncludeSize },
                set: { feature.redisIncludeSize = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Estimate key size during SCAN")
            Button { Task { await feature.loadRedisKeys(pattern: pattern) } } label: { Image(systemName: "arrow.clockwise") }
                .litheIconButton().help("Rescan from the beginning")
                .disabled(feature.isLoading || profile == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .foregroundStyle(LitheTheme.primaryText)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var keyBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Key pattern, e.g. user:*", text: $pattern)
                    .textFieldStyle(.plain)
                    .litheSearchField(isFocused: false)
                    .onSubmit { Task { await feature.loadRedisKeys(pattern: pattern) } }
                Button { Task { await feature.loadRedisKeys(pattern: pattern) } } label: { Image(systemName: "magnifyingglass") }
                    .litheIconButton().help("Search keys with SCAN")
                    .disabled(feature.isLoading || profile == nil)
            }
            .padding(10)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if let profile, feature.connectionStatuses[profile.id] == .failed, let error = feature.errorMessage {
                specializedErrorBanner(message: error) {
                    Task { await feature.loadRedisKeys(pattern: pattern) }
                }
            }

            if feature.redisKeys.isEmpty && feature.isLoading {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Scanning keys…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.redisKeys.isEmpty {
                specializedEmptyState(
                    symbol: "magnifyingglass",
                    title: feature.errorMessage == nil ? "No matching keys" : "No keys loaded",
                    detail: feature.errorMessage == nil
                        ? "No keys matched this pattern. Try a broader pattern to search again."
                        : "Retry the scan after fixing the connection or authentication settings."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(feature.redisKeys) { key in
                            Button {
                                Task { await feature.loadRedisKey(key.key) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: redisTypeSymbol(key.type))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(redisTypeColor(key.type))
                                        .frame(width: 22, height: 22)
                                        .background(redisTypeColor(key.type).opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key.key).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                        Text("\(key.type.uppercased()) · \(redisTTLText(key.ttl)) · \(redisSizeText(key.size))")
                                            .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 40).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).lithePointer()
                            .litheRowHover(isActive: feature.redisSelectedKey?.key == key.key, activeBackground: LitheTheme.subtleSelection)
                        }
                    }
                    .padding(.vertical, 6)
                }
                if feature.redisNextCursor != "0" {
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    Button {
                        Task { await feature.loadRedisKeys(pattern: pattern, reset: false) }
                    } label: {
                        Label("Load next scan page", systemImage: "arrow.down.circle")
                            .font(.system(size: 10.5, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain).lithePointer()
                    .foregroundStyle(LitheTheme.accent)
                    .disabled(feature.isLoading)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var keyDetail: some View {
        if let detail = feature.redisSelectedKey {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: redisTypeSymbol(detail.type))
                        .foregroundStyle(redisTypeColor(detail.type))
                        .frame(width: 28, height: 28)
                        .background(redisTypeColor(detail.type).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.key).font(.system(size: 12.5, weight: .semibold)).textSelection(.enabled)
                        Text("\(detail.type.uppercased()) · \(redisSizeText(detail.size)) · \(redisTTLText(detail.ttl))")
                            .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer()
                    Button { request(.deleteKey(detail.key)) } label: { Image(systemName: "trash") }
                        .litheIconButton().help("Delete key")
                        .foregroundStyle(LitheTheme.error)
                }
                .padding(12)
                .litheWorkbenchSurface(LitheTheme.toolHeader)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        renameAndTTL(detail)
                        if detail.type == "string" {
                            stringEditor(detail)
                        } else if detail.type == "hash" {
                            hashEditor(detail)
                        } else {
                            specializedEmptyState(symbol: "eye", title: "Read-only in this first release", detail: "This key is a \(detail.type). String and Hash editing are available now; other Redis types remain safely inspectable from the key list.")
                                .frame(maxWidth: .infinity, minHeight: 170)
                        }
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            specializedEmptyState(symbol: "square.stack.3d.up", title: "Select a Redis key", detail: "Key values load only after you select one, keeping large Redis instances responsive.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func renameAndTTL(_ detail: RedisKeyDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            specializedSectionTitle("Key settings", systemImage: "gearshape")
            HStack(spacing: 7) {
                TextField("Key name", text: $renameDraft).textFieldStyle(.roundedBorder)
                Button("Rename") { request(.rename(detail.key, renameDraft)) }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameDraft == detail.key)
            }
            HStack(spacing: 7) {
                TextField("TTL seconds (-1 = persistent)", text: $ttlDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Button("Set TTL") {
                    guard let ttl = Int64(ttlDraft.trimmingCharacters(in: .whitespacesAndNewlines)), ttl >= -1 else {
                        feature.errorMessage = "Redis TTL must be -1 or a non-negative number of seconds."
                        return
                    }
                    request(.setTTL(detail.key, ttl))
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
        }
    }

    private func stringEditor(_ detail: RedisKeyDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            specializedSectionTitle("String value", systemImage: "text.alignleft")
            TextEditor(text: $stringDraft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7).frame(minHeight: 230)
                .litheRoundedControlBackground(LitheTheme.inputBackground)
                .overlay { RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius).stroke(LitheTheme.panelBorder, lineWidth: 1) }
            HStack {
                Text("Saving preserves the existing TTL unless you set one above.")
                    .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("Save value") { request(.saveString(detail.key, stringDraft, ttlForSave)) }
                    .buttonStyle(LithePrimaryButtonStyle())
            }
        }
    }

    private func hashEditor(_ detail: RedisKeyDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            specializedSectionTitle("Hash fields", systemImage: "curlybraces.square")
            Text("Edit the field/value mapping as a JSON object. Saving replaces this Hash while preserving its TTL.")
                .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
            TextEditor(text: $hashDraft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7).frame(minHeight: 230)
                .litheRoundedControlBackground(LitheTheme.inputBackground)
                .overlay { RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius).stroke(LitheTheme.panelBorder, lineWidth: 1) }
            HStack {
                Spacer()
                Button("Save hash") { request(.saveHash(detail.key, hashEntries)) }
                    .buttonStyle(LithePrimaryButtonStyle())
            }
        }
    }

    private var ttlForSave: Int64? {
        let value = ttlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : Int64(value)
    }

    private var hashEntries: [RedisHashEntry] {
        guard let data = hashDraft.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return []
        }
        return values.map { RedisHashEntry(field: $0.key, value: $0.value) }.sorted { $0.field < $1.field }
    }

    private func request(_ action: RedisPendingAction) {
        if case .saveHash = action, hashEntries.isEmpty,
           hashDraft.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" {
            feature.errorMessage = "Redis Hash content must be a JSON object whose values are strings."
            return
        }
        if profile?.productionProtection == true || isDestructive(action) {
            pendingAction = action
            showsWriteConfirmation = true
        } else {
            execute(action, confirmed: true)
        }
    }

    private func execute(_ action: RedisPendingAction, confirmed: Bool) {
        Task {
            switch action {
            case let .saveString(key, value, ttl):
                _ = await feature.saveRedisString(key: key, value: value, ttl: ttl, confirmed: confirmed)
            case let .saveHash(key, entries):
                _ = await feature.replaceRedisHash(key: key, entries: entries, confirmed: confirmed)
            case let .setTTL(key, ttl):
                _ = await feature.setRedisTTL(key: key, ttl: ttl, confirmed: confirmed)
            case let .rename(key, newKey):
                _ = await feature.renameRedisKey(key: key, newKey: newKey, confirmed: confirmed)
            case let .deleteKey(key):
                _ = await feature.deleteRedisKey(key: key, confirmed: confirmed)
            }
        }
    }

    private func isDestructive(_ action: RedisPendingAction) -> Bool {
        if case .deleteKey = action { return true }
        return false
    }
}

private enum RedisPendingAction {
    case saveString(String, String, Int64?)
    case saveHash(String, [RedisHashEntry])
    case setTTL(String, Int64)
    case rename(String, String)
    case deleteKey(String)
}

struct NacosWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: NacosSection = .configs
    @State private var dataIDSearch = ""
    @State private var groupSearch = ""
    @State private var serviceSearch = ""
    @State private var serviceGroupSearch = ""
    @State private var draftDataID = ""
    @State private var draftGroup = "DEFAULT_GROUP"
    @State private var draftType = ""
    @State private var draftContent = ""
    @State private var pendingAction: NacosPendingAction?
    @State private var showsWriteConfirmation = false

    private var feature: DatabaseFeatureModel { model.databaseFeature }
    private var profile: DatabaseProfile? { feature.selectedProfile }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            Picker("Nacos workspace", selection: $section) {
                Label("Configurations", systemImage: "doc.text").tag(NacosSection.configs)
                Label("Services", systemImage: "network").tag(NacosSection.services)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 250).padding(10)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if let profile, feature.connectionStatuses[profile.id] == .failed, let error = feature.errorMessage {
                specializedErrorBanner(message: error) {
                    Task {
                        await feature.loadNacosConfigs(dataId: dataIDSearch, group: groupSearch)
                        await feature.loadNacosServices(serviceName: serviceSearch, group: serviceGroupSearch)
                    }
                }
            }
            if section == .configs { configurations } else { services }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .task(id: feature.selectedProfileID) {
            await feature.loadNacosConfigs(dataId: dataIDSearch, group: groupSearch)
            await feature.loadNacosServices(serviceName: serviceSearch, group: serviceGroupSearch)
        }
        .onChange(of: feature.nacosSelectedConfig) { detail in
            guard let detail else {
                draftDataID = ""
                draftGroup = "DEFAULT_GROUP"
                draftType = ""
                draftContent = ""
                return
            }
            draftDataID = detail.dataId; draftGroup = detail.group; draftType = detail.type ?? ""; draftContent = detail.content
        }
        .alert("Confirm Nacos configuration change", isPresented: $showsWriteConfirmation, presenting: pendingAction) { _ in
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button("Continue", role: .destructive) {
                if let pendingAction { execute(pendingAction, confirmed: true) }
                pendingAction = nil
            }
        } message: { action in
            if profile?.productionProtection == true {
                Text("This connection has production protection enabled. Confirm the configuration change before publishing it to Nacos.")
            } else if case .delete = action {
                Text("Deleting a Nacos configuration cannot be undone.")
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.teal)
                .frame(width: 28, height: 28).background(Color.teal.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Nacos Configuration & Services").font(.system(size: 12.5, weight: .semibold))
                Text("Namespace \(profile?.database.isEmpty == false ? profile!.database : "public")")
                    .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            Button { Task { await feature.loadNacosConfigs(dataId: dataIDSearch, group: groupSearch); await feature.loadNacosServices(serviceName: serviceSearch, group: serviceGroupSearch) } } label: { Image(systemName: "arrow.clockwise") }
                .litheIconButton().help("Refresh Nacos workspace")
                .disabled(feature.isLoading || profile == nil)
        }
        .padding(.horizontal, 12).frame(height: 44).foregroundStyle(LitheTheme.primaryText).litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var configurations: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Data ID", text: $dataIDSearch).textFieldStyle(.roundedBorder)
                    TextField("Group", text: $groupSearch).textFieldStyle(.roundedBorder)
                    Button { Task { await feature.loadNacosConfigs(dataId: dataIDSearch, group: groupSearch) } } label: { Image(systemName: "magnifyingglass") }.litheIconButton()
                }
                .padding(10)
                HStack {
                    Text("\(feature.nacosConfigTotalCount) configurations")
                        .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                    Spacer()
                    Button("New") {
                        feature.nacosSelectedConfig = nil
                        draftDataID = ""; draftGroup = "DEFAULT_GROUP"; draftType = ""; draftContent = ""
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(feature.nacosConfigs) { config in
                            Button { Task { await feature.loadNacosConfig(dataId: config.dataId, group: config.group) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.dataId).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text("\(config.group)\(config.type.map { " · \($0)" } ?? "")")
                                        .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
                                }
                                .padding(.horizontal, 9).frame(height: 42).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).lithePointer()
                            .litheRowHover(isActive: feature.nacosSelectedConfig?.dataId == config.dataId && feature.nacosSelectedConfig?.group == config.group, activeBackground: LitheTheme.subtleSelection)
                        }
                    }.padding(.vertical, 6)
                }
            }
            .frame(minWidth: 285, idealWidth: 340, maxWidth: 390).litheWorkbenchSurface(LitheTheme.sidebar)
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            configEditor
        }
    }

    private var configEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Data ID", text: $draftDataID).textFieldStyle(.roundedBorder)
                TextField("Group", text: $draftGroup).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("Type (optional)", text: $draftType).textFieldStyle(.roundedBorder).frame(width: 135)
                Spacer()
                if feature.nacosSelectedConfig != nil {
                    Button { request(.delete(draftDataID, draftGroup)) } label: { Image(systemName: "trash") }
                        .litheIconButton().foregroundStyle(LitheTheme.error).help("Delete configuration")
                }
            }
            .padding(12).litheWorkbenchSurface(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            TextEditor(text: $draftContent)
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(12).litheWorkbenchSurface(LitheTheme.editor)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Text(feature.nacosSelectedConfig == nil ? "Create a configuration" : "Edit configuration")
                    .font(.system(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("Publish configuration") { request(.publish(draftDataID, draftGroup, draftContent, draftType)) }
                    .buttonStyle(LithePrimaryButtonStyle())
                    .disabled(draftDataID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 48).litheWorkbenchSurface(LitheTheme.toolHeader)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var services: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Service", text: $serviceSearch).textFieldStyle(.roundedBorder)
                    TextField("Group", text: $serviceGroupSearch).textFieldStyle(.roundedBorder)
                    Button { Task { await feature.loadNacosServices(serviceName: serviceSearch, group: serviceGroupSearch) } } label: { Image(systemName: "magnifyingglass") }.litheIconButton()
                }.padding(10)
                Text("\(feature.nacosServiceTotalCount) services")
                    .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(feature.nacosServices) { service in
                            Button { Task { await feature.loadNacosInstances(serviceName: service.name, group: service.group) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text("\(service.group) · \(service.clusterCount) clusters").font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                                }
                                .padding(.horizontal, 9).frame(height: 42).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).lithePointer()
                            .litheRowHover(isActive: false, activeBackground: LitheTheme.subtleSelection)
                        }
                    }.padding(.vertical, 6)
                }
            }
            .frame(minWidth: 285, idealWidth: 340, maxWidth: 390).litheWorkbenchSurface(LitheTheme.sidebar)
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Service instances", systemImage: "server.rack")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(feature.nacosInstances.count) instances").font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                }.padding(12).litheWorkbenchSurface(LitheTheme.toolHeader)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                if feature.nacosInstances.isEmpty {
                    specializedEmptyState(symbol: "network", title: "Select a service", detail: "Choose a Nacos service to inspect its registered instances and health state.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(feature.nacosInstances) { instance in
                                HStack(spacing: 10) {
                                    Circle().fill(instance.healthy ? Color.green : LitheTheme.error).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(instance.ip):\(instance.port)").font(.system(size: 11.5, weight: .medium)).textSelection(.enabled)
                                        Text("\(instance.clusterName ?? "DEFAULT") · \(instance.enabled ? "enabled" : "disabled") · \(instance.ephemeral ? "ephemeral" : "persistent")")
                                            .font(.system(size: 9.5)).foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    Spacer()
                                    Text(instance.healthy ? "Healthy" : "Unhealthy").font(.system(size: 9.5, weight: .medium)).foregroundStyle(instance.healthy ? Color.green : LitheTheme.error)
                                }
                                .padding(10).background(LitheTheme.inputBackground.opacity(0.72)).clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func request(_ action: NacosPendingAction) {
        if profile?.productionProtection == true || isDestructive(action) {
            pendingAction = action; showsWriteConfirmation = true
        } else {
            execute(action, confirmed: true)
        }
    }

    private func execute(_ action: NacosPendingAction, confirmed: Bool) {
        Task {
            switch action {
            case let .publish(dataID, group, content, type):
                _ = await feature.publishNacosConfig(dataId: dataID, group: group, content: content, type: type.isEmpty ? nil : type, confirmed: confirmed)
            case let .delete(dataID, group):
                _ = await feature.deleteNacosConfig(dataId: dataID, group: group, confirmed: confirmed)
            }
        }
    }

    private func isDestructive(_ action: NacosPendingAction) -> Bool {
        if case .delete = action { return true }
        return false
    }
}

private enum NacosSection: Hashable { case configs, services }
private enum NacosPendingAction { case publish(String, String, String, String), delete(String, String) }

@ViewBuilder
private func specializedSectionTitle(_ title: LocalizedStringKey, systemImage: String) -> some View {
    Label(title, systemImage: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(LitheTheme.primaryText)
}

private func specializedEmptyState(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    VStack(spacing: 9) {
        Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(LitheTheme.tertiaryText)
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(LitheTheme.secondaryText)
        Text(detail).font(.system(size: 10.5)).foregroundStyle(LitheTheme.tertiaryText).multilineTextAlignment(.center).frame(maxWidth: 340)
    }
    .padding(22)
}

private func specializedErrorBanner(message: String, retry: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(LitheTheme.error)
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(LitheTheme.primaryText)
            .lineLimit(3)
            .textSelection(.enabled)
        Spacer(minLength: 4)
        Button(action: retry) {
            Image(systemName: "arrow.clockwise")
        }
        .litheIconButton()
        .help("Retry")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(LitheTheme.error.opacity(0.1))
    .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.error.opacity(0.35)).frame(height: 1) }
}

private func redisTypeSymbol(_ type: String) -> String {
    switch type.lowercased() {
    case "string": "text.alignleft"
    case "hash": "curlybraces.square"
    case "list": "list.number"
    case "set": "circle.grid.2x2"
    case "zset": "chart.bar"
    case "stream": "water.waves"
    default: "questionmark.square"
    }
}

private func redisTypeColor(_ type: String) -> Color {
    switch type.lowercased() {
    case "string": .blue
    case "hash": .orange
    case "list": .purple
    case "set": .green
    case "zset": .pink
    case "stream": .teal
    default: LitheTheme.secondaryText
    }
}

private func redisTTLText(_ ttl: Int64) -> String {
    switch ttl {
    case -1: "persistent"
    case -2: "expired"
    case 0...: "TTL \(ttl)s"
    default: "TTL unknown"
    }
}

private func redisSizeText(_ size: Int64) -> String {
    size < 0 ? "size not estimated" : "size \(size)"
}
