#!/usr/bin/env bash
# Builds the pinned Lithe-core-rust static library for the Viva desktop client and stages the
# header, archive, native linker flags and build identity under .artifacts/desktop/lithe-core/:
#
# Usage: scripts/desktop/build-desktop-core.sh [--debug|--release|--checkout-only]
#
#   include/lithe_core.h     the C ABI header of that core revision
#   lib/liblithe_core.a      the static library that cgo links
#   bin/lithe-mcp[.exe]      the IDE API stdio helper the desktop client embeds when packaged
#   native-static-libs.txt   the system libraries and frameworks rustc says the archive needs
#   identity.txt             core revision, dirty flag, rustc, target and profile of the build
#
# LITHE_CORE_RUST_DIR points the build at a local core checkout. LITHE_CORE_TARGET selects a Rust
# target; Windows uses x86_64-pc-windows-gnu because cgo cannot link an MSVC .lib archive. The
# staging directory is build state of this worktree and is never written into an app bundle.
#
# --checkout-only prepares the same core checkout, builds nothing and prints the checkout instead.
# scripts/desktop/build-remote-server.sh uses it, so the pin and the clone live only here.
#
# The staging directory is the only line written to standard output, so a caller can read it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Lithe-core-rust #128 (604699f), on top of #127: outputStyle.decode preserves raw
# bytes and decodes each line as UTF-8, with GBK fallback on Windows; outputEncoding.resolve
# supplies actual candidates. run/start and build prepareRun may declare outputEncoding (#2186).
# Lithe-core-rust main at 98e6940 (#119 protocol changelog only) on top of #118 (8c77c3f, on top of #117 plugin
# SDK documentation only): the toolchain catalog records a decision on each workspace (trusted,
# distrusted for safe mode, or unknown) and trusted locations, toolchains.catalogState reports it as
# workspaceTrust, and build plan requests take projectCodeAllowed, without which every plan that
# runs project code is refused as plugin.build.untrustedWorkspace (#2201).
# Below it, Lithe-core-rust main at ce628c7: #116, squash-merged into main: content search and its index read
# every file the editor opens as text (up to 16 MiB, decoded like file.read, binary files skipped)
# and match a CRLF line without its \r; replacement previews still read only strict UTF-8 up to
# 2 MiB. It is on top of #115 (929b8c6, documentation only), #112 (44d62e4, command test
# discovery: build.testDiscoveryPlan and build.decodeTestDiscovery), #111 (c481227, global
# toolchain provider queries resolved), #106 (509c2be, typed toolchain providers in the Rust SDK),
# #114 (a9539ed) and #113 (31657cc, the Go plugin backend SDK), which only changed plugin SDKs and
# documentation, and #110 (7b6a967, Core CI formatting check).
# Below them, Lithe-core-rust main at 0b6da27: #109, squash-merged into main: a canvas's on may list resize
# beside viewport, which the desktop sends with the new width 400 ms after the width stops
# changing; every view event carries width, the width the view's nodes are laid out in. It is on
# top of #108 (9dea6aa), squash-merged into main: managedRuntimes 1 lists mirror URLs for runtime
# artifacts, and #105 (555eb95), which only changed the plugin documentation.
# Below them, Lithe-core-rust main at 545ca11: #104, squash-merged into main: plugin views replace the native
# UI document. A tool window's view.function and a manifest's settingRegions[].view name a backend
# view function the host calls once per event, and plugins.ui.applyResult checks each result (a
# whole view, patches or nothing) against the manifest, the surface and the view drawn last and
# returns the view to draw; settingsState and plugins.settings.catalog carry each settings region
# with its translated keywords. It is on top of #103 (a76f7d1), squash-merged into main:
# plugins.settings.navigation no longer takes limit or returns overflow rows, which the desktop
# never sent or read.
# Below them, Lithe-core-rust main at 8d3c16b: #102, squash-merged into main on top of fa33446:
# toolchains.settingsView issues carry the key of the group their tool is listed under, so the
# Toolchains page opens that group with the tool. Main below it has #99 (2ddfae7):
# toolDefinitions 1 adds a definition's category and audience; toolchains.settingsView filters,
# groups, folds and counts the Toolchains settings list; plugins.settings.navigation takes a
# group's limit, answers each row's matched flag and ancestor path, and folds the children past
# the limit into one overflow row.
# Lithe-core-rust main at 0a15a98: #97, squash-merged into main on top of 7f1fc4b (#96, managed
# runtime preparation and isolated resolver sessions) and c146247 (#95, docs):
# buildSystems[].beforeLaunchTasks (beforeLaunchTasks 0) declare tasks a run configuration's
# Before Launch list may run; runConfig.checkBeforeLaunchTask checks a task's form,
# runConfig.beforeLaunchField reads the list for editors without an editor form,
# runConfig.beforeLaunch expands task steps and build.beforeLaunchTaskPlan plans one (API-29).
# Lithe-core-rust main at e56dbb650 (#93): project tool environments use Core's discovery
# plan, native path validation and machine-local workspace trust catalog (#2122).
# Lithe-core-rust main at 661ef0f: #94, squash-merged into main on top of 8b91b32: a plugin's
# buildSystems[].runConfigurationTypes declare run configuration types, which runConfig lists,
# edits and saves (.lithe/run/plugin/<plugin>.toml) and build.runConfigurationPlan turns into a
# launch plan; every editor form gains the allowMultipleInstances header checkbox (#2100).
# Lithe-core-rust main at 8b91b32: #92, squash-merged into main on top of 5204e81, makes the
# interpreter field of the shell script, PowerShell and cmd editor forms name the shellFamily it
# takes (posix, powershell, cmd), so the run configuration dialog lists the installed shells of
# that family beside automatic and a custom path (#2100).
# Lithe-core-rust main at 5204e81 (#91 squash-merged on top of 16176c1): a run configuration
# names the folder it is listed in, runConfig.resolve returns the list in the order the local layer
# saves (by name by default) with sortAlphabetically, runConfig.arrange moves configurations between
# folders and saves that order, and runConfig.copyConfiguration copies any configuration, a build
# provider run included (#2100). Main 16176c1 adds #86 (build tree layout and the default active
# items of multi-select options) and the squash-merged #75.
# Lithe-core-rust branch feat/workspace-common-references at 5c48a67 (#75, merged with main at
# 6f5fbcc, #87 on top of #90 and #89): git.workspaceCommonReferences takes each repository's
# git.references entries unchanged and returns the branches every repository has in that entry
# shape, current when every repository has it checked out, with the upstream they share and ahead
# and behind added up; git.workspaceBranchPlan plans a checkout or a new branch on such a branch
# across the repositories, skipping the ones already on it, with the writes that roll each step
# back; and git.graphProjection checkedOutHeads marks the commits of every repository's
# checked-out branch, refusing currentBranch beside it (#2013). Switch to main's commit once #75
# is squash-merged.
# #87, squash-merged into main as 6f5fbcc (on top of d8094c6, #90): runConfig.configurationTypes
# lists every built-in kind on every platform, one this platform cannot run with an unsupportedPlatform
# availability, and runConfig.editorForm, runConfig.saveConfiguration and runConfig.resolve treat a cmd
# run off Windows the same way, so it can be created and edited there while runConfig.createLaunchPlan
# still refuses to start it and runConfig.beforeLaunch refuses it as a step (#2100). #90, squash-merged
# into main as d8094c6 (on top of d833d6a): the chrome layout catalog takes alsoOnToolStripes.
# #89, squash-merged into main as d833d6a (on top of bb4832e, #88): buildProviders 1
# adds runs with entrypoints: true; build.runEntrypointsPlan and build.decodeRunEntrypoints ask a
# provider for the entrypoints of one source file, prepareRunPlan takes an entrypoint run without a
# target, and runConfig.createUserConfiguration saves the entrypoint as part of the entry (#2104).
# #88, squash-merged into main as bb4832e (on top of 4ed7a1f, #85): a run
# configuration's beforeLaunch names built-in process runs that start first; runConfig.beforeLaunch
# expands and checks them and fingerprints the lists a project file names, the editor form has a
# beforeLaunch field and runConfig.updateOptions takes the list (#1616). #85, squash-merged into
# main as 4ed7a1f (on top of 10da502, #84): built-in process runs. runConfig.configurationTypes, runConfig.editorForm,
# runConfig.saveConfiguration and runConfig.deleteConfiguration list, edit, save and delete the
# shell script, PowerShell, cmd and executable runs without any plugin, and
# runConfig.createLaunchPlan plans them with a script saved as text; built-in runs are stored in
# .lithe/run/configurations.yaml and local.yaml, and a plugin's runs in
# .lithe/run/plugin/<plugin>.toml and <plugin>.local.toml with the plugin's repository and
# version; runConfig.resolve lists the saved runs of a project nothing was generated for (#2100).
# Lithe-core-rust main at 885f2a6, #83 squash-merged (the same tree as its branch at d10ee76, on
# top of cf2f260): a plugin's TextMate grammar may declare injections, an object of scope selectors
# each with a rule, which the editor tries beside the current rule's patterns wherever the selector
# matches, as vscode-textmate does for a root grammar (#2112).
# Lithe-core-rust main at cf2f260, #82 squash-merged (the same tree as its branch at 4d0dc1c, on
# top of 18a370d): lsp.problems.query also lays out the Problems tool window's tree (the rows
# visible under the group nodes the desktop closes, the diagnostic each row previews and opens, a
# selection behind a closed node moved to that node and one of a gone diagnostic to its file's
# node) and names each file group's file and folder (#2105).
# Lithe-core-rust main at 18a370d, #81 squash-merged (the same tree as its branch at 8dd6c70, on
# top of 5202d3b): processMemory.summarize never compares two tables less than a second apart, so
# the memory details no longer show the burst of their own opening as CPU and GPU use; a table
# read sooner is measured from the counters the baseline was itself measured from, which the
# baseline now carries as earlier, and the baseline comes back unchanged.
# Lithe-core-rust main at 5202d3b, #80 squash-merged (the same tree as its branch at 81a6ecf, on
# top of 788e61e, #79 and #78):
# lsp.references.query lays out the References tool window (usages grouped in natural file
# order, the rows visible under the folds the desktop sends, the usage each row previews and the
# usages before and after it, a selection behind a closed node moved to that node);
# lsp.references.lines cuts each usage's line by the rule search results use, and
# workspace.search answers previewRanges with that preview (#2096).
# Lithe-core-rust main at 6a29169, #70 squash-merged on top of c928514 (#73):
# editor.copyReferenceLocation formats the innermost document symbol a language server reports
# around the caret, with a one-based line, and falls back to the file path when none contains it;
# children may be null as the Go host sends them (#2015). c928514 is #73 squash-merged on top of
# 0d6e16c (#77): lazy project-tree reads ask Git for the tracked directories of all ignored
# siblings in bounded batches instead of one ls-files per directory, keeping the per-directory
# fallback, nested repositories and cancellation.
# Lithe-core-rust main at 84735ea, #76 squash-merged on top of ac8825b: build.modelTree lays out
# the Build tool window's tree of a decoded model for every build tool, projects nested by
# parentID, each with its task folders (by category, else by group), dependencies, targets and
# child projects; a filter marks the matched nodes and keeps the nodes on the way to them
# (#1866).
# Lithe-core-rust main at ac8825b, #72 squash-merged: Core hides only .git, .worktree,
# .worktrees, .DS_Store and .lithe by itself; workspace.configureVisibility takes the
# manifests of the enabled plugins and hides the folders their build systems name in
# layout.hiddenDirectoryNames and their VCS providers name as directory markers, in every
# workspace, until the next call replaces them (#1856). On top of #74 squash-merged:
# git.workspacePushPreview reads for each workspace repository whether it can push (ready, up to
# date, no remote, empty, detached HEAD or failed), its push preview and target, and the order to
# push them in, a submodule before the repository that records it, which the desktop's Push
# Commits dialog reads (#2013); #69 squash-merged, so Core knows no runtime by name and go and
# node resolve through their tool definitions like any other runtime without executables, with no
# hostManaged field (#1856); and #71 squash-merged: git.workspaceHistoryMerge interleaves the
# loaded history pages of several workspace repositories newest first, each in Git's own order,
# stops where a repository with pages left runs out and names it pending, and keys a hash several
# repositories hold <hash>@<id>; git.historyPage takes maxCommits and answers limitReached;
# git.workspaceRepositorySelection takes chosen, the set a view walks together, and answers the
# picks still listed in discovery order; the desktop's Git Log sends and reads all of them (#2013).
# Lithe-core-rust main at 5a8d786, #67 squash-merged: toolchains.candidates takes the optional
# commandHomes, lists the commands found on the PATH as shell rows, and offers each shell home that
# checks out as an installations entry with provider host:shell, once per canonical home (#2032).
# It is on top of #68, squash-merged into main: Core no longer
# recognizes rust-analyzer or gopls; a language server declares indexingExclusions, and the launch
# plan's sessionPolicy, which the desktop sends to lsp.startServer unchanged, carries it. It is on
# top of #66, squash-merged into main: editor.lineCommentToken and Core's table of comment tokens
# are gone; the desktop takes the token from its language registry and editor.lineEdit is
# unchanged (#1856). It is on top of #64, squash-merged into main: gitExecution.consoleQueries
# names the query categories the Git console records and queryCategory names a read the command
# does not tell apart; git.consolePresentation takes display options, all false by default as in
# IDEA; output folds only past ten lines and a deletion never folds; a failed unrecorded query
# still reports its command, stderr and exit; a reported query's started event carries its
# queryCategory (#2025). It is on top of #65, squash-merged into main as db54ba0: every
# workspace.repositories entry has an id relative to the opened folder, a display name and a role
# (workspace or nested);
# git.workspaceRepositorySelection keeps the repository a view picked while discovery still lists
# it and otherwise falls back to the workspace repository, then the first one;
# git.workspaceChangeGroups groups status changes per repository with their staged counts, the
# paths a checkbox stages or unstages and whether the parent's gitlink moved; and
# git.workspaceCommitPrepare binds the nested repositories it is given (#2013). That is on top of
# #63, squash-merged into main as ad148ec:
# a Unix process group whose members have all exited but are not reaped yet is killed without
# error, so disposing a language server or
# closing an SSH session on macOS no longer reports EPERM (#2017). It is on top of #62,
# squash-merged into main as b401949: a backslash or colon in a Unix file name stays part of the
# name, so a folder named D:\logs is one level below the project root and the project tree rows
# accept it (#2009).
# Lithe-core-rust #61, squash-merged into main as 6a14126: the LSP engine keeps a session's hover
# answers, so resting on a symbol again answers without asking the server (#1995). It is on top of
# #60, squash-merged into main as ca80599: language-server indexing exclusions ask Git once per
# directory level instead of once per parent, so gopls starts at once in large repositories (#1994).
# Core #57/#58 add sourceSettings 0 and native compiler/runtime plans; #59 adds the project-free SDK catalog.
PINNED_CORE_REPOSITORY="https://github.com/Lithe-IDEA/Lithe-core-rust.git"
# Lithe-core-rust #56, squash-merged into main as 9425469: targetBindings.cwd may read
# target.directory, so a debugged program runs in its source file's directory rather than in the
# workspace root the debug engine gives a launch without cwd. It is on top of #55, squash-merged
# into main as 4a2ecb3: a debug configuration's targetBindings.adapterArguments fills arguments
# only that adapter defines from a path fact of the target, dotted like a connection destination,
# with env.<variable> adding one variable to the environment (Delve's dlvCwd and env.PWD, so go
# build runs in the package's directory). It is on top of #54, squash-merged into main as dce448d: workbench.notifications.reduceReadState keeps
# the unread notifications and their count, which the desktop does not call yet. It is on top of
# Lithe-core-rust #53, squash-merged into main as c550c2b: a plugin declares commandInstallers that
# install the commands its systemCommand launches need with an injected tool, and Core expands
# them (plugins.commandInstallers.requirements/plan/defaultDirectory). It is on top of
# Lithe-core-rust #52, squash-merged into main as 6477e9a: a tool definition's version probe may
# lead with a subcommand (go version) followed only by flags. It is on top of #51 (Rust 1.100
# clippy lints fixed and the Rust 1.100.0 toolchain pinned), #50 (Core CI runs the affected crates
# only), #49 (Core panics are logged; the desktop panic and crash events are declared) and #48
# (platform rules are data; platform-specific tests live in lithe-platform-tests), all
# squash-merged into main, on top of
# Lithe-core-rust #47, squash-merged into main as a58e07e:
# debug.adapters.readAnnouncement reads one line of a tcpAnnounced adapter's output against its
# declared endpoint (none, announced with a loopback host and port, or invalid), and an adapter's
# launch arguments may bind target.directory, the selected target's directory. It is on top of
# Lithe-core-rust #46, squash-merged into main: the logging event catalog declares the events the
# desktop records (terminal.session.start_failed, vcs.provider.skipped,
# app.background.operation_failed, app.startup.leftovers_resolved, editor.recovery.applied and the
# drag_drop surface) and drops the 90 events only the macOS client used; a failure of
# diagnostics.encodeLogBatch carries the index of the refused input. It is on top of #45,
# squash-merged into main: processMemory.summarize
# also sums the memory the
# system compressed or swapped out, graphics memory, and the processor and graphics use between
# two tables, which the host sends back as a baseline. It is on top of #44, squash-merged into
# main: outputStyle.decode turns console output with ANSI escapes into plain lines and styled
# ranges, carrying each console's state from chunk to chunk, for the colors of the Run, Build and
# Test consoles. It is on top of #43, squash-merged into main: processMemory.summarize
# sorts the native process table into the parts of a Lithe instance (main process, language
# servers, plugin services, their child processes and the system helpers macOS holds the main
# process responsible for) for the memory details of the status bar. It is on top of #42,
# squash-merged into main: htmlPreview.site names the folder an HTML file is previewed from as a
# static site, and htmlPreview.resolveRequest decides what each request of the preview serves. It
# is on top of #41, squash-merged into main: markdown.outline outlines the headings of Markdown
# source as a document-symbol tree for the Structure tool window. It is on top of #40,
# squash-merged into main: the update.delta.cleanup_failed event, which the
# desktop logs when it cannot remove the application a delta update rebuilt in the temporary
# directory. It is on top of #39, squash-merged into main: plugins.installed.lifecycle keeps one
# enabled plugin per language server language; installed versions carry languageServers, and
# enabling or confirming the installation of a plugin returns displacePlugin for every enabled
# plugin that serves one of the same languages. It is on top of #38 (the logging event catalog
# generator is back, with update.delta.fallback_selected), squash-merged into main, on top of
# #37, squash-merged into main: markdown.resolveReference decides what a link or
# an image of a rendered Markdown document points at, for the web view previews. It is on top of
# #36, squash-merged into main: plugin settings read translations a package ships in
# l10n/<language>.json. It is on top of #35, squash-merged into main: build.detect skips the
# workspace's ignored paths, .gitignore patterns relative to the root that only match
# directories, by default every dot-named directory; build.resolveStoredOptions reports the list
# the local or team Build document sets, else the default, and build.editIgnoredPaths replaces or
# removes the local list. It is on top of #34 (workbench.chromeLayout.reduce setHidden hides a
# stripe entry and the layout keeps it in hidden), squash-merged into main, on top of #33,
# squash-merged into main: build.detect and automatic run discovery skip
# directories Git ignores (the .gitignore files inside the workspace and the info/exclude of each
# repository rooted there, a linked worktree's shared one included), so agent worktrees and local
# copies are no longer build or run roots; fingerprint scans are unchanged. It is on top of #32
# (inline SVG in Markdown keeps whitelisted drawing elements), squash-merged into main, on top of
# #31, squash-merged into main. #31 re-lands #30, which was merged into the branch
# of #28 after #28 itself had gone into main, and adds the host rules the desktop no longer keeps
# itself (processLifecycle gracefulStopRule, network.proxyPolicy exclusionRules,
# git.changedFileGroups, git.worktrees states and git.worktreeCreationPreview,
# plugins.installed.lifecycle, editor.groupLayout.*, workspace.rowSelection.reduce and
# workspace.projectTree.rows) in four new rule crates (50 in the workspace). It is on top of #28
# (34 more crates split out of lithe-core, 46 in the workspace; command names, JSON, error codes
# and the C header unchanged, except that a build system's source:"hostIntegration" is now
# refused as plugin.manifest.invalid), squash-merged into main, on top of #29 (cold
# managed runtimes may finish LSP initialization), squash-merged into main, on top of
# #27 (protocol, network, terminal, process, diff and github split into their own
# crates, keymap and action search moved into lithe-core-rules; command names, JSON, error codes
# and the C header unchanged), squash-merged into main, on top of #26 (community.discourse.*
# commands and the wasm build removed, every crate moved to rust/crates/<name without the lithe-
# prefix>/, the C header now at rust/crates/core/include/lithe_core.h), on top of #25 (the ai.*
# commands moved into the lithe-ai crate; command names, JSON and error codes unchanged), #24
# (rust/contracts and rust/fixtures are the only copy of the application contracts and fixtures,
# which desktop tests read through LITHE_CORE_FIXTURE_DIR) and
# #23 (Java, Maven and JDT special cases removed, execution.planLaunchCommand among them;
# run/start temporaryFiles may carry base64 bytes), squash-merged into main, on top of #22 (IDE find/replace,
# recovery, preferences, navigation, keymaps and Scratch lifecycle), squash-merged into main, on top of #21 (debug.setBreakpointsMuted, debug.planMemoryWindow and
# debug.locateMemoryWindow, runConfig.decideTitleAction), squash-merged into main, on top of #20
# (lsp.declarationOrUsages and the references operation's includeDeclaration, for Go to
# Declaration or Usages), #19 (MCP configuration and library commands removed) and #17: the plugin contract is one
# baseline with pluginAPIVersion and every capability, protocol and document version at 0, and
# the contract, plugin guides, reference and SDKs live only in shared/plugins; on top of #16 (reported Git queries folded in the console),
# #15 (git.write cherryPick, revert and reset fields), #14 (word-level changed ranges of diff
# rows), #13, #8, #7, #6 and #4.
# Search pages, unsaved snapshots, source identities and budgets from Core #125,
# merged on top of the build-option changes through Core #124.
# CLI launch policy, isolated document command policy and opt-in shell registration from Core #129.
# Lithe-core-rust main at d630938 (#130 squash-merged): companion marketplace recommendations
# contract, resolveSource.recommendationsURL, and plugins.marketplace.recommendForWorkspace (#2228).
# Core #132, merged into main: reviewed-tip force deletion and first-primary-click selection.
# Core #133, merged into main: commandInstallers 1 pinned archive downloads (API-23).
# Lithe-core-rust main at 43e3f27: #135 resolves an external installation whose layout file links
# to another file name (rustup's cargo and rust-analyzer proxies) to the layout path, so probes and
# launches start cargo, not rustup; #134 hardens remote connections and #136 logs the remote
# connection lifecycle as structured log v2 events.
# Lithe-core-rust main at 4ab420e: #140 records remote workspace trust by target and host real
# path (S01/S02/S04); #141 starts no Git, language server, build provider or VCS that runs project
# code for a workspace the user has not trusted (#2208).
# Lithe-core-rust main at 94408ca: #142 returns Git's authentication failure without asking to
# retry once a credential question was cancelled or expired unanswered (#2231).
# Lithe-core-rust main at 7c1cd55: #143 shares one peer_uid implementation across the remote
# crate; #144 lets toolchains.editCatalog add and remove trustedLocations, refusing filesystem
# roots and lists over 256 entries (#2207).
# Lithe-core-rust main at 7901a86: #145 keeps the saved SSH connections (remote.connections,
# remote.editConnections) and refuses a field of a connection by name; #146 checks the server
# build against the SHA-256 the client names before uploading it (S17); #148 gives OpenSSH only
# allow-listed environment variables (S26); #149 reports resource labels, running time and the
# terminal command in server.state (#2231).
# Lithe-core-rust main at 66a1476: #147 starts, stops and lists port forwards
# (remote.startForward, remote.stopForward, remote.forwards) and names the process of each
# listening port (S28/S29, #2231).
# Lithe-core-rust main at 822f871: #154 remote.parseAddress, remote.effectiveSettings,
# remote.sshConfigHosts and remote.mottyHosts; the connections query, import and markConnected;
# remoteStage events and classified authentication questions (#2231); #155 build preferences.
# Lithe-core-rust main at ae593eb: #156 remote.parseForwardAddress reads a port, host:port or URL
# typed into the Ports window (#2231).
# Lithe-core-rust main at 5c163e9: #157 remote.connect opens a local WSL distribution through
# wsl.exe (the wsl field) and remote.listWslDistributions lists the installed ones (#2231).
# Lithe-core-rust main at 49fb750: #158 remote.preferences and remote.editPreferences (SSH program,
# reconnect limit) feed the remote commands, with the reconnect pauses given by Core (#2231).
# Lithe-core-rust main at 62d44ce: #159 host forward rules and reverse forwards (#2231).
# Lithe-core-rust main at ac80382: #160 remote.connect runs the persistent host session and resumes
# a kept one; remote.disconnect ends or keeps the host programs; remote.runningPrograms,
# remote.endPrograms (all or the listed ones), the closePrograms preference and
# closing.idleTimeoutSeconds; #161 plans the run configurations of a remote workspace (#2231).
# Lithe-core-rust main at 57e55d6: #162 remote.connect enters a running Docker or Podman container
# (the container field), also on an SSH host or in a WSL distribution; remote.listContainers lists
# the running ones; remote.devcontainerConfigs and remote.devcontainerUp build and start the
# container of a devcontainer.json; #163 remote.portRecords keeps a workspace's ports and forwards;
# #164 fs.readFile reads only regular files, so a named pipe no longer blocks it (#2231, #2270).
# Lithe-core-rust main at 2e4be2c: #166 a connection accepts a Windows domain user (DOMAIN\name,
# name@domain) and remote.mottyHosts marks a refused setting on its own field with the invalid
# status; #165 ending a remote session releases the search indexes it built (#2231, #2277).
# Lithe-core-rust main at 18feb4a: #167 remote.attachProcess takes back a process of a resumed or
# kept host session (#2231).
# Lithe-core-rust main at 3cb3c5b: #169 (eeebb58) a WSL connection reads what wsl.exe printed on
# standard output, so a distribution that is not installed is unreachable and other failures keep
# its message (#2231); #170 (1f05cfe) only fixes the Windows clippy CI step and a test; #171 moves
# the Go plugin SDK to Go 1.27.4 like the desktop. The Rust sources are the same as #169's branch
# commit edad041 that the desktop pinned before.
# Lithe-core-rust main at 4430719: #172 a host's capabilities report its WSL interop state;
# #173 plugins.marketplace.resolveSource reports the repository and branch an index follows and
# pins its address to a commit past raw.githubusercontent.com's branch cache, and the GitHub
# requests gain latestCommit and listReleases for that pin and the installed plugins' changelog.
# Lithe-core-rust main at dcb3d77: #174 lets a settings region's tool row carry choose and
# become the tool's picker, and the contract says a view call carries the window's workspace
# context; #174 merged with that field under a new ui 1, and #175 makes choose an optional field
# within ui 0 again. The sources are the same as the branch commit a50cea1 that the desktop
# pinned before; only the protocol changelog differs.
# Lithe-core-rust main at 4880022: #177 lets a tool definition set executableLinksOutsideHome, a
# toolDefinitions 0 addition, so a virtual environment's program that links to its base
# interpreter outside the home is accepted and started from its layout path; the directories on
# the way must stay inside the home. #176 documents that a backend that decides how its language
# server starts is asked again when a setting that applies immediately changes. The sources are
# the same as #177's branch commit 33e6b60 that the desktop pinned before; only the protocol
# changelog and the plugin docs differ.
# Lithe-core-rust main at aadf63d: #184 makes Core the owner of the API-11 file changes. It checks
# the params of the seven methods strictly before routing them (one spelling of a path, the
# target in the same root and not inside the source, the fields of each kind), adds kind
# "symlink" with linkTarget to workspace/create, and adds the kernel commands
# workspace.createEntry, renameEntry, copyEntry and resolveEntry with the codes entry_not_found
# and entry_exists, which the desktop calls for a plugin's create, rename, copy, trash and
# saveAs (workbench/pluginfilechanges.go).
# The plugin delta branch (#187) includes current Core main, including the
# built-in file association catalog and plans (#186). It adds the pinned
# companion index and verifies and reconstructs ZIPs for marketplace updates.
# Lithe-core-rust main at 1310ee36 (PR #198): builds on c6cef0b (#187/#196), adds PR #197 hover Markdown
# language preservation, and extends editor actions `actionIcons` with the four generic gutter
# navigation icon tokens (`navigate-implemented`, `navigate-implementing`, `navigate-overridden`,
# `navigate-overriding`).
# Lithe-core-rust main at e8927412 (PR #200): closes the parent write handle on the SSH `-E` evidence
# log before spawning `ssh.exe` so Win32-OpenSSH no longer fails with ERROR_SHARING_VIOLATION (32 /
# Broken pipe), inherits owner-only DACL on PrivateDirectory, and keeps Evidence alive until
# `end_transport` reaps the SSH process.
# Lithe-core-rust main at 38c60be (#202): discovers local Docker
# contexts, Podman and Windows WSL engines, prepares standard devcontainer configurations,
# and preserves the selected context and distribution through build, connection and trust.
# Lithe-core-rust main at c269c411 (#201): built-in rainbow bracket/variable colors,
# indent guide preferences, and Unicode whole-identifier document highlights.
PINNED_CORE_REVISION="c269c41153c8da2f2e8d064c68550a8f23260e2c"
PROFILE="debug"
CHECKOUT_ONLY="no"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; shift ;;
        --debug) PROFILE="debug"; shift ;;
        --checkout-only) CHECKOUT_ONLY="yes"; shift ;;
        *) printf '%s\n' "Usage: $0 [--debug|--release|--checkout-only]" >&2; exit 2 ;;
    esac
