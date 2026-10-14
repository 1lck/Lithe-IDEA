# Plugin contract v1: declarative plugins

A declarative plugin describes language support as data. The host reads
`plugin.json`, validates it, verifies the package signature, and launches the
declared external processes itself. The host never loads plugin code into its
own process, so a package does not depend on the host's binary layout and does
not need to be rebuilt for each Lithe release.

This directory is the cross-platform source of truth:

| File | Purpose |
| --- | --- |
| `plugin-manifest.schema.json` | JSON shape of `plugin.json` |
| `fixtures/*.plugin.json` | Valid example manifests (PHP, Go, Java, and a discovered Node runtime) |
| `fixtures/invalid-manifests.json` | Edits to a valid manifest and the rejection code every host must report |
| `fixtures/command-plans.json` | Golden run/test command expansions and language-server launch plans |
| `fixtures/runtime-versions.json` | Golden outcomes of the launch runtime version check |
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
| `pluginAPIVersion` | Declarative plugin API level the package needs. Hosts list the levels they support; Lithe's own version is never used for compatibility. This contract defines levels `1` and `2`; see API levels. |
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
| `launch` | `{"kind": "packaged", "path": …}` runs an executable inside the package. `{"kind": "systemCommand", "commands": [...]}` lists bare command names the host resolves with its tool discovery (PATH, project toolchains, user overrides). API 2 adds `{"kind": "runtime", …}`; see Runtime launch. |
| `arguments` | Arguments passed to the server. Literal text at API 1; launch templates at API 2. |
| `validationArguments` | Probe that must exit with status 0 before a candidate is used; empty means the host trusts the candidate and lets the LSP handshake decide. |
| `runtimeDependencies` | Runtimes the host must discover and pass to the server. API 1 tools are `node` and `go`; API 2 adds `java`. The host exports each path as `LITHE_<TOOL>_PATH` (`LITHE_NODE_PATH`, `LITHE_GO_PATH`; a user-set value takes precedence) and prepends its directory to the server's `PATH`, because servers such as gopls run the tool themselves and an app opened from the Dock does not inherit the shell `PATH`. A project-local copy is never chosen, since servers start automatically when a file opens. |

| `initializationOptions` | API 2. A JSON object sent as the LSP `initializationOptions`. Every string value inside it is a launch template. |
| `hostIntegration` | API 2, official plugins only. A named integration implemented in the host, with the package resources it reads; see Host integrations. |

The host owns the language-server process lifecycle, the LSP session, and
stopping the process when the provider is disabled.

#### Runtime launch (API 2)

`{"kind": "runtime", "tool", "packagedRuntime"?, "minimumVersion"?,
"runtimeArguments"?, "entry"}` starts a file inside the package with a
runtime, so the package needs no launcher script. The runtime is either
shipped by the plugin (`packagedRuntime`) or discovered by the host.

| Field | Meaning |
| --- | --- |
| `tool` | `java` or `node`. It decides how the entry is passed to the runtime. |
| `packagedRuntime` | Package-relative path of the runtime executable the plugin ships, for example `runtime/${arch}/bin/java`; `${arch}` is the only variable it may use. The host starts exactly this file: it never looks the tool up on the machine, and no user override or other plugin can replace it. A plugin that needs a specific runtime owns it this way, so the host carries no knowledge of where that runtime lives. It excludes `minimumVersion`. |
| `minimumVersion` | Lowest acceptable runtime version: one to three dot-separated numbers such as `21` or `18.17`, for a runtime the host discovers. Only the components it names are compared, so `21` accepts every 21.x. A runtime whose version cannot be read does not qualify. |
| `runtimeArguments` | Launch templates placed before the entry, such as JVM options. |
| `entry` | Package-relative entry file. The command line is `<java> <runtimeArguments> -jar <entry> <arguments>` for `java` and `<node> <runtimeArguments> <entry> <arguments>` for `node`. |

The launch tool is already a requirement and must not be repeated in
`runtimeDependencies`. A runtime launch declares no `validationArguments`:
the host's probe of the runtime is its version check. The launch plan carries
the probe's `versionArguments`; the host runs the candidate with them and
passes the output to `plugins.declarative.checkRuntimeVersion`, which returns
`{satisfied, version?}`. A candidate that does not satisfy the requirement is
not used, the same as a candidate that fails a validation probe. A `java`
older than 9 does not accept the probe and is therefore treated as too old.

#### Host integrations (API 2)

Most of a language server is described by its launch. A few servers also need
behavior that data cannot express: a project model computed from build files,
virtual documents, test and debug wiring. That behavior is code in the host,
called a host integration. A server opts into one by name and tells it where
the files it needs are inside the plugin's own package:

```json
"hostIntegration": {
  "id": "jdt",
  "capabilities": ["debug", "run", "testing"],
  "resources": { "configuration": "language-server/configuration/${arch}", "lombokAgent": "…" }
}
```

The plugin owns the files; the host owns the behavior. The host enables an
integration only for the server that declares it and never matches on a
language ID or looks for the files anywhere else, so removing the plugin
removes the integration's inputs with it. Because an integration runs trusted
host code, only plugins in the `dev.lithe` namespace may declare one; any
other package, or an ID the host does not implement, is refused with
`plugin.integration.unsupported`.

Each resource is a package-relative path, or a list of them, that may vary
only by `${arch}`. An integration defines which names it reads; a missing
required name, an unknown name, or the wrong shape is `plugin.manifest.invalid`.

