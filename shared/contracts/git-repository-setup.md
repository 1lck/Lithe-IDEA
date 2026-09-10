# Git repository setup

`git.repositorySetup` and `git.initialize` accept `{root, scope: "local" | "global"}`.
`root` is an existing workspace directory. Initialization rejects directories already
inside a working tree or bare repository; it neither stages files nor creates a
commit. Git's configured initial branch is respected.

The response distinguishes `isRepository`, `hasCommits`, and nullable `branch` from
history filtering. It also returns `scope`, nullable `configuredName` / `configuredEmail`
(direct entries in the selected scope), and `effectiveName` / `effectiveEmail`
(normal Git config inheritance, including includes). No credentials are queried.

`git.configureIdentity` accepts `{root, scope, key: "name" | "email", value}`.
Each action writes one field atomically through Git's config lock. `value: null`
explicitly removes that scope's override; an empty string is invalid. Writes are
limited to `user.name` / `user.email`; arbitrary config keys, system config, signing,
credentials, and remote configuration are outside this feature. Local writes require
a repository. Global writes are explicitly selected in Settings and affect other
repositories without their own overrides. Values cannot contain control characters
or angle brackets and are limited to 1024 UTF-8 bytes.

Both products expose identity configuration in Settings, not in Git Log. The Git
empty state links to Settings and distinguishes an uninitialized folder, an unborn
branch, and a history filter with no matches. Workspace/scope switches discard stale
asynchronous results. Each field has its own save/clear action so partial multi-field
success cannot be mistaken for an atomic save.

Settings currently requires an open project directory, including when editing global identity. This provides an explicit repository context for effective configuration and conditional includes. Credentials, signing, arbitrary config keys, and a default-branch editor are outside this contract.
