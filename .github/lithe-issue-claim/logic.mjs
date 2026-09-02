export const CLAIM_LABEL = 'claimed';
export const STALE_LABEL = 'stale-claim';
export const CLAIM_MARKER = '<!-- lithe-claim:';
export const WARNING_MARKER = '<!-- lithe-claim-warning:';
export const RELEASE_MARKER = '<!-- lithe-claim-release:';
export const CLAIM_TTL_DAYS = 30;
export const WARNING_GRACE_DAYS = 7;

export function parseCommand(body) {
  const command = (body ?? '').trim();
  return command === '/assign' || command === '/unassign' ? command : null;
}

export function isPullRequestIssue(issue) {
  return Boolean(issue?.pull_request);
}

export function isMaintainer(authorAssociation) {
  return ['OWNER', 'MEMBER', 'COLLABORATOR'].includes(authorAssociation);
}

export function claimMarker(login, isoDate) {
  return `${CLAIM_MARKER}${login}:${isoDate} -->`;
}

export function warningMarker(login, isoDate) {
  return `${WARNING_MARKER}${login}:${isoDate} -->`;
}

export function releaseMarker(login, isoDate) {
  return `${RELEASE_MARKER}${login}:${isoDate} -->`;
}

export function isActiveClaim(claim, release) {
  return Boolean(claim && (!release || release.login !== claim.login || new Date(release.isoDate) <= new Date(claim.isoDate)));
}

export function releaseMatchesClaim(release, claim) {
  return Boolean(release && claim && release.login === claim.login && new Date(release.isoDate) > new Date(claim.isoDate));
}

export function needsReleaseRecovery(claim, release, assignees = []) {
  return Boolean(releaseMatchesClaim(release, claim) && assignees.includes(claim.login));
}

export function parseMarker(body, prefix) {
  const match = (body ?? '').match(new RegExp(`${prefix.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}([^: >]+):([^ >]+)`));
  return match ? { login: match[1], isoDate: match[2] } : null;
}

export function daysSince(isoDate, now = new Date()) {
  return (now.getTime() - new Date(isoDate).getTime()) / 86_400_000;
}

export function claimStatus(claim, warning, now = new Date()) {
  if (!claim) return 'unclaimed';
  if (warning) return daysSince(warning.isoDate, now) >= WARNING_GRACE_DAYS ? 'release' : 'stale';
  return daysSince(claim.isoDate, now) >= CLAIM_TTL_DAYS ? 'warn' : 'active';
}

export function hasProgressSince(comments, login, claimDate) {
  return latestProgressDate(comments, login, claimDate) !== null;
}

export function latestProgressDate(comments, login, claimDate) {
  const dates = comments.filter((comment) =>
    comment.user?.login === login &&
    new Date(comment.created_at).getTime() > new Date(claimDate).getTime() &&
    parseCommand(comment.body) === null
  ).map((comment) => comment.created_at);
  return dates.length ? dates.sort().at(-1) : null;
}
