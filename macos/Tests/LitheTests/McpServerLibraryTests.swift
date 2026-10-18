import Foundation
import Testing
@testable import Lithe

/// End-to-end library behavior against real files in a temporary home.
///
/// Core still plans every edit; these tests verify the application merge,
/// ownership ledger, backups and project registration around it.
@MainActor
struct McpServerLibraryTests {
    @Test(arguments: McpAgent.allCases, [false, true])
    func staleEditorCannotOverwriteAnotherWindowsSave(agent: McpAgent, refreshBeforeSave: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.feature()
        var initial = first.makeDraft()
        initial.name = "alpha"
        initial.command = "/bin/echo"
        initial.argumentsText = "before"
        initial.enabledAgents = [agent]
        #expect(first.save(initial))
        let original = try #require(first.rows.first)
        var stale = first.draft(for: original)

        // Two feature models share files and the ledger, with a controlled save
        // order. No threads or timing assumptions are needed to expose the race.
        let second = fixture.feature()
        second.refresh()
        var newer = second.draft(for: try #require(second.rows.first))
        newer.argumentsText = "other-window"
        #expect(second.save(newer))
        let url = agent == .codex ? fixture.codexURL : fixture.claudeURL
        let expected = try fixture.text(at: url)
        let ledger = try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))
        if refreshBeforeSave { first.refresh() }

