#!/usr/bin/env node
// Gate helper for lanes whose result is reused from an earlier run of the same
// pull request (see plan-ci-lane-reuse.mjs). A reused job that already passed
// is accepted; one that is still running is awaited with a deadline; anything
// else fails the gate, so a reused result never counts unless it succeeded.
import { pathToFileURL } from 'node:url';

const POLL_MS = 30_000;

export async function verifyReusedJobs({ reuse, repository, token, apiURL = 'https://api.github.com', fetchImpl = fetch,
  timeoutMs = 90 * 60_000, pollMs = POLL_MS, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)), now = () => Date.now(), log = console }) {
  const deadline = now() + timeoutMs;
  const failures = [];
  for (const [lane, source] of Object.entries(reuse)) {
    for (;;) {
      const response = await fetchImpl(`${apiURL}/repos/${repository}/actions/jobs/${source.job_id}`, {
        headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'X-GitHub-Api-Version': '2022-11-28' },
        signal: AbortSignal.timeout(20000),
      });
      if (!response.ok) {
        failures.push(`${lane}: could not read reused job ${source.job_id} (GitHub API ${response.status})`);
        break;
      }
      const job = await response.json();
      if (job.status === 'completed') {
        if (job.conclusion === 'success') log.log(`${lane}: reused result passed (${job.html_url ?? source.url})`);
        else failures.push(`${lane}: reused job ${job.html_url ?? source.job_id} concluded ${job.conclusion}; push again or re-run all jobs to run the lane`);
        break;
      }
      if (now() >= deadline) {
        failures.push(`${lane}: reused job ${job.html_url ?? source.job_id} did not finish before the gate deadline`);
        break;
      }
      log.log(`${lane}: waiting for reused job ${job.html_url ?? source.job_id} (${job.status})`);
      await sleep(pollMs);
    }
  }
  return failures;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const reuse = JSON.parse(process.env.LITHE_CI_REUSE || '{}');
  const failures = await verifyReusedJobs({ reuse, repository: process.env.GITHUB_REPOSITORY, token: process.env.GITHUB_TOKEN,
    apiURL: process.env.GITHUB_API_URL || 'https://api.github.com' });
  for (const failure of failures) console.log(`::error title=Reused CI result::${failure}`);
  process.exit(failures.length ? 1 : 0);
}
