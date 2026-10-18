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
| `fixtures/*.plugin.json` | Valid example manifests: language plugins (PHP, Go, Java, a discovered Node runtime), UI (`hello-lithe`), and level 3 build systems (Cargo, Go, Gradle, Maven, and two build providers) |
| `fixtures/invalid-manifests.json` | Edits to a valid manifest and the rejection code every host must report |
| `fixtures/command-plans.json` | Golden run/test command expansions and language-server launch plans |
| `fixtures/runtime-versions.json` | Golden outcomes of the launch runtime version check |
| `fixtures/build-plans.json` | Golden build-system plans and decoded outputs |
| `plugin-index.schema.json` | JSON shape of a marketplace source index |
| `fixtures/marketplace/*.json` | Marketplace index, availability, source URL, and install review golden cases |

Validation and template expansion are implemented once in Rust Core
(`rust/lithe-core/src/plugins/`, with build systems in
`rust/lithe-core/src/build/`) and exposed through the
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
| `pluginAPIVersion` | Declarative plugin API level of the manifest format. Hosts list the levels they support; Lithe's own version is never used for compatibility. This contract defines levels `1`, `2`, and `3`; see [API levels](#api-levels). |
| `requires` | Level 3 only, and required there: every capability the manifest uses, with the version of that capability's contract it was written against; see [Capability versions](#capability-versions-level-3). |
| `vendor` | `id`, `displayName`, and `signatureRequirement` (see Trust). |
| `permissions` | Capabilities the plugin may ask the host to perform. |
| `activationEvents` | When the host may start each provider. |
| `languages` | Languages the plugin recognizes. |
| `languageServers` | At most one language server per declared language. |
| `executionProviders` | At most one run/test provider per declared language. |
| `settings` | User-adjustable plugin options (level 2 and later). |
| `ui` | Host-rendered tool windows and commands (level 2 and later). |
| `buildSystems` | Project-level build tools (level 3). |