done

HOST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
RUST_TARGET="${LITHE_CORE_TARGET:-$HOST_TARGET}"
# Preparing the checkout links nothing, so it works on an MSVC host as well.
if [[ "$RUST_TARGET" == *-windows-msvc && "$CHECKOUT_ONLY" == "no" ]]; then
    printf '%s\n' "cgo cannot link the MSVC .lib archive for $RUST_TARGET; use x86_64-pc-windows-gnu for Windows." >&2
    exit 2
fi

# cgo's external MinGW linker already supplies the Windows system import libraries.
# winapi's supported switch avoids depending on libwinapi_* archives under a
# Cargo registry/build-script directory that is not part of the staged Core.
# When cross-compiling for x86_64-pc-windows-gnu from a non-Windows host (e.g. Linux CI),
# default the MinGW-w64 cross toolchain so cc-rs and rustc link without extra host config.
if [[ "$RUST_TARGET" == *-windows-gnu ]]; then
    export WINAPI_NO_BUNDLED_LIBRARIES=1
    if [[ "$HOST_TARGET" != *-windows-* && "$RUST_TARGET" == "x86_64-pc-windows-gnu" ]]; then
        export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc}"
        export CC_x86_64_pc_windows_gnu="${CC_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-gcc}"
        export AR_x86_64_pc_windows_gnu="${AR_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-ar}"
    fi
