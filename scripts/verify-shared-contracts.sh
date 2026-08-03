#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

for fixture in shared/fixtures/**/*.json; do
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$fixture"
done

print "Shared contract verification passed: JSON fixtures are valid"
