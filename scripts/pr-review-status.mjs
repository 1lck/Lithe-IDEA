export const REVIEW_LABELS = Object.freeze({
    needsReview: "review:needs-review",
    needsChanges: "review:needs-changes",
});

export const REVIEW_LABEL_DEFINITIONS = Object.freeze({
    [REVIEW_LABELS.needsReview]: Object.freeze({
        color: "1D76DB",
        description: "等待维护者 review",
    }),
    [REVIEW_LABELS.needsChanges]: Object.freeze({
        color: "FBCA04",
        description: "等待 PR 作者修改",
    }),
});

export const MANAGED_REVIEW_LABELS = Object.freeze(Object.keys(REVIEW_LABEL_DEFINITIONS));

const REVIEW_REQUEST_ACTIONS = new Set([
    "opened",
    "ready_for_review",
    "reopened",
    "review_requested",
]);

function normalizeLabels(labels) {
    return (labels ?? [])
        .map((label) => typeof label === "string" ? label : label?.name)
        .filter(Boolean);
}

export function currentReviewStatus(labels) {
    const currentLabels = normalizeLabels(labels);
    if (currentLabels.includes(REVIEW_LABELS.needsChanges)) {
        return REVIEW_LABELS.needsChanges;
    }
    if (currentLabels.includes(REVIEW_LABELS.needsReview)) {
        return REVIEW_LABELS.needsReview;
    }
    return null;
}

export function determineReviewStatus({
    action,
    draft = false,
    eventName,
    hasOutstandingReviewers = false,
    pullRequestState = "open",
    reviewState = null,
    currentLabels = [],
}) {
    const currentStatus = currentReviewStatus(currentLabels);

    if (pullRequestState === "closed" || action === "closed" || action === "converted_to_draft" || draft) {
        return null;
    }

    if (eventName === "pull_request_review") {
        if (action === "submitted" && reviewState === "changes_requested") {
            return REVIEW_LABELS.needsChanges;
        }
        if (action === "submitted" && reviewState === "approved") {
            return hasOutstandingReviewers ? REVIEW_LABELS.needsReview : null;
        }
        if (action === "dismissed") {
            return REVIEW_LABELS.needsReview;
        }
        return currentStatus;
    }

    if (eventName === "pull_request") {
        if (REVIEW_REQUEST_ACTIONS.has(action)) {
            return REVIEW_LABELS.needsReview;
        }
        if (action === "review_request_removed") {
            if (currentStatus === REVIEW_LABELS.needsChanges) {
                return currentStatus;
            }
            return hasOutstandingReviewers ? REVIEW_LABELS.needsReview : null;
        }
    }

    return currentStatus;
}

export function getReviewLabelChanges(currentLabels, nextStatus) {
    const normalizedLabels = normalizeLabels(currentLabels);
    const desiredLabels = nextStatus ? [nextStatus] : [];
    return {
        add: desiredLabels.filter((label) => !normalizedLabels.includes(label)),
        remove: MANAGED_REVIEW_LABELS.filter((label) =>
            normalizedLabels.includes(label) && !desiredLabels.includes(label)
        ),
    };
}
