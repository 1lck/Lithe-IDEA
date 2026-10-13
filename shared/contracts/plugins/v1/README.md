# Plugin contract v1: declarative plugins

A declarative plugin currently describes language support or first-stage UI contributions as data. The host reads
`plugin.json`, validates it, verifies the package signature, and launches the
declared external processes itself. The host never loads plugin code into its
own process, so a package does not depend on the host's binary layout and does
not need to be rebuilt for each Lithe release.

This directory is the cross-platform source of truth:

| File | Purpose |
| --- | --- |
| `plugin-manifest.schema.json` | JSON shape of `plugin.json` |
| `fixtures/*.plugin.json` | Valid example manifests (PHP and Go shapes) |
| `fixtures/invalid-manifests.json` | Edits to a valid manifest and the rejection code every host must report |
| `fixtures/command-plans.json` | Golden run/test command expansions |
| `plugin-index.schema.json` | JSON shape of a marketplace source index |
| `fixtures/marketplace/*.json` | Marketplace index, availability, source URL, and install review golden cases |

Validation and template expansion are implemented once in Rust Core
(`rust/lithe-core/src/plugins/declarative.rs`) and exposed through the
`plugins.declarative.*` commands in `../../rust-core-api.md`. Hosts must not
reimplement them.

## Package layout

```text
<plugin-id>/
├── plugin.json                    # this contract
├── lithe-plugin-signature.json    # publisher signature over every other file
└── …                              # resources referenced by plugin.json
```

Every path in `plugin.json` is relative to the package root, uses `/`, and may
not contain `..`, a leading `/`, a backslash, or NUL. Packages may not contain
symbolic links. A host treats an installed package as read-only.

## Manifest

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Always `2`. Schema `1` was the retired macOS native-bundle manifest; hosts refuse it with `plugin.schema.unsupported`. |
| `id` | Stable plugin ID: lowercase letters, digits, `.` and `-`. |
| `displayName` | Name shown in plugin management. |
| `version` | Plugin version, `major.minor.patch`. Independent of the Lithe version. |
| `pluginAPIVersion` | Declarative plugin API level the package needs. Hosts list the levels they support; Lithe's own version is never used for compatibility. This contract defines level `1`. |
| `vendor` | `id`, `displayName`, and `signatureRequirement` (see Trust). |
| `permissions` | Capabilities the plugin may ask the host to perform. |
| `activationEvents` | When the host may start each provider. |
| `languages` | Languages the plugin recognizes. |
| `languageServers` | At most one language server per declared language. |
| `executionProviders` | At most one run/test provider per declared language. |

Unknown fields are refused (`plugin.manifest.invalid`). A new field requires a
new `pluginAPIVersion` so older hosts reject the package instead of ignoring
part of it.

### Languages

`id` is lowercase (`[a-z0-9+_-]`). `fileExtensions`, `fileNames`, and
`projectFileNames` are matched case-insensitively; at least one must be
present. A leading dot is optional only in `fileExtensions` (`.php` equals
`php`). In complete file names, project markers, and management file names it
is part of the name, so `.toolrc` and `.env.example` stay hidden-file names. Optional `dependencies` lists `managementFileNames`,
`projectDependencyPaths`, and `projectBinaryPaths` relative to the project.

### Language servers

| Field | Meaning |
| --- | --- |
| `languageID` | A declared language. |
| `languageIdentifier` | LSP `languageId` for documents; defaults to `languageID`. |
| `launch` | `{"kind": "packaged", "path": …}` runs an executable inside the package. `{"kind": "systemCommand", "commands": [...]}` lists bare command names the host resolves with its tool discovery (PATH, project toolchains, user overrides). |
| `arguments` | Arguments passed to the server. |
| `validationArguments` | Probe that must exit with status 0 before a candidate is used; empty means the host trusts the candidate and lets the LSP handshake decide. |
| `runtimeDependencies` | Runtimes the host must discover and pass to the server. v1 tools are `node` and `go`. The host exports each path as `LITHE_<TOOL>_PATH` (`LITHE_NODE_PATH`, `LITHE_GO_PATH`; a user-set value takes precedence) and prepends its directory to the server's `PATH`, because servers such as gopls run the tool themselves and an app opened from the Dock does not inherit the shell `PATH`. A project-local copy is never chosen, since servers start automatically when a file opens. |