fi

ARTIFACTS_DIR="$ROOT_DIR/.artifacts/desktop"
STAGE_DIR="$ARTIFACTS_DIR/lithe-core/$RUST_TARGET/$PROFILE"
CARGO_TARGET_DIR_BASH="$ARTIFACTS_DIR/lithe-core-rust/target"
CARGO_TARGET_DIR_NATIVE="$(native_path "$CARGO_TARGET_DIR_BASH")"
export CARGO_TARGET_DIR="$CARGO_TARGET_DIR_NATIVE"
if [[ "$RUST_TARGET" == *-apple-darwin ]]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
else
    unset MACOSX_DEPLOYMENT_TARGET
fi
# The release profile of Lithe-core-rust sets strip = true. On macOS that also strips the
# proc-macro dylibs cargo builds for the host, and rustc then reports "can't find crate" for
# tokio_macros and futures_macro. Build scripts and proc macros are never shipped, so they are
# left unstripped; the static library is still built with the profile as the core defines it.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP:-false}"

HELPER_EXE=""
if [[ "$RUST_TARGET" == *windows* ]]; then
    HELPER_EXE=".exe"
fi
RUSTC_VERSION="$(rustc -V)"

format_identity() {
    local revision="$1" dirty="$2" source="$3"
    printf 'core-revision=%s\n' "$revision"
    printf 'core-worktree=%s\n' "$dirty"
    printf 'core-source=%s\n' "$source"
    printf 'rustc=%s\n' "$RUSTC_VERSION"
    printf 'target=%s\n' "$RUST_TARGET"
    printf 'profile=%s\n' "$PROFILE"
    if [[ "$RUST_TARGET" == *-windows-gnu ]]; then
        printf 'winapi-import-libraries=mingw-system\n'
    fi
    if [[ "$RUST_TARGET" == *-apple-darwin ]]; then
        printf 'macos-deployment-target=%s\n' "$MACOSX_DEPLOYMENT_TARGET"
    fi
}

