// Decision logic for .github/workflows/lithe-issue-form-gate.yml.
// Note: 决策记录见 .agents/notes/implemented/process/2026-10-01-issue-form-enforcement.md

// Each supported Issue Form declares exactly one of these labels in its
// `labels:` list. GitHub applies form labels regardless of the author's
// permission, while labels passed through the REST API or `gh issue create`
// are silently dropped for users without push access, so the label is a
// marker that non-maintainers cannot forge.
export const ISSUE_FORMS = Object.freeze([
  Object.freeze({ label: 'issue-form:bug', template: 'bug_report.yml', title: 'Bug 报告 / Bug report' }),
  Object.freeze({ label: 'issue-form:feature', template: 'feature_request.yml', title: '功能建议 / Feature request' }),
]);

export const ALLOWED_LABELS = Object.freeze(ISSUE_FORMS.map((form) => form.label));

// Hidden marker that identifies the gate's own comment, so a re-run does not
// post a duplicate explanation.
export const GATE_MARKER = '<!-- lithe-issue-form-gate -->';

const MAINTAINER_PERMISSIONS = new Set(['admin', 'maintain', 'write']);

export function labelNames(labels = []) {
  return labels
    .map((label) => (typeof label === 'string' ? label : label?.name))
    .filter(Boolean);
}

// `role_name` reports admin/maintain/write/triage/read or a custom role name;
// the legacy `permission` field still carries the base level for custom roles.
export function isMaintainerPermission(permission) {
  if (!permission) return false;
  return MAINTAINER_PERMISSIONS.has(permission.role_name) || MAINTAINER_PERMISSIONS.has(permission.permission);
}

export function missingAllowedLabels(existingRepoLabels, allowedLabels = ALLOWED_LABELS) {
  const existing = new Set(existingRepoLabels);
  return allowedLabels.filter((label) => !existing.has(label));
}

// Returns { action, reason } where action is:
// - 'allow': the issue stays open;
// - 'close': comment and close the issue;
// - 'skip': the gate cannot decide safely and leaves the issue untouched.
// Every uncertain input fails open so that a form-created issue is never
// closed because of a configuration gap or a transient API failure.
export function decideIssueFormGate({
  issue,
  sender,
  authorPermission,
  missingLabels = [],
  allowedLabels = ALLOWED_LABELS,
}) {
  if (!issue) return { action: 'skip', reason: 'missing-issue' };
  if (issue.pull_request) return { action: 'skip', reason: 'pull-request' };
  if (issue.state && issue.state !== 'open') return { action: 'skip', reason: 'not-open' };
  const author = issue.user?.login;
  if (!author) return { action: 'skip', reason: 'missing-author' };
  // Bot accounts can only create issues here through an app or workflow that
  // a maintainer installed on this repository.
  if (issue.user.type === 'Bot') return { action: 'allow', reason: 'bot-author' };
  // Preserve another actor's transfer or reopen decision. Author reopens
  // still pass through the gate, so closing and reopening cannot bypass it.
  if (sender?.login && sender.login !== author) return { action: 'skip', reason: 'opened-by-another-actor' };
  if (authorPermission === null || authorPermission === undefined) return { action: 'skip', reason: 'permission-unknown' };
  if (isMaintainerPermission(authorPermission)) return { action: 'allow', reason: 'maintainer' };
  const labels = labelNames(issue.labels);
  if (labels.some((label) => allowedLabels.includes(label))) return { action: 'allow', reason: 'issue-form' };
  // Issue Forms cannot apply missing or archived labels. Until every
  // allowed label exists, an unlabeled issue may still come from a form.
  if (missingLabels.length > 0) return { action: 'skip', reason: 'form-labels-missing' };
  return { action: 'close', reason: 'not-from-issue-form' };
}

export function hasGateComment(comments = []) {
  return comments.some((comment) =>
    comment.user?.type === 'Bot' &&
    comment.user?.login === 'github-actions[bot]' &&
    (comment.body ?? '').includes(GATE_MARKER)
  );
}

export function issueFormLinks(serverUrl, owner, repo) {
  const base = `${serverUrl}/${owner}/${repo}/issues/new`;
  return {
    chooser: `${base}/choose`,
    forms: ISSUE_FORMS.map((form) => ({ title: form.title, url: `${base}?template=${encodeURIComponent(form.template)}` })),
  };
}

// The author login comes from GitHub's account model (alphanumerics and
// hyphens); no title or body text is echoed back into the comment.
export function gateComment({ login, serverUrl, owner, repo }) {
  const links = issueFormLinks(serverUrl, owner, repo);
  const formLines = links.forms.map((form) => `- ${form.title}：${form.url}`).join('\n');
  return [
    GATE_MARKER,
    `@${login} 感谢反馈。本仓库要求通过 Issue 表单提交 Issue。这个 Issue 没有经过表单创建（例如空白 Issue，或通过 API、CLI、第三方客户端直接创建），因此已自动关闭。请通过下面的入口重新提交：`,
    '',
    formLines,
    `- 全部模板 / All templates：${links.chooser}`,
    '',
    'Thanks for the report. This repository only accepts issues created from its issue forms. This issue was not created from a form (for example a blank issue, or one created through the API, CLI, or a third-party client), so it was closed automatically. Please resubmit it using one of the links above.',
  ].join('\n');
}