The host owns the language-server process lifecycle, the LSP session, and
stopping the process when the provider is disabled.

### Execution providers

`run` and `test` each name an `executable`: exactly one of a bare `command`
resolved on the host's tool path, or a host-owned project `toolchain` ID such
as `project-go`. The working directory is always the workspace root.

`test` also declares:

| Field | Meaning |
| --- | --- |
| `frameworkID` | Stable framework label such as `phpunit` or `go`. |
| `workspaceLabel` | Label of the "all tests" item and plan. |
| `projectMarkers` | File names, any one of which makes the workspace a test project. |
| `testFilePatterns` | Case-insensitive file-name patterns using only `*`. |
| `workspaceArguments`, `fileArguments`, `testCaseArguments` | Argument templates per scope. |

Argument templates are argv elements, never shell text. Each element is a
string or `{"value": …, "when": "fileSelected" | "noFileSelected"}`;
conditional elements are only allowed in `testCaseArguments`, where a file is
optional.

| Variable | Available in | Value |
| --- | --- | --- |
| `${file}` | run, file, test case | Workspace-relative file. A name starting with `-` becomes `./<name>`. |
| `${fileDirectory}` | run, file, test case | `./<directory>` of the file, or `.` at the workspace root. |
| `${testName}` | test case | Test identifier with surrounding whitespace removed. |
| `${testName:regex}` | test case | The identifier with regular-expression metacharacters escaped. |
| `${userArguments}` | run | The user's program arguments; must be a whole element and may expand to zero elements. |

In `testCaseArguments`, an element that uses `${file}` or `${fileDirectory}`
must be guarded with `"when": "fileSelected"`, and some element must use the
test name.

Discovery returns `{id: "<language>:workspace", kind: "workspace"}` followed by
`{id: "<language>:file:<path>", kind: "file", relativeFilePath}` for matching
files sorted by path, or an empty list when no project marker is present.

## Permissions and activation

| Permission | Required when |
| --- | --- |
| `languageServer.launch` | `languageServers` is not empty |
| `process.run` | any provider declares `run` |
| `process.test` | any provider declares `test` |

| Activation event | Meaning |
| --- | --- |
| `onLanguage:<id>` | Start the language server when a document of the language opens in a project. |
| `onRun:<id>` | Activate the run provider when the user runs a file of the language. |
| `onTest:<id>` | Activate the test provider when the user lists or runs tests. |

Each provider needs its event and each event needs a provider. Enabling a
plugin only permits activation; nothing starts until its event occurs.

## Trust

- `publisherPackage`: the package must carry a valid publisher signature
  (`lithe-plugin-signature.json`, Ed25519 over every file) from a key the host
  trusts. Development builds may install an unsigned package from disk as a
  local development package; release builds refuse it.
- `sameTeamAsHost`: only honored for a package shipped inside the host's own
  signed installation, whose code signature already seals it.
- `none`: a community package without a Lithe signature. A host installs it
  only from a third-party marketplace source, after the archive matched the
  index checksum and the user confirmed the install review (see Marketplace).
  IDs in the official namespace (`dev.lithe`, `dev.lithe.*`) may not use it
  (`plugin.manifest.invalid`). Hosts that predate this value refuse such
  packages as invalid manifests, which is the intended behavior.

A host pins the signature requirement of its official plugin IDs so a package
cannot downgrade itself.

## Marketplace

A marketplace source is a JSON index (`plugin-index.schema.json`) that lists
plugins and their release archives. Hosts fetch, cache, and download; Rust
Core decides validity and availability through `plugins.marketplace.*` so
every product shows the same catalog and the same install review.

### Sources

- The host ships one **official** source: the index at
  `Plugins/marketplace/index.json` in the Lithe repository. A copy is bundled
  read-only with the application so the catalog works offline; refreshing
  fetches the same file from
  `https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json`.
- Hosts also preset one **community** source, Lithe Store
  (`https://github.com/Lithe-IDEA/Lithe-store`, index
  `https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json`).
  It is a third-party source in every respect (community trust, `dev.lithe`
  IDs refused), enabled by default, and removable; a host remembers the
  removal instead of adding it back.