# Fast-path for pinned builds: when the staged archive, header, native-static-libs and lithe-mcp
# helper already match this exact revision, rustc, target and profile, skip git and cargo.
# Local LITHE_CORE_RUST_DIR overrides and --checkout-only never take this path. If a pinned
# checkout already exists, require its rust/Cargo.toml to still be intact so a deleted worktree
# manifest still fails closed.
if [[ "$CHECKOUT_ONLY" == "no" && -z "${LITHE_CORE_RUST_DIR:-}" ]]; then
    PINNED_SOURCE_DIR="$ARTIFACTS_DIR/lithe-core-rust/source"
    EXPECTED_IDENTITY="$(format_identity "$PINNED_CORE_REVISION" "clean" "pinned")"
    if [[ ( ! -d "$PINNED_SOURCE_DIR/.git" || -f "$PINNED_SOURCE_DIR/rust/Cargo.toml" ) \
        && -f "$STAGE_DIR/identity.txt" \
        && "$(cat "$STAGE_DIR/identity.txt")" == "$EXPECTED_IDENTITY" \
        && -s "$STAGE_DIR/lib/liblithe_core.a" \
        && -s "$STAGE_DIR/include/lithe_core.h" \
        && -s "$STAGE_DIR/native-static-libs.txt" \
        && -x "$STAGE_DIR/bin/lithe-mcp$HELPER_EXE" ]]; then
        printf '%s\n' "$STAGE_DIR"
        exit 0
    fi
