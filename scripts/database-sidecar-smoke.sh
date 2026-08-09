#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SIDECAR="${LITHE_DB_SIDECAR_EXECUTABLE:-$ROOT_DIR/rust/target/debug/lithe-db-sidecar}"

if [[ ! -x "$SIDECAR" ]]; then
    print -u2 -- "Database sidecar is not executable: $SIDECAR"
    exit 2
fi

response=$(print -rn -- '{"id":"smoke","method":"capabilities","params":{}}' | "$SIDECAR")
for database_type in mysql postgresql sqlite; do
    if ! print -r -- "$response" | grep -q '"'$database_type'"'; then
        print -u2 -- "Capabilities did not include $database_type."
        exit 1
    fi
done
for feature in transactionalCrud csvImportExport jsonImportExport; do
    if ! print -r -- "$response" | grep -q '"'$feature'"'; then
        print -u2 -- "Capabilities did not include $feature."
        exit 1
    fi
done
print -r -- "$response"