- Users may add **third-party** sources. `plugins.marketplace.resolveSource`
  turns what the user pasted into the index URL to fetch: an https index URL
  is used as is (fragment removed); `https://github.com/<owner>/<repo>`
  resolves to `lithe-plugin-index.json` at the repository root on its default
  branch (`HEAD`); a `…/blob/<ref>/<path>` page resolves to its raw file.
  Plain http, embedded credentials, and other GitHub pages are refused with
  `plugin.source.invalid`.
- Hosts cache fetched indexes in platform cache or application-support
  storage, never inside the installation.

### Index entries

| Field | Meaning |
| --- | --- |
| `id` | Plugin ID; must equal the package's `plugin.json` `id`. |
| `name`, `author`, `description`, `license` | Display metadata; must not be empty. |
| `localizedDescriptions` | Optional translations of `description`, keyed by language tag such as `zh-Hans`. Hosts show the entry matching the interface language and fall back to `description`. |
| `repository` | `https://github.com/<owner>/<repo>` that owns the plugin's releases and issue tracker. |
| `homepage` | Optional https URL. |
| `tags` | Optional single words, lowercased and sorted by Core. |
| `icon` | Optional `raw.githubusercontent.com` file of the same repository. |
| `versions[]` | `version`, required `pluginAPIVersion`, `releaseDate` (`YYYY-MM-DD`), and `downloads[]`. |
| `downloads[]` | `platforms` (for example `darwin-arm64`, `darwin-x64`, `windows-x64`, `windows-arm64`), `downloadURL`, and the archive's lowercase hex `sha256`. A platform may appear in at most one download of a version. |

A `downloadURL` must be a `.zip` GitHub Release asset of the entry's own
repository (`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>.zip`,
owner and repository compared case-insensitively), so an index cannot point a
plugin at another project's release.

### Validation and availability

`plugins.marketplace.validateIndex` accepts
`{ "index": object, "sourceKind": "official" | "thirdParty", "platform": string }`.
A malformed index root or an unsupported `schemaVersion` rejects the whole
index. Otherwise it returns `{ "status": "ok", "index": { "plugins", "rejected" } }`:

- `rejected` lists refused entries in index order with their `error`.
  A third-party source listing an official-namespace ID is refused with
  `plugin.index.officialNamespace`; a repeated ID keeps the first listing and
  refuses later ones with `plugin.index.duplicate`.
- `plugins` is sorted by ID. Each accepted entry is normalized, lists
  `versions` newest first, reports `platforms`, `latestVersion`, and
  `latestReleaseDate` of the newest version, and an `availability`:
  - `{status: "available", version, pluginAPIVersion, releaseDate, downloadURL, sha256}`
    for the newest version with this platform's archive and a supported
    `pluginAPIVersion`;
  - `{status: "unsupported", code: "plugin.index.apiUnsupported", platform, message}`
    when the platform is listed only by versions needing a newer plugin API;
  - `{status: "unsupported", code: "plugin.index.platformUnsupported", platform, message}`
    when no version lists the platform. Hosts show "not supported on
    <platform>" instead of an install action.

### Trust and install review

- **Official**: an entry is official only when it comes from the official
  source and its package passes the Lithe publisher signature.
- **Community**: entries from third-party sources. Hosts install in this
  order: verify the archive SHA-256 against the index
  (`plugin.archive.checksumMismatch`), validate the declaration, run
  `plugins.marketplace.installReview`, show the review, and install only after
  the user confirms.

`plugins.marketplace.installReview` accepts
`{ "manifest": object, "expectedID"?, "expectedVersion"?, "approvedPrograms"?: [object] }`
and returns `{ "status": "ok", "review": { id, version, permissions, programs, newPrograms } }`.
A package whose ID or version differs from the index entry is refused with
`plugin.package.mismatch`. `programs` lists everything the host may start for
the plugin, sorted by `kind`, language, and tool:

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `packagedLanguageServer` | `languageID`, `path`, `arguments`, `validationArguments` | Executable inside the package, with its launch arguments and validation probe |
| `systemLanguageServer` | `languageID`, `commands`, `arguments`, `validationArguments` | Command resolved by host tool discovery |
| `runtime` | `tool` | Runtime the host discovers and passes to a language server |
| `run` | `languageID`, `executable`, `arguments` | Run command and its argument template |
| `test` | `languageID`, `executable`, `workspaceArguments`, `fileArguments`, `testCaseArguments` | Test command and its argument templates |