fi

if [[ -n "${LITHE_CORE_RUST_DIR:-}" ]]; then
    CORE_DIR="$(cd "$LITHE_CORE_RUST_DIR" && pwd -P)"
    CORE_SOURCE="override"
else
    CORE_SOURCE="pinned"
    CORE_DIR="$ARTIFACTS_DIR/lithe-core-rust/source"
    if [[ ! -d "$CORE_DIR/.git" ]]; then
        mkdir -p "$(dirname "$CORE_DIR")"
        git clone --filter=blob:none --no-checkout "$PINNED_CORE_REPOSITORY" "$CORE_DIR" >&2
    fi
    if [[ "$(git -C "$CORE_DIR" rev-parse HEAD 2>/dev/null || true)" != "$PINNED_CORE_REVISION" ]]; then
        git -C "$CORE_DIR" fetch --filter=blob:none origin "$PINNED_CORE_REVISION" >&2
        git -C "$CORE_DIR" checkout --detach --force "$PINNED_CORE_REVISION" >&2
    elif [[ ! -e "$CORE_DIR/.git/index" ]]; then
        # A fresh --no-checkout clone can already point at the pin without
        # having any worktree files. Do not force: untracked user files must
        # prevent checkout rather than being overwritten.
        git -C "$CORE_DIR" checkout --detach "$PINNED_CORE_REVISION" >&2
    fi