Unknown fields are refused (`plugin.manifest.invalid`) so an older host
rejects a package instead of ignoring part of it. At levels 1 and 2 a new
field needs a new `pluginAPIVersion`. From level 3 on it needs a new version
of the one capability that owns it, and only plugins that use the field
declare that version.

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
stopping the process when the provider is disabled. An API 3 build provider is
the same kind of process: it declares `launch`, `arguments`,
`validationArguments`, `runtimeDependencies`, and `initializationOptions` with
the same meaning and validation; see [Build providers](#build-providers).

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
The reported version is the first dotted number in the probe output, ignoring
lines that start with `Picked up ` (a JVM announcing `JAVA_TOOL_OPTIONS`
before its version); see `fixtures/runtime-versions.json`.

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
| `${setting:<id>}` | Current value of a declared [plugin setting](#plugin-settings-api-2). Not available in `validationArguments`, and never inside a package path. |

`plugins.declarative.languageServerLaunchPlan` expands a server's launch. The
host selects the process with exactly one of `languageID` (a language server)
and `buildSystemID` (a build provider), passes `{pluginDirectory,
stateDirectory, workspaceStateDirectory, architecture, settings?}`, and
receives:

| Field | Meaning |
| --- | --- |
| `launch` | `{kind: "packaged", path}`, `{kind: "systemCommand", commands}`, or `{kind: "runtime", tool, entry, packagedRuntime?, minimumVersion?, versionArguments?}`: what the host resolves to an executable. `packagedRuntime` is the expanded package-relative path of a shipped runtime. `minimumVersion` and `versionArguments` appear together when a discovered runtime must meet a minimum version. |
| `arguments` | Complete argument list after the executable, including `-jar` and the entry of a runtime launch. |
| `validationArguments` | Expanded probe arguments. |
| `runtimeRequirements` | `{tool, minimumVersion?}` for every runtime the host must discover, a discovered launch tool included, sorted by tool. A packaged runtime is not listed. Only the launch tool can carry a minimum version. |
| `initializationOptions` | Expanded options; absent when the server declares none. |
| `requiredDirectories` | `state` and/or `workspaceState`: the directories the host must create before starting the server. |
| `requiredPackagePaths` | Sorted package-relative paths the launch points at. The host verifies each is inside the package and not a symbolic link before starting the server. |
| `settings` | Effective value of every declared setting that produced this plan; absent when the plugin declares none. |
| `buildProvider` | Present only for a `buildSystemID` selection: `{buildSystemID, executesProjectCode, mayUseNetwork, languageServer?}`. `languageServer` names the language whose server is the provider; the rest of the plan is then that server's plan, and the host reuses its running session instead of starting a second process. |

A language without a server, an undeclared build system, and a build system
without a provider are `plugin.launch.unavailable`. Core never creates or
reads any of these paths. The command also serves API 1
manifests, whose arguments are returned unchanged.

#### Plugin settings (API 2)

A plugin may declare options the user can change, one set per plugin and
shared by every workspace. The host shows them on the plugin's page, stores
the values, and passes the stored values as `settings` (setting ID to JSON
value) with each launch plan request. Hosts restart the plugin's language
servers when a value changes.

```json
"settings": [
  { "id": "heapMB", "type": "integer", "title": "Maximum memory",
    "default": 2048, "minimum": 512, "maximum": 8192, "unit": "MB" },
  { "id": "logLevel", "type": "enum", "title": "Log level", "default": "info",
    "options": [{ "value": "info", "title": "Information" }, { "value": "debug", "title": "Debug" }] },
  { "id": "telemetry", "type": "boolean", "title": "Send usage data", "default": false }
]
```

| Field | Meaning |
| --- | --- |
| `id` | Starts with a lowercase letter, then letters and digits. Unique within the plugin. |
| `type` | `integer` (requires `minimum` and `maximum`, optional `unit`), `enum` (requires one to sixteen `options`, each `{value, title}`; values contain only letters, digits, `.`, `_`, `-`), or `boolean`. |
| `title`, `description` | Text the host shows; the host localizes only its own chrome. |
| `default` | Value used until the user changes it. Its JSON type follows `type`, and it must be accepted by the declaration. |

Because every value is a number, a boolean, or one of the declared option
values, a setting can never inject extra arguments or change which package
file runs. A stored value the declaration no longer accepts (for example after
an update narrowed a range) is replaced by the default; a launch never fails
for it. Values for undeclared IDs are ignored. A template that is exactly one
`${setting:<id>}` keeps the setting's JSON type, so an `initializationOptions`
value can be a number or boolean; inside longer text the value is substituted
as text. Declaring settings, or referring to an undeclared one, is refused
with `plugin.manifest.invalid` or `plugin.template.invalid`. The settings
declaration is not part of an install review's program list, because no value
can change what runs beyond what the templates already show.

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
| `2` | `runtime` launches with a packaged or discovered runtime, host integrations, the `java` runtime, launch templates, `initializationOptions`, and plugin settings. |
| `3` | Capability versions (`requires`), and `buildSystems`: declarative build tools with detection, options, a project model, tasks, run entries, tests, diagnostics, dependencies, and sync. |

A level 2 feature in a level 1 manifest is refused with
`plugin.manifest.invalid` (`plugin.runtime.unsupported` for the `java` tool),
so a package cannot use a feature that hosts of its declared level would
reject for a different reason. Level 1 language-server arguments stay literal
at every host level.

### Capability versions (level 3)

Levels 1 and 2 version the whole manifest: a change to one section raised the
level of every plugin, and hid plugins that never use that section from older
hosts. Level 3 versions each section on its own. A level 3 manifest lists in
`requires` exactly the capabilities it uses:

```json
"pluginAPIVersion": 3,
"requires": { "buildProviders": 1, "buildSystems": 1, "languageServers": 1, "languages": 1, "serverProcess": 1 }
```

| Capability | Covers | Versions |
| --- | --- | --- |
| `languages` | `languages[]` | `1` |
| `languageServers` | `languageServers[]` apart from their launch fields | `1` |
| `serverProcess` | The launch fields of language servers and of build providers with a process of their own: `launch`, `arguments`, `validationArguments`, `runtimeDependencies`, `initializationOptions` | `1` |
| `executionProviders` | `executionProviders[]` | `1` |
| `settings` | `settings[]` | `1` |
| `ui` | `ui` | `1`, `2` (adds [web content](#web-content-ui-2)) |
| `buildSystems` | Declarative build detection, models, and command plans | `1` |
| `buildProviders` | `buildSystems[].provider`, including own-process and shared language-server providers | `1` |

Version 1 of every capability means what its section means at level 2
(runtime launches, launch templates, `initializationOptions`, and so on), so
moving a level 2 manifest to level 3 only adds `requires`.

- `requires` is required at level 3 and refused below it
  (`plugin.manifest.invalid`). IDs are lowerCamelCase identifiers of at most
  64 characters; versions are positive integers.
- Core reads `requires` before it decodes any section. A capability or
  version this Core build does not support is `plugin.api.unsupported` with
  `field: "requires.<capability>"`, even when the manifest also holds a
  section Core does not know, so the user learns which capability needs a
  newer Lithe instead of seeing an unknown field.
- `requires` lists exactly the capabilities the manifest uses. Leaving out a
  used one, or listing an unused one, is `plugin.manifest.invalid`. Every
  language server, and every build provider with its own process, uses
  `serverProcess`; a shared build provider does not add another process. Any
  `buildSystems[].provider` requires `buildProviders: 1`, whether it starts its
  own process or shares a language server. A template-only build plugin must
  omit `buildProviders`. Launch support alone does not implement Provider
  negotiation, requests, and lifecycle.
- The base fields (`schemaVersion`, `id`, `displayName`, `version`, `vendor`,
  `permissions`, `activationEvents`, and `requires` itself) change only with a
  new `pluginAPIVersion`.

Validating a capability is not running it. Core validates every capability it
supports on every platform, but each host implements only some of them, so a
host states what it runs as `hostCapabilities: { "<capability>": [versions] }`
in `plugins.declarative.validate`, `plugins.marketplace.validateIndex`, and
`plugins.marketplace.installReview`:

- `validate` and `installReview` refuse a level 3 manifest whose `requires`
  names a version missing from `hostCapabilities` with
  `plugin.api.unsupported` and `field: "requires.<capability>"`. Without
  `hostCapabilities` they check only what Core supports.
- `validateIndex` offers a level 3 version only when the host and this Core
  build both support every entry of its `requires`; without
  `hostCapabilities` it offers none. A plugin that uses no build systems is
  therefore offered on a host that cannot run them.
- `hostCapabilities` has no effect on levels 1 and 2.

The macOS host runs levels 1 to 3 and sends its capability table, including
`buildSystems: [1]`, with all three commands. It does not implement build
providers and does not declare `buildProviders`. Provider plugins are therefore
filtered from the market and refused by declarative validation and install
review; template-only build plugins remain available. Core supports
`buildProviders: 1` for validation and plans without a host table. Windows has
no declarative plugin host and sends no `hostCapabilities`, so it offers no
level 3 version.

Rules for publishing across levels and capability versions:

- Levels and capability versions only add. A released version never changes
  meaning, and hosts keep supporting older versions.
- A plugin declares the lowest level, and for each capability the lowest
  version, it needs. Raising one without using what it adds only cuts off
  older hosts.
- A new capability version is added only for a change an older host must not
  ignore. Plugins that do not use the change keep the older version and stay
  installable wherever they were.
- Raising a plugin's level or a capability version requires a new plugin
  version, and its index entry keeps the last version with the previous
  requirements so older hosts still have a version to install. Published
  packages are signed and are never rewritten.
- A host release that supports a level or capability version ships before any
  plugin version that declares it.
- The manifest holds only what a host must know before it starts a process:
  what to start, with which permissions, for which files and projects. What a
  running process can answer is negotiated over its own protocol (see
  [Build providers](#build-providers)), never declared in the manifest.

## Permissions and activation

| Permission | Required when |
| --- | --- |
| `languageServer.launch` | `languageServers` is not empty |
| `process.run` | any provider declares `run` |
| `process.test` | any provider declares `test` |
| `process.build` | `buildSystems` is not empty |
| `ui.contribute` | `ui` is declared |
| `ui.web` | a tool window shows [web content](#web-content-ui-2) |

| Activation event | Meaning |
| --- | --- |
| `onLanguage:<id>` | Start the language server when a document of the language opens in a project. |
| `onRun:<id>` | Activate the run provider when the user runs a file of the language. |
| `onTest:<id>` | Activate the test provider when the user lists or runs tests. |
| `onBuildSystem:<id>` | Activate the build system before its first plan, model, or decode. |

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
| `versions[]` | `version`, required `pluginAPIVersion`, `requires` (level 3 only, and required there: the package manifest's `requires`; capability IDs this contract does not define are allowed and make the version unavailable), `releaseDate` (`YYYY-MM-DD`), and `downloads[]`. |
| `downloads[]` | `platforms` (for example `darwin-arm64`, `darwin-x64`, `windows-x64`, `windows-arm64`), `downloadURL`, and the archive's lowercase hex `sha256`. A platform may appear in at most one download of a version. |

A `downloadURL` must be a `.zip` GitHub Release asset of the entry's own
repository (`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>.zip`,
owner and repository compared case-insensitively), so an index cannot point a
plugin at another project's release.

### Validation and availability

`plugins.marketplace.validateIndex` accepts
`{ "index": object, "sourceKind": "official" | "thirdParty", "platform": string, "hostCapabilities"?: object }`.
A malformed index root or an unsupported `schemaVersion` rejects the whole
index. Otherwise it returns `{ "status": "ok", "index": { "plugins", "rejected" } }`:

- `rejected` lists refused entries in index order with their `error`.
  A third-party source listing an official-namespace ID is refused with
  `plugin.index.officialNamespace`; a repeated ID keeps the first listing and
  refuses later ones with `plugin.index.duplicate`.
- `plugins` is sorted by ID. Each accepted entry is normalized, lists
  `versions` newest first (each with its `requires` at level 3), reports
  `platforms`, `latestVersion`, and `latestReleaseDate` of the newest
  version, and an `availability`:
  - `{status: "available", version, pluginAPIVersion, releaseDate, downloadURL, sha256}`
    for the newest version with this platform's archive that the host can
    run: level 1, level 2 on a platform with the level 2 UI host (macOS), or
    level 3 with every capability of its `requires` hosted (see
    [Capability versions](#capability-versions-level-3));
  - `{status: "unsupported", code: "plugin.index.apiUnsupported", platform, message}`
    when the platform is listed only by versions needing a newer plugin API
    or a capability the host does not run;
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
`{ "manifest": object, "expectedID"?, "expectedVersion"?, "approvedPrograms"?: [object], "hostCapabilities"?: object }`
and returns `{ "status": "ok", "review": { id, version, permissions, programs, newPrograms } }`.
A package whose ID or version differs from the index entry is refused with
`plugin.package.mismatch`, and a level 3 package that requires a capability
missing from `hostCapabilities` with `plugin.api.unsupported`. `programs` lists everything the host may start for
the plugin, sorted by `kind`, language, and tool:

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `packagedLanguageServer` | `languageID`, `path`, `arguments`, `validationArguments` | Executable inside the package, with its launch arguments and validation probe |
| `systemLanguageServer` | `languageID`, `commands`, `arguments`, `validationArguments` | Command resolved by host tool discovery |
| `runtimeLanguageServer` | `languageID`, `tool`, `packagedRuntime`, `entry`, `runtimeArguments`, `arguments`, `validationArguments` | Package entry started by a runtime; `packagedRuntime` is `null` for a discovered runtime |
| `buildSystem` | `buildSystemID`, `invocation`, `options`, `tasks`, `run`, `test`, `model`, `dependencies`, `hostIntegration`?, `provider`? | Every command line the build system can plan; `provider` is the shared form, which sends build requests to a language server |
| `packagedBuildProvider`, `systemBuildProvider`, `runtimeBuildProvider` | the matching language-server fields with `buildSystemID`, `executesProjectCode`, `mayUseNetwork` instead of `languageID` | A build provider with a process of its own |
| `runtime` | `tool`, `minimumVersion`? | Runtime the host discovers and passes to a language server or build provider |
| `run` | `languageID`, `executable`, `arguments` | Run command and its argument template |
| `test` | `languageID`, `executable`, `workspaceArguments`, `fileArguments`, `testCaseArguments` | Test command and its argument templates |

Each entry carries everything that decides what actually runs, so an update
that keeps the same executable but changes its arguments, argument templates,
or validation probe is a new program; language-server and build-provider
entries also carry `initializationOptions` when declared. Hosts record the approved `programs`
with the installation. An update passes them as `approvedPrograms`; a
non-empty `newPrograms` requires the user to confirm again. When several sources list the same ID, the user chooses the
source at install time and later updates come only from that source.

## API level 3: build systems

`buildSystems` describes a project-level build tool (Cargo, Go, Gradle,
Maven, …) as data. Every build tool gets the same model and the same
commands: Core validates the declaration, detects instances, decodes the
model, and expands every command line; the host only runs the processes Core
planned and passes their output back. A community plugin therefore needs no
host change to add a build tool, and no host code branches on a build-system
ID. The fixtures `cargo-build`, `go-build`, `gradle-build`, and `maven-build`
are complete examples, `gradle-provider` and `mix-provider` show the two
forms of a build provider, and `fixtures/build-plans.json` is the golden list
of plans and decoded outputs every host gets from them.

A build system needs `pluginAPIVersion` 3 with `buildSystems` in `requires`,
the `process.build` permission,
and the activation event `onBuildSystem:<id>`. IDs of build systems, tasks,
and run entries start with a lowercase letter and use lowercase letters,
digits, and hyphens. Option IDs are camelCase like setting IDs. Paths in a
declaration are relative, use `/`, and stay inside their base directory
(`plugin.path.invalid` otherwise).

| Field | Meaning |
| --- | --- |
| `detection` | `markers` are file names; a directory holding one is a candidate root. `nesting: "outermost"` folds deeper candidates into the outer instance (Gradle builds, Maven reactors); `"separate"` (default) keeps each (Cargo packages). `priority` (0–100, default 50) decides between plugins declaring the same ID; ties go to the smaller plugin ID. |
| `invocation` | `executables` in preference order: `projectFile` (a wrapper inside the root, with `requires` files; always runs project code), `environment` (a path below a variable listed in `environmentInputs`), `command` (a bare name found on `PATH`), `runtime` (a declared runtime dependency itself). `platforms` limits a candidate. `globalArguments` precede every command. `version` probes the executable with literal `arguments` and a `pattern` whose first group is the version; `minimumVersion` needs a probe. |
| `runtimeDependencies` | `java`, `node`, and `go` are host-managed: only `id` and `minimumVersion`, discovered with the user's runtime settings; `build.invocationPlan` returns the probe arguments Core reads their version with, so hosts keep no per-runtime probe. Any other ID describes its own `executables` and `version` probe, so the runtime list is open. |
| `options` | Build dimensions the user chooses: `boolean`, `singleSelect`, `multiSelect`, `text`, `file`, `directory`. Each contributes `arguments` and `environment` (with `${value}`) when it has a value. Choices are declared, come from the model (`choicesFromModel`), or are free (`allowCustom`). |
| `provider` | The process that answers model and dependency requests when no command prints them; see [Build providers](#build-providers). |
| `model` | `static` (a `toml` file read during detection, no process), `command` (a command whose output Core decodes; it states `executesProjectCode` and `mayUseNetwork`), `provider`, or `hostIntegration`. |
| `tasks` | The task catalog. `scopes` say what a task runs on (`workspace`, `project`, `target`); `targetTags` restrict targets; `requiresUserArguments` makes the host ask for arguments. A `fromModel` task is the template for tasks the model lists. |
| `run` | Run entries from model targets (`fromTargets.tags`, with `arguments`) or model tasks (`fromTasks`, reusing the template task's arguments). |
| `test` | How tests run: `scopes`, `targetTags`, the `filters` (`suite`, `case`) it can select, and `results` (`junitXml` or `litheTestResults` report globs relative to the project, or `hostIntegration`). A workspace run reads the globs under the root and every model project. A requested filter must reach the command line through a template whose conditions hold; a `case` guarded by `suiteSelected` therefore needs its suite. |
| `diagnostics` | `lineMatcher` patterns with capture-group numbers, or `litheDiagnostics` lines. |
| `dependencies` | A command (with `scopes`) whose output Core decodes, as a flat list through a `map` or as a tree from `litheDependencies`; `provider` (with `scopes`, `workspace` and `project` only); or `hostIntegration`. |
| `sync` | Files whose change makes the model stale, relative to the root and to each project. |
| `layout` | `excluded` directories relative to each project, added to every project as `excluded` content roots. |
| `languageImport` | The project import Lithe's Java language server performs for this build system: `kind` `maven` or `gradle`, and `options` mapping its settings to the plugin's own option IDs. `maven` has `profiles` (`multiSelect`), `settingsFile` (`file`) and `localRepository` (`directory`); `gradle` has `offline` (`boolean`) and `gradleUserHome` (`directory`). `build.languageImport` turns the user's values into the `mavenContext` or `javaGradle` input of `lsp.startServer`; settings without an option keep the language server's defaults. |

### Presentation

Each enabled build system gets a tool window of its own, titled with its
`displayName`; `icon` (a [UI icon](#ui-icons-macos-host)) is its activity-bar
icon. As for every tool window, the host owns the shell: dock, order,
visibility, layout, and lifecycle. The host draws the window body from the
model, and three optional fields tell it where an entry goes. None of them
changes a plan.

- `options[].presentation: "toolbar"` puts a boolean option on the window's
  toolbar as a toggle, for offline mode or skipping tests; it needs an
  `icon`. `"tree"` shows a multiSelect option as a checklist node at the top
  of the tree (Maven profiles). Without `presentation` the option appears only
  in the option list. An icon on an option that is not `toolbar` is
  `plugin.manifest.invalid`.
- `tasks[].category` lists 1–4 headings, outermost first, that file the task
  in its project (`["Lifecycle"]`). Without it the host files the task by
  `group`. On a `fromModel` template it is the default for the tasks the
  model lists.
- A model task in a `litheBuildModel` document can carry its own `category`,
  an array of strings. Core trims the headings. A category that is deeper
  than four headings or has an empty heading falls back to the template's, so
  a tool that reports a bad heading still has its task filed.

The macOS host gives each detected build system its own tool window and uses
these presentation fields. The host-drawn windows share Build Output, docking,
layout restoration, activation, and lifecycle with other workbench contributions.
Windows has not integrated build-system windows yet.

### Templates

Arguments are template strings, or `{ "value": …, "when": condition }` with
one condition or a list that must all hold: `projectSelected`,
`nestedProjectSelected` (a project other than the root one), `targetSelected`,
`suiteSelected`, `caseSelected`, and their `no…` opposites.

| Variable | Available in |
| --- | --- |
| `${root}` | every list |
| `${project.name}`, `${project.path}` (relative to the root), `${project.property:<key>}` | lists with a project scope; guard with `projectSelected` when the project may be absent |
| `${target.name}`, `${target.property:<key>}` | target-scoped tasks, tests, and target run entries; guard with `targetSelected` when the target may be absent |
| `${task.name}`, `${task.property:<key>}` | `fromModel` tasks |
| `${test.suite}`, `${test.case}`, `${test.case:regex}` (regex-escaped) | `test.arguments`, guarded by `suiteSelected` / `caseSelected` |
| `${optionArguments}`, `${optionArguments:<id>}` | every command list; a whole argument that expands to all options, or one option |
| `${userArguments}` | tasks and tests; a whole argument. A task with `requiresUserArguments` must pass it |
| `${pluginDir}`, `${workspaceStateDir}`, `${outputFile}` | model and dependency commands; `${outputFile}` exactly when `output` is `outputFile` |
| `${value}` | option `arguments` and `environment` |

Each option's arguments are emitted once per command line: reference them
either in `globalArguments` or in the command's list, and only once within a
list, except under opposite conditions. An option that no list references
contributes nothing. Unknown, misplaced, unguarded, or repeated variables are
`plugin.template.invalid`.

### Model and outputs

A model or dependency command prints to `stdout` (default) or to the
host-allocated `${outputFile}`. Its decoder is `jsonStream`
(whitespace-separated JSON values such as NDJSON or `go list -json`, decoded
as an array; a single document becomes a one-element array) or a canonical
format that needs no `map`. A static model file is `toml`.

A `map` only selects values. A model map turns a decoded document into
projects, each with its targets and content roots, and into option values; a
dependency map turns it into a flat list. Rules select elements with `each`,
filter them with `where` predicates (`{ "pointer", "equals" | "exists" }`),
apply only as a `fallback` or `whenFile` a file exists, and read fields with
selectors: `""` (the element), `@key` (its key), `/a/b` (relative to the
element), `$/a/b` (from the document root), `*` (each item). A field is a
selector, `{ "from", "transform": "lastSegment" }`, or a literal
`{ "value": "src" }`. Target `tags` are a literal list, and a project's
parent is the deepest project containing it. Paths are relative to the root
or absolute inside the workspace; anything else is dropped. A target `fallback` is
skipped only when a non-fallback target rule with an overlapping tag already
produced a target, so an explicit binary suppresses an implicit `src/main.rs`
target while explicit test or example targets do not.

Whatever a map cannot express is the plugin's own work: other file formats,
tasks read from the tool, explicit parent links, tags computed from values,
and dependency trees. The plugin's command (a script under `${pluginDir}`,
or the tool itself with a plugin-supplied init script, as Gradle does) prints
`litheBuildModel` or `litheDependencies`, or a
[build provider](#build-providers) answers. Unlike a static file, a command
runs only when the host starts it on request. The map does not grow into a
transformation language: a later `buildSystems` version adds a rule only when
real plugins need it and it cannot reasonably live in the plugin.

Canonical formats let a plugin's own script print the shape Core expects:

| Format | Shape |
| --- | --- |
| `litheBuildModel` | `{ "format": "litheBuildModel", "version": 1, "projects", "targets", "tasks", "contentRoots", "optionValues" }` with the model's field names; `tasks[].category` is an array of headings |
| `litheTestResults` | `{ "format": "litheTestResults", "version": 1, "tests": [{ "suite", "case", "status", "message"?, "durationMillis"?, "path"?, "line"? }] }` |
| `litheDependencies` | `{ "format": "litheDependencies", "version": 1, "dependencies": [{ "name", "group"?, "version"?, "scope"?, "properties"?, "children" }] }` |
| `litheDiagnostics` | output lines `{ "lithe": "diagnostic", "path", "line", "column"?, "severity"?, "message" }` |

Unknown fields in canonical documents are ignored so newer scripts work with
older hosts. Output that does not fit its decoder is `plugin.build.invalidOutput`.

### Build providers

Some tools expose their model only through their own API (the Gradle Tooling
API, Mix inside the BEAM). Their plugin declares `provider`: a long-lived LSP
base-protocol process of the same kind as a language server, which answers
`lithe/build/model` and `lithe/build/dependencies`. It has one of two forms,
told apart by the `languageServer` key; mixing them is
`plugin.manifest.invalid`.

| Form | Fields |
| --- | --- |
| Shared | `{ "languageServer": "<languageID>", "executesProjectCode", "mayUseNetwork" }`. The named language must have a language server in the same plugin; the host sends the requests to that session. |
| Own process | The language-server process fields (`launch`, `arguments`, `validationArguments`, `runtimeDependencies`, `initializationOptions`) plus `executesProjectCode` and `mayUseNetwork`. Validation, launch templates, settings, and the install review are those of a language server, so it needs the `languageServer.launch` permission and is listed as a `packagedBuildProvider`, `systemBuildProvider`, or `runtimeBuildProvider` program with its `buildSystemID` and flags. |

`model.source: "provider"` and `dependencies.source: "provider"` use it. A
provider no source uses, or a provider source without a provider, is
`plugin.manifest.invalid`. Detection never starts a provider: its instances
report `modelSource: "provider"` without a model.

The host starts the process from `plugins.declarative.languageServerLaunchPlan`
with `buildSystemID`. For a provider source, `build.modelPlan` and
`build.dependencyPlan` return `provider: { method, params }` instead of
`arguments`, with the request's `decoder` (`litheBuildModel` or
`litheDependencies`) and the declared `executesProjectCode` and
`mayUseNetwork`:

| Param | Meaning |
| --- | --- |
| `buildSystemID`, `root` | The instance. A model request always covers the whole instance. |
| `options` | Effective option values by option ID. |
| `optionArguments`, `environment` | What the options contribute, for a provider that runs the tool. |
| `project` | Dependencies only: `{ name, path }` of the selected project, or `null` for the workspace. |

The host passes the JSON result of the request as `result` to
`build.decodeModel` or `build.decodeDependencies`, which decode it like the
canonical format of a command; a missing result is
`plugin.build.invalidSelection`, and a result over the output limit or of
another format is `plugin.build.invalidOutput`.

The manifest only says how to start the provider and which sources use it.
Everything else is negotiated in the LSP `initialize` exchange, so a provider
can grow without a new manifest field or capability version:

- The host sends `capabilities.experimental.litheBuild: { "versions": [1] }`,
  the build-provider protocol versions it speaks. Version 1 is the two
  requests above with the params and result formats of this section.
- The provider answers `capabilities.experimental.litheBuild: { "version": 1 }`
  with the version it chose from that list. A provider that answers no
  version, or one the host did not offer, is not used for build requests; a
  shared provider still serves its language.
- Both sides ignore fields they do not know in these objects and in request
  params and results, so either side can add optional data within a version.
  A change the other side must not ignore needs a new protocol version.

### Host integrations

`hostIntegration` names host code that owns one concern while a built-in tool
migrates onto this model. Only official plugins may name one, and only
`maven` exists; a model, test-result, or dependency source of
`hostIntegration` needs it. Anything else is
`plugin.integration.unsupported`. New build systems use the declarative
contract or a canonical format instead.

### Commands

The `build.*` Core commands (see `shared/contracts/rust-core-api.md`) take the
manifest, the build-system ID, and a request, and revalidate the manifest
every time. `build.detect` walks the workspace once for all enabled plugins
and returns instances, with the model of `static` and `hostIntegration`
sources. `build.invocationPlan` and `build.checkToolVersion` resolve the
executable; `build.resolveOptions` checks stored option values and returns
the configuration fingerprint; `build.modelPlan`, `build.taskPlan`,
`build.testPlan`, and `build.dependencyPlan` return argv plans, or provider
requests for a provider source;
`build.decodeModel`, `build.decodeTestResults`, `build.decodeDiagnostics`,
and `build.decodeDependencies` normalize output or a provider result; `build.syncFingerprint`
digests the watched files. A selection the declaration does not allow is
`plugin.build.invalidSelection`; an operation it does not declare is
`plugin.build.unavailable`.

## Outcomes and error codes

`plugins.declarative.*`, `plugins.marketplace.*`, and `build.*` commands return `{"status": "ok", …}` or
`{"status": "rejected", "error": {"code", "message", "field"?}}`. A malformed
command payload is a Core `invalid_request` failure instead.

| Code | Reported by | Meaning |
| --- | --- | --- |
| `plugin.manifest.invalid` | Core | Malformed manifest, unknown field, or broken cross reference |
| `plugin.schema.unsupported` | Core | `schemaVersion` is not `2` |
| `plugin.api.unsupported` | Core | `pluginAPIVersion`, or a capability version in `requires`, is not supported by this Core build or, when the host sent `hostCapabilities`, by the host |
| `plugin.permission.unknown` | Core | Unknown permission |
| `plugin.permission.undeclared` | Core | A provider or build system is declared without its permission |
| `plugin.activation.invalid` | Core | Missing or orphan activation event |
| `plugin.runtime.unsupported` | Core | Unknown runtime dependency, or a launch runtime that cannot start an entry file |
| `plugin.template.invalid` | Core | Unknown, misplaced, or unguarded template variable |
| `plugin.path.invalid` | Core | A request path leaves the workspace, or a declared path leaves its base directory |
| `plugin.test.invalidIdentifier` | Core | Empty or multi-line test identifier |
| `plugin.test.unsupportedProject` | Core | No project marker in the workspace |
| `plugin.execution.unavailable` | Core | The plugin has no run/test provider for the language |
| `plugin.integration.unsupported` | Core | A host integration the host does not implement, or one requested by a plugin outside the official namespace |
| `plugin.launch.unavailable` | Core | The plugin has no language server for the language, or no provider process for the build system |
| `plugin.build.unavailable` | Core | The plugin declares no such build system, or the build system does not declare the requested operation |
| `plugin.build.invalidSelection` | Core | A build request selects a scope, target, filter, or argument the declaration does not allow, or misses a required path |
| `plugin.build.invalidOutput` | Core | Build-tool output or a report does not fit its decoder |
| `plugin.launch.invalidRequest` | Core | A launch plan request has an unusable directory or an unknown architecture |
| `plugin.index.invalid` | Core | Malformed index root or entry, or an invalid URL, checksum, platform, version, or date |
| `plugin.index.schemaUnsupported` | Core | The index `schemaVersion` is not `1` |
| `plugin.index.officialNamespace` | Core | A third-party source lists a `dev.lithe` ID |
| `plugin.index.duplicate` | Core | An index lists the same plugin ID more than once |
| `plugin.index.platformUnsupported` | Core | No version has an archive for this platform (availability, not a rejection) |
| `plugin.index.apiUnsupported` | Core | Only versions needing a newer plugin API, or a capability the host does not run, list this platform (availability, not a rejection) |
| `plugin.source.invalid` | Core | A marketplace source URL cannot be used |
| `plugin.package.mismatch` | Core | A downloaded package's ID or version differs from its index entry |
| `plugin.archive.checksumMismatch` | Host | A downloaded archive does not match the index SHA-256 |
| `plugin.download.failed` | Host | An index or archive could not be downloaded |
| `plugin.signature.missing`, `plugin.signature.invalid`, `plugin.signature.untrusted` | Host | Package signature problems |
| `plugin.launch.missing` | Host | The packaged language server is missing or not executable |
| `plugin.runtime.missing` | Host | A declared runtime (for example Node.js) cannot be found, or is older than its `minimumVersion`, when the server starts |
| `plugin.legacyNative.updateRequired` | Host | An installed schema-1 native package must be replaced by its declarative version |
| `plugin.web.unknownMethod` | Host | A plugin page called a bridge method the host does not implement |
| `plugin.web.invalidRequest` | Host | A bridge call has malformed parameters |
| `plugin.web.forbidden` | Host | A bridge call names an instance, run, or path outside the page's plugin or workspace, or the page is closed |

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
  A window shows exactly one of `text` and, from `ui` 2 on,
  [`web`](#web-content-ui-2).
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

### Web content (`ui` 2)

A plugin does not have to bring a UI: build systems get a host-drawn window
(see [Presentation](#presentation)), and text windows need no code. A plugin
that wants its own UI can show its own page in a tool window instead of
`text`:

```json
"requires": { "ui": 2 },
"permissions": ["ui.contribute", "ui.web"],
"ui": { "toolWindows": [{ "id": "…", "title": "…", "placement": "right", "web": { "entry": "ui/index.html" } }] }
```

- `web` needs `pluginAPIVersion` 3, `requires.ui: 2`, and the `ui.web`
  permission, which the install review lists like every permission.
  `requires.ui: 2` without a web window is `plugin.manifest.invalid`, so a
  text-only plugin stays installable on hosts that run only `ui` 1.
- `entry` is a package-relative `.html` path. `fixtures/web-panel.plugin.json`
  is the example; the web cases of `fixtures/invalid-manifests.json` are the
  rejections.

The window shell stays the host's: dock, title, activity-bar entry, order,
visibility, layout, and lifecycle are declared or managed exactly as for a
text window. The page fills the body only and cannot open, place, size, or
title a window.

Hosts load a page under these rules:

- Only files of the installed package are served, read-only, from an origin
  private to the plugin. The host's content security policy refuses network
  connections, remote resources, frames, inline scripts, and `eval`.
  Navigation away from the package, popups, and downloads are blocked.
- Web storage is not persistent. A page keeps its state through the bridge.
- The host creates the page when the window is first shown. It may destroy
  the page whenever the window is hidden, and does destroy it when the plugin
  is disabled, updated, or uninstalled. A page restores itself from its
  state.
- The root element carries `data-theme` (`light` or `dark`) and the host's
  `--lithe-*` CSS colour and font variables, updated with the theme.

Before the page's scripts run, the host defines `window.lithe` (bridge
version 1): `lithe.context` (`pluginID`, `windowID`, `platform`, `locale`,
`theme`), `lithe.request(method, params)`, which returns a promise of the
result or rejects with `{ code, message }`, and `lithe.on(event, listener)`,
which returns an unsubscribe function. A page reaches only its own plugin's
build systems and the open workspace. Requests that run anything go through
the same workspace trust and consent prompts as the host's own controls, and
their output appears in the host's Build output window.

| Method | Parameters | Result |
| --- | --- | --- |
| `build.instances` | none | `{ instances: [{ id, buildSystemID, root, state, model?, options, error? }] }`: this plugin's detected instances, `model` as `build.decodeModel` returns it, `options` the stored values |
| `build.refresh` | `{ instance }` | `{}`; reloads the model |
| `build.runTask` | `{ instance, task, project?, target?, modelTask?, userArguments? }`, the selection of `build.taskPlan` | `{ run }` |
| `build.runTests` | `{ instance, project?, target?, suite?, case? }`, the selection of `build.testPlan` | `{ run }` |
| `build.cancel` | `{ run }` | `{}` |
| `build.dependencies` | `{ instance, project? }` | the tree `build.decodeDependencies` returns |
| `build.setOptions` | `{ instance, values }` | `{ options }`, checked by `build.resolveOptions` and stored like values set in the host's option list |
| `workspace.openFile` | `{ path, line?, column? }`, a path inside the workspace | `{}` |
| `ui.getState`, `ui.setState` | none, `{ state }` | `{ state }`, `{}`; JSON of at most 64 KiB per window and workspace |

| Event | Payload |
| --- | --- |
| `build.instancesChanged` | `{ instances }`, as `build.instances` returns them |
| `build.runChanged` | `{ run, instance, state, exitCode? }`, `state` one of `running`, `succeeded`, `failed`, `cancelled` |
| `ui.themeChanged` | `{ theme }` |

Bridge errors are `plugin.web.unknownMethod`, `plugin.web.invalidRequest`,
and `plugin.web.forbidden`. Build requests also report the `build.*` codes.
No host implements web content yet. macOS sends `ui: [1]`, so Core refuses a
`ui` 2 plugin there with `plugin.api.unsupported` until its web-view host ships.

### Future public extension direction (not implemented in API level 2)

- Plugins may bring their own UI as [web content](#web-content-ui-2) inside
  host-owned windows. A separately versioned JSON component tree
  (Tree/List/Form/Input/Button, data sources and events) rendered by native
  platform adapters remains the direction for plugins that want native
  controls without writing a page. Built-in or trusted native modules may
  register Native View/Renderer Factories under the same host window
  management. This does not restore arbitrary dynamic third-party Swift
  Bundle loading; ABI, signing and isolation need separate design.
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