Each entry carries everything that decides what actually runs, so an update
that keeps the same executable but changes its arguments, argument templates,
or validation probe is a new program. Hosts record the approved `programs`
with the installation. An update passes them as `approvedPrograms`; a
non-empty `newPrograms` requires the user to confirm again. When several sources list the same ID, the user chooses the
source at install time and later updates come only from that source.

## Outcomes and error codes

`plugins.declarative.*` and `plugins.marketplace.*` commands return `{"status": "ok", …}` or
`{"status": "rejected", "error": {"code", "message", "field"?}}`. A malformed
command payload is a Core `invalid_request` failure instead.

| Code | Reported by | Meaning |
| --- | --- | --- |
| `plugin.manifest.invalid` | Core | Malformed manifest, unknown field, or broken cross reference |
| `plugin.schema.unsupported` | Core | `schemaVersion` is not `2` |
| `plugin.api.unsupported` | Core | `pluginAPIVersion` is not supported by this host |
| `plugin.permission.unknown` | Core | Unknown permission |
| `plugin.permission.undeclared` | Core | A provider is declared without its permission |
| `plugin.activation.invalid` | Core | Missing or orphan activation event |
| `plugin.runtime.unsupported` | Core | Unknown runtime dependency |
| `plugin.template.invalid` | Core | Unknown, misplaced, or unguarded template variable |
| `plugin.path.invalid` | Core | A request path leaves the workspace |
| `plugin.test.invalidIdentifier` | Core | Empty or multi-line test identifier |
| `plugin.test.unsupportedProject` | Core | No project marker in the workspace |
| `plugin.execution.unavailable` | Core | The plugin has no run/test provider for the language |
| `plugin.index.invalid` | Core | Malformed index root or entry, or an invalid URL, checksum, platform, version, or date |
| `plugin.index.schemaUnsupported` | Core | The index `schemaVersion` is not `1` |
| `plugin.index.officialNamespace` | Core | A third-party source lists a `dev.lithe` ID |
| `plugin.index.duplicate` | Core | An index lists the same plugin ID more than once |
| `plugin.index.platformUnsupported` | Core | No version has an archive for this platform (availability, not a rejection) |
| `plugin.index.apiUnsupported` | Core | Only versions needing a newer plugin API list this platform (availability, not a rejection) |
| `plugin.source.invalid` | Core | A marketplace source URL cannot be used |
| `plugin.package.mismatch` | Core | A downloaded package's ID or version differs from its index entry |
| `plugin.archive.checksumMismatch` | Host | A downloaded archive does not match the index SHA-256 |
| `plugin.download.failed` | Host | An index or archive could not be downloaded |
| `plugin.signature.missing`, `plugin.signature.invalid`, `plugin.signature.untrusted` | Host | Package signature problems |
| `plugin.launch.missing` | Host | The packaged language server is missing or not executable |
| `plugin.runtime.missing` | Host | A declared runtime (for example Node.js) cannot be found when the server starts |
| `plugin.legacyNative.updateRequired` | Host | An installed schema-1 native package must be replaced by its declarative version |

Host-facing plugin states are `notInstalled`, `installed` (enabled or
disabled), `running`, `restartRequired`, `updateRequired`, and `failed`.

## Windows mapping

The Windows extension manifest (`Plugins/win/Official/*/plugin.json`) predates
this contract. Its adapter maps `languages[].extensions` to
`languages[].fileExtensions`, `lsp.server`/`lsp.args` to `languageServers[]`,
`lsp.requiredExecutables: ["node"]` to `runtimeDependencies`, and
`runActions.manifestFiles` to `test.projectMarkers`. Composer script discovery
is Windows-only behavior outside v1.

## API level 2: first-stage host-owned workbench UI

`pluginAPIVersion: 2` adds optional `ui` contributions and the `ui.contribute`
permission. API level 1 language packages continue to work. UI-only packages may
omit `languages`; every package must still declare a language provider or a
nonempty UI catalog. See `fixtures/hello-lithe.plugin.json` and the UI cases in
`fixtures/invalid-manifests.json`.

- `ui.toolWindows`: 1–64 entries with stable `id`, `title`, initial `placement`
  (`left`, `bottom` or `right`), integer `order` (default 0), and plain `text`.
