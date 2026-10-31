# Toolchain manifest contributions (proposal)

**Status: full proposal, not a claim of native host support.** The implemented
Core subset is specified by [the active contract](../../toolchains.md). This
document follows the
[final scope of PR #1581](https://github.com/1lck/Lithe-IDEA/pull/1581#issuecomment-6541366112).
It is a host contract draft, not a plugin author tutorial. The current manifest
schema now admits only that subset; generic consumer/runtime migration remains
unsupported. Do not install these projection examples as `plugin.json`.

[`manifest-contributions.schema.json`](manifest-contributions.schema.json) is a
standalone **review projection**, not a replacement manifest schema and not an
`allOf` extension of the current closed schema. Its `proposalVersion`, `pluginID`
and `consumers` envelope fields organize fixtures; they are not new production
manifest fields. `toolDefinitions`, `toolchainProviders`, and the consumer fields
below would be integrated into the existing manifest only when Core and the
corresponding host adapters implement and advertise the capabilities. The
production `schemaVersion: 2` and existing API levels are not changed by this
proposal. A future implementation must not silently accept these fields under an
older capability.

## Three contributors, one tool registry

| Contributor | Owns | Does not own |
| --- | --- | --- |
| Tool definition | Identity, executable layout, version probe, bounded discovery, candidate order, exported environment, argv launch template | Version-manager aliases, private configuration formats, provider priority rules |
| Toolchain provider | Installed tools and project/global requirements, computed by its own backend or upstream manager | Tool definitions, arbitrary command replacement, host UI or resolver code |
| Consumer | Explicit tool references and minimum versions, directory, response to a changed selection | Discovery paths, alternate secret selection chains |

There are **no host-owned tool definitions, built-in definition data files,
short-name aliases, or tool-name switches**. Java support defines `java`; a Maven
plugin defines `maven`. Node, Python and other official plugins migrate only when
they supply their own definitions. This draft does not remove existing behavior
or authorize new hardcoded fallbacks during that staged migration.

The enabled registry is populated from installed, enabled plugins. A namespaced
definition ID is `<own-plugin-id>:<local-id>`; a plugin cannot define another
plugin's namespace. Short IDs such as `java` are reserved for packages whose
official identity the **host independently verified during installation**. A
manifest's vendor or signature-policy text is not evidence of that identity.
Community providers may answer short IDs; defining and answering are different
authorities. The first registered owner of an ID remains the owner; a later
duplicate is rejected, never used as an override. Stable enumeration order makes
diagnostics reproducible, not a priority policy for conflicting runtime facts.

## Proposed capability admission

The names and versions here are review assignments, not host advertisements:

| Capability | Required exactly when |
| --- | --- |
| `toolDefinitions: 1` | The plugin contributes definitions |
| `toolchainProviders: 1` | The plugin contributes providers |
| `executableResolution: 2` | A definition uses the new shared candidate projection, including `toolchain` or `setting.layer` |
| `toolchainConsumers: 1` | A consumer uses generic tool references and change policy |
| Existing `backend: 2`, `serverProcess: 1` | A provider uses the plugin's backend |

Each actual contribution still declares its existing language/build/run/debug
capabilities and permissions. The review envelope lists only capabilities relevant
to this proposal. Missing **or unused** capabilities are rejected, just as the
current manifest contract requires. There is no broad new API-level increment to
pretend that an unimplemented launch adapter supports the draft.

## Tool definitions

The [Java-support-style projection](fixtures/java-tool-definition.json) supplies
the tool name and every executable policy. Its short ID is valid only in an
independently official installation context; the fixture itself is not signed.

| Field | Draft meaning and limits |
| --- | --- |
| `id`, `displayName`, `icon` | Tool ID, one-line label of at most 64 characters, and existing shared `uiIcon` format; normal icon package checks still apply |
| `executableLayouts` | 1-8 exact tool-home-relative executable paths, optionally filtered by platform, in fallback order; native executable checks apply |
| `executables` | 1-32 **resolver candidates**, not executable filenames; see below |
| `version` | 1-8 flag-shaped literal probe arguments and a Rust-regex-compatible expression of at most 512 bytes; first capture yields the normalized version |
| `homeLayouts` | At most 8 ordered, single-component name matches mapping a selected installation directory to `.` or a relative home suffix; for example `*.jdk` maps to `Contents/Home` |
| `discovery` | At most 16 bounded scans with root `home`, named `environment`, or an absolute system directory; the host executes data, not a tool-specific scanner |
| `homeVariable`, `commands` | Metadata identifying the login-shell input and 1-8 bare commands belonging to this tool |
| `wrappers` | At most 8 exact project-relative wrapper paths, required marker files, and platform filters |
| `exports` | At most 16 unique environment names, each assigned exactly `${home}` or `${executable}` |
| `pathPrepend` | At most 8 paths under `${home}`; no traversal, shell interpolation, or replacement of PATH |
| `launch` | At most 32 argv tokens; the first is exactly `${executable}` |

`homeLayouts` applies only when normalizing a manual selection or a system
discovery match. A provider's `installations[].home` is already the final tool
home; applying a layout again could append the same suffix twice.

`executableLayouts` and `executables` deliberately have different roles. The first
locates the executable **within an already chosen installation**. The second
selects which source may supply that installation or executable. A candidate does
not gain permission to launch a same-named command for another tool.

`homeVariable`, `commands`, and `wrappers` are checked metadata for the same
candidate plan, **not alternate discovery or launch paths**: every `environment`
candidate must use the declared home variable and one declared executable layout;
every `command` must belong to `commands`; every wrapper `projectFile` must match
one wrapper, including its `requires` markers and platform applicability. A
`projectFile` with `projectKind: "environment"` instead declares its own exact
`path`, `requires` markers and mandatory project-relative `home`; its path must
equal that home plus an applicable executable layout. It is not a wrapper or
an external provider installation. Conversely,
declared wrappers and shell inputs must have their corresponding candidate(s).
Any mismatch rejects the definition, so the UI and resolver cannot drift. Only
the candidate plan is executed. An implementation may normalize these references
to one internal representation; it must not maintain two independent pipelines.

### Version probing and argv safety

The first version capture must match `[0-9]+(?:\.[0-9]+){0,7}`, at most 64 bytes.
Core compares unsigned numeric components, padding absent trailing components
with zeros. The Java fixture's optional `1.` prefix is declared by that plugin:
`1.8.0_422` produces `8.0`, while `21.0.4` produces `21.0.4`. The host has no Java
8 branch. Provider display text is provenance; auto-selection uses the validated
probe capture, not a parsed alias such as `temurin-21`.

The host caps probe stdout and stderr at 64 KiB each, applies a 5-second monotonic
deadline, and cancels the child tree on timeout or cancellation. A failed probe
does not provide a sortable version. It cannot satisfy a consumer's minimum
version by assumption. Equal normalized versions with distinct homes are shown
as an explicit ambiguity requiring a choice; no plugin ID or directory name wins.

Arguments match `-x`/`--long-flag` shape only; no positional commands, `=value`,
scripts, or environment templates. This is a syntax restriction, **not proof that
an executable is side-effect-free**. Installation review must list each executable,
probe arguments, scan roots, export names, and provider backend the package can
run. A future tool whose upstream version command cannot satisfy this restriction
needs a reviewed generic extension; do not add a tool-name exception.

Launch is an argv vector, never a shell command. `${home}`, `${executable}` and
`${entry}` are whole scalar tokens; `${runtimeArguments}` and `${arguments}` are
whole-token list expansions, at most once each. No inline interpolation, unknown
variable, shell evaluation, shell launcher, or empty executable is allowed.
`${entry}` is independently validated inside the consumer package. Empty argument
lists expand to zero tokens. Arguments and paths with spaces remain single argv
elements. On Windows the existing platform argv-quoting adapter owns native
serialization; the plugin cannot supply shell quoting.

Exports reject `PATH`, `DYLD_*`, and `LD_*` names. Existing host process-environment
filtering still applies; the permission does not authorize injecting credentials,
loader variables or arbitrary environment expressions. `pathPrepend` is checked
after canonicalization: symlinks may not escape the selected home. Exports from a
rejected candidate never leak into the next candidate's environment.

## One candidate resolver, four product layers

The draft extends the
[existing candidate model](../../README.md#shared-executable-candidates-executableresolution-1)
rather than building a second runtime resolver:

- `setting` gains mandatory `layer: "project" | "global"` in this projection.
  `settingID: "executable"` names a generic framework slot, not a plugin private
  path-setting ID. Project values come from nearest-ancestor `pins`; global values
  are Lithe-owned application preferences. An invalid nonempty fixed/default
  value is `terminalFailure`, never an automatic fallback.
- `toolchain` gains `scope: "project" | "global" | "installed"`. The tool is the
  containing definition; a candidate cannot inject facts for a different ID.
- Existing `projectFile`, `environment`, `command`, and `runtime` source kinds
  retain their source meanings; `runtime` references an explicit tool ID and
  dependency cycles are rejected. A `projectFile` only runs through the existing
  consumer trust/explicit-user-action boundary, never passive discovery/probing.
- Under the new capability only, `projectFile.projectKind` distinguishes
  `wrapper` (default, executable-only) from `environment` (explicit `home`). A
  wrapper produces `home: null`; it never invents a tool home from the workspace
  root. The environment's home and program are relative to the candidate's
  source-directory anchor, which also determines project specificity. The
  existing `environment` kind still means an external login-shell variable,
  not a project environment. Old executable-resolution v1 is unchanged.
- IDs, signed priority, insertion anchors, deterministic topological ordering,
  platform filtering, and validation of the whole set remain the current model.
  Anchors cannot cross contributions or plugins. Consumer adjustments apply only
  to their own candidate set, not to another tool's definition or global registry.

The normalized candidate list must preserve these four barriers:

1. Fixed: nearest ancestor pin in the chosen directory, invalid means terminal.
2. Project: nearest applicable directory, then wrapper > environment > declaration;
   for the same source file native reader > compatible reader. Equal claims are
   an explicit unresolved conflict, not an ID-based tie-break. Uninstalled requests
   return `skip` **with structured reason**, and remain visible as unsatisfied.
3. Global: Lithe default > unambiguous provider global > login shell. Conflicting
   provider globals require a user choice; until then, skip them with a conflict
   reason and use login-shell candidates. No hidden provider-ID precedence.
4. Automatic: eligible installations reported by providers, including the generic
   system scanner driven only by `discovery`; select the highest valid normalized
   version satisfying the consumer minimum, excluding manually added pin-only homes.

Array order is the default source order inside these barriers. Ordering metadata
must not move candidates across a barrier or reverse project specificity/reader
precedence; such a definition is rejected. Tool definitions may omit unavailable
sources, but cannot silently redefine the four-layer policy. Absence is `skip`,
not a fabricated value. See the adjacent protocol/selection proposal for exact
query results and reason shapes; no current `skip` consumer changes in this stage.

## Providers, file watching, and bootstrap

The [mise projection](fixtures/mise-provider.json) declares `id`, `displayName`,
`tools`, and `watchFiles`. Provider IDs are local to the plugin/session; registry
identity is the pair `(verified pluginID, provider id)`. There are at most eight
providers, each naming 1-32 tool IDs. The query set is the intersection of requested
and declared IDs; this may include dormant IDs solely for requirement diagnostics.
Only its subset with enabled definitions can supply executable candidates.
Dormant unknown IDs do not inject commands; the host may preserve the requirements
as diagnostics so it can offer enabling the installed definition plugin. A
consumer with a missing required definition cannot launch.

`toolchains.provide` means the backend may supply candidates which influence the
program Lithe launches, **not merely read directories**. Its installation review
must say so explicitly. It does not authorize installation/download, network,
trusting workspace code, reading secrets, writing native configuration, or
replacing arbitrary commands. Normal backend permission and sandbox restrictions
continue to apply.

`watchFiles` entries are `{pattern, reader: "native" | "compatible"}`. The host
validates each project statement's source and reader against the declaration;
returned facts cannot promote a compatible reader to native. Native reader
ownership conflicts are explicit and not resolved by plugin registration order.
Patterns are relative, at most eight path components and 256 bytes. Only `*`
inside a single component is supported; no `**`, `?`, classes, braces, traversal,
absolute paths or following a symlink outside the watched root. The host applies
each pattern directly at the selected directory and at most 64 ancestor
directories, including enclosing configuration above the opened workspace; no
recursive `**` scan is implied. Providers also return potential external/global
inputs, including missing paths, in `watch`. Watching an enclosing source does
not expand the workspace identity or editable pin scope. Expansion across the
whole query round is bounded to 256 watch roots and 4,096 enumerated entries,
not just successful matches, as well as the existing workspace scan budget.
Limit hits are reported, never treated as a complete snapshot. The host observes
the parent of missing matches so creation and deletion also invalidate the snapshot.

Any declared watched file or returned absolute input change cancels the generation
and re-queries **all enabled providers**; no mixed-generation incremental result
is published. Remote workspaces query their own authority or are explicitly
unsupported, never the local machine's managers. Providers own private version-file
formats, `lts`, `latest`, `system`, configuration hierarchy and manager semantics.
The host neither parses those files nor independently guesses their precedence.

The provider uses the plugin's existing `backend`; no per-tool process framework
and no LSP language feature is required. It must negotiate the typed toolchain
capability over the existing base JSON-RPC transport before receiving queries.
`toolchainProviders: 1` proposes an additional **host-query startup trigger** for
that backend. Existing `backend: 2` alone does not start the fixture today: its
current view/command/`onWorkspaceOpen` admission rules remain unchanged until this
new capability is implemented. The future host starts at most one backend for
the plugin when it needs a query, not one process per tool or directory; after
startup it negotiates support before dispatch. A query is not an implicit
`onWorkspaceOpen` activation declaration.
The backend is either `launch.kind: "packaged"` (a signed/package-checked native
executable), or `launch.kind: "runtime"` with mandatory `packagedRuntime`. The
latter starts exactly that packaged executable and uses the referenced active
tool definition's argv launch template; it never calls the resolver for its own
runtime. The launch definition must be registered independently of provider
queries and must be available before backend start. Missing definitions or
dependency cycles fail admission/start explicitly. A packaged runtime is not a
host fallback if a definition is disabled. Native packaged executables are the
recommended bootstrap, and are what the mise fixture demonstrates.

Provider backends stay within the current restart-required activation policy.
This proposal does not relax live activation. Disabling/uninstalling cancels
queries, invalidates generations, stops the owned backend, and removes active
definitions, dependent consumer rows, exports, and plugin settings together.
Local pins remain stored for re-enable; dormant pins are not allowed to re-create
an executable definition or export.

## Consumer field projections

`consumers[]` exists only in this review envelope. Its fields project additions
onto existing language-server, build-provider, execution-provider, debug-adapter
or run-configuration contributions:

- `launch.kind: "runtime"` accepts any registered `tool` ID; no `java | node`
  enum or inferred filename mapping remains on the migrated path.
- `runtimeDependencies[].tool` likewise accepts any registered ID, with existing
  uniqueness/no-duplicate-launch-runtime checks retained.
- `requiresTools: [{tool, minimumVersion?}]` explicitly lists every tool a
  consumer uses. `launch.tool` and dependencies must be included, each once.
- `onToolchainChange` is `restart`, `resync`, or `nextRun`; an absent corresponding
  lifecycle adapter makes that contribution unsupported, not silently ignored.

Definitions must be known for a required consumer to launch. A syntactically valid
ID alone grants no authority. If its installed defining plugin is disabled, show
the requirement, known owner, and plugin-page enable action; do not launch a stale
pin. Optional provider facts for missing definitions remain diagnostic data only.

The environment/source page skeleton renders only enabled registry data, scoped
to each directory/module. Tool/plugin-specific settings are contributed on that
plugin's settings page. Manually added homes live in platform application storage,
can only be pinned, never enter auto-selection, and are validated through the
same declared layouts/probe before a confirmed pin is written.

## Validation boundaries and fixtures

The standalone schema proves shape and bounded syntax only. Registry semantics
also check capability exactness, ownership, references, candidate graph/layers,
regular-expression validity, version captures, metadata consistency and template
usage. The native host separately proves verified signature provenance, package
containment, canonical paths, executable status, workspace exclusion, cancellation
and limits. None of those checks can be replaced by JSON Schema.

[`manifest-rejections.json`](fixtures/manifest-rejections.json) separates these
phases. Each case applies RFC 6902 `patch` to its `base`; `context` is **host test
input**, never a plugin field. `phase: "schema"` must fail schema validation;
`registry` and `hostTrust` cases intentionally remain valid JSON shape and describe
the later semantic rejection. Codes reuse existing `plugin.manifest.invalid`,
`plugin.permission.undeclared`, and `plugin.template.invalid` categories; `reason`
is structured diagnostic detail, not a second numeric JSON-RPC error mapping.
These are proposed acceptance/rejection vectors, not tests of current Core.

The implementation stage must add executable Core and host tests before declaring
support, then run both SDK end-to-end suites for actual backend protocol changes.
After merging contract changes, synchronize the byte-for-byte mirror using
`node scripts/contract.mjs sync --revision <merged-preview-commit>` in
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs); do not hand-edit
the mirror or place SDK parsing helpers in the Lithe host.