        // A stale save must also fail when its desired fields happen to equal
        // disk: an unchanged fast path must not silently accept the old editor.
        stale.argumentsText = refreshBeforeSave ? "other-window" : "stale-write"
        #expect(first.save(stale) == false)
        #expect(first.error?.contains("outside Lithe") == true)
        #expect(try fixture.text(at: url) == expected)
        #expect(fixture.ledger.data(forKey: "settings.mcpServerRegistrations") == ledger)
        #expect(first.lastBackupURL == nil)
    }

    @Test(arguments: ["bearer_token_env_var = \"CHANGED_TOKEN\"", "startup_timeout_sec = 90"])
    func codexUnmodeledChangesBlockOwnedRemovalAndStaleEdits(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedCodex("""
        [mcp_servers.alpha]
        url = "https://example.invalid/mcp"
        bearer_token_env_var = "ORIGINAL_TOKEN"
        startup_timeout_sec = 30
        """)
        let feature = fixture.feature()
        feature.refresh()
        let unowned = try #require(feature.rows.first)
        feature.takeOwnership(of: unowned, agent: .codex)
        let owned = try #require(feature.rows.first)
        var stale = feature.draft(for: owned)
        let ledger = try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))
        let external = try fixture.codexText()
            .replacingOccurrences(
                of: field.hasPrefix("bearer") ? "bearer_token_env_var = \"ORIGINAL_TOKEN\"" : "startup_timeout_sec = 30",
                with: field
            )
        try fixture.seedCodex(external)
        feature.refresh()
        let changed = try #require(feature.rows.first)
        #expect(changed.id == owned.id)
        #expect(changed.ownedGlobalAgents.isEmpty)
        #expect(feature.setAgent(.codex, enabled: false, for: owned) == false)
        #expect(feature.delete(owned) == false)
        stale.url = "https://example.invalid/edited"
        #expect(feature.save(stale) == false)
        stale.name = "renamed"
        #expect(feature.save(stale) == false)
        #expect(try fixture.codexText() == external)
        #expect(fixture.ledger.data(forKey: "settings.mcpServerRegistrations") == ledger)
        #expect(feature.lastBackupURL == nil)
    }

    @Test
    func mergedAgentsUseTheirOwnFullSourceVersionsWhenEditing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers":{"alpha":{"url":"https://example.invalid/mcp","type":"http","vendorFlag":true}}}
        """)
        try fixture.seedCodex("""
        [mcp_servers.alpha]
        url = "https://example.invalid/mcp"
        bearer_token_env_var = "TOKEN_NAME"
        """)
        let feature = fixture.feature()
        feature.refresh()
        #expect(feature.rows.count == 1)
        let row = try #require(feature.rows.first)
        #expect(Set(row.globalSources.compactMap(\.sourceHash)).count == 2)
        var draft = feature.draft(for: row)
        draft.url = "https://example.invalid/updated"
        #expect(feature.save(draft))
        #expect(try fixture.claudeText().contains("vendorFlag"))
        #expect(try fixture.codexText().contains("TOKEN_NAME"))
        #expect(try #require(feature.rows.first).ownedGlobalAgents == Set(McpAgent.allCases))
    }

    @Test
    func projectCleanupKeepsAgentSpecificExternalChanges() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(name: "lithe", command: "/bin/echo"))
        #expect(feature.litheRegistration == .registered)
        let url = fixture.workspace.appendingPathComponent(".codex/config.toml")
        let external = try fixture.text(at: url) + "\nstartup_timeout_sec = 90\n"
        try fixture.write(external, to: url)
        let ledger = try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))
        let before = try JSONDecoder().decode([String: [McpOwnedEntry]].self, from: ledger)

        fixture.clearWorkspace()
        feature.unregisterLitheServer()

        #expect(try fixture.text(at: url) == external)
        #expect(feature.error?.contains("outside Lithe") == true)
        let after = try JSONDecoder().decode(
            [String: [McpOwnedEntry]].self,
            from: try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))
        )
        let key = "codex|project|\(fixture.workspace.path)"
        #expect(after[key] == before[key])
        #expect(try fixture.claudeText().contains("\"lithe\"") == false)
    }

    @Test
    func repeatedProjectRegistrationDoesNotAdoptExternalTimeoutChanges() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        let server = McpServerDefinition(name: "lithe", command: "/bin/echo")
        feature.registerLitheServer(server)
        #expect(feature.litheRegistration == .registered)
        let url = fixture.workspace.appendingPathComponent(".codex/config.toml")
        let external = try fixture.text(at: url) + "\nstartup_timeout_sec = 90\n"
        try fixture.write(external, to: url)
        let ledger = try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))

        feature.registerLitheServer(server)

        if case .needsAttention(let message) = feature.litheRegistration {
            #expect(message.contains("outside Lithe"))
        } else {
            Issue.record("Expected unchanged automatic registration to keep the ownership conflict")
        }
        #expect(try fixture.text(at: url) == external)
        #expect(fixture.ledger.data(forKey: "settings.mcpServerRegistrations") == ledger)
    }

    @Test
    func legacyLedgerRequiresExplicitAdoptionBeforeAutomaticDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedCodex("[mcp_servers.alpha]\ncommand = \"/bin/echo\"\nstartup_timeout_sec = 90\n")
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first)
        let key = "codex|global|"
        // Older versions stored no complete source identity. Matching the visible
        // fields alone cannot prove these Agent-specific settings are still owned.
        let legacy = [key: [McpOwnedEntry(name: row.name, definitionHash: row.definition.definitionHash)]]
        fixture.ledger.set(try JSONEncoder().encode(legacy), forKey: "settings.mcpServerRegistrations")
        let expected = try fixture.codexText()
        feature.refresh()
        #expect(try #require(feature.rows.first).ownedGlobalAgents.isEmpty)
        #expect(feature.delete(row) == false)
        #expect(try fixture.codexText() == expected)
        feature.takeOwnership(of: try #require(feature.rows.first), agent: .codex)
        #expect(feature.delete(try #require(feature.rows.first)))
        #expect(try fixture.codexText().contains("[mcp_servers.alpha]") == false)
    }

    @Test
    func discoversSameDefinitionFromBothAgentsAsOneRow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {
          "numStartups": 12,
          "mcpServers": {
            "alpha": {"command": "/bin/echo", "args": ["-y", "alpha"], "env": {"TOKEN": "secret"}}
          }
        }
        """)
        try fixture.seedCodex("""
        # keep this comment
        model = "gpt-5"

        [mcp_servers.alpha]
        command = "/bin/echo"
        args = ["-y", "alpha"]
        env = { TOKEN = "secret" }
        """)

        let feature = fixture.feature()
        feature.refresh()

        #expect(feature.loadErrors.isEmpty)
        #expect(feature.rows.count == 1)
        let row = try #require(feature.rows.first)
        #expect(row.name == "alpha")
        #expect(row.enabledGlobalAgents == Set(McpAgent.allCases))
        #expect(row.hasDefinitionConflict == false)
        #expect(row.ownedGlobalAgents.isEmpty)
    }

    @Test
    func takingOwnershipEnablesRemovingAnExternallyCreatedEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["keep-me"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first)

        #expect(feature.setAgent(.claudeCode, enabled: false, for: row) == false)
        #expect(feature.error?.contains("outside Lithe") == true)
        #expect(try fixture.claudeText().contains("keep-me"))

        feature.error = nil
        feature.takeOwnership(of: row, agent: .claudeCode)
        let owned = try #require(feature.rows.first)
        #expect(owned.ownedGlobalAgents == [.claudeCode])
        #expect(feature.setAgent(.claudeCode, enabled: false, for: owned))

        let updated = try fixture.claudeText()
        #expect(updated.contains("alpha") == false)
        let object = try JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any]
        let root = try #require(object)
        let servers = root["mcpServers"] as? [String: Any]
        #expect(servers?.isEmpty == true)
    }

    @Test
    func takingOwnershipInTheOpenEditorAllowsClosingThatAgent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["keep"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.draft(for: try #require(feature.rows.first { $0.name == "alpha" }))
        #expect(draft.enabledAgents == [.claudeCode])
        draft.enabledAgents = [.codex]

        // Closing the Agent that owns the entry is still refused before the
        // user adopts it, even though the draft already targets Codex.
        #expect(feature.save(draft) == false)
        #expect(feature.error?.contains("outside Lithe") == true)
        #expect(try fixture.claudeText().contains("keep"))

        // Taking ownership refreshes the list but must also authorize the
        // still-open draft, whose captured sources predate the adoption.
        feature.takeOwnership(
            of: try #require(feature.rows.first { $0.name == "alpha" }), agent: .claudeCode
        )
        #expect(feature.save(draft))
        #expect(feature.error == nil)
        #expect(try fixture.claudeText().contains("\"alpha\"") == false)
        #expect(try fixture.codexText().contains("[mcp_servers.alpha]"))
    }

    @Test
    func newerLedgerEntryDoesNotAuthorizeAStaleDraftRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let first = fixture.feature()
        first.refresh()
        var created = first.makeDraft()
        created.name = "alpha"
        created.command = "/bin/echo"
        created.enabledAgents = [.claudeCode]
        #expect(first.save(created))

        // The first editor captures the complete source version it displays.
        let captured = try #require(first.rows.first { $0.name == "alpha" })
        var stale = first.draft(for: captured)

        // Another window edits and saves the same entry under a new hash.
        let second = fixture.feature()
        second.refresh()
        var newer = second.draft(for: try #require(second.rows.first { $0.name == "alpha" }))
        newer.env = [McpKeyValue(key: "TOKEN", value: "new")]
        #expect(second.save(newer))
        let afterNewerSave = try fixture.claudeText()
        let ledgerAfterNewerSave = try #require(
            fixture.ledger.data(forKey: "settings.mcpServerRegistrations")
        )

        // The newest ledger entry must not authorize the stale draft to close
        // the Agent; the captured source version stays a precondition.
        stale.enabledAgents = [.codex]
        #expect(first.save(stale) == false)
        #expect(first.error?.contains("outside Lithe") == true)
        #expect(try fixture.claudeText() == afterNewerSave)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexURL.path))
        #expect(fixture.ledger.data(forKey: "settings.mcpServerRegistrations") == ledgerAfterNewerSave)
    }

    @Test
    func legacyLedgerStillAsksForOwnershipWhenClosingAnAgent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        try fixture.seedCodex("[mcp_servers.alpha]\ncommand = \"/bin/echo\"\nstartup_timeout_sec = 20\n")
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "alpha" })
        var draft = feature.draft(for: row)
        // An older ledger has no complete source version, so refreshing cannot
        // turn it into ownership; the user must take ownership explicitly.
        let legacy = [
            "codex|global|": [McpOwnedEntry(
                name: row.name, definitionHash: row.definition.definitionHash
            )]
        ]
        fixture.ledger.set(
            try JSONEncoder().encode(legacy), forKey: "settings.mcpServerRegistrations"
        )
        draft.enabledAgents = [.claudeCode]
        #expect(feature.save(draft) == false)
        #expect(feature.error?.contains("Take ownership") == true)
        #expect(try fixture.codexText().contains("alpha"))
    }

    @Test
    func lostLedgerRecordDoesNotAuthorizeADraftRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let feature = fixture.feature()
        feature.refresh()
        var created = feature.makeDraft()
        created.name = "alpha"
        created.command = "/bin/echo"
        created.enabledAgents = [.claudeCode]
        #expect(feature.save(created))
        let captured = try #require(feature.rows.first { $0.name == "alpha" })
        var stale = feature.draft(for: captured)

        // The shared ledger loses the record while the file stays intact. An
        // OR-style guard would let the draft remove the entry via Core, so
        // this pins the captured-version precondition in Swift.
        fixture.ledger.set(
            try JSONEncoder().encode([String: [McpOwnedEntry]]()),
            forKey: "settings.mcpServerRegistrations"
        )
        stale.enabledAgents = [.codex]
        #expect(feature.save(stale) == false)
        #expect(feature.error?.contains("Refresh") == true)
        #expect(try fixture.claudeText().contains("alpha"))
        #expect(!FileManager.default.fileExists(atPath: fixture.codexURL.path))
    }

    @Test
    func removedEntryTellsTheStaleEditorToRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let first = fixture.feature()
        first.refresh()
        var created = first.makeDraft()
        created.name = "alpha"
        created.command = "/bin/echo"
        created.enabledAgents = [.claudeCode]
        #expect(first.save(created))
        let captured = try #require(first.rows.first { $0.name == "alpha" })
        var stale = first.draft(for: captured)

        // Another window deletes the entry and its ledger record.
        let second = fixture.feature()
        second.refresh()
        #expect(second.delete(try #require(second.rows.first { $0.name == "alpha" })))
        #expect(try fixture.claudeText().contains("alpha") == false)

        stale.enabledAgents = [.codex]
        #expect(first.save(stale) == false)
        #expect(first.error?.contains("Refresh") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexURL.path))
        let remainingLedger = try JSONDecoder().decode(
            [String: [McpOwnedEntry]].self,
            from: try #require(fixture.ledger.data(forKey: "settings.mcpServerRegistrations"))
        )
        #expect(remainingLedger.isEmpty)
    }

    @Test
    func editsAnExternallyCreatedEntryWhileTheDisplayedDefinitionIsCurrent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["before"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "alpha" })
        #expect(row.ownedGlobalAgents.isEmpty)

        var draft = feature.draft(for: row)
        draft.argumentsText = "after"
        #expect(feature.save(draft))
        let updated = try fixture.claudeText()
        #expect(updated.contains("after"))
        #expect(updated.contains("before") == false)

        // A row captured before an external edit must not overwrite that edit.
        let stale = try #require(feature.rows.first { $0.name == "alpha" })
        var staleDraft = feature.draft(for: stale)
        try fixture.write(
            "{\"mcpServers\": {\"alpha\": {\"command\": \"/bin/echo\", \"args\": [\"external\"]}}}",
            to: fixture.claudeURL
        )
        staleDraft.argumentsText = "stale-write"
        #expect(feature.save(staleDraft) == false)
        #expect(feature.error?.contains("outside Lithe") == true)
        let untouched = try fixture.claudeText()
        #expect(untouched.contains("external"))
        #expect(untouched.contains("stale-write") == false)
    }

    @Test
    func addsAndEditsOneDefinitionInBothAgentFilesWithoutLosingFormatting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {
          "numStartups": 12,
          "mcpServers": {}
        }
        """)
        try fixture.seedCodex("""
        # keep this comment
        model = "gpt-5"

        [mcp_servers.existing]
        command = "/bin/true"
        """)

        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "gamma"
        draft.transport = .stdio
        draft.command = "/bin/echo"
        draft.argumentsText = "hello world\n--flag"
        draft.env = [McpKeyValue(key: "TOKEN", value: "abc")]
        draft.enabledAgents = Set(McpAgent.allCases)

        #expect(feature.save(draft))
        #expect(feature.lastBackupURL != nil)

        let claude = try fixture.claudeText()
        #expect(claude.contains("\"numStartups\": 12"))
        #expect(claude.contains("\"gamma\""))
        #expect(claude.contains("hello world"))
        let codex = try fixture.codexText()
        #expect(codex.contains("# keep this comment"))
        #expect(codex.contains("[mcp_servers.existing]"))
        #expect(codex.contains("[mcp_servers.gamma]"))
        #expect(codex.contains("hello world"))

        let added = try #require(feature.rows.first { $0.name == "gamma" })
        #expect(added.ownedGlobalAgents == Set(McpAgent.allCases))

        // Editing the owned definition replaces it in both files and records
        // the fresh hash, so removing it needs no second adoption.
        var edited = feature.draft(for: added)
        edited.argumentsText = "updated"
        #expect(feature.save(edited))
        let editedCodex = try fixture.codexText()
        let editedClaude = try fixture.claudeText()
        #expect(editedCodex.contains("updated"))
        #expect(editedClaude.contains("updated"))
        let updated = try #require(feature.rows.first { $0.name == "gamma" })
        #expect(feature.delete(updated))
        let deletedCodex = try fixture.codexText()
        let deletedClaude = try fixture.claudeText()
        #expect(deletedCodex.contains("gamma") == false)
        #expect(deletedClaude.contains("gamma") == false)
        #expect(deletedCodex.contains("[mcp_servers.existing]"))
    }

    @Test
    func projectRegistrationWritesBothAgentsAndCleansUpOnDisable() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"global": {"command": "/bin/true"}}}
        """)
        let feature = fixture.feature()
        feature.refresh()

        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))

        #expect(feature.litheRegistration == .registered)
        #expect(feature.litheRegisteredAgents == Set(McpAgent.allCases))
        let claude = try fixture.claudeText()
        #expect(claude.contains("\"global\""))
        #expect(claude.contains("fixture"))
        let codexProjectURL = fixture.workspace.appendingPathComponent(".codex/config.toml")
        let codex = try fixture.text(at: codexProjectURL)
        #expect(codex.contains("[mcp_servers.lithe]"))
        let exclude = try fixture.text(at: fixture.workspace.appendingPathComponent(".git/info/exclude"))
        #expect(exclude.contains(".codex/config.toml"))

        feature.unregisterLitheServer()

        #expect(feature.litheRegistration == .inactive)
        let unregisteredClaude = try fixture.claudeText()
        let unregisteredCodex = try fixture.text(at: codexProjectURL)
        #expect(unregisteredClaude.contains("fixture") == false)
        #expect(unregisteredCodex.contains("[mcp_servers.lithe]") == false)
        #expect(unregisteredClaude.contains("\"global\""))
    }

    @Test
    func projectCloseFindsTheRegistrationWorkspaceAfterTheSessionClearsIt() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))
        #expect(feature.litheRegistration == .registered)

        // WorkspaceSessionCoordinator clears the session before the close
        // callback reaches the MCP grant, so the current URL is already nil.
        fixture.clearWorkspace()
        feature.unregisterLitheServer()

        #expect(feature.litheRegistration == .inactive)
        let claude = try fixture.claudeText()
        #expect(claude.contains("\"lithe\"") == false)
        let codexURL = fixture.workspace.appendingPathComponent(".codex/config.toml")
        let codex = try fixture.text(at: codexURL)
        #expect(codex.contains("[mcp_servers.lithe]") == false)
    }

    @Test
    func linkedWorktreeRegistrationUsesTheSharedExcludeFile() throws {
        let fixture = try Fixture(workspace: true, linkedWorktree: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))
        #expect(feature.litheRegistration == .registered)

        // Git reads excludes from the common directory, not from the linked
        // worktree's `.git/worktrees/<name>/info/exclude`.
        let exclude = try fixture.text(
            at: fixture.commonGitDirectory.appendingPathComponent("info/exclude")
        )
        #expect(exclude.contains(".codex/config.toml"))
    }

    @Test
    func refusesToOverwriteBytesThatChangedAfterPlanning() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let file = try #require(fixture.store.configurationFiles(workspace: nil)
            .first { $0.agent == .claudeCode && $0.scope == .global })
        let plannedFrom = try #require(try fixture.store.read(file))

        // Another Agent saves between planning and the write.
        try fixture.write(
            "{\"mcpServers\": {\"external\": {\"command\": \"/bin/false\"}}}",
            to: fixture.claudeURL
        )
        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try fixture.store.write(
                "{\"mcpServers\": {\"a\": {\"command\": \"/bin/true\"}}}",
                to: file,
                replacing: plannedFrom
            )
        }
        let untouched = try fixture.claudeText()
        #expect(untouched.contains("external"))
        #expect(untouched.contains("/bin/true") == false)
    }

    @Test
    func refusesToCreateAFileThatAppearedAfterPlanning() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = try #require(fixture.store.configurationFiles(workspace: nil)
            .first { $0.agent == .claudeCode && $0.scope == .global })
        #expect(try fixture.store.read(file) == nil)

        try fixture.seedClaude("{\"mcpServers\": {\"external\": {\"command\": \"/bin/false\"}}}")
        #expect(throws: McpConfigurationError.changedOnDisk) {
            _ = try fixture.store.write("{\"mcpServers\": {}}", to: file, replacing: nil)
        }
        #expect(try fixture.claudeText().contains("external"))
    }

    @Test
    func renamingARowKeepsCodexSpecificFields() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedCodex("""
        model = "gpt-5"

        [mcp_servers.remote]
        url = "https://example.test/mcp"
        bearer_token_env_var = "REMOTE_TOKEN"
        startup_timeout_sec = 20
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "remote" })
        feature.takeOwnership(of: row, agent: .codex)
        let owned = try #require(feature.rows.first { $0.name == "remote" })

        var draft = feature.draft(for: owned)
        draft.name = "renamed"
        #expect(feature.save(draft))

        let codex = try fixture.codexText()
        #expect(codex.contains("[mcp_servers.renamed]"))
        #expect(codex.contains("[mcp_servers.remote]") == false)
        #expect(codex.contains("bearer_token_env_var = \"REMOTE_TOKEN\""))
        #expect(codex.contains("startup_timeout_sec = 20"))
        let renamed = try #require(feature.rows.first { $0.name == "renamed" })
        #expect(renamed.ownedGlobalAgents == [.codex])
    }

    @Test
    func savingNaturallyOrderedEntriesKeepsOwnershipAfterRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "ordered"
        draft.transport = .stdio
        draft.command = "/bin/echo"
        // Swift sorts TOKEN2 before TOKEN10; Rust parses in byte order. Both
        // paths must produce the same identity hash.
        draft.env = [
            McpKeyValue(key: "TOKEN2", value: "b"),
            McpKeyValue(key: "TOKEN10", value: "a")
        ]
        draft.enabledAgents = [.claudeCode]

        #expect(feature.save(draft))
        let row = try #require(feature.rows.first { $0.name == "ordered" })
        #expect(row.ownedGlobalAgents == [.claudeCode])
    }

    @Test
    func windowsMergeTheirOwnershipLedgers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Both windows open the page before either saves, so each starts from
        // the same (empty) ledger.
        let first = fixture.feature()
        let second = fixture.feature()
        first.refresh()
        second.refresh()

        var alpha = first.makeDraft()
        alpha.name = "alpha"
        alpha.command = "/bin/echo"
        alpha.enabledAgents = [.claudeCode]
        #expect(first.save(alpha))

        var beta = second.makeDraft()
        beta.name = "beta"
        beta.command = "/bin/echo"
        beta.enabledAgents = [.claudeCode]
        #expect(second.save(beta))

        // A reopened window must still see both entries as Lithe-owned.
        let reopened = fixture.feature()
        reopened.refresh()
        let alphaRow = try #require(reopened.rows.first { $0.name == "alpha" })
        let betaRow = try #require(reopened.rows.first { $0.name == "beta" })
        #expect(alphaRow.ownedGlobalAgents == [.claudeCode])
        #expect(betaRow.ownedGlobalAgents == [.claudeCode])
    }

    @Test
    func unregisteringAfterAProjectSwitchCleansBothProjects() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        let definition = McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        )
        feature.registerLitheServer(definition)
        #expect(feature.litheRegistration == .registered)

        // The next project registers before the previous registration is
        // cleaned up, so a single stored workspace would strand the first one.
        let second = fixture.root.appendingPathComponent("project-two", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        fixture.setWorkspace(second)
        feature.registerLitheServer(definition)
        #expect(feature.litheRegistration == .registered)

        feature.unregisterLitheServer()

        let firstCodex = try fixture.text(
            at: fixture.workspace.appendingPathComponent(".codex/config.toml")
        )
        let secondCodex = try fixture.text(
            at: second.appendingPathComponent(".codex/config.toml")
        )
        #expect(firstCodex.contains("[mcp_servers.lithe]") == false)
        #expect(secondCodex.contains("[mcp_servers.lithe]") == false)
        let claude = try fixture.claudeText()
        #expect(claude.contains("\"lithe\"") == false)
    }

    @Test
    func excludeFailureKeepsAProjectRegistrationThatCanStillBeCleanedUp() throws {
        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        // A directory at the exclude path makes the append fail without
        // depending on file permissions or the user running the test.
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".git/info/exclude"),
            withIntermediateDirectories: true
        )
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))

        guard case .needsAttention(let message) = feature.litheRegistration else {
            Issue.record("Expected a Git exclude warning")
            return
        }
        #expect(message.contains("could not be added"))
        #expect(feature.litheRegisteredAgents == Set(McpAgent.allCases))
        let codexURL = fixture.workspace.appendingPathComponent(".codex/config.toml")
        #expect(try fixture.text(at: codexURL).contains("[mcp_servers.lithe]"))

        // The ledger must still find the entry, otherwise the grant can never
        // remove the project configuration it successfully wrote.
        feature.unregisterLitheServer()
        #expect(try fixture.text(at: codexURL).contains("[mcp_servers.lithe]") == false)
    }

    @Test
    func rejectsDuplicateEnvironmentVariableNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "duplicates"
        draft.command = "/bin/echo"
        draft.env = [
            McpKeyValue(key: "TOKEN", value: "first"),
            McpKeyValue(key: "TOKEN", value: "second")
        ]
        draft.enabledAgents = [.claudeCode]

        #expect(feature.save(draft) == false)
        #expect(feature.error?.contains("unique") == true)
        #expect(try fixture.claudeText().contains("duplicates") == false)

        // The inactive transport's entries are not written, so they cannot
        // collide and must not block the save.
        draft.transport = .http
        draft.url = "https://example.test/mcp"
        #expect(feature.save(draft))
    }

    @Test
    func renamingAnExternallyCreatedEntryMovesIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("""
        {"mcpServers": {"alpha": {"command": "/bin/echo", "args": ["keep"]}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "alpha" })
        #expect(row.ownedGlobalAgents.isEmpty)

        // An explicit edit may move an entry Lithe did not create, but both
        // the new name and the removal of the old name need the displayed
        // hash as authorization.
        var draft = feature.draft(for: row)
        draft.name = "beta"
        #expect(feature.save(draft))

        let claude = try fixture.claudeText()
        #expect(claude.contains("\"beta\""))
        #expect(claude.contains("\"alpha\"") == false)
        #expect(claude.contains("keep"))
        let renamed = try #require(feature.rows.first { $0.name == "beta" })
        #expect(renamed.ownedGlobalAgents == [.claudeCode])
    }

    @Test
    func enablingAnAgentIgnoresEntriesTheTransportDoesNotWrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // The Claude entry carries an env map even though HTTP servers do not
        // use one. Codex writes only the URL, so the identity hash must ignore
        // env or the fresh Codex entry would immediately lose ownership.
        try fixture.seedClaude("""
        {"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp", "env": {"STRAY": "1"}}}}
        """)
        let feature = fixture.feature()
        feature.refresh()
        let row = try #require(feature.rows.first { $0.name == "remote" })
        #expect(feature.setAgent(.codex, enabled: true, for: row))

        let merged = try #require(feature.rows.first { $0.name == "remote" })
        #expect(merged.ownedGlobalAgents == [.codex])
        #expect(feature.setAgent(.codex, enabled: false, for: merged))
        let codex = try fixture.codexText()
        #expect(codex.contains("remote") == false)
    }

    @Test
    func changingTransportDropsFieldsTheNewTransportDoesNotWrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.seedClaude("{\"mcpServers\": {}}")
        let feature = fixture.feature()
        feature.refresh()
        var draft = feature.makeDraft()
        draft.name = "switched"
        draft.command = "/bin/echo"
        draft.argumentsText = "--old"
        draft.env = [McpKeyValue(key: "TOKEN", value: "secret")]
        draft.enabledAgents = [.claudeCode]
        #expect(feature.save(draft))

        // The editor hides stdio arguments after switching to HTTP but does
        // not erase them. They must not be hashed or written for the HTTP
        // entry, or the saved row immediately loses ownership.
        let saved = try #require(feature.rows.first { $0.name == "switched" })
        var edited = feature.draft(for: saved)
        edited.transport = .http
        edited.url = "https://example.test/mcp"
        #expect(feature.save(edited))

        let claude = try fixture.claudeText()
        #expect(claude.contains("--old") == false)
        #expect(claude.contains("\"TOKEN\"") == false)
        let switched = try #require(feature.rows.first { $0.name == "switched" })
        #expect(switched.definition.transport == .http)
        #expect(switched.ownedGlobalAgents == [.claudeCode])
        #expect(feature.setAgent(.claudeCode, enabled: false, for: switched))
    }

    @Test
    func externallyModifiedProjectEntryIsKeptAndReported() throws {        let fixture = try Fixture(workspace: true)
        defer { fixture.cleanUp() }
        let feature = fixture.feature()
        feature.registerLitheServer(McpServerDefinition(
            name: "lithe",
            transport: .stdio,
            command: "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            args: ["--connection", "fixture"]
        ))
        #expect(feature.litheRegistration == .registered)

        // The Agent's project Codex entry is edited outside Lithe.
        try fixture.write(
            """
            [mcp_servers.lithe]
            command = "/usr/local/bin/other"
            """,
            to: fixture.workspace.appendingPathComponent(".codex/config.toml")
        )

        feature.unregisterLitheServer()

        if case .needsAttention(let message) = feature.litheRegistration {
            #expect(message.contains("outside Lithe"))
        } else {
            Issue.record("Expected a registration conflict")
        }
        // The project section hides its registration line when the grant is
        // off, so the library error banner is the only visible warning.
        #expect(feature.error?.contains("outside Lithe") == true)
        let kept = try fixture.text(at: fixture.workspace.appendingPathComponent(".codex/config.toml"))
        #expect(kept.contains("/usr/local/bin/other"))
    }
}