- `ui.commands`: up to 128 entries with stable `id`, `title`, `toolWindowID`,
  integer `order` (default 0), and nonempty `placements` (`commandPalette`,
  `toolbar`, `menu`). A command opens one of the same plugin's tool windows.
- IDs use the plugin ID followed by a dot and a suffix. Duplicate or foreign
  identities, invalid references, unsupported placements and executable UI
  fields are rejected with `plugin.manifest.invalid`.
- Titles are at most 256 UTF-8 bytes and window text at most 65536 UTF-8 bytes.
  Text is displayed literally; it is never evaluated as HTML or a script.
- Declare `onView:<window-id>` and `onCommand:<command-id>` for every window and
  command, plus `ui.contribute`. The existing permission and activation error
  codes apply. IDs and presentation order are normalized deterministically.
- The host exposes metadata without instantiating the module. Opening an
  entry activates the plugin's UI module on demand; a disabled, quarantined
  or safe-mode-suppressed module has no executable UI entries. Disabling it
  removes the entries and closes its visible content.
- The host owns header controls, widgets, menus, theme, ordering and layout.
  Saved workspace preferences override a declaration's initial placement and
  order. Moving or hiding content does not create a new module or session.
  Unknown and temporarily absent contributions never execute an action;
  placement/order preferences remain available if the plugin returns.

API level 2 is the first UI Contribution infrastructure stage. Its static text
windows and open-own-window commands are a supported subset, not the final public
extension API. The required window/text/command-target fields and rejection of
packages without language or UI contributions remain unchanged for v2 compatibility.
The macOS host supports mouse docking through the existing shared dock state;
that presentation behavior does not grant additional plugin execution capabilities.

### Future public extension direction (not implemented in API level 2)

- Third-party UI uses a separately versioned JSON component tree (Tree/List/Form/
  Input/Button, data sources and events) rendered by native platform adapters.
  Plugin UI does not use HTML, Webviews or third-party frontend frameworks.
  Built-in or trusted native modules may register Native View/Renderer Factories
  under the same host window management. This does not restore arbitrary dynamic
  third-party Swift Bundle loading; ABI, signing and isolation need separate design.
- Actions declare handlers and availability/context conditions independently of
  Tool Windows. Commands, menus/context menus, toolbars, status bars and settings
  contributions must not require dummy windows. Opening a window is one action kind.
- A new, explicitly versioned Extension Contract will cover Language/LSP,
  BuildSystem/Task, RunConfiguration/Test, DebugAdapter and ServiceProvider,
  including pure Build/Debug/Services packages with no UI or language declaration.
  Exact version numbers, handler transport and fields are not published here.
- Built-in and plugin providers should use the same typed domain registries.
  Providers supply behavior/processes/data; hosts own scheduling, permission,
  presentation and lifecycle. Reuse existing language, build, run/test and DAP
  backends instead of duplicating them or branching by plugin name in composition.
- Services will accept general resources with provider/descriptor/instance/status/
  actions/logs semantics. Disabling unregisters contributions and releases
  plugin-owned resources; it must not implicitly stop independently running
  external services. An explicit stop action requires its own authorization.
- API level 2 remains supported unchanged. UI Schema evolves independently;
  domain extension points need a new contract version and compatibility fixtures.
  Windows implements its own host adapter over shared data, not SwiftUI types.

Planned end-to-end samples are a native Tree with an independent refresh command,
Build Task in existing Build, ServiceProvider in Services, and third-party DAP in
existing Debug UI. Each must verify disable/re-enable, resource ownership and
restoration; view-bearing samples also verify layout persistence. These samples
are future acceptance criteria, not claims about current runtime support.

The design source is the [proposed public Extension Contract and Provider API](../../../../.agents/notes/proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md).
Current runtime behavior is recorded in the [first-stage workbench UI Note](../../../../.agents/notes/implemented/architecture/2026-10-12-workbench-ui-contributions.md).

### Current Windows availability
Windows can validate API level 2 through Rust Core but its UI adapter has not
implemented this contract yet. Its marketplace must filter unsupported API
levels until that adapter is available.

### Existing community store and Lua template

