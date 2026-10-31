# Plugin-injected toolchains (draft)

> **Status: broader proposal; a Core-only foundation is now implemented.**
> The implemented subset is specified in [the active contract](../../toolchains.md).
> This directory remains a review artifact for
> [PR #1581's replacement plan](https://github.com/1lck/Lithe-IDEA/pull/1581#issuecomment-6541366112).
> It is not an extension of the currently accepted `plugin.json` format.
> The active manifest admits the implemented definition/provider fields, not
> these projection envelopes or the whole proposal. Native runtime selection,
> consumer migration, query transport, persistence and UI remain unimplemented.

## Ownership

A **tool definition** describes a tool's identity, executable layouts, version
probe, discovery locations, launch template, and environment exports. Only an
enabled plugin contributes a definition. The host has no built-in definitions,
reserved-name alias table, or tool-name-dependent launch logic in the proposed
path. Officially signed plugins may define short IDs; community plugins define
IDs in their own plugin namespace and may provide installations for any enabled
definition, including official short IDs. Verified package identity, not a
manifest assertion or ID prefix, establishes official status.

A **toolchain provider** reports installed tools and the project's or user's
requirements. Version-manager configuration, version aliases, and file precedence
remain upstream/provider-owned. The host never interprets opaque version
requests such as `lts`. A **consumer** references a defined tool and declares
whether a changed selection needs a restart, resynchronization, or the next run.
These are independent contributions, not additional language/build requirements.

The host owns a single generic resolver and query client, directory-scoped pins,
and the environment/sources presentation skeleton. Provider-specific settings
are injected through that provider plugin's existing settings page. Definitions
and provider replies are untrusted input; permission to provide toolchains does
not authorize replacing unrelated host commands.

## Review Artifacts

| File | Purpose |
| --- | --- |
| [manifest.md](manifest.md) | Definition, provider, consumer, trust, and capability contribution rules |
| [manifest-contributions.schema.json](manifest-contributions.schema.json) | Standalone draft contribution projection, not a complete plugin manifest |
| [protocol.md](protocol.md) | Query lifecycle, validation, four-layer selection, storage, and stable failures |
| [query.schema.json](query.schema.json) | Query request/reply shapes |
| [resolution.schema.json](resolution.schema.json) | Resolver outcomes and structured reasons |
| [local.schema.json](local.schema.json) | Proposed extension of the machine-local document with directory pins |
| [fixtures/](fixtures/) | Illustrative contributions, queries, resolution outcomes, pins, and rejections |

Schemas describe JSON shape. Signature verification, duplicate-definition
registration, enabled-plugin ownership, path containment, executable evidence,
and lifecycle state require separate semantic validation during implementation.
A shape-valid reply is never sufficient permission to launch a program.
Example filesystem paths are fictional and must not be probed on the reader's
machine; filesystem observations in cases are inputs for future test doubles.

## Required Behavior

Every tool uses the existing shared executable-candidate mechanism, extended
with `toolchain` candidates and structured `skip` reasons. There is no parallel
Java, Maven, or generic-command selection chain in the proposed path.

| Layer | Selection rule |
| --- | --- |
| Pin | Nearest ancestor directory's explicit pin; an unusable pin is a terminal failure, never automatic fallback |
| Project | Nearest declaring directory; at equal depth wrapper before environment before version statement; for the same file native before compatible reader |
| Global | Lithe's explicit global default, then provider defaults; conflicting provider defaults require a user choice, using login-shell discovery until chosen |
| Automatic | Newest eligible provider installation satisfying the minimum version; manually added installations are excluded |

An uninstalled project requirement skips with an explicit reason and stays
visible as unmet even if a lower layer succeeds. Provider installations cannot
come from the workspace; project wrappers remain project code and require the
consumer's existing explicit-action/consent policy. Queries, discovery, settings
inspection, and passive project import must not execute project code.

The built-in **system provider** is a mechanism, not a contributor of definitions:
it scans only enabled definitions' declared locations. Adding a manager or tool
must not require a new parser, directory constant, or tool-name branch in Core.
The first implementation must prove this with two different providers.

Each query has an operation identity, cancellation, a bounded deadline, and a
snapshot generation. New, changed, or deleted declared watch inputs invalidate
the entire generation and requery all enabled providers. Late replies cannot
repopulate revoked state. Disabling/uninstalling the defining plugin removes its
tool rows, consumers, settings, and exports, but retains stored pins for a later
reenable. Unknown/disabled definitions grant no executable authority; only bounded
display diagnostics may remain to explain the missing plugin.

Reading `.lithe/toolchains/local.json` never creates it. Explicitly confirmed pin
edits use conflict-protected atomic replacement, then reread the result; the first
write preserves `.lithe/.gitignore` and adds `/toolchains/local.json`. Manually
added installations live in platform-owned application storage and are pin-only.
Installed app bundles and plugin packages remain read-only throughout.

## Staged Landing And Compatibility

1. **Proposal:** review schemas, examples, trust boundaries, and
   the decision record. No host capability is enabled and no production format
   is relaxed merely by this draft. Only the active contract allocates supported
   Core capability versions; native hosts have not advertised them.
2. **Core and query client:** implement definition/answer validation, candidate
   extensions, pin inheritance, full-generation invalidation, and macOS query
   lifecycle. Preserve strict rejection by unsupported hosts. System discovery
   consumes plugin declarations, never a built-in definition data file.
3. **Selection and UI:** integrate consumers and the environment/sources pages,
   move Java definitions into Java Support and coordinate Maven definitions with
   [PR #1558](https://github.com/1lck/Lithe-IDEA/pull/1558). Remove migrated legacy
   special cases in the same slice. Other tools keep existing behavior until
   their official plugins declare definitions; do not add new compatibility
   aliases or tool-specific branches.
4. **Provider acceptance:** mise delegates to its upstream machine-readable CLI;
   SDKMAN supplies the second, different provider without Core changes. Each
   owns its own settings and bootstrap runtime. Backend-bearing providers still
   require restart in the initial implementation; this proposal does not relax
   live activation.

The existing executable-resolution v1 contract does not permit project tool
overrides and supports only the documented consumer positions. These new
semantics need explicit capability admission and implemented adapters; do not
retroactively change v1 or advertise support based on schema changes alone.
Runtime minimum-version checking must use the definition's version probe rather
than a new per-tool branch. No current API is removed by this proposal.

The Chinese architecture decision and acceptance criteria are recorded in the
[proposed Agent Note](https://github.com/1lck/Lithe-IDEA/blob/preview/.agents/notes/proposed/architecture/2026-10-31-plugin-injected-toolchains.md).
The UI reference is the
[interactive prototype](https://gist.github.com/xiaoyumuxi/2ae889a6592599b13998bc811c647942).
This directory specifies host-readable contracts, not a plugin-author tutorial
or SDK implementation; those belong in `lithe-plugin-docs`.

After the proposal merges, sync the byte-identical contract mirror in
`Lithe-IDEA/lithe-plugin-docs` using
`node scripts/contract.mjs sync --revision <merged-preview-commit>` and commit
there. Draft status must survive the sync. SDK protocol compatibility and both
SDK end-to-end suites become implementation-stage gates; this proposal does not
claim that either SDK already implements these messages.
