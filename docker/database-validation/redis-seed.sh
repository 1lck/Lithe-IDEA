#!/bin/sh

set -eu

export REDISCLI_AUTH="$REDIS_PASSWORD"

redis-cli -h redis DEL profile:42 cache:empty session:42 queue:jobs ttl:short
redis-cli -h redis SET profile:42 'Alice / demo'
redis-cli -h redis SET cache:empty ''
redis-cli -h redis HSET session:42 user_id 42 locale zh-CN
redis-cli -h redis RPUSH queue:jobs job-1 job-2
redis-cli -h redis SETEX ttl:short 3600 'expires later'
redis-cli -h redis DBSIZE
