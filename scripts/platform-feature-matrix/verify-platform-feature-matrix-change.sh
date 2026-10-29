#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
node scripts/platform-feature-matrix/verify-platform-feature-matrix-change.mjs "$@"
