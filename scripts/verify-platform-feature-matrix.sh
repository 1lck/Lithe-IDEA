#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
node scripts/generate-platform-feature-matrix.mjs --check
