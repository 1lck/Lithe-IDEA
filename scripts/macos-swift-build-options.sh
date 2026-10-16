#!/bin/zsh
# Sourced by SwiftPM entry points; leave local and hosted builds unchanged unless
# a runner explicitly supplies its per-job compilation budget.
LITHE_SWIFT_BUILD_ARGS=()
if [[ -n "${LITHE_SWIFT_BUILD_JOBS:-}" ]]; then
    if [[ ! "$LITHE_SWIFT_BUILD_JOBS" =~ '^[1-9][0-9]*$' ]]; then
        print -u2 -- "LITHE_SWIFT_BUILD_JOBS must be a positive integer"
        return 2
    fi
    LITHE_SWIFT_BUILD_ARGS=(--jobs "$LITHE_SWIFT_BUILD_JOBS")
fi
