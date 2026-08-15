# GitHub Integration Contract

Lithe connects a GitHub identity directly; it does not require or create a
Lithe account. macOS currently implements the platform adapters. A future
Windows implementation consumes the same Rust Core JSON commands.

## Ownership

- Rust Core parses GitHub remotes, validates operation inputs, builds trusted
  request plans, normalizes responses, orders lists, and translates errors.
- Platform adapters execute HTTPS, open the verification page, and store the
  OAuth token in the operating system credential store.
- The service coordinates authorization and pull-request workflows.
- The application feature model owns UI state. Views never receive an OAuth
  token or call GitHub directly.

Rust Core never performs GitHub network I/O. A request plan selects only `api`
(`https://api.github.com`) or `web` (`https://github.com`); platform adapters
must not accept an arbitrary host from application input.

## Authorization

The preferred flow is GitHub OAuth Device Flow:

1. `deviceCode` creates a device authorization request using the configured
   public OAuth client ID and the `repo read:user` scope needed by the supported
   pull-request mutations.
2. The UI displays `userCode` and opens `verificationURI`.
3. `deviceToken` is polled at the returned `interval`. `slowDown` increases the
   interval by five seconds; `pending`, `expired`, and `denied` are explicit.
4. The platform stores an authorized token in Keychain or Credential Manager.
5. `currentUser` validates the token before connected state is published.

An OAuth client secret and GitHub password are never requested or stored.
Development builds may use a manually supplied fine-grained personal access
token when no product OAuth client ID is configured. Tokens are never placed
in Rust requests, logs, fixtures, user defaults, or error details.

The macOS product reads `LitheGitHubOAuthClientID` from `Resources/Info.plist`.
Its checked-in value is intentionally empty until the product's GitHub OAuth
App is provisioned. Development runs may override it with
`LITHE_GITHUB_CLIENT_ID`; an empty configuration keeps Device Flow disabled and
leaves the manual-token connection available.

## Rust Commands

- `github.parseRemote` accepts `{ "remoteUrl": string }` and supports canonical
  GitHub HTTPS and SSH remotes. It returns `{ "owner", "name" }`.
- `github.requestPlan` accepts an `operation` and typed operation fields. It
  returns `host`, uppercase `method`, absolute `path`, ordered `query`, optional
  JSON `body`, and `requiresAuthentication`.
- `github.normalizeResponse` accepts `operation`, HTTP `status`, and raw UTF-8
  JSON `body`. It returns a normalized value or the standard Core error.

Supported operations are `deviceCode`, `deviceToken`, `currentUser`,
`listPullRequests`, `getPullRequest`, `createPullRequest`, `updatePullRequest`,
`listPullRequestFiles`, `listPullRequestComments`,
`createPullRequestComment`, `createPullRequestReview`, `mergePullRequest`, and
`updatePullRequestMetadata`.

PR lists are sorted by descending number. Labels, assignees, comments, and
files are deterministically ordered as demonstrated by
`shared/fixtures/github/pull-request-v1.json`.

## Product Scope

The first macOS surface supports connect/disconnect, repository resolution
from `origin`, PR list/detail/create/update, files, conversation comments,
comment creation, review submission, merge/squash/rebase, close/reopen,
labels/assignees, and argument-based checkout of the PR head branch.
Line-level review threads, merge queues, and auto-merge are outside this
contract version.
