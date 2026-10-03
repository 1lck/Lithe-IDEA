import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
    determineReviewStatus,
    getReviewLabelChanges,
    hasOutstandingChangesRequestedReviews,
    REVIEW_LABELS,
} from "./pr-review-status.mjs";

const workflowPath = ".github/workflows/lithe-pr-review-status.yml";
const observerWorkflowPath = ".github/workflows/lithe-pr-review-status-observer.yml";
const verificationWorkflowPath = ".github/workflows/verify-pr-review-status.yml";

test("marks a newly ready non-draft PR as waiting for review", () => {
    assert.equal(determineReviewStatus({
        action: "opened",
        eventName: "pull_request",
        draft: false,
    }), REVIEW_LABELS.needsReview);
    assert.equal(determineReviewStatus({
        action: "opened",
        eventName: "pull_request",
        draft: true,
    }), null);
});

test("keeps draft PRs free of review status labels", () => {
    assert.equal(determineReviewStatus({
        action: "converted_to_draft",
        currentLabels: [REVIEW_LABELS.needsReview],
        draft: true,
        eventName: "pull_request",
    }), null);
});

test("moves a PR to waiting for changes after request changes", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        eventName: "pull_request_review",
        reviewState: "changes_requested",
    }), REVIEW_LABELS.needsChanges);
});

test("returns a changed PR to waiting for review only on an explicit request", () => {
    assert.equal(determineReviewStatus({
        action: "synchronize",
        currentLabels: [REVIEW_LABELS.needsChanges],
        eventName: "pull_request",
    }), REVIEW_LABELS.needsChanges);
    assert.equal(determineReviewStatus({
        action: "review_requested",
        currentLabels: [REVIEW_LABELS.needsChanges],
        eventName: "pull_request",
    }), REVIEW_LABELS.needsReview);
});

test("clears review status after approval when no reviewer remains outstanding", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        currentLabels: [REVIEW_LABELS.needsReview],
        eventName: "pull_request_review",
        reviewState: "approved",
    }), null);
    assert.deepEqual(getReviewLabelChanges([REVIEW_LABELS.needsReview], null), {
        add: [],
        remove: [REVIEW_LABELS.needsReview],
    });
});

test("keeps a review request when another requested reviewer is outstanding", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        eventName: "pull_request_review",
        hasOutstandingReviewers: true,
        reviewState: "approved",
    }), REVIEW_LABELS.needsReview);
});

test("keeps another reviewer's changes request after an approval", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        eventName: "pull_request_review",
        reviewState: "approved",
        reviews: [
            {
                id: 1,
                state: "CHANGES_REQUESTED",
                submitted_at: "2026-10-03T11:00:00Z",
                user: { login: "alice" },
            },
            {
                id: 2,
                state: "APPROVED",
                submitted_at: "2026-10-03T11:05:00Z",
                user: { login: "bob" },
            },
        ],
    }), REVIEW_LABELS.needsChanges);
});

test("treats a later review from the same reviewer as the effective state", () => {
    assert.equal(hasOutstandingChangesRequestedReviews([
        {
            id: 1,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        },
        {
            id: 2,
            state: "APPROVED",
            submitted_at: "2026-10-03T11:05:00Z",
            user: { login: "alice" },
        },
    ]), false);
});

test("does not clear the current state for a submitted comment review", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        currentLabels: [REVIEW_LABELS.needsReview],
        eventName: "pull_request_review",
        reviewState: "commented",
    }), REVIEW_LABELS.needsReview);
    assert.equal(determineReviewStatus({
        action: "submitted",
        currentLabels: [REVIEW_LABELS.needsChanges],
        eventName: "pull_request_review",
        reviewState: "commented",
    }), REVIEW_LABELS.needsChanges);
});

test("uses the API review record when a stale event has the same review ID", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        currentLabels: [REVIEW_LABELS.needsChanges],
        currentReview: {
            id: 9,
            state: "changes_requested",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        },
        eventName: "pull_request_review",
        reviewState: "changes_requested",
        reviews: [{
            id: 9,
            state: "dismissed",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        }],
    }), null);
});

test("preserves other changes requests when one reviewer is requested again", () => {
    const reviews = [
        {
            id: 1,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        },
        {
            id: 2,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-10-03T11:05:00Z",
            user: { login: "bob" },
        },
    ];
    assert.equal(determineReviewStatus({
        action: "review_requested",
        eventName: "pull_request",
        hasOutstandingReviewers: true,
        reviews,
        requestedReviewerLogins: ["alice"],
    }), REVIEW_LABELS.needsChanges);
    assert.equal(determineReviewStatus({
        action: "review_requested",
        eventName: "pull_request",
        hasOutstandingReviewers: true,
        reviews: [reviews[0]],
        requestedReviewerLogins: ["alice"],
    }), REVIEW_LABELS.needsReview);
});

