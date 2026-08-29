import type { GitCommit } from "../types/git.types";

function getGitHubLoginFromEmail(email: string) {
  const match = email
    .trim()
    .toLowerCase()
    .match(/^(?:\d+\+)?([^@]+)@users\.noreply\.github\.com$/);
  return match?.[1] || null;
}

function getGitHubAvatarUrl(login: string) {
  return `https://github.com/${encodeURIComponent(login)}.png?size=64`;
}

export function getGitAuthorAvatarUrl(commit: GitCommit) {
  const commitEmail = commit.email?.trim().toLowerCase() || "";
  const githubLogin = getGitHubLoginFromEmail(commitEmail);
  return githubLogin ? getGitHubAvatarUrl(githubLogin) : null;
}
