#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";

import {
    buildReviewPrompt,
    extractIssueReferences,
    isAuthorizedReviewer,
    parseAllowedReviewers,
} from "./prepare-lithe-pr-review.mjs";

test("defaults review authorization to the repository owner", () => {
    const reviewers = parseAllowedReviewers("", "1lck");
    assert.equal(isAuthorizedReviewer("1LCK", reviewers), true);
    assert.equal(isAuthorizedReviewer("external-user", reviewers), false);
});

test("accepts only configured reviewers", () => {
    const reviewers = parseAllowedReviewers('["1lck", "maintainer"]', "owner");
    assert.equal(isAuthorizedReviewer("maintainer", reviewers), true);
    assert.equal(isAuthorizedReviewer("owner", reviewers), false);
});

test("rejects malformed reviewer configuration", () => {
    assert.throws(
        () => parseAllowedReviewers("1lck,maintainer", "owner"),
        /must be a JSON array/,
    );
    assert.throws(
        () => parseAllowedReviewers('["1lck", 42]', "owner"),
        /non-empty GitHub usernames/,
    );
});

test("extracts local closing and mentioned Issues without treating the PR as an Issue", () => {
    const references = extractIssueReferences(
        ["Fixes #123. Related to #98 and other/repo#77. PR #456."],
        "1lck",
        "Lithe-IDEA",
        456,
    );
    assert.deepEqual([...references.entries()], [[123, "closes"], [98, "mentioned"]]);
});

test("builds a prompt with complete revision and Issue context", () => {
    const prompt = buildReviewPrompt({
        instructions: "Review instructions.",
        repository: "1lck/Lithe-IDEA",
        pullRequest: {
            number: 456,
            title: "Fix cancellation",
            body: "Fixes #123",
            base: { ref: "preview/0.3.0", sha: "base123" },
            head: { ref: "fix/cancellation", sha: "head456" },
        },
        triggerComment: { user: { login: "1lck" } },
        issueContexts: [{
            relationship: "closes",
            issue: {
                number: 123,
                title: "Old output is delivered",
                state: "open",
                user: { login: "reporter" },
                labels: [{ name: "bug" }],
                html_url: "https://github.com/1lck/Lithe-IDEA/issues/123",
                body: "Reproduction steps",
            },
            comments: [{ user: { login: "maintainer" }, created_at: "2026-08-20", body: "Expected behavior" }],
        }],
        conversationComments: [],
        reviews: [],
        reviewComments: [],
        checks: [{ name: "macOS CI", conclusion: "success" }],
    });

    assert.match(prompt, /完整的 head 版本/);
    assert.match(prompt, /git show base123:<path>/);
    assert.match(prompt, /git diff base123\.\.\.head456/);
    assert.match(prompt, /Issue #123: Old output is delivered/);
    assert.match(prompt, /Expected behavior/);
    assert.match(prompt, /macOS CI: success/);
});