A plugin that declares a language owns its process-backed features: the host
stops running its built-in tools for that language, so a missing or disabled
plugin never falls back to them. `capabilities` is how the plugin hands a
feature back. It lists the features of the server's language that the host's
own implementation provides through the integration: `run`, `testing`, and
`debug`. A feature that is neither listed here nor supplied by one of the
plugin's `executionProviders` is unavailable for the language. Omitting the
list claims nothing.

Each integration defines the capabilities it provides and the resources each
one reads. A capability the integration does not provide, a capability whose
resource is not declared, and `run` or `testing` listed for a language whose
execution provider already supplies it are all `plugin.manifest.invalid`. The
normalized manifest lists capabilities sorted and without duplicates.

| Integration | Requires | Capabilities | Resources |
| --- | --- | --- | --- |
| `jdt` | A `runtime` launch with the `java` tool | `run`. `debug`: needs `extensionBundleDirectories`, which must contain the Java Debug Server bundle. `testing`: needs `extensionBundleDirectories` with the Java Test bundles, and `testRunner`. | `configuration` (required): the Equinox configuration directory, of which the host gives each launch a writable copy. `lombokAgent` (required): the Lombok agent JAR. `extensionBundleDirectories` (list): directories whose JAR files are loaded as JDT LS extension bundles, in declared order and then by file name. `testRunner`: the standalone Java test runner JAR. |

The launch plan returns `hostIntegration` as `{id, resources}` with every
path expanded, and lists the paths in `requiredPackagePaths`.

#### Launch templates (API 2)

`arguments`, `validationArguments`, `runtimeArguments`, and the string values
of `initializationOptions` may use these variables. A package therefore never
contains a machine path, and the host decides where state lives.

| Variable | Value |
| --- | --- |
| `${pluginDir}` | Root of the installed, read-only package. It must be used at most once per value and be followed by a `/`-rooted path inside the package; that path may vary only by `${arch}`. |
| `${stateDir}` | Writable directory the host keeps for this plugin's server and removes when the plugin is uninstalled. Not available in `validationArguments`. |
| `${workspaceStateDir}` | Writable directory for the server's state of the current workspace. Not available in `validationArguments`. |
| `${arch}` | Host CPU architecture: `arm64` or `x86_64`. |

`plugins.declarative.languageServerLaunchPlan` expands a server's launch. The
host passes `{pluginDirectory, stateDirectory, workspaceStateDirectory,
architecture}` and receives:

| Field | Meaning |
| --- | --- |
| `launch` | `{kind: "packaged", path}`, `{kind: "systemCommand", commands}`, or `{kind: "runtime", tool, entry, packagedRuntime?, minimumVersion?, versionArguments?}`: what the host resolves to an executable. `packagedRuntime` is the expanded package-relative path of a shipped runtime. `minimumVersion` and `versionArguments` appear together when a discovered runtime must meet a minimum version. |
| `arguments` | Complete argument list after the executable, including `-jar` and the entry of a runtime launch. |
| `validationArguments` | Expanded probe arguments. |
| `runtimeRequirements` | `{tool, minimumVersion?}` for every runtime the host must discover, a discovered launch tool included, sorted by tool. A packaged runtime is not listed. Only the launch tool can carry a minimum version. |
| `initializationOptions` | Expanded options; absent when the server declares none. |
| `requiredDirectories` | `state` and/or `workspaceState`: the directories the host must create before starting the server. |
| `requiredPackagePaths` | Sorted package-relative paths the launch points at. The host verifies each is inside the package and not a symbolic link before starting the server. |

Core never creates or reads any of these paths. The command also serves API 1
manifests, whose arguments are returned unchanged.

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

## API levels

| Level | Adds |
| --- | --- |
| `1` | Languages, `packaged` and `systemCommand` language servers, `node` and `go` runtime dependencies, run and test providers. |
| `2` | `runtime` launches with a packaged or discovered runtime, host integrations, the `java` runtime, launch templates, and `initializationOptions`. |

A level 2 feature in a level 1 manifest is refused with
`plugin.manifest.invalid` (`plugin.runtime.unsupported` for the `java` tool),
so a package cannot use a feature that hosts of its declared level would
reject for a different reason. Level 1 language-server arguments stay literal
at every host level.

Rules for publishing across levels:

- Levels only add features. The meaning of a released level never changes,
  and hosts keep supporting older levels.
- A plugin declares the lowest level it needs. Raising the level without
  using a new feature only cuts off older hosts.
- Raising a plugin's level requires a new plugin version, and its index entry
  keeps the last version of the previous level so older hosts still have a
  version to install. Published packages are signed and are never rewritten.
- A host release that supports a level ships before any plugin version that
  declares it.

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
| `plugin.runtime.unsupported` | Core | Unknown runtime dependency, or a launch runtime that cannot start an entry file |
| `plugin.template.invalid` | Core | Unknown, misplaced, or unguarded template variable |
| `plugin.path.invalid` | Core | A request path leaves the workspace |
| `plugin.test.invalidIdentifier` | Core | Empty or multi-line test identifier |
| `plugin.test.unsupportedProject` | Core | No project marker in the workspace |
| `plugin.execution.unavailable` | Core | The plugin has no run/test provider for the language |
| `plugin.integration.unsupported` | Core | A host integration the host does not implement, or one requested by a plugin outside the official namespace |
| `plugin.launch.unavailable` | Core | The plugin has no language server for the language |
| `plugin.launch.invalidRequest` | Core | A launch plan request has an unusable directory or an unknown architecture |
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
| `plugin.runtime.missing` | Host | A declared runtime (for example Node.js) cannot be found, or is older than its `minimumVersion`, when the server starts |
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