The community index is [Lithe Store](https://github.com/Lithe-IDEA/Lithe-store).
The [Lua plugin template](https://github.com/Lithe-IDEA/lithe-plugin-lua) uses
schema 2 / API level 1 for language-server and run providers; those declarations
remain valid. To add a host-rendered view to that template:

1. Set `pluginAPIVersion` to 2. Keep the existing language and execution fields.
2. Add `ui.contribute` to the existing permissions and the new `onView` /
   `onCommand` events to the existing activation events.
3. Add `ui.toolWindows` and `ui.commands`; prefix every ID with the plugin ID,
   for example `io.github.lithe-idea.lua-support.tools`.
4. Keep `vendor.signatureRequirement: "none"` for community packages. The
   existing package checksum, user install review and content digest still
   apply; UI does not bypass them.
5. Set the new Store version entry's `pluginAPIVersion` to 2. The index schema,
   release archive format and SHA-256 rules stay unchanged. Only list platforms
   with an implemented API level 2 UI host (currently macOS).

`fixtures/hello-lithe.plugin.json` is a contract fixture in the reserved test
namespace, not a ready-to-publish community package. Change its ID and all
references to your own namespace before using it in Lithe Store.

### UI icons (macOS host)

API level 2 tool windows and commands accept an optional `icon`. Prefer a stable
host icon ID; it resolves through Lithe's existing icon library, not SF Symbols:

```json
"icon": { "host": "database" }
```

Supported host IDs: `tool-window`, `plugin`, `database`, `services`, `terminal`,
`search`, `refresh`, `run`, `debug`, `settings`, `add`, `remove`, `git`, `problems`.
These IDs are public; bundled SVG paths remain implementation details.

Custom SVG and PNG icons are relative to the plugin package root:

```json
"icon": {
  "path": "icons/database.svg",
  "darkPath": "icons/database-dark.svg",
  "mode": "template"
}
```

`mode` defaults to `template`: the host tints the image using the containing
control's theme and selected/hover state. `original` preserves brand colors;
control backgrounds and disabled opacity still follow the host. `darkPath` is
optional; without it the same resource is used in both themes. Brand authors
must make that resource legible in both themes or provide a dark variant.
`host` cannot be combined with resource paths or original-color mode.

The host owns icon size: 20pt tool-window rail, 16pt actions/menus/palette, 13pt
window header. Aspect ratio is preserved inside that slot. Plugin-specified
size, color, stroke, arbitrary style, remote URLs and SF Symbol names are rejected.
Stroke geometry belongs to the asset; authors should follow the host icon
weight, rather than expecting the host to rewrite paths or PNG pixels.

Window and toolbar management submenus reuse the same declared icons at the
host menu size. Template icons in the command palette use the host selected-text token on the
selected row; brand icons retain their theme variant when keyboard selection moves.

Files must be regular files inside the verified package, without symbolic links
in their path. Each resource is limited to 256 KiB and 1024×1024; unique icon
bytes per package are limited to 8 MiB, with at most 4,194,304 total image pixels. PNG is decoded as a single image. SVG
accepts static shapes, groups, gradients, clip paths and the standard SVG version attribute; scripts, event handlers,
external references, embedded images, style elements/attributes, entities and
DOCTYPEs are refused. Use explicit presentation attributes for SVG colors.
Unknown fields and unsupported formats are rejected at installation and launch.

Window entries without an icon use the shared generic tool-window icon. Commands
without an icon remain text actions (palette retains its existing action marker).
Missing/unreadable declared resources reject the package instead of silently
using a different image. Assets are read-only and held in process memory; no
runtime disk cache or app-bundle write is created. Installed icon bytes follow
the existing package signature/digest, update and rollback lifecycle.

macOS 宿主布局菜单允许把已注册工具窗口移到左侧、右侧或底部，并保存入口
顺序与显隐；`ui.toolWindows[].placement` 仍只声明首次使用的 `bottom`/`right`
位置，未新增插件契约值。项目、提交和搜索采用相同的工具窗口注册路径，
原生业务内容保持宿主所有；左侧恢复插件窗口仍按 `onView` 激活所属模块。

macOS 动作的可见、可用、勾选和激活中状态由宿主计算，不接受清单中的可执行
条件脚本。窗口尚在激活时，其打开命令在工具栏、菜单和命令面板禁用；窗口入口
仍可取消显示。多个窗口同时请求同一插件模块时只构造一次；禁用或关闭会取消
并清理在途激活，旧的菜单或命令引用不能重新调用已禁用的贡献。
