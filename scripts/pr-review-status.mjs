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

function normalizeReviewerLogin(reviewer) {
    const login = typeof reviewer === "string" ? reviewer : reviewer?.login;
    return typeof login === "string" && login.length > 0 ? login.toLowerCase() : null;
}

function normalizeReviewState(state) {
    return typeof state === "string" ? state.toLowerCase() : null;
}

function reviewOrder(review) {
    const submittedAt = Date.parse(review?.submitted_at ?? review?.submittedAt ?? "");
    const reviewId = Number(review?.id);
    return [
        Number.isFinite(submittedAt) ? submittedAt : Number.NEGATIVE_INFINITY,
        Number.isFinite(reviewId) ? reviewId : Number.NEGATIVE_INFINITY,
    ];
}

function isReviewAfter(left, right) {
    const leftOrder = reviewOrder(left);
    const rightOrder = reviewOrder(right);
    return leftOrder[0] > rightOrder[0] ||
        (leftOrder[0] === rightOrder[0] && leftOrder[1] >= rightOrder[1]);
}

function latestReviewsByReviewer(reviews) {
    const latestReviews = new Map();
    for (const review of reviews ?? []) {
        const reviewerLogin = normalizeReviewerLogin(review?.user ?? review?.author);
        if (!reviewerLogin) {
            continue;
        }
        const previousReview = latestReviews.get(reviewerLogin);
        if (!previousReview || isReviewAfter(review, previousReview)) {
            latestReviews.set(reviewerLogin, review);
        }
    }
    return latestReviews;
}

function mergeCurrentReview(reviews, currentReview) {
    const reviewHistory = [...(reviews ?? [])];
    if (!currentReview) {
        return reviewHistory;
    }

    const currentReviewId = currentReview.id == null ? null : String(currentReview.id);
    if (currentReviewId && reviewHistory.some((review) => String(review?.id ?? "") === currentReviewId)) {
        return reviewHistory;
    }

    reviewHistory.push(currentReview);
    return reviewHistory;
}

export function hasOutstandingChangesRequestedReviews(reviews = [], requestedReviewerLogins = []) {
    const requestedReviewers = new Set(
        (requestedReviewerLogins ?? [])
            .map(normalizeReviewerLogin)
            .filter(Boolean),
    );

    return [...latestReviewsByReviewer(reviews).entries()].some(([reviewerLogin, review]) =>
        normalizeReviewState(review?.state) === "changes_requested" &&
        !requestedReviewers.has(reviewerLogin)
    );
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
    reviews = [],
    currentReview = null,
    requestedReviewerLogins = [],
    pullRequestState = "open",
    reviewState = null,
    currentLabels = [],
}) {
    const currentStatus = currentReviewStatus(currentLabels);
    const reviewHistory = mergeCurrentReview(reviews, currentReview);
    const hasOutstandingChangesRequested = hasOutstandingChangesRequestedReviews(
        reviewHistory,
        requestedReviewerLogins,
    );
    const reviewSubmittedChangesRequested =
        eventName === "pull_request_review" &&
        action === "submitted" &&
        normalizeReviewState(reviewState) === "changes_requested";
    const hasChangesRequestedState = hasOutstandingChangesRequested ||
        (reviewHistory.length === 0 && reviewSubmittedChangesRequested);

    if (pullRequestState === "closed" || action === "closed" || action === "converted_to_draft" || draft) {
        return null;
    }

    if (eventName === "pull_request_review") {
        const normalizedReviewState = normalizeReviewState(reviewState);
        if (action === "submitted" && normalizedReviewState === "commented") {
            if (currentStatus) {
                return currentStatus;
            }
            if (hasChangesRequestedState) {
                return REVIEW_LABELS.needsChanges;
            }
            return hasOutstandingReviewers ? REVIEW_LABELS.needsReview : null;
        }
        if (action === "submitted" || action === "dismissed") {
            if (hasChangesRequestedState) {
                return REVIEW_LABELS.needsChanges;
            }
            return hasOutstandingReviewers ? REVIEW_LABELS.needsReview : null;
        }
        return currentStatus;
    }

    if (eventName === "pull_request") {
        if (REVIEW_REQUEST_ACTIONS.has(action) && action !== "review_requested") {
            return REVIEW_LABELS.needsReview;
        }
        if (action === "review_requested") {
            return hasChangesRequestedState
                ? REVIEW_LABELS.needsChanges
                : REVIEW_LABELS.needsReview;
        }
        if (action === "review_request_removed") {
            if (hasChangesRequestedState ||
                (reviewHistory.length === 0 && currentStatus === REVIEW_LABELS.needsChanges)) {
                return REVIEW_LABELS.needsChanges;
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
