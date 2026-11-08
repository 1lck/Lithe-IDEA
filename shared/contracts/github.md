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
3. `github.deviceAuthorizationTransition` decides when to poll based on elapsed
   monotonic time and the normalized response. `slowDown` increases the
   interval by five seconds; `pending`, `expired`, and `denied` are explicit.
   Waits stop at the local deadline, and the platform checks the deadline again
   after waking before making another network request. An authorization already
   accepted by the server remains authoritative if the response arrives late.
4. The platform stores an authorized token in Keychain or Credential Manager.
5. `currentUser` validates the token before connected state is published.

An OAuth client secret, personal access token, and GitHub password are never
requested from the user. Tokens are never placed in Rust requests, logs,
fixtures, user defaults, or error details.

The macOS product reads `LitheGitHubOAuthClientID` from `macos/Resources/Info.plist`.
The checked-in public client ID identifies Lithe's product-owned GitHub OAuth
App for every installation. It is not a credential or secret. Development runs
may override it with `LITHE_GITHUB_CLIENT_ID`; an empty configuration leaves
GitHub sign-in unavailable rather than asking the user for a personal token.

## Rust Commands

- `github.parseRemote` accepts `{ "remoteUrl": string }` and supports canonical
  GitHub HTTPS and SSH remotes. It returns `{ "owner", "name" }`.
- `github.requestPlan` accepts an `operation` and typed operation fields. It
  returns `host`, uppercase `method`, absolute `path`, ordered `query`, optional
  JSON `body`, and `requiresAuthentication`.
- `github.normalizeResponse` accepts `operation`, HTTP `status`, and raw UTF-8
  JSON `body`. It returns a normalized value or the standard Core error.
- `github.deviceAuthorizationTransition` accepts `event`, `expiresIn`,
  `interval`, `elapsedMilliseconds`, and optional `suggestedInterval`. It
  returns `action`, `intervalSeconds`, and `waitMilliseconds`; it accepts no
  device code, access token, or other credential. Events and responses are
  specified by `shared/fixtures/github/device-authorization-transition-v1.json`.
  Expiration is bounded to one day and intervals are bounded to that maximum
  lifetime. The maximum cannot cause early polling: by the time it elapses,
  the authorization has expired. This preserves the mandatory cumulative
  `slow_down` delay even after the previous 60-second limit. See
  [RFC 8628 §3.5](https://datatracker.ietf.org/doc/html/rfc8628#section-3.5)
  and [GitHub's device-flow documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).
- `github.pullRequestCheckoutPlan` accepts a pull-request `number`, `headRef`,
  and a `branchExists` fact. It returns the proposed branch, an explicit
  conflict, and ordered actions; see `shared/fixtures/github/pr-checkout-plan-v1.json`.
- `git.pullRequestCheckoutPreview` inspects the repository and returns that
  plan with its current HEAD, symbolic branch, and a process-salted fingerprint
  of the effective origin URL; the URL and its possible credentials are not
  returned. A caller displaying a GitHub repository also provides
  `expectedRepository` so Core verifies that the configured origin still names
  that repository. A conflicting local ref returns `git_branch_exists` before
  prompting. The client presents the
  actions and branch to the user. `git.pullRequestCheckout` rechecks the
  reviewed HEAD, branch, repository and origin fingerprint, plus target-ref conflicts, under the Git write
  lease. It fetches from origin, rechecks after network I/O, and creates the
  local branch without resetting an existing ref. A conflict or changed checkout
  requires a new review, reported as `git_branch_exists` or
  `git_checkout_changed` respectively. Errors after a subprocess may be carried
  in the Git result's `operationError` rather than the outer envelope. External
  Git can still operate outside Lithe's lease.

Supported operations are `deviceCode`, `deviceToken`, `currentUser`,
`listBranches`, `compareBranches`, `listPullRequests`, `getPullRequest`, `createPullRequest`, `updatePullRequest`,
`listPullRequestFiles`, `listPullRequestComments`,
`createPullRequestComment`, `createPullRequestReview`, `mergePullRequest`, and
`updatePullRequestMetadata`.

PR lists are sorted by descending number. Labels, assignees, comments, and
files are deterministically ordered as demonstrated by
`shared/fixtures/github/pull-request-v1.json`.
Branch lists are sorted by branch name and duplicate names are removed before
they cross the Rust boundary. The first page is capped at 100 branches, which
matches the current creation workflow's bounded picker.
Branch comparisons preserve GitHub's commit order and sort changed files by
repository-relative path. Branch names are percent-encoded by Rust Core before
they enter the trusted compare request path.

## Product Scope

The first macOS surface supports connect/disconnect, repository resolution
from `origin`, PR list/detail/create/update, files, conversation comments,
comment creation, review submission, merge/squash/rebase, close/reopen,
labels/assignees, and argument-based checkout of the PR head branch.
Pull-request creation can send the normalized comparison's textual patches and
commit messages to the user's configured AI provider to draft an editable title
and Markdown description. Sensitive-file filtering and the configured diff
character limit are shared with commit-message generation. AI output never
creates or submits a pull request without the user's explicit action.
When the opened workspace has a detached HEAD or commits not present on its
upstream, creation is blocked until the user explicitly publishes the branch.
Rust Core suggests a branch name and likely base branch, validates the name,
and performs the branch creation/push mutation; the platform UI reports that
uncommitted working-tree changes are retained locally and are not part of the
pull request. A failed push retains the new local branch for a safe retry.
Line-level review threads, merge queues, and auto-merge are outside this
contract version.
