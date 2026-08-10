#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
COMPOSE_FILE="$ROOT_DIR/docker/database-validation/compose.yaml"
SIDECAR="${LITHE_DB_SIDECAR_EXECUTABLE:-$ROOT_DIR/rust/target/debug/lithe-db-sidecar}"
BIND_ADDRESS="${LITHE_BIND_ADDRESS:-127.0.0.1}"
MARIADB_PORT="${LITHE_MARIADB_PORT:-53307}"
MONGODB_PORT="${LITHE_MONGODB_PORT:-57019}"
REDIS_PORT="${LITHE_REDIS_PORT:-6381}"
DB_PASSWORD="${LITHE_DB_PASSWORD:-lithe_root}"

if [[ ! -x "$SIDECAR" ]]; then
    print -u2 -- "Database sidecar is not executable: $SIDECAR"
    print -u2 -- "Build it with: cargo build --manifest-path $ROOT_DIR/rust/Cargo.toml -p lithe-db-sidecar"
    exit 2
fi

docker compose -f "$COMPOSE_FILE" config --quiet
docker compose -f "$COMPOSE_FILE" up -d mariadb mongodb redis

wait_for_health() {
    local container="$1"
    local attempt
    local health_status
    for attempt in {1..60}; do
        health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)
        if [[ "$health_status" == "healthy" ]]; then
            return 0
        fi
        if [[ "$health_status" == "unhealthy" || "$health_status" == "exited" || "$health_status" == "dead" ]]; then
            docker logs "$container" >&2 || true
            print -u2 -- "$container did not become healthy (status: $health_status)"
            return 1
        fi
        sleep 1
    done
    docker logs "$container" >&2 || true
    print -u2 -- "$container healthcheck timed out"
    return 1
}

wait_for_health lithe-database-validation-mariadb
wait_for_health lithe-database-validation-mongodb
wait_for_health lithe-database-validation-redis
docker compose -f "$COMPOSE_FILE" up --no-deps redis-seed

typeset -g LAST_RESPONSE

request() {
    local request_id="$1"
    local method="$2"
    local params="$3"
    LAST_RESPONSE=$(print -rn -- "{\"id\":\"$request_id\",\"method\":\"$method\",\"params\":$params}" | "$SIDECAR" || true)
    print -r -- "$LAST_RESPONSE"
    print -rn -- "$LAST_RESPONSE" | python3 -c '
import json
import sys
response = json.load(sys.stdin)
if not response.get("ok"):
    error = response.get("error", {})
    code = error.get("code", "unknown")
    message = error.get("message", "unknown error")
    raise SystemExit(f"sidecar request failed: {code}: {message}")
'
}

assert_result_contains() {
    local needle="$1"
    print -rn -- "$LAST_RESPONSE" | python3 -c '
import json
import sys
response = json.load(sys.stdin)
needle = sys.argv[1]
if needle not in json.dumps(response.get("result"), ensure_ascii=False):
    raise SystemExit(f"expected result to contain {needle!r}")
' "$needle"
}

assert_result() {
    local check="$1"
    print -rn -- "$LAST_RESPONSE" | python3 -c '
import json
import sys
response = json.load(sys.stdin)
check = sys.argv[1]
result = response.get("result")
if check == "mariadb_rows":
    rows = result.get("rows", [])
    assert len(rows) == 2 and rows[0]["empty_value"] == "" and rows[0]["nullable_note"] is None
elif check == "mariadb_page":
    assert result.get("totalRows") == 2 and len(result.get("rows", [])) == 1
elif check == "mongo_page":
    assert result.get("totalRows") == 2 and len(result.get("rows", [])) == 2
elif check == "mongo_query":
    assert len(result.get("rows", [])) == 1 and result["rows"][0]["name"] == "中文 / emoji 🚀"
elif check == "redis_scan":
    keys = {item["key"] for item in result.get("keys", [])}
    assert {"profile:42", "session:42", "queue:jobs", "ttl:short"}.issubset(keys)
elif check == "redis_hash":
    assert result["type"] == "hash" and {entry["field"] for entry in result["hashEntries"]} == {"user_id", "locale"}
else:
    raise SystemExit(f"unknown assertion {check!r}")
' "$check"
}

mariadb='{"kind":"mariadb","host":"'$BIND_ADDRESS'","port":'$MARIADB_PORT',"username":"root","password":"'$DB_PASSWORD'","database":"lithe_test"}'
mongodb='{"kind":"mongodb","host":"'$BIND_ADDRESS'","port":'$MONGODB_PORT',"username":"root","password":"'$DB_PASSWORD'","database":"lithe_test"}'
redis='{"kind":"redis","host":"'$BIND_ADDRESS'","port":'$REDIS_PORT',"password":"'$DB_PASSWORD'","database":"0"}'

print -r -- "MariaDB: test connection, metadata, typed values, and pagination"
request mariadb-connect testConnection '{"connection":'$mariadb'}'
request mariadb-tables listTables '{"connection":'$mariadb'}'
assert_result_contains records
request mariadb-columns describeTable '{"connection":'$mariadb',"table":"records"}'
assert_result_contains empty_value
assert_result_contains tiny_value
request mariadb-query query '{"connection":'$mariadb',"sql":"SELECT id, empty_value, nullable_note, flag, tiny_value, amount FROM records ORDER BY id","limit":10}'
assert_result mariadb_rows
request mariadb-page pageTable '{"connection":'$mariadb',"table":"records","limit":1,"offset":1,"sort":[{"column":"id"}]}'
assert_result mariadb_page

print -r -- "MongoDB: test connection, collections, indexes, documents, and filters"
request mongodb-connect testConnection '{"connection":'$mongodb'}'
request mongodb-tables listTables '{"connection":'$mongodb'}'
assert_result_contains items
request mongodb-indexes listIndexes '{"connection":'$mongodb',"table":"items"}'
assert_result_contains items_name_idx
request mongodb-page pageTable '{"connection":'$mongodb',"table":"items","limit":10,"sort":[{"column":"score","descending":true}]}'
assert_result mongo_page
request mongodb-query query '{"connection":'$mongodb',"table":"items","sql":"{\"name\":\"中文 / emoji 🚀\"}","limit":10}'
assert_result mongo_query

print -r -- "Redis: test connection, scan, string/hash/list metadata, and key detail"
request redis-connect testConnection '{"connection":'$redis'}'
request redis-scan redisScan '{"connection":'$redis',"cursor":"0","pattern":"*","count":100,"includeSize":true}'
assert_result redis_scan
request redis-string redisGetKey '{"connection":'$redis',"key":"profile:42"}'
assert_result_contains 'Alice / demo'
request redis-hash redisGetKey '{"connection":'$redis',"key":"session:42"}'
assert_result redis_hash
request redis-list redisGetKey '{"connection":'$redis',"key":"queue:jobs"}'
assert_result_contains 'list'

print -r -- "Database validation smoke passed. Containers remain running for manual Lithe verification."