fi

MANIFEST="$CORE_DIR/rust/Cargo.toml"
if [[ ! -f "$MANIFEST" ]]; then
    printf '%s\n' "No Lithe-core-rust workspace at $CORE_DIR (expected rust/Cargo.toml)." >&2
    exit 1
fi
MANIFEST_NATIVE="$(native_path "$MANIFEST")"
if [[ "$CHECKOUT_ONLY" == "yes" ]]; then
    printf '%s\n' "$CORE_DIR"
    exit 0
fi

CORE_REVISION="$(git -C "$CORE_DIR" rev-parse HEAD)"
CORE_DIRTY="clean"
if [[ -n "$(git -C "$CORE_DIR" status --porcelain --untracked-files=normal -- rust)" ]]; then
    CORE_DIRTY="dirty"
fi
# rustc prints native libraries only when it links the archive. The file survives up-to-date
# builds, so a missing one triggers a clean that makes rustc report it again.
mkdir -p "$STAGE_DIR/include" "$STAGE_DIR/lib"
NATIVE_LIBS_FILE="$STAGE_DIR/native-static-libs.txt"
NATIVE_LIBS_FILE_NATIVE="$(native_path "$NATIVE_LIBS_FILE")"
PROFILE_ARGS=()
if [[ "$PROFILE" == "release" ]]; then
    PROFILE_ARGS=(--release)