@MainActor
private final class LibraryActionsFixture: McpServerLibraryActions {
    let store: MacAgentMcpConfigurationStore
    var mcpWorkspaceURL: URL?
    let ledger = LibraryTestKeyValueStore()

    init(store: MacAgentMcpConfigurationStore, workspace: URL?) {
        self.store = store
        mcpWorkspaceURL = workspace
    }

    var mcpConfigurationStore: (any McpConfigurationStore)? { store }
    var mcpLedgerStore: any KeyValueStore { ledger }
}

private final class LibraryTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct LibraryTestFileStorage: FileStorage {
    let root: URL
    private let files = MacFileStorage()

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root.appendingPathComponent("Caches", isDirectory: true) }
    func applicationSupportDirectory() -> URL {
        root.appendingPathComponent("Application Support", isDirectory: true)
    }
    func temporaryDirectory() -> URL { root.appendingPathComponent("tmp", isDirectory: true) }

    func metadata(for url: URL) -> FileMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        return FileMetadata(
            byteCount: (attributes[.size] as? NSNumber)?.intValue,
            modificationDate: attributes[.modificationDate] as? Date,
            isRegularFile: type == .typeRegular,
            isDirectory: type == .typeDirectory,
            isWritable: FileManager.default.isWritableFile(atPath: url.path)
        )
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func listDirectory(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []
    }

    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        try Data(contentsOf: url).prefix(byteCount)
    }

    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        try Data(contentsOf: url, options: options)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        try files.replaceData(data, at: url, expecting: expected)
    }

    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        try files.removeData(at: url, expecting: expected)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let workspace: URL
    let claudeHome: URL
    let codexHome: URL
    /// Git common directory, used for the shared `info/exclude`.
    let commonGitDirectory: URL
    private let actions: LibraryActionsFixture

    init(workspace: Bool = false, linkedWorktree: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        codexHome = root.appendingPathComponent("codex", isDirectory: true)
        self.workspace = root.appendingPathComponent("project", isDirectory: true)
        if workspace {
            try FileManager.default.createDirectory(
                at: self.workspace, withIntermediateDirectories: true
            )
            if linkedWorktree {
                let common = root.appendingPathComponent("repository/.git", isDirectory: true)
                commonGitDirectory = common
                let worktreeGit = common.appendingPathComponent("worktrees/linked", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: worktreeGit, withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: common.appendingPathComponent("info"), withIntermediateDirectories: true
                )
                try Data("gitdir: \(worktreeGit.path)\n".utf8).write(
                    to: self.workspace.appendingPathComponent(".git")
                )
                try Data("../..\n".utf8).write(
                    to: worktreeGit.appendingPathComponent("commondir")
                )
            } else {
                commonGitDirectory = self.workspace.appendingPathComponent(".git", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: self.workspace.appendingPathComponent(".git/info", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        } else {
            commonGitDirectory = root.appendingPathComponent("repository/.git", isDirectory: true)
        }
        let storage = LibraryTestFileStorage(root: root)
        actions = LibraryActionsFixture(
            store: MacAgentMcpConfigurationStore(
                core: RustCoreBridge(),
                storage: storage,
                environment: [
                    "CLAUDE_CONFIG_DIR": claudeHome.path,
                    "CODEX_HOME": codexHome.path
                ]
            ),
            workspace: workspace ? self.workspace : nil
        )
    }

    func feature() -> McpServerLibraryFeatureModel {
        McpServerLibraryFeatureModel(model: actions)
    }

    var store: MacAgentMcpConfigurationStore { actions.store }
    var ledger: any KeyValueStore { actions.ledger }

    /// Simulates the session URL being cleared before the close callback.
    func clearWorkspace() {
        actions.mcpWorkspaceURL = nil
    }

    /// Switches the open project without going through the grant lifecycle.
    func setWorkspace(_ url: URL) {
        actions.mcpWorkspaceURL = url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var claudeURL: URL { claudeHome.appendingPathComponent(".claude.json") }
    var codexURL: URL { codexHome.appendingPathComponent("config.toml") }

    func seedClaude(_ text: String) throws { try write(text, to: claudeURL) }
    func seedCodex(_ text: String) throws { try write(text, to: codexURL) }
    func claudeText() throws -> String { try text(at: claudeURL) }
    func codexText() throws -> String { try text(at: codexURL) }

    func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
