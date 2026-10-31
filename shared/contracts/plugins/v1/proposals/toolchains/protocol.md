# Proposed toolchain query, resolution and local pins

**Status: broader proposal; native querying and SDK support are not implemented.**
The Core-only validation/resolution subset is specified by
[the active contract](../../toolchains.md). These files remain review vectors,
not an advertised native capability or an SDK guide. The existing local-toolchain
writer/schema is unchanged. The design follows the
[latest #1581 review](https://github.com/1lck/Lithe-IDEA/pull/1581#issuecomment-6541366112).

## Ownership and transport

A tool definition says how to recognize, probe and use a tool. A provider
answers which installations and requirements exist. A consumer explicitly
references a tool ID. The host supplies query orchestration and one resolver;
it never parses a manager's version files, aliases or requested-version syntax.
There are no built-in tool definitions, short-name aliases or tool-name
branches. The generic system scanner is a host provider whose entire scan plan
comes from enabled definitions' `discovery` contributions.

The logical **and wire** method is `toolchains/query`. This independent typed
extension reuses the existing LSP base JSON-RPC transport and ServerProcess
lifecycle, not the language-intelligence domain. A toolchain backend need not
declare a language, language server, Build provider or private callable
function. Initialization offers `experimental.litheToolchains: {versions: [1],
providers: ["mise"]}`; the backend selects `{version: 1, providers: ["mise"]}`.
The host intersects the returned local provider IDs with the verified manifest.
An unoffered version, duplicate/undeclared provider ID, or malformed answer fails
negotiation rather than enabling a partial registry; no query is sent before
negotiation succeeds.
This draft does not upgrade or relax any existing `litheFunctions` version.

An installed, enabled provider requires `toolchains.provide` and explicit
installation review of the programs it may invoke. This permission can affect
which external program the host launches; it is not described as a harmless
filesystem read. Plugin identity, signature/trust, package digest and enabled
state come from the host registry, never from a reply. The provider's stable
identity is `pluginID:providerID`; the unqualified `providerID` on the wire is
bound to that already authenticated session.

## Query and reply

[`query.schema.json`](query.schema.json) defines JSON-RPC envelopes. A request
contains `operationID`, `generation`, `providerID`, `authority`, `context`,
`workspace`, and `tools`. The host round generation also applies to global-only
queries, which have no workspace context. Tools are unique and sorted by ID. `workspace: null` asks only about
global state. Otherwise `workspace.root` is the absolute native root in the
query's authority, `rootID` is the host's opaque identity, and `directory` is
the directory being resolved relative to that root (`.` for the root). A
non-null workspace requires the existing `{contextID, generation}` host context
reference. These native paths are transient machine-local bindings, not portable
project identities. The opened workspace, not its containing repository, sets
the default scope.

The host queries the intersection of requested tool IDs and the provider's
declared `tools`. IDs with no enabled definition may still be queried for
display-only requirement diagnostics. They cannot create installations, exports,
launches or tool rows. IDs outside that intersection are discarded entirely.
A failed or empty provider reply is not proof that there is no requirement.

A successful result echoes `operationID`, `generation` and `providerID`, then returns:

| Field | Meaning |
| --- | --- |
| `installations` | `{tool, version, home}` for external installations; `home` is absolute, `version` is provider display data, not a manager selector interpreted by Core. |
| `statements` | `{tool, scope, source, request, installation, kind, reader}` requirements; `request` is opaque, `installation` is a listed home or `null` for unmet. |
| `watch` | Absolute native input paths to fingerprint, including absent inputs and installation roots. This does not authorize reading contents, executing or writing these paths. |

`scope` is `project` or `global`; `source` is the absolute originating file.
`kind` is `environment` or `declaration`. Wrappers are separate `projectFile`
candidates supplied by the tool definition, never provider installations.
`reader` is `native` or `compatible`, matching that file's declared
`watchFiles[].reader`; a backend cannot claim native ownership arbitrarily.
If more than one enabled provider declares native ownership of the same source,
the host reports an unresolved conflict rather than sorting plugin IDs.

For a project statement, match the declared watch pattern relative to each
candidate source-directory anchor, with at most 64 ancestors of the requested
native directory considered. The matching anchor determines project specificity,
not the source file's physical parent: `.mise/config.toml` at `/project` belongs
to `/project`, not `/project/.mise`. If more than one pattern/anchor matches the
same canonical source, use the nearest matching anchor and then native-reader
precedence; indistinguishable conflicting claims remain explicit conflicts.
An upstream may identify an enclosing project file above the opened workspace;
its absolute source is evidence only and never expands the workspace identity
or the editable pins scope. Global sources need not be ancestors. A global-only
query cannot return project statements. `installation: null` means the manager
knows the request but cannot supply a usable installed choice. The host does not
translate `lts`, `system`, `ref:`, `prefix:` or any other request syntax.

## Validation and limits

The host passes untrusted replies through Core's deterministic shape and policy
validation before publishing them. Native adapters supply canonical paths,
file identities, existence, type and executable evidence; Core must not assume a
string prefix or JSON Schema proves any of these facts. Every candidate is
revalidated before launch to close stale-cache and symlink replacement windows.
The eventual launch adapter retains its existing atomic/native identity checks.

- A reply is at most 1 MiB of UTF-8 JSON: at most 512 installations, 256
  statements and 256 watch paths. Each native path is at most 4096 characters;
  operation/tool/provider identifiers and request strings have schema bounds.
  Oversized replies fail as a whole. Deduplication cannot hide a limit breach.
- Installation homes are absolute directories. Executables come only from the
  enabled tool definition's `executableLayouts`; the provider cannot replace
  them with arbitrary argv, executables or environment variables. The selected
  executable must exist, be a regular executable in the current authority, and
  remain inside the canonical home. Providers return the final tool home;
  `homeLayouts` applies to manual/system discovery inputs, not a second rewrite
  of a provider home.
- Neither a provider installation's canonical home nor its executable may be
  inside any root of the current workspace, including a symlink into a root.
  An unsafe installation rejects the provider reply with `unsafePath`; it is
  not silently promoted to a project wrapper. A provider can report an unmet
  requirement instead of returning a project-contained home.
- A non-null statement installation must reference a validated installation of
  the same tool in this reply. Unknown or disabled definition IDs lose all
  installation authority. Their statements retain only bounded diagnostic facts
  (`tool`, `scope`, `source`, `request`), never a usable path.
- Apply byte/count/string bounds and structural validation before filtering.
  Then discard installation entries without requested, declared and active
  definition IDs **before native filesystem validation**. Only remaining
  installations undergo existence/executable/containment checks. Consequently,
  an unknown tool's unusable home cannot invalidate an otherwise valid reply;
  malformed JSON or a bounds violation still can.
- The host's installed-plugin registry supplies any missing-definition plugin
  name and Enable action. Provider data cannot invent plugin names, install
  links, enable targets or arbitrary commands. Enabling requires user action.
- Paths cannot contain controls, unnormalized parent traversal or mismatched
  authority. Native case and volume rules determine equality and containment;
  do not lowercase all paths. Canonical duplicates are collapsed after bounds
  checking. Missing watch paths are valid; missing installations are not.
- Lists are normalized deterministically: installations by tool, canonical
  home, then version; statements by tool, scope, canonical source, kind, reader,
  request, then installation; watch paths by canonical identity. Sorting is not
  a tie-breaking rule for conflicting provider requirements.

Project wrappers and environments are **project code**, not exceptions to the
provider boundary. A tool definition's `projectFile`/wrapper candidate may
resolve a workspace-contained program only through the consumer's existing
explicit user-action/consent flow (there is no persistent workspace trust state
in the current product). Passive import or opening settings does not
execute wrappers or probe project environments. All resulting selections carry
`projectCode: true`, and automatic background consumers must reject them unless
their existing trust boundary explicitly permits execution. Returning
`kind: environment` from a provider cannot waive this rule.

The new capability's `projectFile.projectKind` is `wrapper` by default or
`environment` with an explicit source-directory-relative `home`. The latter's
`path` must equal that home plus an applicable declared executable layout; no
tool-name or `bin`-parent heuristic supplies a home. Specificity uses the
candidate's source-directory anchor, not the executable's parent directory.
A project-environment candidate can be declared as
`{"kind":"projectFile","projectKind":"environment","home":".venv","path":".venv/bin/python"}`;
the tool's executable layout supplies `bin/python`, not the host.
A wrapper is executable-only and returns `selection.home: null`. It emits no
`${home}` exports or PATH entries; a launch template requiring `${home}` skips
with `homeUnavailable` rather than pretending the repository is an installation.

Project environments may contain executable symlinks (for example a venv's
interpreter link to an external interpreter). This is a distinct project-code
policy, not a provider exception: the lexical home must remain within the
workspace, the lexical program must match its declared layout, and the adapter
must validate the resolved executable and the complete link chain's identities
at the authorized launch boundary. Preserve the declared lexical launch path;
substituting the canonical target can change environment semantics. A changed
link or missing native identity check rejects the launch. No link grants
background execution authority. Without the consumer's explicit-action/consent
admission, skip with `projectCodeRequiresAction`, never `requestedNotInstalled`.

## Query lifecycle, cache and watching

Each query round captures authority, workspace/root/context generation, enabled
definition/provider digests, tool set, environment snapshot and a monotonic
round generation. It queries **every enabled provider** relevant to that round;
each request owns a unique operation ID and JSON-RPC ID. Replies must match
both IDs, round generation and the bound provider. A round publishes one atomic snapshot after
all requests finish, fail, or reach their deadlines. It can preserve a previous
valid snapshot while visibly loading, but cannot label old state as current.
Partial failures stay visible; absence of a reply never means an empty provider.

The default per-query deadline is 5 seconds including backend startup;
host configuration can choose 100-30000 milliseconds. Cancellation sends
`$/cancelRequest` with the JSON-RPC ID and completes local ownership immediately.
An owned backend unresponsive to cancellation gets a bounded 2-second cleanup
grace before the existing process-tree termination path. A shared backend's
unrelated operations are not stopped to cancel one query. Session shutdown,
disable, uninstall or workspace replacement cancels all owned operations and
listeners; callbacks recheck generation before changing any state. Every
operation completes once. A reply after cancellation, timeout, generation
change or provider removal is discarded, never cached or published.

The cache key includes the captured identities above. Its input fingerprint
combines returned `watch` paths with the manifest's `watchFiles` declarations.
The host watches parent directories and the bounded set of matching inputs so
creation, deletion, atomic replacement and rename are observable even when a
file did not exist in the previous reply. Missing/existing, type, identity,
size, modification time and canonical target are fingerprinted; native watcher
events invalidate even if a replacement happens to preserve metadata. A lost
watcher event/overflow invalidates the round rather than claiming the cache is
fresh. No file contents or manager syntax are parsed by this cache.

Manifest patterns have at most eight components and no recursive `**`; matching
is bounded to workspace/context ancestor directories and explicitly returned
absolute watch roots. The host caps each round at 256 watch roots and 4096
enumerated directory entries, not only successful matches; exceeding this
produces a visible limit failure, not a recursive scan
of the user's home. Multiple file events may coalesce in one scheduling turn.
**Any** matching file change invalidates the entire snapshot, cancels a pending
round, and re-queries **all** providers. There are no per-provider or per-tool
incremental updates. Providers remain responsible for returning every external
global/configuration input they read or would consult if created, including
absent inputs during a global-only query. Returning only existing files is not
sufficient to detect the first creation of a higher-priority configuration.

Local and remote authorities never share caches, shell environment, native
paths or providers. The first implementation is local only. A remote request
fails with `authorityUnsupported` until that authority has an actual query and
filesystem adapter. It never probes the local placeholder, shell, local pins
or local installations as a fallback. Static definitions may be reused only as
inert data, not as permission to run a local scanner for a remote workspace.

## One four-layer resolver

[`resolution.schema.json`](resolution.schema.json) describes normalized output,
not a second resolver implementation. Tool definitions supply their ordered
`executables` candidates; the reusable executable resolver extends its existing
`skip`, `resolved`, `terminalFailure` result. `setting.layer` distinguishes
project pins from application defaults; `toolchain.scope` is `project`,
`global`, or `installed`. Existing per-owner candidate ordering and insertion
rules remain; a consumer cannot reorder another plugin's candidate set or move
a lower layer above a pin. The following layer order is invariant:

| Layer | Selection and failure behavior |
| --- | --- |
| 1 Fixed | Nearest ancestor pin for this directory and tool; invalid/missing/unexecutable/probe-failing/incompatible nonempty pin is `terminalFailure`, never fallback. |
| 2 Project | Nearest originating directory first; within it wrapper > environment > version declaration. For the same source, native reader > compatible reader. Uninstalled requirements are `skip` with a reason, retained as unmet while lower layers continue. |
| 3 Global | Lithe's explicitly saved default > selected provider global statement > login-shell home variable/commands. Conflicting provider globals require user choice; before choosing, skip provider globals and follow login Shell, not plugin-ID order. |
| 4 Automatic | Highest compatible probed installed release from all providers plus the definition-driven system scanner; excludes manual-only registrations. |

Project distance is compared **before** project candidate category: a child
version file beats a wrapper in a more distant parent. After native/compatible
precedence, differing equally specific project statements are an explicit
conflict requiring user choice; while unresolved they skip with a conflict
reason. Equal normalized installations are deduplicated, not conflicts. Chosen
provider identities are application-owned preferences scoped by authority,
workspace/directory and tool, never implicit ID ordering.

Consequently, project sources must expand into one bounded project-layer plan
before its first candidate is attempted. A sequential implementation that
searches every ancestor for the wrapper candidate before considering the next
`toolchain` candidate violates this contract. The existing resolver consumes
the normalized plan; source enumeration is read-only and must not execute or
probe shadowed wrappers/environments to establish their precedence.

The `skip.reason` object is mandatory. `requestedNotInstalled` includes `tool`,
`provider`, `source`, and opaque `request`; `definitionUnavailable` always includes
`tool` and also includes `source` and `request` when it describes an observed
statement rather than an inactive definition or dormant pin. `providerConflict` is accompanied by a
`conflicts` entry listing qualified identities. Reasons are structured facts
rendered through shared i18n, not English sentences assembled in Core. A
successful fallback retains all applicable unmet requirements and conflicts.
Empty layers remain `empty` trace rows; layers masked by success are `shadowed`
and must not be probed just to populate the settings display. Expanders show
only the effective layer by default; Show All exposes the trace without
changing execution behavior. No selection means `skip`, not invented success.

The version probe's declared regular expression supplies a normalized numeric
dotted release in its first capture (at most eight unsigned 32-bit components,
64 characters). Compare components numerically with absent trailing components
as zero; there is no Java-8, `v` prefix, vendor, alias or pre-release special
case. No valid comparable capture means not eligible for automatic selection;
an explicit choice still cannot claim to satisfy a consumer's declared minimum
without a successful probe. The provider's `version` is preserved as display
provenance, never trusted instead of the definition's probe. A wrapper may have
`selection.version: null` until the existing user-authorized execution flow can
probe it; consumers requiring a version cannot treat `null` as compatible.
If the newest normalized release has different canonical homes, automatic
resolution reports `ambiguousInstallation`, an `automatic` conflict listing
the distinct canonical homes, and a `chooseInstallation` action; it requires an
explicit choice; sorting homes or plugin IDs must not silently decide which binary runs.
Multiple reports of the same canonical home are one installation.

Environment exports and PATH prepend entries are generated solely by enabled
definitions using the selected validated home/executable. A failed candidate's
environment is discarded before trying the next. Consumer `requiresTools`,
`launch.tool` and `onToolchainChange` bind directory-scoped usage and explain
whether a switch needs restart, resync or applies next run. Disabling a
definition withdraws its rows, consumers, exports and injected settings page;
it does not delete saved pins. Existing processes do not silently restart.
An executable-only wrapper can export `${executable}`, but cannot export or
prepend paths based on an absent home. Its consumer still owns wrapper-specific
launch arguments; it cannot silently reuse a runtime entry template requiring
installation facts that the wrapper does not provide.

## Local pins and manual installations

[`local.schema.json`](local.schema.json) is an isolated proposed extension of
the machine-local `.lithe/toolchains/local.json`, retaining `version: 1` and
legacy `toolchains` while adding `pins`. It does not modify the active v1
schema or promise that an old host accepts new fields. The implementation phase
must gate writers on the new capability and migrate the corresponding readers
together; it must not write this draft shape for an old reader.

`pins` maps normalized workspace-relative directory keys to tool-ID maps.
`.` is the opened root; absolute keys, backslashes, empty segments, `.`, `..`
segments and trailing separators are rejected. Dotted directory names are valid.
For `apps/web/src`, check that directory, `apps/web`, `apps`, then `.`, never
`apps/website` by string prefix. Each pin stores `{home, version, provider}`;
provider is a qualified identity or the reserved generic `host:manual` /
`host:system`, not a backend activation instruction. An inherited pin applies
until a nearer explicit value replaces it. Removing an override reveals the
ancestor; it does not delete that ancestor or the whole local file.

Opening a project or settings only reads. An edit is a draft until explicit
Save/Apply confirms the target directory, tool and machine-local path. The
platform adapter checks the read revision and rejects stale writes, preserves
unrelated legacy entries/pins and permissions, atomically replaces the file,
then reads it again to display the effective choice. No write on focus loss,
navigation, startup, cancellation or unchanged inherited values. Read failures
are errors, not empty defaults. Reject symlinked local targets and any write
escaping the selected workspace's machine-local store.

The first explicit save adds `/toolchains/local.json` exactly once to
`.lithe/.gitignore`, preserving other content and using conflict protection.
There is no transaction spanning two files: secure the ignore entry before
publishing the new local file; an ignore-write failure aborts the save. If local
file publication fails afterward, the harmless ignore entry may remain and the
draft remains unsaved. Neither target is created merely by opening a project.

Manual Add validates a user-selected directory via `homeLayouts`,
`executableLayouts`, and the declared bounded version probe. It registers the
installation only in platform application storage, outside app bundles,
installed plugin packages and the project. Such registrations can be explicitly
pinned but do not participate in automatic discovery. A workspace-contained
directory is not converted into a trusted external installation by manual Add;
project wrappers/environments retain their separate project-code boundary.
Pins survive plugin disable/uninstall and reactivate only when that definition
is enabled again. No tool is downloaded, installed, trusted or repaired by query.

## Stable failure mapping

These are proposed additions, not assignments in the current runtime. Existing
host-service codes `-32010` through `-32021` keep their meanings. Toolchain
custom failures reserve `-32070` through `-32077` in the server-error range;
each numeric code has exactly one semantic code. JSON-RPC error `data` includes
`code`, `operationID`, and `providerID`; optional details are bounded to 4 KiB
serialized and contain no credentials. Native errors are translated to shared
i18n at the host boundary; plugin diagnostic text remains unmodified but is
not a policy selector. Timeout is not cancellation, and stale replies do not
generate a second completion.

| JSON-RPC | Semantic code | Meaning |
| --- | --- | --- |
| `-32601` | `plugin.toolchain.methodUnavailable` | Query method/capability not negotiated. |
| `-32602` | `plugin.toolchain.invalidParams` | Malformed request or invalid declared input. |
| `-32800` | `plugin.toolchain.cancelled` | Caller cancelled the owned request. |
| `-32070` | `plugin.toolchain.permissionDenied` | Permission/review/enabled-state prerequisite absent. |
| `-32071` | `plugin.toolchain.authorityUnsupported` | No adapter for this authority. |
| `-32072` | `plugin.toolchain.timeout` | Monotonic local deadline exceeded. |
| `-32073` | `plugin.toolchain.providerUnavailable` | Backend failed to start, disconnected, or failed its upstream query. |
| `-32074` | `plugin.toolchain.invalidReply` | Malformed reply or inconsistent same-tool installation reference. |
| `-32075` | `plugin.toolchain.limitExceeded` | Reply/scan/watch budget exceeded. |
| `-32076` | `plugin.toolchain.unsafePath` | Invalid absolute path, containment or executable safety evidence. |
| `-32077` | `plugin.toolchain.operationExpired` | Context/generation was already invalid when a query was dispatched. |

Request-local failures (missing installation, incompatible version, conflicting
requirements) are resolver reasons, not JSON-RPC transport errors. The query
fixture includes the numeric mapping; runtime tests, SDK end-to-end tests and
both native host lifecycle tests are required in later implementation phases.