fi
# Cargo puts an explicit target below target/<triple>/ and keeps host builds in target/<profile>/.
LIBRARY_DIR="$CARGO_TARGET_DIR_BASH/$PROFILE"
if [[ "$RUST_TARGET" != "$HOST_TARGET" ]]; then
    PROFILE_ARGS+=(--target "$RUST_TARGET")
    LIBRARY_DIR="$CARGO_TARGET_DIR_BASH/$RUST_TARGET/$PROFILE"
fi
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    cargo clean --manifest-path "$MANIFEST_NATIVE" -p lithe-core \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
fi
# The pinned checkout and a LITHE_CORE_RUST_DIR override share this target directory, and Cargo
# hashes a workspace member by its path inside the workspace, not by where the checkout is: both
# checkouts build every member, such as the event catalog in lithe-diagnostics, to the same
# files with the same fingerprint. Freshness is judged by modification times, so after the other
# checkout overwrote them, the files still look up to date and the staged library would carry
# the other checkout's code under this checkout's identity. The checkout that built the members
# last is recorded per target and profile; a different one cleans the workspace members, which
# are then built from it, while registry dependencies stay cached.
BUILT_FROM_FILE="$CARGO_TARGET_DIR_BASH/lithe-core-built-from-$RUST_TARGET-$PROFILE.txt"
if [[ "$(cat "$BUILT_FROM_FILE" 2>/dev/null || true)" != "$CORE_DIR" ]]; then
    cargo clean --manifest-path "$MANIFEST_NATIVE" --workspace \
        "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
    mkdir -p "$CARGO_TARGET_DIR_BASH"
    printf '%s\n' "$CORE_DIR" > "$BUILT_FROM_FILE"
