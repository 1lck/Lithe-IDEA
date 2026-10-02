#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
node scripts/verify-platform-feature-matrix-change.mjs "$@"