test("does not let a delayed old review overwrite a renewed review request", () => {
    assert.equal(determineReviewStatus({
        action: "submitted",
        eventName: "pull_request_review",
        hasOutstandingReviewers: true,
        reviewState: "changes_requested",
        reviews: [{
            id: 1,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        }],
        currentReview: {
            id: 1,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-10-03T11:00:00Z",
            user: { login: "alice" },
        },
        requestedReviewerLogins: ["alice"],
    }), REVIEW_LABELS.needsReview);
});

test("does not let a review comment or code push erase the current state", () => {
    assert.equal(determineReviewStatus({
        action: "commented",
        currentLabels: [REVIEW_LABELS.needsReview],
        eventName: "pull_request_review",
        reviewState: "commented",
    }), REVIEW_LABELS.needsReview);
    assert.equal(determineReviewStatus({
        action: "synchronize",
        currentLabels: [REVIEW_LABELS.needsChanges],
        eventName: "pull_request",
    }), REVIEW_LABELS.needsChanges);
});

test("clears review status when the last review request is removed", () => {
    assert.equal(determineReviewStatus({
        action: "review_request_removed",
        currentLabels: [REVIEW_LABELS.needsReview],
        eventName: "pull_request",
        hasOutstandingReviewers: false,
    }), null);
    assert.equal(determineReviewStatus({
        action: "review_request_removed",
        currentLabels: [REVIEW_LABELS.needsChanges],
        eventName: "pull_request",
        hasOutstandingReviewers: false,
    }), REVIEW_LABELS.needsChanges);
});

test("clears review status when a PR is closed", () => {
    assert.equal(determineReviewStatus({
        action: "closed",
        currentLabels: [REVIEW_LABELS.needsReview],
        eventName: "pull_request",
        pullRequestState: "closed",
    }), null);
});

test("swaps managed labels without changing unrelated labels", () => {
    assert.deepEqual(getReviewLabelChanges([
        "bug",
        REVIEW_LABELS.needsReview,
        "priority:high",
    ], REVIEW_LABELS.needsChanges), {
        add: [REVIEW_LABELS.needsChanges],
        remove: [REVIEW_LABELS.needsReview],
    });
});

test("workflow uses trusted base code and only owns review labels", async () => {
    const workflow = await readFile(workflowPath, "utf8");
    assert.match(workflow, /pull_request_target:/);
    assert.match(workflow, /workflow_run:/);
    assert.match(workflow, /uses: actions\/download-artifact@v4/);
    assert.match(workflow, /ref: \$\{\{ steps\.event\.outputs\.base-sha \}\}/);
    assert.doesNotMatch(workflow, /github\.event\.pull_request\.head\.sha/);
    assert.match(workflow, /github\.rest\.actions\.getWorkflowRun/);
    assert.match(workflow, /workflowRun\.head_sha === pullRequest\.head\?\.sha/);
    assert.match(workflow, /workflowRun\.head_branch === pullRequest\.head\?\.ref/);
    assert.match(workflow, /pullRequestHeadRepository/);
    assert.match(workflow, /workflowPullRequests\.length > 0 && !belongsToWorkflowRun/);
    assert.match(workflow, /github\.rest\.pulls\.getReview/);
    assert.match(workflow, /github\.paginate\(github\.rest\.pulls\.listReviews/);
    assert.match(workflow, /review\.state\?\.toLowerCase\(\)/);
    assert.match(workflow, /env:\n          PULL_REQUEST_NUMBER/);
    assert.match(workflow, /actions: read/);
    assert.match(workflow, /issues: write/);
    assert.match(workflow, /pull-requests: read/);
    assert.match(workflow, /concurrency:/);
    assert.doesNotMatch(workflow, /review:approved/);

    const observerWorkflow = await readFile(observerWorkflowPath, "utf8");
    assert.match(observerWorkflow, /pull_request_review:/);
    assert.match(observerWorkflow, /uses: actions\/upload-artifact@v4/);
    assert.doesNotMatch(observerWorkflow, /issues: write/);
    assert.doesNotMatch(observerWorkflow, /actions\/checkout/);

    const verificationWorkflow = await readFile(verificationWorkflowPath, "utf8");
    assert.match(verificationWorkflow, /rhysd\/actionlint:1\.7\.7/);
});
