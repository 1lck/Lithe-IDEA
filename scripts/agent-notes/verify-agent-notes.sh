#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
cd "$ROOT_DIR"

node scripts/agent-notes/verify-agent-notes.mjs