fi
cargo rustc --manifest-path "$MANIFEST_NATIVE" -p lithe-core --lib --crate-type staticlib \
    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" \
    -- --print "native-static-libs=$NATIVE_LIBS_FILE_NATIVE" >&2
if [[ ! -s "$NATIVE_LIBS_FILE" ]]; then
    printf '%s\n' "rustc did not report the native libraries of liblithe_core.a." >&2
    exit 1
fi

install -m 0644 "$LIBRARY_DIR/liblithe_core.a" "$STAGE_DIR/lib/liblithe_core.a"
install -m 0644 "$CORE_DIR/rust/crates/core/include/lithe_core.h" "$STAGE_DIR/include/lithe_core.h"

# On Windows GNU targets, copy any Cargo-supplied native import archives referenced by
# native-static-libs.txt into $STAGE_DIR/lib/ so the staged directory is self-contained and can
# be produced by Linux cross-compilation and linked on Windows without carrying target/.
if [[ "$RUST_TARGET" == *-windows-gnu ]]; then
    CARGO_BUILD_ROOT="$LIBRARY_DIR/build"
    NATIVE_STATIC_LIBS="$(<"$NATIVE_LIBS_FILE")"
    read -r -a NATIVE_ARGS <<< "$NATIVE_STATIC_LIBS"
    FOUND_NAMES=()
    FOUND_ARCHIVES=()
    for output in "$CARGO_BUILD_ROOT"/*/output; do
        [[ -f "$output" ]] || continue
        while IFS= read -r line; do
            line="${line%$'\r'}"
            case "$line" in
                cargo:rustc-link-search=native=*) native_dir="${line#cargo:rustc-link-search=native=}" ;;
                cargo::rustc-link-search=native=*) native_dir="${line#cargo::rustc-link-search=native=}" ;;
                *) continue ;;
            esac
            if command -v cygpath >/dev/null 2>&1; then
                native_dir="$(cygpath -u "$native_dir")"
            fi
            for arg in "${NATIVE_ARGS[@]}"; do
                case "$arg" in -l*) lib_name="${arg#-l}" ;; *) continue ;; esac
                archive="$native_dir/lib$lib_name.a"
                [[ -f "$archive" ]] || continue
                for i in "${!FOUND_NAMES[@]}"; do
                    if [[ "${FOUND_NAMES[$i]}" == "$lib_name" ]] && ! cmp -s "$archive" "${FOUND_ARCHIVES[$i]}"; then
                        printf 'Conflicting Cargo import libraries for %s: %s and %s\n' "$lib_name" "$archive" "${FOUND_ARCHIVES[$i]}" >&2
                        exit 1
                    fi
                done
                FOUND_NAMES+=("$lib_name")
                FOUND_ARCHIVES+=("$archive")
                install -m 0644 "$archive" "$STAGE_DIR/lib/lib$lib_name.a"
            done
        done < "$output"
    done
fi

# The IDE API helper is the lithe-ide-host crate's lithe-mcp binary from the same pinned
# checkout. It is staged here so packaging can embed it; nothing at runtime reads this
# directory, and the installed client runs only the copy it installs under application data.
mkdir -p "$STAGE_DIR/bin"
cargo build --manifest-path "$MANIFEST_NATIVE" -p lithe-ide-host --bin lithe-mcp --features mcp \
    "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" >&2
HELPER="$LIBRARY_DIR/lithe-mcp$HELPER_EXE"
if [[ ! -f "$HELPER" ]]; then
    printf '%s\n' "cargo did not build the lithe-mcp helper at $HELPER." >&2
    exit 1
fi
install -m 0755 "$HELPER" "$STAGE_DIR/bin/lithe-mcp$HELPER_EXE"
format_identity "$CORE_REVISION" "$CORE_DIRTY" "$CORE_SOURCE" > "$STAGE_DIR/identity.txt"
printf '%s\n' "$STAGE_DIR"
