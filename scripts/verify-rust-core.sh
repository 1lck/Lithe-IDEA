#!/bin/zsh
# Complete local Rust Core verification. CI runs the two halves separately so
# the Swift-linked checks reuse the Swift tests job's build.
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
"$ROOT_DIR/scripts/verify-rust-core-crates.sh"
"$ROOT_DIR/scripts/verify-rust-core-swift-bridge.sh"

print "Rust Core verification passed: comments, Rust tests, Swift bridge, linked symbols, and Git execution integration"
