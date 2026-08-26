#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";

import {
    buildReviewPrompt,
    buildReviewScope,
    extractIssueReferences,
    isAuthorizedReviewTrigger,
    isAuthorizedReviewer,
    parseAllowedReviewers,
} from "./prepare-lithe-pr-review.mjs";

test("classifies large reviews and excludes low-signal files from the entry list", () => {
    const changedFiles = [
        { filename: "windows/src/editor.ts", status: "modified", additions: 40, deletions: 5, changes: 45 },
        { filename: "macos/Sources/App.swift", status: "modified", additions: 4, deletions: 2, changes: 6 },
        { filename: "windows/icons/folder.svg", status: "modified", additions: 1, deletions: 1, changes: 2 },
        { filename: "Cargo.lock", status: "modified", additions: 20, deletions: 20, changes: 40 },
        { filename: "docs/new.md", previous_filename: "docs/old.md", status: "renamed", additions: 0, deletions: 0, changes: 0 },
    ];
    const scope = buildReviewScope({ changed_files: 120, additions: 15_000, deletions: 6_000 }, changedFiles);

    assert.equal(scope.mode, "large");
    assert.equal(scope.inventoryComplete, false);
    assert.deepEqual(
        scope.selectedSemanticFiles.map((file) => file.filename),
        ["windows/src/editor.ts", "macos/Sources/App.swift"],
    );
    assert.deepEqual(scope.lowSignalCounts, {
        assetOrBinary: 1,
        generatedOrLock: 1,
        renameOnly: 1,
    });
});

test("caps the semantic entry list for a large pull request", () => {
    const changedFiles = Array.from({ length: 300 }, (_, index) => ({
        filename: `windows/src/file-${String(index).padStart(3, "0")}.ts`,
        status: "modified",
        additions: index,
        deletions: 0,
        changes: index,
    }));
    const scope = buildReviewScope({ changed_files: 300, additions: 30_000, deletions: 0 }, changedFiles);

    assert.equal(scope.selectedSemanticFiles.length, 240);
    assert.equal(scope.omittedSemanticFileCount, 60);
    assert.equal(scope.selectedSemanticFiles[0].filename, "windows/src/file-299.ts");
});

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

test("allows the pull request author to review a pull request targeting preview", () => {
    const reviewers = parseAllowedReviewers('["maintainer"]', "owner");
    const pullRequest = {
        base: { ref: "preview" },
        user: { login: "external-contributor" },
    };

    assert.equal(isAuthorizedReviewTrigger("External-Contributor", reviewers, pullRequest), true);
    assert.equal(isAuthorizedReviewTrigger("someone-else", reviewers, pullRequest), false);
});

test("does not extend pull request author authorization beyond the preview branch", () => {
    const reviewers = parseAllowedReviewers('["maintainer"]', "owner");
    const pullRequestAuthor = { user: { login: "external-contributor" } };

    assert.equal(isAuthorizedReviewTrigger(
        "external-contributor",
        reviewers,
        { ...pullRequestAuthor, base: { ref: "main" } },
    ), false);
    assert.equal(isAuthorizedReviewTrigger(
        "external-contributor",
        reviewers,
        { ...pullRequestAuthor, base: { ref: "preview/0.3.0" } },
    ), false);
    assert.equal(isAuthorizedReviewTrigger(
        "maintainer",
        reviewers,
        { ...pullRequestAuthor, base: { ref: "main" } },
    ), true);
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
        instructions: "Review instructions. Return review_markdown.",
        repository: "1lck/Lithe-IDEA",
        pullRequest: {
            number: 456,
            title: "Fix cancellation",
            body: "Fixes #123",
            base: { ref: "preview", sha: "base123" },
            head: { ref: "fix/cancellation", sha: "head456" },
            changed_files: 2,
            additions: 12,
            deletions: 3,
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
        changedFiles: [
            { filename: "macos/Sources/Feature.swift", status: "modified", additions: 12, deletions: 3, changes: 15 },
            { filename: "macos/Resources/icon.svg", status: "modified", additions: 0, deletions: 0, changes: 0 },
        ],
    });

    assert.match(prompt, /完整的 head 版本/);
    assert.match(prompt, /git show base123:<path>/);
    assert.match(prompt, /git diff base123\.\.\.head456/);
    assert.match(prompt, /标准模式/);
    assert.match(prompt, /macos\/Sources\/Feature\.swift/);
    assert.doesNotMatch(prompt, /macos\/Resources\/icon\.svg.*modified/);
    assert.match(prompt, /Issue #123: Old output is delivered/);
    assert.match(prompt, /Expected behavior/);
    assert.match(prompt, /macOS CI: success/);
    assert.match(prompt, /review_markdown/);
});
