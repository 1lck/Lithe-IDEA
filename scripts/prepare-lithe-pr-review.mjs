#!/usr/bin/env node

import { createHash } from "node:crypto";
import { appendFile, readFile, writeFile } from "node:fs/promises";
import process from "node:process";
import { pathToFileURL } from "node:url";

const exactCommand = "@lithe review";

export function parseAllowedReviewers(rawValue, repositoryOwner) {
    if (!rawValue?.trim()) {
        return new Set([repositoryOwner.toLowerCase()]);
    }

    let parsed;
    try {
        parsed = JSON.parse(rawValue);
    } catch (error) {
        throw new Error(`LITHE_ALLOWED_REVIEWERS must be a JSON array: ${error.message}`);
    }

    if (!Array.isArray(parsed) || parsed.some((value) => typeof value !== "string" || !value.trim())) {
        throw new Error("LITHE_ALLOWED_REVIEWERS must be a JSON array of non-empty GitHub usernames");
    }

    return new Set(parsed.map((value) => value.trim().toLowerCase()));
}

export function isAuthorizedReviewer(actor, allowedReviewers) {
    return allowedReviewers.has(actor.toLowerCase());
}

export function extractIssueReferences(texts, owner, repository, pullRequestNumber) {
    const references = new Map();
    const repositoryKey = `${owner}/${repository}`.toLowerCase();
    const closingPattern = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+(?:(?<repository>[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#(?<number>\d+)\b/gi;
    const mentionPattern = /(?:(?<repository>[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#(?<number>\d+)\b/g;

    const addReference = (match, relationship) => {
        const referencedRepository = match.groups?.repository?.toLowerCase();
        const number = Number(match.groups?.number);
        if ((referencedRepository && referencedRepository !== repositoryKey) || number === pullRequestNumber) {
            return;
        }
        const current = references.get(number);
        if (!current || relationship === "closes") {
            references.set(number, relationship);
        }
    };

    for (const text of texts) {
        if (!text) {
            continue;
        }
        for (const match of text.matchAll(closingPattern)) {
            addReference(match, "closes");
        }
        for (const match of text.matchAll(mentionPattern)) {
            addReference(match, "mentioned");
        }
    }

    return references;
}

function formatPerson(person) {
    return person?.login ?? "unknown";
}

function formatComments(comments) {
    if (!comments.length) {
        return "（无）";
    }
    return comments.map((comment) => {
        const location = comment.path
            ? ` · ${comment.path}:${comment.line ?? comment.original_line ?? "unknown line"}`
            : "";
        return [
            `#### ${formatPerson(comment.user)} · ${comment.created_at ?? comment.submitted_at ?? "unknown time"}${location}`,
            comment.body?.trim() || "（空）",
        ].join("\n\n");
    }).join("\n\n");
}

function formatIssue(issue, relationship, comments) {
    const relationshipNames = {
        closes: "关闭关联",
        mentioned: "正文引用",
        "cross-referenced": "交叉引用",
    };
    const labels = issue.labels?.map((label) => typeof label === "string" ? label : label.name).filter(Boolean) ?? [];
    return [
        `### Issue #${issue.number}: ${issue.title}`,
        `关联方式：${relationshipNames[relationship] ?? relationship}`,
        `状态：${issue.state}`,
        `作者：${formatPerson(issue.user)}`,
        `标签：${labels.length ? labels.join(", ") : "（无）"}`,
        `地址：${issue.html_url}`,
        "",
        "#### 正文",
        issue.body?.trim() || "（空）",
        "",
        "#### 评论",
        formatComments(comments),
    ].join("\n");
}

export function buildReviewPrompt({
    instructions,
    repository,
    pullRequest,
    triggerComment,
    issueContexts,
    conversationComments,
    reviews,
    reviewComments,
    checks,
}) {
    const issueText = issueContexts.length
        ? issueContexts.map(({ issue, relationship, comments }) => formatIssue(issue, relationship, comments)).join("\n\n")
        : "未找到原始或相关 Issue。不得虚构 Issue 需求。";
    const checkText = checks.length
        ? checks.map((check) => `- ${check.name}: ${check.conclusion ?? check.status}`).join("\n")
        : "- head 提交暂无 Check Run 结果。";

    return `${instructions.trim()}

## 可信版本信息

- 仓库：${repository}
- Pull Request：#${pullRequest.number}
- Base：${pullRequest.base.ref} @ ${pullRequest.base.sha}
- Head：${pullRequest.head.ref} @ ${pullRequest.head.sha}
- 召唤者：${formatPerson(triggerComment.user)}
- 触发命令：${exactCommand}

当前工作区是完整的 head 版本，base 版本存在于 Git 历史中。使用普通只读工具
检查整个 head 仓库；使用 \`git show ${pullRequest.base.sha}:<path>\` 阅读 base
中的文件；使用 \`git diff ${pullRequest.base.sha}...${pullRequest.head.sha}\`
比较两个完整版本。

## 不可信的 Pull Request 上下文

### 标题

${pullRequest.title}

### 正文

${pullRequest.body?.trim() || "（空）"}

### 对话区评论

${formatComments(conversationComments)}

### 已提交的 Review

${formatComments(reviews.filter((review) => review.body?.trim()))}

### 行级 Review 评论

${formatComments(reviewComments)}

## 不可信的关联 Issue 上下文

${issueText}

## head SHA 上已观察到的 Check Run

${checkText}
`;
}

class GitHubClient {
    constructor({ token, apiUrl = "https://api.github.com" }) {
        this.token = token;
        this.apiUrl = apiUrl.replace(/\/$/, "");
    }

    async request(path, options = {}) {
        const method = options.method ?? "GET";
        const startedAt = performance.now();
        const response = await fetch(`${this.apiUrl}${path}`, {
            ...options,
            headers: {
                Accept: "application/vnd.github+json",
                Authorization: `Bearer ${this.token}`,
                "X-GitHub-Api-Version": "2022-11-28",
                ...options.headers,
            },
        });
        const elapsedMilliseconds = Math.round(performance.now() - startedAt);
        console.log(`[lithe-review] GitHub API ${method} ${path} -> ${response.status} (${elapsedMilliseconds} ms)`);
        if (!response.ok) {
            const detail = await response.text();
            throw new Error(`GitHub API ${response.status} for ${path}: ${detail}`);
        }
        return response.status === 204 ? null : response.json();
    }

    async paginate(path) {
        const values = [];
        for (let page = 1; ; page += 1) {
            const separator = path.includes("?") ? "&" : "?";
            const batch = await this.request(`${path}${separator}per_page=100&page=${page}`);
            values.push(...batch);
            if (batch.length < 100) {
                return values;
            }
        }
    }

    async closingIssueNumbers(owner, repository, pullRequestNumber) {
        const query = `
            query($owner: String!, $repository: String!, $number: Int!) {
                repository(owner: $owner, name: $repository) {
                    pullRequest(number: $number) {
                        closingIssuesReferences(first: 100) { nodes { number } }
                    }
                }
            }
        `;
        const result = await this.request("/graphql", {
            method: "POST",
            body: JSON.stringify({ query, variables: { owner, repository, number: pullRequestNumber } }),
            headers: { "Content-Type": "application/json" },
        });
        if (result.errors?.length) {
            throw new Error(`GitHub GraphQL error: ${JSON.stringify(result.errors)}`);
        }
        return result.data.repository.pullRequest.closingIssuesReferences.nodes.map((issue) => issue.number);
    }
}

async function writeOutput(name, value) {
    const outputPath = process.env.GITHUB_OUTPUT;
    if (!outputPath) {
        throw new Error("GITHUB_OUTPUT is required");
    }
    await appendFile(outputPath, `${name}=${value}\n`);
}

async function main() {
    const required = ["GITHUB_EVENT_PATH", "GITHUB_REPOSITORY", "GH_TOKEN", "LITHE_PROMPT_OUTPUT"];
    for (const name of required) {
        if (!process.env[name]) {
            throw new Error(`${name} is required`);
        }
    }

    const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, "utf8"));
    const [owner, repository] = process.env.GITHUB_REPOSITORY.split("/");
    if (!event.issue?.pull_request || event.comment?.body !== exactCommand) {
        await writeOutput("authorized", "false");
        return;
    }

    const allowedReviewers = parseAllowedReviewers(process.env.LITHE_ALLOWED_REVIEWERS, owner);
    const actor = event.comment.user?.login ?? "";
    if (!actor || !isAuthorizedReviewer(actor, allowedReviewers)) {
        console.warn(`[lithe-review] Ignoring unauthorized trigger from ${actor || "unknown"}`);
        await writeOutput("authorized", "false");
        return;
    }

    console.log(`[lithe-review] Accepted trigger from ${actor} for PR #${event.issue.number}`);

    const client = new GitHubClient({ token: process.env.GH_TOKEN, apiUrl: process.env.GITHUB_API_URL });
    try {
        await client.request(`/repos/${owner}/${repository}/issues/comments/${event.comment.id}/reactions`, {
            method: "POST",
            body: JSON.stringify({ content: "eyes" }),
            headers: { "Content-Type": "application/json" },
        });
        console.log("[lithe-review] Added acknowledgement reaction");
    } catch (error) {
        console.warn(`[lithe-review] Could not add acknowledgement reaction: ${error.message}`);
    }

    const pullRequestNumber = event.issue.number;
    const pullRequest = await client.request(`/repos/${owner}/${repository}/pulls/${pullRequestNumber}`);

    const [conversationComments, reviews, reviewComments, timeline, checkResult, closingIssueNumbers] = await Promise.all([
        client.paginate(`/repos/${owner}/${repository}/issues/${pullRequestNumber}/comments`),
        client.paginate(`/repos/${owner}/${repository}/pulls/${pullRequestNumber}/reviews`),
        client.paginate(`/repos/${owner}/${repository}/pulls/${pullRequestNumber}/comments`),
        client.paginate(`/repos/${owner}/${repository}/issues/${pullRequestNumber}/timeline`),
        client.request(`/repos/${owner}/${repository}/commits/${pullRequest.head.sha}/check-runs?per_page=100`),
        client.closingIssueNumbers(owner, repository, pullRequestNumber),
    ]);

    const issueReferences = extractIssueReferences(
        [pullRequest.body, ...conversationComments.map((comment) => comment.body)],
        owner,
        repository,
        pullRequestNumber,
    );
    for (const number of closingIssueNumbers) {
        issueReferences.set(number, "closes");
    }
    for (const event of timeline) {
        const sourceIssue = event.event === "cross-referenced" ? event.source?.issue : null;
        const sourceRepository = sourceIssue?.repository?.full_name?.toLowerCase();
        if (
            sourceIssue &&
            !sourceIssue.pull_request &&
            (!sourceRepository || sourceRepository === process.env.GITHUB_REPOSITORY.toLowerCase()) &&
            sourceIssue.number !== pullRequestNumber &&
            !issueReferences.has(sourceIssue.number)
        ) {
            issueReferences.set(sourceIssue.number, "cross-referenced");
        }
    }

    const possibleIssueContexts = await Promise.all(
        [...issueReferences.entries()].sort(([left], [right]) => left - right).map(async ([number, relationship]) => {
            try {
                return {
                    relationship,
                    issue: await client.request(`/repos/${owner}/${repository}/issues/${number}`),
                    comments: await client.paginate(`/repos/${owner}/${repository}/issues/${number}/comments`),
                };
            } catch (error) {
                console.warn(`Could not load referenced Issue #${number}: ${error.message}`);
                return null;
            }
        }),
    );
    const issueContexts = possibleIssueContexts.filter((context) => context && !context.issue.pull_request);

    const promptPath = new URL("../.github/lithe-review/review-prompt.md", import.meta.url);
    const instructions = await readFile(promptPath, "utf8");
    const prompt = buildReviewPrompt({
        instructions,
        repository: process.env.GITHUB_REPOSITORY,
        pullRequest,
        triggerComment: event.comment,
        issueContexts,
        conversationComments,
        reviews,
        reviewComments,
        checks: checkResult.check_runs ?? [],
    });
    await writeFile(process.env.LITHE_PROMPT_OUTPUT, prompt, { mode: 0o600 });
    const promptDigest = createHash("sha256").update(prompt).digest("hex");
    console.log(`[lithe-review] Context summary ${JSON.stringify({
        base: `${pullRequest.base.ref}@${pullRequest.base.sha}`,
        head: `${pullRequest.head.ref}@${pullRequest.head.sha}`,
        conversationComments: conversationComments.length,
        reviews: reviews.length,
        reviewComments: reviewComments.length,
        relatedIssues: issueContexts.length,
        checks: checkResult.check_runs?.length ?? 0,
        promptBytes: Buffer.byteLength(prompt),
        promptLines: prompt.split("\n").length,
        promptSha256: promptDigest,
    })}`);
    await writeOutput("authorized", "true");
    await writeOutput("base_sha", pullRequest.base.sha);
    await writeOutput("head_sha", pullRequest.head.sha);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch((error) => {
        console.error(error.stack ?? error.message);
        process.exitCode = 1;
    });
}
