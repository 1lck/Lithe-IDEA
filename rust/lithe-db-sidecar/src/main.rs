mod mongodb_adapter;
mod sqlserver_adapter;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use futures_util::TryStreamExt;
use redis::AsyncCommands;
use reqwest::{Client as HttpClient, Method as HttpMethod, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use sqlx::{
    any::AnyPoolOptions,
    mysql::{MySqlPoolOptions, MySqlRow},
    postgres::{PgPoolOptions, PgRow},
    sqlite::{SqlitePoolOptions, SqliteRow},
    Any, AnyPool, Column, MySql, MySqlPool, PgPool, Postgres, Row, Sqlite, SqlitePool, TypeInfo,
    ValueRef,
};
use std::{
    fs::File,
    io::{self, BufReader, BufWriter, Read, Write},
    process::{Child, Command, Stdio},
    time::Duration,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    id: String,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Serialize)]
struct Response {
    id: String,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

#[derive(Serialize)]
struct ErrorBody {
    code: String,
    message: String,
}

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Connection {
    kind: String,
    #[serde(default)]
    host: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    database: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    ssl: bool,
    #[serde(default)]
    ca_certificate_path: String,
    #[serde(default)]
    server_name: String,
    #[serde(default)]
    ssh_host: String,
    #[serde(default)]
    ssh_port: u16,
    #[serde(default)]
    ssh_username: String,
    #[serde(default)]
    ssh_key_path: String,
    #[serde(default)]
    ssh_local_port: u16,
    #[serde(default)]
    proxy_url: String,
    #[serde(default)]
    read_only: bool,
    #[serde(default)]
    production_protection: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Params {
    connection: Connection,
    #[serde(default)]
    schema: String,
    #[serde(default)]
    table: String,
    #[serde(default)]
    sql: String,
    #[serde(default)]
    values: Vec<Value>,
    #[serde(default = "default_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
    #[serde(default)]
    mutations: Vec<Mutation>,
    #[serde(default)]
    data: String,
    #[serde(default)]
    output_path: String,
    #[serde(default)]
    filters: Vec<Filter>,
    #[serde(default)]
    sort: Vec<Sort>,
    #[serde(default)]
    selected_tables: Vec<String>,
    #[serde(default = "default_true")]
    include_structure: bool,
    #[serde(default = "default_true")]
    include_data: bool,
    #[serde(default)]
    allow_write: bool,
    #[serde(default)]
    confirmed: bool,
    #[serde(default)]
    operation: String,
    #[serde(default)]
    object_kind: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    old_name: String,
    #[serde(default)]
    data_type: String,
    #[serde(default)]
    nullable: bool,
    #[serde(default)]
    default_value: String,
    #[serde(default)]
    index_name: String,
    #[serde(default)]
    index_columns: Vec<String>,
    #[serde(default)]
    constraint_name: String,
    #[serde(default)]
    referenced_table: String,
    #[serde(default)]
    referenced_columns: Vec<String>,
    #[serde(default)]
    explain_format: String,
    #[serde(default)]
    diagnostic_kind: String,
    #[serde(default)]
    statements: Vec<Statement>,
    #[serde(default)]
    cursor: String,
    #[serde(default)]
    pattern: String,
    #[serde(default)]
    count: usize,
    #[serde(default)]
    key: String,
    #[serde(default)]
    value: String,
    #[serde(default)]
    new_key: String,
    #[serde(default)]
    ttl: Option<i64>,
    #[serde(default)]
    entries: Vec<RedisHashEntry>,
    #[serde(default)]
    data_id: String,
    #[serde(default)]
    group: String,
    #[serde(default)]
    content: String,
    #[serde(default)]
    r#type: String,
    #[serde(default)]
    service_name: String,
    #[serde(default)]
    page: u32,
    #[serde(default)]
    page_size: u32,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RedisHashEntry {
    field: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Statement {
    sql: String,
    #[serde(default)]
    values: Vec<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Filter {
    column: String,
    operator: String,
    #[serde(default)]
    value: Value,
    #[serde(default = "default_filter_join")]
    join: String,
}

#[derive(Deserialize)]
struct Sort {
    column: String,
    #[serde(default)]
    descending: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mutation {
    action: String,
    table: String,
    #[serde(default)]
    values: Map<String, Value>,
    #[serde(default)]
    key: Map<String, Value>,
}

type DbResult = Result<Value, (String, String)>;
fn default_limit() -> u32 {
    200
}
fn default_true() -> bool {
    true
}
fn default_filter_join() -> String {
    "and".into()
}

#[tokio::main]
async fn main() {
    sqlx::any::install_default_drivers();
    let response = match read_request() {
        Ok(request) => dispatch(request).await,
        Err(message) => Response::failure("unknown", "invalid_request", message),
    };
    println!(
        "{}",
        serde_json::to_string(&response).expect("serialize response")
    );
    if !response.ok {
        std::process::exit(1);
    }
}

fn read_request() -> Result<Request, String> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())?;
    serde_json::from_str(&input).map_err(|e| format!("Invalid request JSON: {e}"))
}

async fn dispatch(request: Request) -> Response {
    let id = request.id;
    let result = if request.method == "capabilities" {
        Ok(json!({
            "protocolVersion": 1,
            "databaseTypes": ["mysql", "mariadb", "postgresql", "sqlite", "sqlserver", "mongodb", "redis", "nacos"],
            "features": ["testConnection", "schema", "indexes", "foreignKeys", "objects", "schemaChanges", "pagedFilterSort", "transactionalCrud", "query", "explain", "diagnostics", "csvImportExport", "jsonImportExport", "sqlBackupRestore", "writeProtection", "sqlServerDataGrid", "mongoCollections", "mongoDocumentEditor", "redisScan", "redisStringHashEditor", "redisTTL", "redisFlushDatabase", "nacosConfigManagement", "nacosServiceDiscovery"]
        }))
    } else {
        database_method(&request.method, request.params).await
    };
    match result {
        Ok(value) => Response::success(id, value),
        Err((code, message)) => Response::failure(id, code, message),
    }
}

async fn database_method(method: &str, value: Value) -> DbResult {
    let params: Params =
        serde_json::from_value(value).map_err(|e| ("invalid_params".into(), e.to_string()))?;
    match params.connection.kind.as_str() {
        "redis" => redis_method(method, params).await,
        "nacos" => nacos_method(method, params).await,
        "sqlserver" => sqlserver_adapter::method(method, params).await,
        "mongodb" => mongodb_adapter::method(method, params).await,
        _ => sql_database_method(method, params).await,
    }
}

async fn sql_database_method(method: &str, params: Params) -> DbResult {
    let tunnel = open_ssh_tunnel(&params.connection).await?;
    let connection = if tunnel.is_some() {
        params.connection.with_tunnel()?
    } else {
        params.connection.clone()
    };
    let kind = normalized_kind(&connection.kind)?;
    let needs_direct = matches!(
        method,
        "query"
            | "pageTable"
            | "applyChanges"
            | "importCsv"
            | "importJson"
            | "exportCsv"
            | "exportJson"
            | "exportSql"
            | "exportSqlToFile"
            | "schemaChange"
            | "transaction"
    );
    let direct = if needs_direct {
        Some(connect_direct(&connection).await?)
    } else {
        None
    };
    let pool = connect(&connection).await?;
    let result = match method {
        "testConnection" => Ok(json!({"connected": true})),
        "listTables" => list_tables(&pool, kind, &params.schema).await,
        "describeTable" => describe_table(&pool, kind, &params.schema, &params.table).await,
        "listIndexes" => list_indexes(&pool, kind, &params.schema, &params.table).await,
        "listForeignKeys" => list_foreign_keys(&pool, kind, &params.schema, &params.table).await,
        "listObjects" => list_objects(&pool, kind, &params.schema, &params.object_kind).await,
        "query" => {
            query_direct(
                direct.as_ref().unwrap(),
                &params.sql,
                &params.values,
                params.limit,
            )
            .await
        }
        "pageTable" => {
            page_table(
                &pool,
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.table,
                params.limit,
                params.offset,
                &params.filters,
                &params.sort,
            )
            .await
        }
        "execute" => {
            ensure_write_allowed(
                &connection,
                &params.sql,
                params.confirmed,
                params.allow_write,
            )?;
            execute(&pool, &params.sql, &params.values).await
        }
        "applyChanges" => {
            ensure_mutations_allowed(
                &connection,
                &params.mutations,
                params.confirmed,
                params.allow_write,
            )?;
            apply_changes(
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.mutations,
            )
            .await
        }
        "schemaChange" => {
            ensure_write_allowed(
                &connection,
                "ALTER TABLE",
                params.confirmed,
                params.allow_write,
            )?;
            schema_change(direct.as_ref().unwrap(), kind, &params).await
        }
        "explain" => explain(&pool, kind, &params.sql, &params.explain_format).await,
        "diagnostics" => diagnostics(&pool, kind, &params).await,
        "transaction" => {
            ensure_transaction_allowed(
                &connection,
                &params.statements,
                params.confirmed,
                params.allow_write,
            )?;
            run_transaction(direct.as_ref().unwrap(), kind, &params.statements).await
        }
        "exportCsv" => {
            export_csv(
                direct.as_ref().unwrap(),
                &params.sql,
                &params.values,
                params.limit,
            )
            .await
        }
        "exportJson" => {
            export_json(
                direct.as_ref().unwrap(),
                &params.sql,
                &params.values,
                params.limit,
            )
            .await
        }
        "importCsv" => {
            ensure_write_allowed(&connection, "INSERT", params.confirmed, params.allow_write)?;
            import_data(
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.table,
                &params.data,
                "csv",
            )
            .await
        }
        "importJson" => {
            ensure_write_allowed(&connection, "INSERT", params.confirmed, params.allow_write)?;
            import_data(
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.table,
                &params.data,
                "json",
            )
            .await
        }
        "exportSql" => {
            export_sql(
                &pool,
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.selected_tables,
                params.include_structure,
                params.include_data,
                params.limit,
            )
            .await
        }
        "exportSqlToFile" => {
            export_sql_to_file(
                &pool,
                direct.as_ref().unwrap(),
                kind,
                &params.schema,
                &params.selected_tables,
                params.include_structure,
                params.include_data,
                params.limit,
                &params.output_path,
            )
            .await
        }
        "importSql" => {
            ensure_write_allowed(&connection, "RESTORE", params.confirmed, params.allow_write)?;
            import_sql(&pool, &params.data).await
        }
        "importSqlFile" => {
            ensure_write_allowed(&connection, "RESTORE", params.confirmed, params.allow_write)?;
            import_sql_file(&pool, &params.output_path).await
        }
        "restoreSql" => {
            ensure_write_allowed(&connection, "RESTORE", params.confirmed, params.allow_write)?;
            restore_sql(&pool, kind, &params.schema, &params.data).await
        }
        "restoreSqlFile" => {
            ensure_write_allowed(&connection, "RESTORE", params.confirmed, params.allow_write)?;
            restore_sql_file(&pool, kind, &params.schema, &params.output_path).await
        }
        _ => Err(("unknown_method".into(), format!("Unknown method: {method}"))),
    };
    pool.close().await;
    if let Some(direct) = direct {
        direct.close().await;
    }
    if let Some(mut tunnel) = tunnel {
        let _ = tunnel.child.kill();
        let _ = tunnel.child.wait();
    }
    result
}

// MARK: - Redis specialised workspace

async fn redis_method(method: &str, params: Params) -> DbResult {
    let tunnel = open_ssh_tunnel(&params.connection).await?;
    let connection = if tunnel.is_some() {
        params.connection.with_tunnel()?
    } else {
        params.connection.clone()
    };
    let result = redis_method_with_connection(method, &params, &connection).await;
    if let Some(mut tunnel) = tunnel {
        let _ = tunnel.child.kill();
        let _ = tunnel.child.wait();
    }
    result
}

async fn redis_method_with_connection(
    method: &str,
    params: &Params,
    connection: &Connection,
) -> DbResult {
    let mut redis = redis_connect(connection).await?;
    let result = match method {
        "testConnection" => {
            let _: String = redis::cmd("PING")
                .query_async(&mut redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
            Ok(json!({"connected": true}))
        }
        "redisScan" => redis_scan(&mut redis, params, connection).await,
        "redisGetKey" => redis_get_key(&mut redis, &params.key, connection).await,
        "redisSetString" => {
            ensure_specialized_write(
                connection,
                "Update Redis key",
                params.confirmed,
                params.allow_write,
            )?;
            redis_set_string(&mut redis, params, connection).await?;
            Ok(json!({}))
        }
        "redisReplaceHash" => {
            ensure_specialized_write(
                connection,
                "Update Redis hash",
                params.confirmed,
                params.allow_write,
            )?;
            redis_replace_hash(&mut redis, params, connection).await?;
            Ok(json!({}))
        }
        "redisDeleteKey" => {
            ensure_specialized_write(
                connection,
                "Delete Redis key",
                params.confirmed,
                params.allow_write,
            )?;
            require_nonempty(&params.key, "Redis key")?;
            let _: i64 = redis::cmd("DEL")
                .arg(&params.key)
                .query_async(&mut redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
            Ok(json!({}))
        }
        "redisRenameKey" => {
            ensure_specialized_write(
                connection,
                "Rename Redis key",
                params.confirmed,
                params.allow_write,
            )?;
            require_nonempty(&params.key, "Redis key")?;
            require_nonempty(&params.new_key, "New Redis key")?;
            let _: String = redis::cmd("RENAME")
                .arg(&params.key)
                .arg(&params.new_key)
                .query_async(&mut redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
            Ok(json!({}))
        }
        "redisSetTTL" => {
            ensure_specialized_write(
                connection,
                "Update Redis TTL",
                params.confirmed,
                params.allow_write,
            )?;
            require_nonempty(&params.key, "Redis key")?;
            let ttl = params
                .ttl
                .ok_or_else(|| ("invalid_params".into(), "Redis TTL is required".into()))?;
            if ttl < -1 {
                return Err((
                    "invalid_params".into(),
                    "Redis TTL must be -1 or a non-negative number of seconds".into(),
                ));
            }
            if ttl == -1 {
                let _: i64 = redis::cmd("PERSIST")
                    .arg(&params.key)
                    .query_async(&mut redis)
                    .await
                    .map_err(|e| redis_error(e, connection))?;
            } else {
                let _: i64 = redis::cmd("EXPIRE")
                    .arg(&params.key)
                    .arg(ttl)
                    .query_async(&mut redis)
                    .await
                    .map_err(|e| redis_error(e, connection))?;
            }
            Ok(json!({}))
        }
        "redisFlushDatabase" => {
            ensure_specialized_write(
                connection,
                "Clear Redis database",
                params.confirmed,
                params.allow_write,
            )?;
            let _: String = redis::cmd("FLUSHDB")
                .query_async(&mut redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
            Ok(json!({}))
        }
        _ => Err((
            "unknown_method".into(),
            format!("Unknown Redis method: {method}"),
        )),
    };
    result
}

async fn redis_connect(
    connection: &Connection,
) -> Result<redis::aio::MultiplexedConnection, (String, String)> {
    let url = redis_url(connection)?;
    let client = redis::Client::open(url.as_str()).map_err(|e| redis_error(e, connection))?;
    let mut redis = tokio::time::timeout(
        Duration::from_secs(8),
        client.get_multiplexed_tokio_connection(),
    )
    .await
    .map_err(|_| {
        (
            "connection_failed".into(),
            "Redis connection timed out after 8 seconds".into(),
        )
    })?
    .map_err(|e| redis_error(e, connection))?;
    let db = redis_database(connection)?;
    if db != 0 {
        let _: String = redis::cmd("SELECT")
            .arg(db)
            .query_async(&mut redis)
            .await
            .map_err(|e| redis_error(e, connection))?;
    }
    Ok(redis)
}

fn redis_url(connection: &Connection) -> Result<Url, (String, String)> {
    let host = connection.host.trim();
    if host.is_empty() {
        return Err(("invalid_connection".into(), "Redis host is required".into()));
    }
    if !connection.proxy_url.is_empty() && connection.ssh_host.is_empty() {
        return Err((
            "unsupported_proxy".into(),
            "A proxy URL requires an SSH tunnel in the current Redis driver".into(),
        ));
    }
    let scheme = if connection.ssl { "rediss" } else { "redis" };
    let port = if connection.port == 0 {
        6379
    } else {
        connection.port
    };
    let db = redis_database(connection)?;
    let credential = if connection.password.is_empty() {
        String::new()
    } else if connection.username.is_empty() {
        format!(":{}@", urlencoding::encode(&connection.password))
    } else {
        format!(
            "{}:{}@",
            urlencoding::encode(&connection.username),
            urlencoding::encode(&connection.password)
        )
    };
    Url::parse(&format!("{scheme}://{credential}{host}:{port}/{db}")).map_err(|e| {
        (
            "invalid_connection".into(),
            format!("Redis address is invalid: {e}"),
        )
    })
}

fn redis_database(connection: &Connection) -> Result<u32, (String, String)> {
    if connection.database.trim().is_empty() {
        return Ok(0);
    }
    connection.database.trim().parse::<u32>().map_err(|_| {
        (
            "invalid_connection".into(),
            "Redis database index must be a non-negative integer".into(),
        )
    })
}

async fn redis_scan(
    redis: &mut redis::aio::MultiplexedConnection,
    params: &Params,
    connection: &Connection,
) -> DbResult {
    let cursor = if params.cursor.trim().is_empty() {
        0
    } else {
        params.cursor.parse::<u64>().map_err(|_| {
            (
                "invalid_params".into(),
                "Redis scan cursor is invalid".into(),
            )
        })?
    };
    let pattern = if params.pattern.trim().is_empty() {
        "*"
    } else {
        params.pattern.trim()
    };
    let count = params.count.clamp(1, 250);
    let (next_cursor, keys): (u64, Vec<String>) = redis::cmd("SCAN")
        .arg(cursor)
        .arg("MATCH")
        .arg(pattern)
        .arg("COUNT")
        .arg(count)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    let mut summaries = Vec::with_capacity(keys.len());
    for key in keys {
        let kind: String = redis::cmd("TYPE")
            .arg(&key)
            .query_async(redis)
            .await
            .map_err(|e| redis_error(e, connection))?;
        if kind == "none" {
            continue;
        }
        let ttl: i64 = redis::cmd("TTL")
            .arg(&key)
            .query_async(redis)
            .await
            .map_err(|e| redis_error(e, connection))?;
        let size = redis_key_size(redis, &key, &kind, connection).await?;
        summaries.push(json!({"key": key, "type": kind, "ttl": ttl, "size": size}));
    }
    Ok(json!({"keys": summaries, "nextCursor": next_cursor.to_string()}))
}

async fn redis_key_size(
    redis: &mut redis::aio::MultiplexedConnection,
    key: &str,
    kind: &str,
    connection: &Connection,
) -> Result<i64, (String, String)> {
    let command = match kind {
        "string" => "STRLEN",
        "hash" => "HLEN",
        "list" => "LLEN",
        "set" => "SCARD",
        "zset" => "ZCARD",
        "stream" => "XLEN",
        _ => return Ok(0),
    };
    redis::cmd(command)
        .arg(key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))
}

async fn redis_get_key(
    redis: &mut redis::aio::MultiplexedConnection,
    key: &str,
    connection: &Connection,
) -> DbResult {
    require_nonempty(key, "Redis key")?;
    let kind: String = redis::cmd("TYPE")
        .arg(key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    if kind == "none" {
        return Err(("not_found".into(), "The Redis key no longer exists".into()));
    }
    let ttl: i64 = redis::cmd("TTL")
        .arg(key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    let size = redis_key_size(redis, key, &kind, connection).await?;
    let string_value = if kind == "string" {
        Some(
            redis::cmd("GET")
                .arg(key)
                .query_async::<Option<String>>(redis)
                .await
                .map_err(|e| redis_error(e, connection))?
                .unwrap_or_default(),
        )
    } else {
        None
    };
    let hash_entries = if kind == "hash" {
        let pairs: Vec<(String, String)> = redis
            .hgetall(key)
            .await
            .map_err(|e| redis_error(e, connection))?;
        pairs
            .into_iter()
            .map(|(field, value)| json!({"field": field, "value": value}))
            .collect()
    } else {
        Vec::new()
    };
    Ok(
        json!({"key": key, "type": kind, "ttl": ttl, "size": size, "stringValue": string_value, "hashEntries": hash_entries}),
    )
}

async fn redis_set_string(
    redis: &mut redis::aio::MultiplexedConnection,
    params: &Params,
    connection: &Connection,
) -> Result<(), (String, String)> {
    require_nonempty(&params.key, "Redis key")?;
    let prior_ttl: i64 = redis::cmd("PTTL")
        .arg(&params.key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    let _: String = redis::cmd("SET")
        .arg(&params.key)
        .arg(&params.value)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    redis_apply_ttl(redis, &params.key, params.ttl, prior_ttl, connection).await
}

async fn redis_replace_hash(
    redis: &mut redis::aio::MultiplexedConnection,
    params: &Params,
    connection: &Connection,
) -> Result<(), (String, String)> {
    require_nonempty(&params.key, "Redis key")?;
    if params.entries.iter().any(|entry| entry.field.is_empty()) {
        return Err((
            "invalid_params".into(),
            "Redis hash fields cannot be empty".into(),
        ));
    }
    let prior_ttl: i64 = redis::cmd("PTTL")
        .arg(&params.key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    let _: i64 = redis::cmd("DEL")
        .arg(&params.key)
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    if params.entries.is_empty() {
        return Ok(());
    }
    let mut command = redis::cmd("HSET");
    command.arg(&params.key);
    for entry in &params.entries {
        command.arg(&entry.field).arg(&entry.value);
    }
    let _: i64 = command
        .query_async(redis)
        .await
        .map_err(|e| redis_error(e, connection))?;
    redis_apply_ttl(redis, &params.key, None, prior_ttl, connection).await
}

async fn redis_apply_ttl(
    redis: &mut redis::aio::MultiplexedConnection,
    key: &str,
    requested_ttl: Option<i64>,
    prior_ttl: i64,
    connection: &Connection,
) -> Result<(), (String, String)> {
    match requested_ttl {
        Some(-1) => {
            let _: i64 = redis::cmd("PERSIST")
                .arg(key)
                .query_async(redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
        }
        Some(ttl) if ttl >= 0 => {
            let _: i64 = redis::cmd("EXPIRE")
                .arg(key)
                .arg(ttl)
                .query_async(redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
        }
        Some(_) => {
            return Err((
                "invalid_params".into(),
                "Redis TTL must be -1 or a non-negative number of seconds".into(),
            ))
        }
        None if prior_ttl >= 0 => {
            let _: i64 = redis::cmd("PEXPIRE")
                .arg(key)
                .arg(prior_ttl)
                .query_async(redis)
                .await
                .map_err(|e| redis_error(e, connection))?;
        }
        None => {}
    }
    Ok(())
}

fn redis_error(error: redis::RedisError, connection: &Connection) -> (String, String) {
    (
        "redis_error".into(),
        redact(error.to_string(), &connection.password),
    )
}

// MARK: - Nacos specialised workspace

struct NacosClient {
    http: HttpClient,
    base: Url,
    token: Option<String>,
}

async fn nacos_method(method: &str, params: Params) -> DbResult {
    let tunnel = open_ssh_tunnel(&params.connection).await?;
    let connection = if tunnel.is_some() {
        params.connection.with_tunnel()?
    } else {
        params.connection.clone()
    };
    let client = nacos_connect(&connection).await;
    let result = match client {
        Ok(mut client) => nacos_method_with_client(method, &params, &connection, &mut client).await,
        Err(error) => Err(error),
    };
    if let Some(mut tunnel) = tunnel {
        let _ = tunnel.child.kill();
        let _ = tunnel.child.wait();
    }
    result
}

async fn nacos_method_with_client(
    method: &str,
    params: &Params,
    connection: &Connection,
    client: &mut NacosClient,
) -> DbResult {
    match method {
        "testConnection" => {
            let _ = nacos_list_configs(client, connection, "", "", 1, 1).await?;
            Ok(json!({"connected": true}))
        }
        "nacosListConfigs" => {
            nacos_list_configs(
                client,
                connection,
                &params.data_id,
                &params.group,
                normalized_page(params.page),
                normalized_page_size(params.page_size),
            )
            .await
        }
        "nacosGetConfig" => {
            nacos_get_config(client, connection, &params.data_id, &params.group).await
        }
        "nacosPublishConfig" => {
            ensure_specialized_write(
                connection,
                "Publish Nacos configuration",
                params.confirmed,
                params.allow_write,
            )?;
            nacos_publish_config(client, connection, params).await?;
            Ok(json!({}))
        }
        "nacosDeleteConfig" => {
            ensure_specialized_write(
                connection,
                "Delete Nacos configuration",
                params.confirmed,
                params.allow_write,
            )?;
            nacos_delete_config(client, connection, params).await?;
            Ok(json!({}))
        }
        "nacosListServices" => {
            nacos_list_services(
                client,
                connection,
                &params.service_name,
                &params.group,
                normalized_page(params.page),
                normalized_page_size(params.page_size),
            )
            .await
        }
        "nacosListInstances" => {
            nacos_list_instances(client, connection, &params.service_name, &params.group).await
        }
        _ => Err((
            "unknown_method".into(),
            format!("Unknown Nacos method: {method}"),
        )),
    }
}

async fn nacos_connect(connection: &Connection) -> Result<NacosClient, (String, String)> {
    let base = nacos_base_url(connection)?;
    let http = HttpClient::builder()
        .timeout(Duration::from_secs(12))
        .build()
        .map_err(|e| ("connection_failed".into(), e.to_string()))?;
    let mut client = NacosClient {
        http,
        base,
        token: None,
    };
    if !connection.username.trim().is_empty() {
        client.token = Some(nacos_login(&client, connection).await?);
    }
    Ok(client)
}

fn nacos_base_url(connection: &Connection) -> Result<Url, (String, String)> {
    let host = connection.host.trim();
    if host.is_empty() {
        return Err((
            "invalid_connection".into(),
            "Nacos server address is required".into(),
        ));
    }
    if !connection.proxy_url.is_empty() && connection.ssh_host.is_empty() {
        return Err((
            "unsupported_proxy".into(),
            "A proxy URL requires an SSH tunnel in the current Nacos driver".into(),
        ));
    }
    let scheme = if connection.ssl { "https" } else { "http" };
    let port = if connection.port == 0 {
        8848
    } else {
        connection.port
    };
    let mut url = if host.starts_with("http://") || host.starts_with("https://") {
        Url::parse(host).map_err(|e| {
            (
                "invalid_connection".into(),
                format!("Nacos server address is invalid: {e}"),
            )
        })?
    } else {
        Url::parse(&format!("{scheme}://{host}:{port}")).map_err(|e| {
            (
                "invalid_connection".into(),
                format!("Nacos server address is invalid: {e}"),
            )
        })?
    };
    if url.port().is_none() {
        url.set_port(Some(port))
            .map_err(|_| ("invalid_connection".into(), "Nacos port is invalid".into()))?;
    }
    let context = if connection.path.trim().is_empty() {
        "/nacos"
    } else {
        connection.path.trim()
    };
    let context = format!("/{}", context.trim_matches('/'));
    url.set_path(&format!("{context}/"));
    url.set_query(None);
    Ok(url)
}

async fn nacos_login(
    client: &NacosClient,
    connection: &Connection,
) -> Result<String, (String, String)> {
    let form = vec![
        ("username".to_string(), connection.username.clone()),
        ("password".to_string(), connection.password.clone()),
    ];
    let mut errors = Vec::new();
    for path in ["/v1/auth/login", "/v1/auth/users/login"] {
        let response = nacos_request_raw(
            &client.http,
            &client.base,
            HttpMethod::POST,
            path,
            &[],
            Some(&form),
        )
        .await;
        match response {
            Ok(response) if response.status().is_success() => {
                let value: Value = response.json().await.map_err(|e| {
                    (
                        "nacos_auth_failed".into(),
                        format!("Nacos login response is invalid: {e}"),
                    )
                })?;
                if let Some(token) = value
                    .get("accessToken")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    return Ok(token.to_string());
                }
                errors.push("Nacos login response did not contain an access token".to_string());
            }
            Ok(response) => errors.push(nacos_http_error(response, connection).await.1),
            Err(error) => errors.push(error.1),
        }
    }
    Err(("nacos_auth_failed".into(), errors.join("; ")))
}

async fn nacos_list_configs(
    client: &NacosClient,
    connection: &Connection,
    data_id: &str,
    group: &str,
    page: u32,
    page_size: u32,
) -> DbResult {
    let response = nacos_request(
        client,
        HttpMethod::GET,
        "/v1/cs/configs",
        &[
            ("search".to_string(), "blur".to_string()),
            ("dataId".to_string(), data_id.to_string()),
            ("group".to_string(), group.to_string()),
            ("tenant".to_string(), connection.database.clone()),
            ("pageNo".to_string(), page.to_string()),
            ("pageSize".to_string(), page_size.to_string()),
        ],
        None,
    )
    .await?;
    let value = nacos_json(response, connection).await?;
    let items = value.get("pageItems").or_else(|| value.get("items")).and_then(Value::as_array).cloned().unwrap_or_default().into_iter().map(|item| json!({
        "dataId": item.get("dataId").and_then(Value::as_str).unwrap_or_default(),
        "group": item.get("group").or_else(|| item.get("groupName")).and_then(Value::as_str).unwrap_or("DEFAULT_GROUP"),
        "namespace": item.get("tenant").or_else(|| item.get("namespace")).or_else(|| item.get("namespaceId")).and_then(Value::as_str).unwrap_or(&connection.database),
        "type": item.get("type").or_else(|| item.get("configType")).and_then(Value::as_str),
        "md5": item.get("md5").and_then(Value::as_str)
    })).collect::<Vec<_>>();
    let total_count = value
        .get("totalCount")
        .or_else(|| value.get("count"))
        .and_then(Value::as_i64)
        .unwrap_or(items.len() as i64);
    Ok(json!({"items": items, "totalCount": total_count.max(0)}))
}

async fn nacos_get_config(
    client: &NacosClient,
    connection: &Connection,
    data_id: &str,
    group: &str,
) -> DbResult {
    require_nonempty(data_id, "Nacos data ID")?;
    let group = nonempty_or(group, "DEFAULT_GROUP");
    let response = nacos_request(
        client,
        HttpMethod::GET,
        "/v1/cs/configs",
        &[
            ("dataId".to_string(), data_id.to_string()),
            ("group".to_string(), group.to_string()),
            ("tenant".to_string(), connection.database.clone()),
            ("show".to_string(), "all".to_string()),
        ],
        None,
    )
    .await?;
    if !response.status().is_success() {
        return Err(nacos_http_error(response, connection).await);
    }
    let text = response.text().await.map_err(|e| {
        (
            "nacos_error".into(),
            format!("Unable to read Nacos configuration: {e}"),
        )
    })?;
    let parsed = serde_json::from_str::<Value>(&text).ok();
    let content = parsed
        .as_ref()
        .and_then(|value| value.get("content"))
        .and_then(Value::as_str)
        .unwrap_or(&text)
        .to_string();
    Ok(json!({
        "dataId": parsed.as_ref().and_then(|value| value.get("dataId")).and_then(Value::as_str).unwrap_or(data_id),
        "group": parsed.as_ref().and_then(|value| value.get("group")).or_else(|| parsed.as_ref().and_then(|value| value.get("groupName"))).and_then(Value::as_str).unwrap_or(group),
        "namespace": parsed.as_ref().and_then(|value| value.get("tenant")).or_else(|| parsed.as_ref().and_then(|value| value.get("namespace"))).and_then(Value::as_str).unwrap_or(&connection.database),
        "content": content,
        "type": parsed.as_ref().and_then(|value| value.get("type")).or_else(|| parsed.as_ref().and_then(|value| value.get("configType"))).and_then(Value::as_str),
        "md5": parsed.as_ref().and_then(|value| value.get("md5")).and_then(Value::as_str)
    }))
}

async fn nacos_publish_config(
    client: &NacosClient,
    connection: &Connection,
    params: &Params,
) -> Result<(), (String, String)> {
    require_nonempty(&params.data_id, "Nacos data ID")?;
    let group = nonempty_or(&params.group, "DEFAULT_GROUP");
    let mut form = vec![
        ("dataId".to_string(), params.data_id.clone()),
        ("group".to_string(), group.to_string()),
        ("tenant".to_string(), connection.database.clone()),
        ("content".to_string(), params.content.clone()),
    ];
    if !params.r#type.trim().is_empty() {
        form.push(("type".to_string(), params.r#type.clone()));
    }
    let response =
        nacos_request(client, HttpMethod::POST, "/v1/cs/configs", &[], Some(&form)).await?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(nacos_http_error(response, connection).await)
    }
}

async fn nacos_delete_config(
    client: &NacosClient,
    connection: &Connection,
    params: &Params,
) -> Result<(), (String, String)> {
    require_nonempty(&params.data_id, "Nacos data ID")?;
    let group = nonempty_or(&params.group, "DEFAULT_GROUP");
    let response = nacos_request(
        client,
        HttpMethod::DELETE,
        "/v1/cs/configs",
        &[
            ("dataId".to_string(), params.data_id.clone()),
            ("group".to_string(), group.to_string()),
            ("tenant".to_string(), connection.database.clone()),
        ],
        None,
    )
    .await?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(nacos_http_error(response, connection).await)
    }
}

async fn nacos_list_services(
    client: &NacosClient,
    connection: &Connection,
    service_name: &str,
    group: &str,
    page: u32,
    page_size: u32,
) -> DbResult {
    let mut query = vec![
        ("namespaceId".to_string(), connection.database.clone()),
        ("pageNo".to_string(), page.to_string()),
        ("pageSize".to_string(), page_size.to_string()),
    ];
    if !group.trim().is_empty() {
        query.push(("groupNameParam".to_string(), group.to_string()));
    }
    if !service_name.trim().is_empty() {
        query.push(("serviceNameParam".to_string(), service_name.to_string()));
    }
    let response = nacos_request(
        client,
        HttpMethod::GET,
        "/v1/ns/catalog/services",
        &query,
        None,
    )
    .await?;
    let value = nacos_json(response, connection).await?;
    let items = value.get("serviceList").or_else(|| value.get("doms")).and_then(Value::as_array).cloned().unwrap_or_default().into_iter().map(|item| {
        let raw_name = item.get("name").or_else(|| item.get("serviceName")).and_then(Value::as_str).unwrap_or_default();
        let group_name = item.get("groupName").and_then(Value::as_str).unwrap_or_else(|| raw_name.split("@@").next().filter(|_| raw_name.contains("@@")).unwrap_or("DEFAULT_GROUP"));
        let name = raw_name.strip_prefix(&format!("{group_name}@@")).unwrap_or(raw_name);
        json!({"name": name, "group": group_name, "clusterCount": item.get("clusterCount").and_then(Value::as_i64).unwrap_or(0).max(0)})
    }).collect::<Vec<_>>();
    let total_count = value
        .get("count")
        .or_else(|| value.get("totalCount"))
        .and_then(Value::as_i64)
        .unwrap_or(items.len() as i64);
    Ok(json!({"items": items, "totalCount": total_count.max(0)}))
}

async fn nacos_list_instances(
    client: &NacosClient,
    connection: &Connection,
    service_name: &str,
    group: &str,
) -> DbResult {
    require_nonempty(service_name, "Nacos service name")?;
    let mut query = vec![
        ("serviceName".to_string(), service_name.to_string()),
        ("namespaceId".to_string(), connection.database.clone()),
    ];
    if !group.trim().is_empty() {
        query.push(("groupName".to_string(), group.to_string()));
    }
    let response = nacos_request(
        client,
        HttpMethod::GET,
        "/v1/ns/instance/list",
        &query,
        None,
    )
    .await?;
    let value = nacos_json(response, connection).await?;
    let hosts = value
        .get("hosts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(Value::Array(
        hosts
            .into_iter()
            .map(|host| {
                json!({
                    "ip": host.get("ip").and_then(Value::as_str).unwrap_or_default(),
                    "port": host.get("port").and_then(Value::as_i64).unwrap_or(0).max(0),
                    "healthy": host.get("healthy").and_then(Value::as_bool).unwrap_or(false),
                    "enabled": host.get("enabled").and_then(Value::as_bool).unwrap_or(true),
                    "ephemeral": host.get("ephemeral").and_then(Value::as_bool).unwrap_or(true),
                    "clusterName": host.get("clusterName").and_then(Value::as_str)
                })
            })
            .collect(),
    ))
}

async fn nacos_request(
    client: &NacosClient,
    method: HttpMethod,
    path: &str,
    query: &[(String, String)],
    form: Option<&[(String, String)]>,
) -> Result<reqwest::Response, (String, String)> {
    let mut query = query.to_vec();
    if let Some(token) = &client.token {
        query.push(("accessToken".to_string(), token.clone()));
    }
    nacos_request_raw(&client.http, &client.base, method, path, &query, form).await
}

async fn nacos_request_raw(
    http: &HttpClient,
    base: &Url,
    method: HttpMethod,
    path: &str,
    query: &[(String, String)],
    form: Option<&[(String, String)]>,
) -> Result<reqwest::Response, (String, String)> {
    let endpoint = base.join(path.trim_start_matches('/')).map_err(|e| {
        (
            "invalid_connection".into(),
            format!("Nacos endpoint is invalid: {e}"),
        )
    })?;
    let mut request = http.request(method, endpoint).query(query);
    if let Some(form) = form {
        request = request.form(form);
    }
    request
        .send()
        .await
        .map_err(|e| ("nacos_error".into(), format!("Nacos request failed: {e}")))
}

async fn nacos_json(
    response: reqwest::Response,
    connection: &Connection,
) -> Result<Value, (String, String)> {
    if !response.status().is_success() {
        return Err(nacos_http_error(response, connection).await);
    }
    response.json().await.map_err(|e| {
        (
            "nacos_error".into(),
            format!("Nacos response is not valid JSON: {e}"),
        )
    })
}

async fn nacos_http_error(
    response: reqwest::Response,
    connection: &Connection,
) -> (String, String) {
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    (
        "nacos_error".into(),
        redact(
            format!("Nacos server returned {status}: {}", text.trim()),
            &connection.password,
        ),
    )
}

fn normalized_page(page: u32) -> u32 {
    page.max(1)
}
fn normalized_page_size(page_size: u32) -> u32 {
    if page_size == 0 {
        100
    } else {
        page_size.clamp(1, 500)
    }
}
fn nonempty_or<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.trim().is_empty() {
        fallback
    } else {
        value.trim()
    }
}
fn require_nonempty(value: &str, label: &str) -> Result<(), (String, String)> {
    if value.trim().is_empty() {
        Err(("invalid_params".into(), format!("{label} is required")))
    } else {
        Ok(())
    }
}

fn ensure_specialized_write(
    connection: &Connection,
    action: &str,
    confirmed: bool,
    allow_write: bool,
) -> Result<(), (String, String)> {
    if connection.read_only && !allow_write {
        return Err(("read_only".into(), "This connection is read-only".into()));
    }
    if connection.production_protection && !confirmed {
        return Err((
            "write_confirmation_required".into(),
            format!("{action} requires confirmation because production protection is enabled"),
        ));
    }
    Ok(())
}

enum DirectPool {
    MySql(MySqlPool),
    Postgres(PgPool),
    Sqlite(SqlitePool),
}

impl DirectPool {
    async fn close(self) {
        match self {
            Self::MySql(pool) => pool.close().await,
            Self::Postgres(pool) => pool.close().await,
            Self::Sqlite(pool) => pool.close().await,
        }
    }
}

async fn connect_direct(connection: &Connection) -> Result<DirectPool, (String, String)> {
    let url = connection.url()?;
    let error = |error: sqlx::Error| {
        (
            "connection_failed".into(),
            redact(error.to_string(), &connection.password),
        )
    };
    match normalized_kind(&connection.kind)? {
        "mysql" => MySqlPoolOptions::new()
            .max_connections(2)
            .acquire_timeout(Duration::from_secs(8))
            .connect(&url)
            .await
            .map(DirectPool::MySql)
            .map_err(error),
        "postgresql" => PgPoolOptions::new()
            .max_connections(2)
            .acquire_timeout(Duration::from_secs(8))
            .connect(&url)
            .await
            .map(DirectPool::Postgres)
            .map_err(error),
        _ => SqlitePoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(8))
            .connect(&url)
            .await
            .map(DirectPool::Sqlite)
            .map_err(error),
    }
}

fn normalized_kind(kind: &str) -> Result<&str, (String, String)> {
    match kind {
        "mysql" | "mariadb" => Ok("mysql"),
        "postgres" | "postgresql" => Ok("postgresql"),
        "sqlite" => Ok("sqlite"),
        _ => Err((
            "unsupported_database".into(),
            format!("Unsupported database type: {kind}"),
        )),
    }
}

impl Connection {
    fn url(&self) -> Result<String, (String, String)> {
        match normalized_kind(&self.kind)? {
            "sqlite" if self.path.is_empty() => Err((
                "invalid_connection".into(),
                "SQLite path is required".into(),
            )),
            "sqlite" => Ok(format!("sqlite://{}?mode=rwc", self.path)),
            kind if self.host.is_empty() || self.username.is_empty() => Err((
                "invalid_connection".into(),
                format!("Host and username are required for {kind}"),
            )),
            kind => {
                let port = if self.port > 0 {
                    self.port
                } else if kind == "mysql" {
                    3306
                } else {
                    5432
                };
                let scheme = if kind == "mysql" { "mysql" } else { "postgres" };
                if !self.proxy_url.is_empty() && self.ssh_host.is_empty() {
                    return Err((
                        "unsupported_proxy".into(),
                        "A proxy URL requires an SSH tunnel in the current database driver".into(),
                    ));
                }
                let mut query = Vec::new();
                if kind == "postgresql" {
                    query.push(if self.ssl {
                        "sslmode=require".to_string()
                    } else {
                        "sslmode=disable".to_string()
                    });
                    if !self.ca_certificate_path.is_empty() {
                        query.push(format!(
                            "sslrootcert={}",
                            urlencoding::encode(&self.ca_certificate_path)
                        ));
                    }
                    if !self.server_name.is_empty() {
                        query.push(format!("host={}", urlencoding::encode(&self.server_name)));
                    }
                } else if self.ssl {
                    query.push("ssl-mode=REQUIRED".to_string());
                    if !self.ca_certificate_path.is_empty() {
                        query.push(format!(
                            "ssl-ca={}",
                            urlencoding::encode(&self.ca_certificate_path)
                        ));
                    }
                }
                let suffix = if query.is_empty() {
                    String::new()
                } else {
                    format!("?{}", query.join("&"))
                };
                Ok(format!(
                    "{scheme}://{}:{}@{}:{port}/{}{suffix}",
                    urlencoding::encode(&self.username),
                    urlencoding::encode(&self.password),
                    self.host,
                    self.database
                ))
            }
        }
    }

    fn with_tunnel(&self) -> Result<Self, (String, String)> {
        if self.ssh_local_port == 0 {
            return Err((
                "invalid_ssh_tunnel".into(),
                "SSH local port is required when using a tunnel".into(),
            ));
        }
        let mut connection = self.clone();
        connection.host = "127.0.0.1".into();
        connection.port = self.ssh_local_port;
        Ok(connection)
    }
}

struct SshTunnel {
    child: Child,
}

async fn open_ssh_tunnel(connection: &Connection) -> Result<Option<SshTunnel>, (String, String)> {
    if connection.ssh_host.is_empty() {
        return Ok(None);
    }
    if connection.ssh_username.is_empty() || connection.ssh_local_port == 0 {
        return Err((
            "invalid_ssh_tunnel".into(),
            "SSH host, username, and local port are required".into(),
        ));
    }
    let target_port = if connection.port > 0 {
        connection.port
    } else {
        match connection.kind.as_str() {
            "mysql" | "mariadb" => 3306,
            "sqlserver" => 1433,
            "mongodb" => 27017,
            "redis" => 6379,
            "nacos" => 8848,
            _ => 5432,
        }
    };
    let target = format!("{}:{target_port}", connection.host);
    let destination = format!("{}@{}", connection.ssh_username, connection.ssh_host);
    let mut command = Command::new("ssh");
    command
        .arg("-N")
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-L")
        .arg(format!("{}:{}", connection.ssh_local_port, target))
        .arg("-p")
        .arg(
            if connection.ssh_port == 0 {
                22
            } else {
                connection.ssh_port
            }
            .to_string(),
        );
    if !connection.ssh_key_path.is_empty() {
        command.arg("-i").arg(&connection.ssh_key_path);
    }
    if !connection.proxy_url.is_empty() {
        command
            .arg("-o")
            .arg(format!("ProxyCommand={}", connection.proxy_url));
    }
    let mut child = command
        .arg(destination)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| ("ssh_tunnel_failed".into(), error.to_string()))?;
    tokio::time::sleep(Duration::from_millis(180)).await;
    if let Some(status) = child
        .try_wait()
        .map_err(|error| ("ssh_tunnel_failed".into(), error.to_string()))?
    {
        return Err((
            "ssh_tunnel_failed".into(),
            format!("SSH tunnel exited with status {status}"),
        ));
    }
    Ok(Some(SshTunnel { child }))
}

async fn connect(connection: &Connection) -> Result<AnyPool, (String, String)> {
    AnyPoolOptions::new()
        .max_connections(2)
        .acquire_timeout(Duration::from_secs(8))
        .connect(&connection.url()?)
        .await
        .map_err(|e| {
            (
                "connection_failed".into(),
                redact(e.to_string(), &connection.password),
            )
        })
}

async fn list_tables(pool: &AnyPool, kind: &str, schema: &str) -> DbResult {
    let sql = match kind {
        "mysql" => "SELECT table_name AS table_name, CAST(table_type AS CHAR) AS table_type FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name",
        "postgresql" => "SELECT CAST(table_name AS TEXT) AS table_name, CAST(table_type AS TEXT) AS table_type FROM information_schema.tables WHERE table_schema = $1 ORDER BY table_name",
        _ => "SELECT name AS table_name, type AS table_type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
    };
    let mut q = sqlx::query(sql);
    if kind == "postgresql" {
        q = q.bind(if schema.is_empty() { "public" } else { schema });
    }
    rows_value(q.fetch_all(pool).await.map_err(db_error)?)
}

async fn describe_table(pool: &AnyPool, kind: &str, schema: &str, table: &str) -> DbResult {
    validate_identifier(table)?;
    let sql = match kind {
        "mysql" => "SELECT column_name AS column_name, CAST(data_type AS CHAR) AS data_type, CAST(is_nullable AS CHAR) AS is_nullable, CAST(column_default AS CHAR) AS column_default, CAST(column_key AS CHAR) AS column_key FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position".to_string(),
        "postgresql" => r#"SELECT CAST(c.column_name AS TEXT) AS column_name, CAST(c.data_type AS TEXT) AS data_type,
            CAST(c.is_nullable AS TEXT) AS is_nullable, CAST(c.column_default AS TEXT) AS column_default,
            CASE WHEN EXISTS (
                SELECT 1 FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON tc.constraint_name=kcu.constraint_name AND tc.constraint_schema=kcu.constraint_schema
                WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema=c.table_schema
                  AND tc.table_name=c.table_name AND kcu.column_name=c.column_name
            ) THEN 'PRI' ELSE '' END AS column_key
            FROM information_schema.columns c
            WHERE c.table_schema=$1 AND c.table_name=$2 ORDER BY c.ordinal_position"#.to_string(),
        _ => format!("PRAGMA table_info({})", quote_identifier(kind, table)?),
    };
    let mut q = sqlx::query(&sql);
    if kind == "mysql" {
        q = q.bind(table);
    }
    if kind == "postgresql" {
        q = q
            .bind(if schema.is_empty() { "public" } else { schema })
            .bind(table);
    }
    metadata_rows_value(q.fetch_all(pool).await.map_err(db_error)?)
}

async fn list_indexes(pool: &AnyPool, kind: &str, schema: &str, table: &str) -> DbResult {
    validate_identifier(table)?;
    let sql = match kind {
        "mysql" => "SELECT CAST(index_name AS CHAR) AS index_name, CAST(CONCAT('CREATE ', CASE WHEN index_type = 'FULLTEXT' THEN 'FULLTEXT ' WHEN index_type = 'SPATIAL' THEN 'SPATIAL ' WHEN non_unique = 0 THEN 'UNIQUE ' ELSE '' END, 'INDEX `', REPLACE(index_name, '`', '``'), '` ON `', REPLACE(table_name, '`', '``'), '` (', GROUP_CONCAT(CONCAT('`', REPLACE(column_name, '`', '``'), '`', CASE WHEN sub_part IS NULL THEN '' ELSE CONCAT('(', sub_part, ')') END, CASE WHEN collation = 'D' THEN ' DESC' ELSE '' END) ORDER BY seq_in_index SEPARATOR ', '), ')') AS CHAR) AS definition FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name <> 'PRIMARY' GROUP BY index_name, index_type, non_unique, table_name ORDER BY index_name".to_string(),
        "postgresql" => "SELECT CAST(indexname AS TEXT) AS index_name, CAST(indexdef AS TEXT) AS definition FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 ORDER BY indexname".to_string(),
        _ => "SELECT name AS index_name, sql AS definition FROM sqlite_master WHERE type='index' AND tbl_name = ? AND sql IS NOT NULL ORDER BY name".to_string(),
    };
    let mut q = sqlx::query(&sql);
    if kind == "mysql" {
        q = q.bind(table);
    }
    if kind == "sqlite" {
        q = q.bind(table);
    }
    if kind == "postgresql" {
        q = q
            .bind(if schema.is_empty() { "public" } else { schema })
            .bind(table);
    }
    rows_value(q.fetch_all(pool).await.map_err(db_error)?)
}

async fn list_foreign_keys(pool: &AnyPool, kind: &str, schema: &str, table: &str) -> DbResult {
    validate_identifier(table)?;
    let sql = match kind {
        "mysql" => "SELECT constraint_name, column_name, referenced_table_name, referenced_column_name FROM information_schema.key_column_usage WHERE table_schema = DATABASE() AND table_name = ? AND referenced_table_name IS NOT NULL ORDER BY constraint_name, ordinal_position".to_string(),
        "postgresql" => "SELECT CAST(tc.constraint_name AS TEXT) AS constraint_name, CAST(kcu.column_name AS TEXT) AS column_name, CAST(ccu.table_name AS TEXT) AS referenced_table_name, CAST(ccu.column_name AS TEXT) AS referenced_column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name AND tc.constraint_schema=kcu.constraint_schema JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name AND ccu.constraint_schema=tc.constraint_schema WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema=$1 AND tc.table_name=$2 ORDER BY tc.constraint_name, kcu.ordinal_position".to_string(),
        _ => format!("PRAGMA foreign_key_list({})", quote_identifier(kind, table)?),
    };
    let mut q = sqlx::query(&sql);
    if kind == "mysql" {
        q = q.bind(table);
    }
    if kind == "postgresql" {
        q = q
            .bind(if schema.is_empty() { "public" } else { schema })
            .bind(table);
    }
    rows_value(q.fetch_all(pool).await.map_err(db_error)?)
}

async fn list_objects(pool: &AnyPool, kind: &str, schema: &str, object_kind: &str) -> DbResult {
    let requested = if object_kind.is_empty() {
        "all"
    } else {
        object_kind
    };
    let sql = match (kind, requested) {
        ("mysql", "views") => "SELECT table_name AS object_name, 'view' AS object_kind, view_definition AS definition FROM information_schema.views WHERE table_schema=DATABASE() ORDER BY table_name".to_string(),
        ("mysql", "routines" | "procedures" | "functions") => "SELECT routine_name AS object_name, routine_type AS object_kind, routine_definition AS definition FROM information_schema.routines WHERE routine_schema=DATABASE() ORDER BY routine_name".to_string(),
        ("mysql", "triggers") => "SELECT trigger_name AS object_name, 'trigger' AS object_kind, action_statement AS definition FROM information_schema.triggers WHERE trigger_schema=DATABASE() ORDER BY trigger_name".to_string(),
        ("mysql", "sequences") => "SELECT CAST(NULL AS CHAR) AS object_name, 'sequence' AS object_kind, CAST(NULL AS CHAR) AS definition WHERE 1=0".to_string(),
        ("mysql", _) => "SELECT table_name AS object_name, table_type AS object_kind, CAST(NULL AS CHAR) AS definition FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY table_name".to_string(),
        ("postgresql", "views") => "SELECT CAST(viewname AS TEXT) AS object_name, 'view' AS object_kind, CAST(definition AS TEXT) AS definition FROM pg_views WHERE schemaname=$1 ORDER BY viewname".to_string(),
        ("postgresql", "routines" | "procedures" | "functions") => "SELECT CAST(p.proname AS TEXT) AS object_name, CASE WHEN p.prokind='p' THEN 'procedure' ELSE 'function' END AS object_kind, CAST(pg_get_functiondef(p.oid) AS TEXT) AS definition FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=$1 ORDER BY p.proname".to_string(),
        ("postgresql", "triggers") => "SELECT CAST(t.tgname AS TEXT) AS object_name, 'trigger' AS object_kind, CAST(pg_get_triggerdef(t.oid) AS TEXT) AS definition FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND NOT t.tgisinternal ORDER BY t.tgname".to_string(),
        ("postgresql", "sequences") => "SELECT CAST(c.relname AS TEXT) AS object_name, 'sequence' AS object_kind, CAST(NULL AS TEXT) AS definition FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relkind='S' ORDER BY c.relname".to_string(),
        ("postgresql", _) => "SELECT CAST(c.relname AS TEXT) AS object_name, CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'S' THEN 'sequence' ELSE c.relkind::TEXT END AS object_kind, CAST(NULL AS TEXT) AS definition FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relkind IN ('r','v','S') ORDER BY c.relname".to_string(),
        ("sqlite", "views") => "SELECT name AS object_name, 'view' AS object_kind, sql AS definition FROM sqlite_master WHERE type='view' ORDER BY name".to_string(),
        ("sqlite", "triggers") => "SELECT name AS object_name, 'trigger' AS object_kind, sql AS definition FROM sqlite_master WHERE type='trigger' ORDER BY name".to_string(),
        ("sqlite", "sequences" | "routines" | "procedures" | "functions") => "SELECT NULL AS object_name, 'unsupported' AS object_kind, NULL AS definition WHERE 1=0".to_string(),
        ("sqlite", _) => "SELECT name AS object_name, type AS object_kind, sql AS definition FROM sqlite_master WHERE type IN ('table','view','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name".to_string(),
        _ => return Err(("unsupported_database".into(), "Unsupported database type".into())),
    };
    let mut query = sqlx::query(&sql);
    if kind == "postgresql" {
        query = query.bind(if schema.is_empty() { "public" } else { schema });
    }
    rows_value(query.fetch_all(pool).await.map_err(db_error)?)
}

async fn schema_change(direct: &DirectPool, kind: &str, params: &Params) -> DbResult {
    let table = params.table.trim();
    validate_identifier(table)?;
    let qualified = if !params.schema.is_empty() && kind != "mysql" {
        format!(
            "{}.{}",
            quote_identifier(kind, &params.schema)?,
            quote_identifier(kind, table)?
        )
    } else {
        quote_identifier(kind, table)?
    };
    let operation = params.operation.as_str();
    let sql = match operation {
        "addColumn" => {
            validate_identifier(&params.name)?;
            let data_type = safe_sql_fragment(&params.data_type, "column type")?;
            let mut sql = format!(
                "ALTER TABLE {qualified} ADD COLUMN {} {data_type}",
                quote_identifier(kind, &params.name)?
            );
            if !params.nullable {
                sql.push_str(" NOT NULL");
            }
            if !params.default_value.is_empty() {
                sql.push_str(&format!(
                    " DEFAULT {}",
                    safe_sql_fragment(&params.default_value, "default")?
                ));
            }
            sql
        }
        "renameColumn" => {
            validate_identifier(&params.old_name)?;
            validate_identifier(&params.name)?;
            format!(
                "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                quote_identifier(kind, &params.old_name)?,
                quote_identifier(kind, &params.name)?
            )
        }
        "dropColumn" => {
            validate_identifier(&params.name)?;
            format!(
                "ALTER TABLE {qualified} DROP COLUMN {}",
                quote_identifier(kind, &params.name)?
            )
        }
        "createIndex" => {
            validate_identifier(&params.index_name)?;
            let columns = quoted_columns(kind, &params.index_columns)?;
            if columns.is_empty() {
                return Err((
                    "invalid_schema_change".into(),
                    "At least one index column is required".into(),
                ));
            }
            format!(
                "CREATE INDEX {} ON {qualified} ({})",
                quote_identifier(kind, &params.index_name)?,
                columns.join(", ")
            )
        }
        "dropIndex" => {
            validate_identifier(&params.index_name)?;
            if kind == "mysql" {
                format!(
                    "DROP INDEX {} ON {qualified}",
                    quote_identifier(kind, &params.index_name)?
                )
            } else {
                format!("DROP INDEX {}", quote_identifier(kind, &params.index_name)?)
            }
        }
        "addForeignKey" => {
            validate_identifier(&params.constraint_name)?;
            validate_identifier(&params.referenced_table)?;
            let columns = quoted_columns(kind, &params.index_columns)?;
            let referenced = quoted_columns(kind, &params.referenced_columns)?;
            if columns.is_empty() || referenced.is_empty() || columns.len() != referenced.len() {
                return Err((
                    "invalid_schema_change".into(),
                    "Foreign-key columns must be paired".into(),
                ));
            }
            format!(
                "ALTER TABLE {qualified} ADD CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {} ({})",
                quote_identifier(kind, &params.constraint_name)?,
                columns.join(", "),
                quote_identifier(kind, &params.referenced_table)?,
                referenced.join(", ")
            )
        }
        "dropForeignKey" => {
            validate_identifier(&params.constraint_name)?;
            if kind == "mysql" {
                format!(
                    "ALTER TABLE {qualified} DROP FOREIGN KEY {}",
                    quote_identifier(kind, &params.constraint_name)?
                )
            } else {
                format!(
                    "ALTER TABLE {qualified} DROP CONSTRAINT {}",
                    quote_identifier(kind, &params.constraint_name)?
                )
            }
        }
        "createView" => {
            validate_identifier(&params.name)?;
            if params.sql.trim().is_empty() {
                return Err((
                    "invalid_schema_change".into(),
                    "View SQL is required".into(),
                ));
            }
            format!(
                "CREATE VIEW {} AS {}",
                quote_identifier(kind, &params.name)?,
                require_single_sql(&params.sql)?
            )
        }
        "dropView" => {
            validate_identifier(&params.name)?;
            format!("DROP VIEW {}", quote_identifier(kind, &params.name)?)
        }
        _ => {
            return Err((
                "invalid_schema_change".into(),
                format!("Unsupported schema operation: {operation}"),
            ))
        }
    };
    execute_direct(direct, &sql, &[]).await
}

fn quoted_columns(kind: &str, columns: &[String]) -> Result<Vec<String>, (String, String)> {
    columns
        .iter()
        .map(|column| {
            validate_identifier(column)?;
            quote_identifier(kind, column)
        })
        .collect()
}

fn safe_sql_fragment(value: &str, label: &str) -> Result<String, (String, String)> {
    let value = value.trim();
    if value.is_empty()
        || value.contains(';')
        || value.contains("--")
        || value.contains("/*")
        || value.contains("*/")
        || value.chars().any(|character| character.is_control())
    {
        return Err(("invalid_schema_change".into(), format!("Invalid {label}")));
    }
    Ok(value.to_string())
}

fn require_single_sql(sql: &str) -> Result<String, (String, String)> {
    let trimmed = sql.trim();
    if trimmed.is_empty() || trimmed.contains(';') {
        return Err((
            "invalid_query".into(),
            "A single SQL statement is required".into(),
        ));
    }
    Ok(trimmed.to_string())
}

async fn page_table(
    pool: &AnyPool,
    direct: &DirectPool,
    kind: &str,
    schema: &str,
    table: &str,
    limit: u32,
    offset: u32,
    filters: &[Filter],
    sort: &[Sort],
) -> DbResult {
    validate_identifier(table)?;
    let qualified = if !schema.is_empty() && kind != "mysql" {
        format!(
            "{}.{}",
            quote_identifier(kind, schema)?,
            quote_identifier(kind, table)?
        )
    } else {
        quote_identifier(kind, table)?
    };
    let (where_sql, values) = filter_clause(kind, filters)?;
    let order_sql = sort_clause(kind, sort)?;
    let limit = limit.clamp(1, 1000);
    let sql =
        format!("SELECT * FROM {qualified}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}");
    let count_sql = format!("SELECT COUNT(*) AS total_rows FROM {qualified}{where_sql}");
    let mut result = query_direct(direct, &sql, &values, limit).await?;
    let count = bind_values(sqlx::query(&count_sql), &values)?
        .fetch_one(pool)
        .await
        .map_err(db_error)?;
    let total = count.try_get::<i64, _>(0).map_err(db_error)?;
    result
        .as_object_mut()
        .expect("query result object")
        .insert("totalRows".into(), json!(total));
    Ok(result)
}

fn filter_clause(kind: &str, filters: &[Filter]) -> Result<(String, Vec<Value>), (String, String)> {
    let mut predicates = Vec::new();
    let mut values = Vec::new();
    for filter in filters {
        let column = quote_identifier(kind, &filter.column)?;
        let index = values.len() + 1;
        let predicate = match filter.operator.as_str() {
            "equals" => {
                values.push(filter.value.clone());
                format!("{column} = {}", placeholder(kind, index))
            }
            "notEquals" => {
                values.push(filter.value.clone());
                format!("{column} <> {}", placeholder(kind, index))
            }
            "greaterThan" => {
                values.push(filter.value.clone());
                format!("{column} > {}", placeholder(kind, index))
            }
            "lessThan" => {
                values.push(filter.value.clone());
                format!("{column} < {}", placeholder(kind, index))
            }
            "contains" => {
                values.push(Value::String(format!(
                    "%{}%",
                    scalar_string(&filter.value)?
                )));
                format!("{column} LIKE {}", placeholder(kind, index))
            }
            "startsWith" => {
                values.push(Value::String(format!("{}%", scalar_string(&filter.value)?)));
                format!("{column} LIKE {}", placeholder(kind, index))
            }
            "isNull" => format!("{column} IS NULL"),
            "isNotNull" => format!("{column} IS NOT NULL"),
            value => {
                return Err((
                    "invalid_filter".into(),
                    format!("Unsupported filter operator: {value}"),
                ))
            }
        };
        let join = match filter.join.as_str() {
            "and" => "AND",
            "or" => "OR",
            value => {
                return Err((
                    "invalid_filter".into(),
                    format!("Unsupported filter join: {value}"),
                ))
            }
        };
        predicates.push((join, predicate));
    }
    Ok((
        if predicates.is_empty() {
            String::new()
        } else {
            let mut clause = predicates[0].1.clone();
            for (join, predicate) in predicates.iter().skip(1) {
                clause.push_str(&format!(" {join} {predicate}"));
            }
            format!(" WHERE ({clause})")
        },
        values,
    ))
}

fn sort_clause(kind: &str, sort: &[Sort]) -> Result<String, (String, String)> {
    let mut items = Vec::new();
    for item in sort {
        items.push(format!(
            "{} {}",
            quote_identifier(kind, &item.column)?,
            if item.descending { "DESC" } else { "ASC" }
        ));
    }
    Ok(if items.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", items.join(", "))
    })
}

fn scalar_string(value: &Value) -> Result<String, (String, String)> {
    match value {
        Value::String(value) => Ok(value.clone()),
        Value::Number(value) => Ok(value.to_string()),
        Value::Bool(value) => Ok(value.to_string()),
        _ => Err((
            "invalid_filter".into(),
            "Text filters require a scalar value".into(),
        )),
    }
}

async fn query_direct(pool: &DirectPool, sql: &str, values: &[Value], limit: u32) -> DbResult {
    require_sql(sql)?;
    let maximum = limit.clamp(1, 100_000) as usize;
    let mut rows = Vec::with_capacity(maximum.min(200));
    let (truncated, columns) = match pool {
        DirectPool::MySql(pool) => {
            let mut stream = bind_mysql(sqlx::query(sql), values)?.fetch(pool);
            collect_query_rows(&mut stream, maximum, &mut rows, mysql_row_json).await?
        }
        DirectPool::Postgres(pool) => {
            let mut stream = bind_postgres(sqlx::query(sql), values)?.fetch(pool);
            collect_query_rows(&mut stream, maximum, &mut rows, postgres_row_json).await?
        }
        DirectPool::Sqlite(pool) => {
            let mut stream = bind_sqlite(sqlx::query(sql), values)?.fetch(pool);
            collect_query_rows(&mut stream, maximum, &mut rows, sqlite_row_json).await?
        }
    };
    Ok(json!({"columns": columns, "truncated": truncated, "rows": rows}))
}

async fn collect_query_rows<'a, R, S>(
    stream: &mut S,
    maximum: usize,
    destination: &mut Vec<Value>,
    decode: fn(&R) -> Result<Value, (String, String)>,
) -> Result<(bool, Vec<String>), (String, String)>
where
    S: futures_util::TryStream<Ok = R, Error = sqlx::Error> + Unpin,
    R: Row,
{
    let mut columns = Vec::new();
    while let Some(row) = stream.try_next().await.map_err(db_error)? {
        if columns.is_empty() {
            columns = row
                .columns()
                .iter()
                .map(|column| column.name().to_string())
                .collect();
        }
        if destination.len() == maximum {
            return Ok((true, columns));
        }
        destination.push(decode(&row)?);
    }
    Ok((false, columns))
}

fn bind_mysql<'q>(
    mut query: sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>,
    values: &'q [Value],
) -> Result<sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>, (String, String)> {
    for value in values {
        query = bind_mysql_value(query, value);
    }
    Ok(query)
}
fn bind_postgres<'q>(
    mut query: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
    values: &'q [Value],
) -> Result<sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>, (String, String)> {
    for value in values {
        query = bind_postgres_value(query, value);
    }
    Ok(query)
}
fn bind_sqlite<'q>(
    mut query: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>>,
    values: &'q [Value],
) -> Result<sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>>, (String, String)> {
    for value in values {
        query = bind_sqlite_value(query, value);
    }
    Ok(query)
}

macro_rules! bind_value_fn {
    ($name:ident, $db:ty, $args:ty) => {
        fn $name<'q>(
            query: sqlx::query::Query<'q, $db, $args>,
            value: &'q Value,
        ) -> sqlx::query::Query<'q, $db, $args> {
            match value {
                Value::Null => query.bind(Option::<String>::None),
                Value::Bool(v) => query.bind(*v),
                Value::Number(v) if v.is_i64() => query.bind(v.as_i64().unwrap()),
                Value::Number(v) if v.is_u64() => query.bind(v.as_u64().unwrap() as i64),
                Value::Number(v) => query.bind(v.as_f64().unwrap()),
                Value::String(v) => query.bind(v),
                Value::Object(v) if v.get("decimal").and_then(Value::as_str).is_some() => {
                    match v["decimal"]
                        .as_str()
                        .unwrap()
                        .parse::<rust_decimal::Decimal>()
                    {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(v["decimal"].as_str().unwrap()),
                    }
                }
                Value::Object(v) if v.get("date").and_then(Value::as_str).is_some() => {
                    match v["date"].as_str().unwrap().parse::<chrono::NaiveDate>() {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(v["date"].as_str().unwrap()),
                    }
                }
                Value::Object(v) if v.get("time").and_then(Value::as_str).is_some() => {
                    match v["time"].as_str().unwrap().parse::<chrono::NaiveTime>() {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(v["time"].as_str().unwrap()),
                    }
                }
                Value::Object(v) if v.get("datetime").and_then(Value::as_str).is_some() => {
                    match v["datetime"]
                        .as_str()
                        .unwrap()
                        .parse::<chrono::NaiveDateTime>()
                    {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(v["datetime"].as_str().unwrap()),
                    }
                }
                Value::Object(v)
                    if v.get("timestampWithTimeZone")
                        .and_then(Value::as_str)
                        .is_some() =>
                {
                    match chrono::DateTime::parse_from_rfc3339(
                        v["timestampWithTimeZone"].as_str().unwrap(),
                    ) {
                        Ok(value) => query.bind(value.with_timezone(&chrono::Utc)),
                        Err(_) => query.bind(v["timestampWithTimeZone"].as_str().unwrap()),
                    }
                }
                Value::Object(v) if v.get("uuid").and_then(Value::as_str).is_some() => {
                    match v["uuid"].as_str().unwrap().parse::<uuid::Uuid>() {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(v["uuid"].as_str().unwrap()),
                    }
                }
                Value::Object(v) if v.get("json").is_some() => {
                    query.bind(sqlx::types::Json(v["json"].clone()))
                }
                Value::Object(v) if v.get("base64").and_then(Value::as_str).is_some() => {
                    match BASE64.decode(v["base64"].as_str().unwrap()) {
                        Ok(value) => query.bind(value),
                        Err(_) => query.bind(Vec::<u8>::new()),
                    }
                }
                other => query.bind(other.to_string()),
            }
        }
    };
}
bind_value_fn!(bind_mysql_value, MySql, sqlx::mysql::MySqlArguments);
bind_value_fn!(bind_postgres_value, Postgres, sqlx::postgres::PgArguments);

fn bind_sqlite_value<'q>(
    query: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>>,
    value: &'q Value,
) -> sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>> {
    match value {
        Value::Null => query.bind(Option::<String>::None),
        Value::Bool(v) => query.bind(*v),
        Value::Number(v) if v.is_i64() => query.bind(v.as_i64().unwrap()),
        Value::Number(v) if v.is_u64() => query.bind(v.as_u64().unwrap() as i64),
        Value::Number(v) => query.bind(v.as_f64().unwrap()),
        Value::String(v) => query.bind(v),
        Value::Object(v) if v.get("base64").and_then(Value::as_str).is_some() => query.bind(
            BASE64
                .decode(v["base64"].as_str().unwrap())
                .unwrap_or_default(),
        ),
        Value::Object(v) if v.get("json").is_some() => query.bind(v["json"].to_string()),
        Value::Object(v) => {
            let tagged = [
                "decimal",
                "date",
                "time",
                "datetime",
                "timestampWithTimeZone",
                "uuid",
            ]
            .iter()
            .find_map(|key| v.get(*key).and_then(Value::as_str));
            query.bind(tagged.unwrap_or_else(|| ""))
        }
        other => query.bind(other.to_string()),
    }
}

fn mysql_row_json(row: &MySqlRow) -> Result<Value, (String, String)> {
    typed_row_json(row, mysql_value)
}
fn postgres_row_json(row: &PgRow) -> Result<Value, (String, String)> {
    typed_row_json(row, postgres_value)
}
fn sqlite_row_json(row: &SqliteRow) -> Result<Value, (String, String)> {
    typed_row_json(row, sqlite_value)
}

fn typed_row_json<R>(
    row: &R,
    decode: fn(&R, usize, &str) -> Value,
) -> Result<Value, (String, String)>
where
    R: Row,
    usize: sqlx::ColumnIndex<R>,
{
    let mut object = Map::new();
    for (index, column) in row.columns().iter().enumerate() {
        let raw = row
            .try_get_raw(index)
            .map_err(|e| ("database_error".into(), e.to_string()))?;
        let value = if raw.is_null() {
            Value::Null
        } else {
            decode(row, index, column.type_info().name())
        };
        object.insert(column.name().to_string(), value);
    }
    Ok(Value::Object(object))
}

fn mysql_value(row: &MySqlRow, index: usize, kind: &str) -> Value {
    match kind.to_ascii_uppercase().as_str() {
        "DECIMAL" | "NEWDECIMAL" => row
            .try_get::<rust_decimal::Decimal, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "DATETIME" => row
            .try_get::<chrono::NaiveDateTime, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "TIMESTAMP" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(index)
            .map(|v| Value::String(v.to_rfc3339()))
            .or_else(|_| {
                row.try_get::<chrono::NaiveDateTime, _>(index)
                    .map(|v| Value::String(v.to_string()))
            })
            .unwrap_or_else(|_| mysql_text(row, index)),
        "BOOLEAN" | "BOOL" => row
            .try_get::<bool, _>(index)
            .map(Value::Bool)
            .or_else(|_| row.try_get::<i8, _>(index).map(|v| Value::Bool(v != 0)))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "JSON" => row
            .try_get::<Value, _>(index)
            .unwrap_or_else(|_| mysql_text(row, index)),
        "BLOB" | "BINARY" | "VARBINARY" => row
            .try_get::<Vec<u8>, _>(index)
            .map(|v| json!({"base64": BASE64.encode(v)}))
            .unwrap_or_else(|_| mysql_text(row, index)),
        "FLOAT" | "DOUBLE" => row
            .try_get::<f64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| mysql_text(row, index)),
        value if value == "TINYINT" => row
            .try_get::<i8, _>(index)
            .map(|v| json!(v))
            .or_else(|_| row.try_get::<u8, _>(index).map(|v| json!(v)))
            .or_else(|_| row.try_get::<i64, _>(index).map(|v| json!(v)))
            .unwrap_or_else(|_| mysql_text(row, index)),
        value if value.contains("INT") || value == "YEAR" => row
            .try_get::<i64, _>(index)
            .map(|v| json!(v))
            .or_else(|_| row.try_get::<u64, _>(index).map(|v| json!(v)))
            .unwrap_or_else(|_| mysql_text(row, index)),
        _ => mysql_text(row, index),
    }
}
fn mysql_text(row: &MySqlRow, index: usize) -> Value {
    row.try_get::<String, _>(index)
        .map(Value::String)
        .unwrap_or_else(|_| Value::String("<unsupported>".into()))
}

fn postgres_value(row: &PgRow, index: usize, kind: &str) -> Value {
    match kind.to_ascii_uppercase().as_str() {
        "NUMERIC" => row
            .try_get::<rust_decimal::Decimal, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "TIMESTAMP" => row
            .try_get::<chrono::NaiveDateTime, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "TIMESTAMPTZ" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(index)
            .map(|v| Value::String(v.to_rfc3339()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "UUID" => row
            .try_get::<uuid::Uuid, _>(index)
            .map(|v| Value::String(v.to_string()))
            .unwrap_or_else(|_| pg_text(row, index)),
        "JSON" | "JSONB" => row
            .try_get::<Value, _>(index)
            .unwrap_or_else(|_| pg_text(row, index)),
        "BYTEA" => row
            .try_get::<Vec<u8>, _>(index)
            .map(|v| json!({"base64":BASE64.encode(v)}))
            .unwrap_or_else(|_| pg_text(row, index)),
        "BOOL" => row
            .try_get::<bool, _>(index)
            .map(Value::Bool)
            .unwrap_or_else(|_| pg_text(row, index)),
        "INT2" => row
            .try_get::<i16, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| pg_text(row, index)),
        "INT4" => row
            .try_get::<i32, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| pg_text(row, index)),
        "INT8" => row
            .try_get::<i64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| pg_text(row, index)),
        "FLOAT4" => row
            .try_get::<f32, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| pg_text(row, index)),
        "FLOAT8" => row
            .try_get::<f64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| pg_text(row, index)),
        _ => pg_text(row, index),
    }
}
fn pg_text(row: &PgRow, index: usize) -> Value {
    row.try_get::<String, _>(index)
        .map(Value::String)
        .unwrap_or_else(|_| Value::String("<unsupported>".into()))
}

fn sqlite_value(row: &SqliteRow, index: usize, kind: &str) -> Value {
    match kind.to_ascii_uppercase().as_str() {
        "INTEGER" | "INT" | "INT64" => row
            .try_get::<i64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| sqlite_text(row, index)),
        "REAL" | "FLOAT" | "DOUBLE" => row
            .try_get::<f64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| sqlite_text(row, index)),
        "BLOB" => row
            .try_get::<Vec<u8>, _>(index)
            .map(|v| json!({"base64":BASE64.encode(v)}))
            .unwrap_or_else(|_| sqlite_text(row, index)),
        "BOOL" | "BOOLEAN" => row
            .try_get::<bool, _>(index)
            .map(Value::Bool)
            .unwrap_or_else(|_| sqlite_text(row, index)),
        _ => sqlite_text(row, index),
    }
}
fn sqlite_text(row: &SqliteRow, index: usize) -> Value {
    row.try_get::<String, _>(index)
        .map(Value::String)
        .unwrap_or_else(|_| Value::String("<unsupported>".into()))
}

async fn execute(pool: &AnyPool, sql: &str, values: &[Value]) -> DbResult {
    require_sql(sql)?;
    let result = bind_values(sqlx::query(sql), values)?
        .execute(pool)
        .await
        .map_err(db_error)?;
    Ok(json!({"rowsAffected": result.rows_affected()}))
}

async fn execute_direct(pool: &DirectPool, sql: &str, values: &[Value]) -> DbResult {
    require_sql(sql)?;
    let affected = match pool {
        DirectPool::MySql(pool) => bind_mysql(sqlx::query(sql), values)?
            .execute(pool)
            .await
            .map_err(db_error)?
            .rows_affected(),
        DirectPool::Postgres(pool) => bind_postgres(sqlx::query(sql), values)?
            .execute(pool)
            .await
            .map_err(db_error)?
            .rows_affected(),
        DirectPool::Sqlite(pool) => bind_sqlite(sqlx::query(sql), values)?
            .execute(pool)
            .await
            .map_err(db_error)?
            .rows_affected(),
    };
    Ok(json!({"rowsAffected": affected}))
}

async fn explain(pool: &AnyPool, kind: &str, sql: &str, format: &str) -> DbResult {
    let sql = require_single_sql(sql)?;
    let explain_sql = match kind {
        "postgresql" if format.eq_ignore_ascii_case("json") || format.is_empty() => {
            format!("EXPLAIN (FORMAT JSON) {sql}")
        }
        "postgresql" => format!("EXPLAIN {sql}"),
        "sqlite" => format!("EXPLAIN QUERY PLAN {sql}"),
        _ => format!("EXPLAIN {sql}"),
    };
    let rows = sqlx::query(&explain_sql)
        .fetch_all(pool)
        .await
        .map_err(db_error)?;
    Ok(
        json!({"format": if kind == "postgresql" && (format.is_empty() || format.eq_ignore_ascii_case("json")) { "json" } else { "rows" }, "rows": rows_value(rows)?, "truncated": false}),
    )
}

async fn diagnostics(pool: &AnyPool, kind: &str, params: &Params) -> DbResult {
    let diagnostic_kind = if params.diagnostic_kind.is_empty() {
        "tableSize"
    } else {
        params.diagnostic_kind.as_str()
    };
    if diagnostic_kind == "indexes" {
        let rows = list_indexes(pool, kind, &params.schema, &params.table).await?;
        return Ok(json!({"rows": rows, "truncated": false}));
    }
    let sql = match (kind, diagnostic_kind) {
        ("mysql", "tableSize") => "SELECT table_name, table_rows, data_length, index_length, (data_length + index_length) AS total_bytes FROM information_schema.tables WHERE table_schema=DATABASE() AND (? = '' OR table_name = ?) ORDER BY total_bytes DESC".to_string(),
        ("postgresql", "tableSize") => "SELECT c.relname AS table_name, c.reltuples AS estimated_rows, pg_total_relation_size(c.oid) AS total_bytes, pg_relation_size(c.oid) AS table_bytes FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND ($2='' OR c.relname=$2) AND c.relkind IN ('r','m') ORDER BY total_bytes DESC".to_string(),
        ("sqlite", "tableSize") => "SELECT name AS table_name, (SELECT page_count * page_size FROM pragma_page_count, pragma_page_size) AS total_bytes FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND (?='' OR name=?) ORDER BY name".to_string(),
        ("mysql", "locks") => "SELECT trx_id, trx_started, trx_state, trx_mysql_thread_id, trx_query FROM information_schema.innodb_trx ORDER BY trx_started".to_string(),
        ("postgresql", "locks") => "SELECT pid, locktype, mode, granted, relation::regclass AS relation, transactionid, query FROM pg_locks l LEFT JOIN pg_stat_activity a ON a.pid=l.pid WHERE NOT granted OR l.relation IS NOT NULL ORDER BY granted, pid".to_string(),
        ("sqlite", "locks") => "SELECT 'SQLite uses file-level locking; active lock state is not exposed by the driver' AS message".to_string(),
        ("mysql", "slowQueries") => "SELECT DIGEST_TEXT AS query, COUNT_STAR AS executions, AVG_TIMER_WAIT/1000000 AS avg_ms, SUM_TIMER_WAIT/1000000 AS total_ms, SUM_ROWS_AFFECTED AS rows_affected FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL ORDER BY SUM_TIMER_WAIT DESC LIMIT 100".to_string(),
        ("postgresql", "slowQueries") => "SELECT query, calls AS executions, mean_exec_time AS avg_ms, total_exec_time AS total_ms, rows FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 100".to_string(),
        ("sqlite", "slowQueries") => "SELECT NULL AS query, 0 AS executions, 0 AS avg_ms, 0 AS total_ms WHERE 1=0".to_string(),
        ("mysql", "schemaImpact") => "SELECT TABLE_NAME AS table_name, CONSTRAINT_NAME AS constraint_name, REFERENCED_TABLE_NAME AS referenced_table_name FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL AND (?='' OR REFERENCED_TABLE_NAME=?) ORDER BY TABLE_NAME".to_string(),
        ("postgresql", "schemaImpact") => "SELECT CAST(tc.table_name AS TEXT) AS table_name, CAST(tc.constraint_name AS TEXT) AS constraint_name, CAST(ccu.table_name AS TEXT) AS referenced_table_name FROM information_schema.table_constraints tc JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name AND ccu.constraint_schema=tc.constraint_schema WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema=$1 AND ($2='' OR ccu.table_name=$2) ORDER BY tc.table_name".to_string(),
        ("sqlite", "schemaImpact") => "SELECT m.name AS table_name, f.id AS foreign_key_id, f.table AS referenced_table_name FROM sqlite_master m, pragma_foreign_key_list(m.name) f WHERE m.type='table' AND (?='' OR f.table=?) ORDER BY m.name".to_string(),
        (_, "dataQuality") => return data_quality(pool, kind, params).await,
        _ => return Err(("unsupported_diagnostic".into(), format!("Unsupported diagnostic: {diagnostic_kind}"))),
    };
    let mut query = sqlx::query(&sql);
    match (kind, diagnostic_kind) {
        ("postgresql", "tableSize" | "locks" | "slowQueries") => {}
        ("postgresql", "schemaImpact") => {
            query = query
                .bind(if params.schema.is_empty() {
                    "public"
                } else {
                    params.schema.as_str()
                })
                .bind(&params.table);
        }
        ("mysql" | "sqlite", "tableSize" | "schemaImpact") => {
            query = query.bind(&params.table).bind(&params.table);
        }
        _ => {}
    }
    if kind == "postgresql" && diagnostic_kind == "tableSize" {
        query = query
            .bind(if params.schema.is_empty() {
                "public"
            } else {
                params.schema.as_str()
            })
            .bind(&params.table);
    }
    rows_value(query.fetch_all(pool).await.map_err(db_error)?)
}

async fn data_quality(pool: &AnyPool, kind: &str, params: &Params) -> DbResult {
    validate_identifier(&params.table)?;
    let description = describe_table(pool, kind, &params.schema, &params.table).await?;
    let rows = description.as_array().cloned().unwrap_or_default();
    let mut results = Vec::new();
    for row in rows {
        let column = row
            .get("column_name")
            .and_then(Value::as_str)
            .or_else(|| row.get("name").and_then(Value::as_str))
            .unwrap_or_default();
        if column.is_empty() {
            continue;
        }
        let qualified = if !params.schema.is_empty() && kind != "mysql" {
            format!(
                "{}.{}",
                quote_identifier(kind, &params.schema)?,
                quote_identifier(kind, &params.table)?
            )
        } else {
            quote_identifier(kind, &params.table)?
        };
        let sql = format!("SELECT COUNT(*) AS total_rows, SUM(CASE WHEN {} IS NULL THEN 1 ELSE 0 END) AS null_rows FROM {qualified}", quote_identifier(kind, column)?);
        let values = rows_value(sqlx::query(&sql).fetch_all(pool).await.map_err(db_error)?)?;
        if let Some(value) = values.as_array().and_then(|items| items.first()) {
            results.push(json!({"column": column, "metrics": value}));
        }
    }
    Ok(json!({"rows": results, "truncated": false}))
}

async fn run_transaction(pool: &DirectPool, _kind: &str, statements: &[Statement]) -> DbResult {
    if statements.is_empty() {
        return Ok(json!({"rowsAffected": 0}));
    }
    let mut affected = 0_u64;
    match pool {
        DirectPool::MySql(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for statement in statements {
                affected += bind_mysql(sqlx::query(&statement.sql), &statement.values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
        DirectPool::Postgres(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for statement in statements {
                affected += bind_postgres(sqlx::query(&statement.sql), &statement.values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
        DirectPool::Sqlite(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for statement in statements {
                affected += bind_sqlite(sqlx::query(&statement.sql), &statement.values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
    }
    Ok(json!({"rowsAffected": affected}))
}

fn ensure_write_allowed(
    connection: &Connection,
    sql: &str,
    confirmed: bool,
    allow_write: bool,
) -> Result<(), (String, String)> {
    if connection.read_only && !allow_write {
        return Err((
            "read_only".into(),
            "This connection is configured as read-only".into(),
        ));
    }
    if connection.production_protection && is_dangerous_sql(sql) && !confirmed {
        return Err((
            "confirmation_required".into(),
            "Production protection requires explicit confirmation".into(),
        ));
    }
    Ok(())
}

fn ensure_mutations_allowed(
    connection: &Connection,
    mutations: &[Mutation],
    confirmed: bool,
    allow_write: bool,
) -> Result<(), (String, String)> {
    if connection.read_only && !allow_write {
        return Err((
            "read_only".into(),
            "This connection is configured as read-only".into(),
        ));
    }
    if connection.production_protection
        && mutations.iter().any(|mutation| mutation.action == "delete")
        && !confirmed
    {
        return Err((
            "confirmation_required".into(),
            "Production protection requires explicit confirmation".into(),
        ));
    }
    Ok(())
}

fn ensure_transaction_allowed(
    connection: &Connection,
    statements: &[Statement],
    confirmed: bool,
    allow_write: bool,
) -> Result<(), (String, String)> {
    if connection.read_only && !allow_write {
        return Err((
            "read_only".into(),
            "This connection is configured as read-only".into(),
        ));
    }
    if connection.production_protection
        && statements
            .iter()
            .any(|statement| is_dangerous_sql(&statement.sql))
        && !confirmed
    {
        return Err((
            "confirmation_required".into(),
            "Production protection requires explicit confirmation".into(),
        ));
    }
    Ok(())
}

fn is_dangerous_sql(sql: &str) -> bool {
    let upper = sql.trim_start().to_ascii_uppercase();
    upper == "RESTORE"
        || upper.starts_with("DROP ")
        || upper.starts_with("TRUNCATE ")
        || (upper.starts_with("UPDATE ") && !upper.contains(" WHERE "))
        || (upper.starts_with("DELETE ") && !upper.contains(" WHERE "))
}

async fn apply_changes(
    pool: &DirectPool,
    kind: &str,
    schema: &str,
    mutations: &[Mutation],
) -> DbResult {
    if mutations.is_empty() {
        return Ok(json!({"rowsAffected": 0}));
    }
    let mut affected = 0_u64;
    match pool {
        DirectPool::MySql(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for mutation in mutations {
                let (sql, values) = mutation_sql(kind, schema, mutation)?;
                affected += bind_mysql(sqlx::query(&sql), &values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
        DirectPool::Postgres(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for mutation in mutations {
                let (sql, values) = mutation_sql(kind, schema, mutation)?;
                affected += bind_postgres(sqlx::query(&sql), &values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
        DirectPool::Sqlite(pool) => {
            let mut transaction = pool.begin().await.map_err(db_error)?;
            for mutation in mutations {
                let (sql, values) = mutation_sql(kind, schema, mutation)?;
                affected += bind_sqlite(sqlx::query(&sql), &values)?
                    .execute(&mut *transaction)
                    .await
                    .map_err(db_error)?
                    .rows_affected();
            }
            transaction.commit().await.map_err(db_error)?;
        }
    }
    Ok(json!({"rowsAffected": affected}))
}

fn mutation_sql(
    kind: &str,
    schema: &str,
    mutation: &Mutation,
) -> Result<(String, Vec<Value>), (String, String)> {
    validate_identifier(&mutation.table)?;
    let table = if !schema.is_empty() && kind != "mysql" {
        format!(
            "{}.{}",
            quote_identifier(kind, schema)?,
            quote_identifier(kind, &mutation.table)?
        )
    } else {
        quote_identifier(kind, &mutation.table)?
    };
    let columns = |map: &Map<String, Value>| -> Result<Vec<String>, (String, String)> {
        map.keys().map(|key| quote_identifier(kind, key)).collect()
    };
    match mutation.action.as_str() {
        "insert" => {
            if mutation.values.is_empty() {
                let sql = if kind == "mysql" {
                    format!("INSERT INTO {table} () VALUES ()")
                } else {
                    format!("INSERT INTO {table} DEFAULT VALUES")
                };
                return Ok((sql, Vec::new()));
            }
            let names = columns(&mutation.values)?;
            let placeholders = placeholders(kind, 1, names.len());
            Ok((
                format!(
                    "INSERT INTO {table} ({}) VALUES ({})",
                    names.join(", "),
                    placeholders.join(", ")
                ),
                mutation.values.values().cloned().collect(),
            ))
        }
        "update" => {
            require_key(&mutation.key)?;
            if mutation.values.is_empty() {
                return Err((
                    "invalid_mutation".into(),
                    "Update values cannot be empty".into(),
                ));
            }
            let names = columns(&mutation.values)?;
            let key_names = columns(&mutation.key)?;
            let assignments: Vec<String> = names
                .iter()
                .enumerate()
                .map(|(index, name)| format!("{name} = {}", placeholder(kind, index + 1)))
                .collect();
            let predicates: Vec<String> = key_names
                .iter()
                .enumerate()
                .map(|(index, name)| {
                    format!("{name} = {}", placeholder(kind, names.len() + index + 1))
                })
                .collect();
            let mut values: Vec<Value> = mutation.values.values().cloned().collect();
            values.extend(mutation.key.values().cloned());
            Ok((
                format!(
                    "UPDATE {table} SET {} WHERE {}",
                    assignments.join(", "),
                    predicates.join(" AND ")
                ),
                values,
            ))
        }
        "delete" => {
            require_key(&mutation.key)?;
            let names = columns(&mutation.key)?;
            let predicates: Vec<String> = names
                .iter()
                .enumerate()
                .map(|(index, name)| format!("{name} = {}", placeholder(kind, index + 1)))
                .collect();
            Ok((
                format!("DELETE FROM {table} WHERE {}", predicates.join(" AND ")),
                mutation.key.values().cloned().collect(),
            ))
        }
        action => Err((
            "invalid_mutation".into(),
            format!("Unsupported mutation action: {action}"),
        )),
    }
}

fn require_key(key: &Map<String, Value>) -> Result<(), (String, String)> {
    if key.is_empty() {
        Err((
            "unsafe_mutation".into(),
            "Update and delete require a primary key".into(),
        ))
    } else {
        Ok(())
    }
}

fn placeholders(kind: &str, start: usize, count: usize) -> Vec<String> {
    (start..start + count)
        .map(|index| placeholder(kind, index))
        .collect()
}

fn placeholder(kind: &str, index: usize) -> String {
    if kind == "postgresql" {
        format!("${index}")
    } else {
        "?".into()
    }
}

async fn export_csv(pool: &DirectPool, sql: &str, values: &[Value], limit: u32) -> DbResult {
    let result = query_direct(pool, sql, values, limit).await?;
    let rows = result["rows"].as_array().cloned().unwrap_or_default();
    let headers: Vec<String> = result["columns"]
        .as_array()
        .map(|columns| {
            columns
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .filter(|columns: &Vec<String>| !columns.is_empty())
        .unwrap_or_else(|| {
            rows.first()
                .and_then(Value::as_object)
                .map(|row| row.keys().cloned().collect())
                .unwrap_or_default()
        });
    let mut writer = csv::Writer::from_writer(Vec::new());
    writer.write_record(&headers).map_err(csv_error)?;
    for row in rows {
        let object = row
            .as_object()
            .ok_or_else(|| ("export_failed".into(), "Invalid row".into()))?;
        writer
            .write_record(
                headers
                    .iter()
                    .map(|key| csv_value(object.get(key).unwrap_or(&Value::Null))),
            )
            .map_err(csv_error)?;
    }
    let bytes = writer
        .into_inner()
        .map_err(|e| ("export_failed".into(), e.to_string()))?;
    Ok(json!({"encoding": "base64", "data": BASE64.encode(bytes)}))
}

async fn export_json(pool: &DirectPool, sql: &str, values: &[Value], limit: u32) -> DbResult {
    let result = query_direct(pool, sql, values, limit).await?;
    let bytes = serde_json::to_vec_pretty(&result["rows"])
        .map_err(|e| ("export_failed".into(), e.to_string()))?;
    Ok(json!({"encoding": "base64", "data": BASE64.encode(bytes)}))
}

async fn import_data(
    pool: &DirectPool,
    kind: &str,
    schema: &str,
    table: &str,
    data: &str,
    format: &str,
) -> DbResult {
    let bytes = BASE64
        .decode(data)
        .map_err(|e| ("invalid_import".into(), format!("Invalid base64 data: {e}")))?;
    let rows = if format == "csv" {
        parse_csv(&bytes)?
    } else {
        parse_json(&bytes)?
    };
    if rows.is_empty() {
        return Ok(json!({"rowsAffected": 0}));
    }
    if rows.len() > 100_000 {
        return Err((
            "import_too_large".into(),
            "A single import is limited to 100000 rows".into(),
        ));
    }
    let mutations: Vec<Mutation> = rows
        .into_iter()
        .map(|values| Mutation {
            action: "insert".into(),
            table: table.into(),
            values,
            key: Map::new(),
        })
        .collect();
    apply_changes(pool, kind, schema, &mutations).await
}

fn parse_csv(bytes: &[u8]) -> Result<Vec<Map<String, Value>>, (String, String)> {
    let mut reader = csv::ReaderBuilder::new().flexible(false).from_reader(bytes);
    let headers: Vec<String> = reader
        .headers()
        .map_err(csv_error)?
        .iter()
        .map(str::to_string)
        .collect();
    for header in &headers {
        validate_identifier(header)?;
    }
    reader
        .records()
        .map(|record| {
            let record = record.map_err(csv_error)?;
            Ok(headers
                .iter()
                .zip(record.iter())
                .map(|(key, value)| (key.clone(), Value::String(value.into())))
                .collect())
        })
        .collect()
}

fn parse_json(bytes: &[u8]) -> Result<Vec<Map<String, Value>>, (String, String)> {
    let rows: Vec<Map<String, Value>> = serde_json::from_slice(bytes).map_err(|e| {
        (
            "invalid_import".into(),
            format!("Expected an array of JSON objects: {e}"),
        )
    })?;
    for row in &rows {
        for key in row.keys() {
            validate_identifier(key)?;
        }
    }
    Ok(rows)
}

async fn import_sql(pool: &AnyPool, data: &str) -> DbResult {
    let bytes = BASE64
        .decode(data)
        .map_err(|e| ("invalid_import".into(), format!("Invalid base64 data: {e}")))?;
    import_sql_bytes(pool, &bytes).await
}

async fn import_sql_file(pool: &AnyPool, path: &str) -> DbResult {
    if path.trim().is_empty() {
        return Err(("invalid_import".into(), "SQL file path is required".into()));
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|error| ("invalid_import".into(), error.to_string()))?;
    import_sql_bytes(pool, &bytes).await
}

async fn restore_sql(pool: &AnyPool, kind: &str, schema: &str, data: &str) -> DbResult {
    let bytes = BASE64
        .decode(data)
        .map_err(|e| ("invalid_import".into(), format!("Invalid base64 data: {e}")))?;
    restore_sql_bytes(pool, kind, schema, &bytes).await
}

async fn restore_sql_file(pool: &AnyPool, kind: &str, schema: &str, path: &str) -> DbResult {
    if path.trim().is_empty() {
        return Err(("invalid_import".into(), "SQL file path is required".into()));
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|error| ("invalid_import".into(), error.to_string()))?;
    restore_sql_bytes(pool, kind, schema, &bytes).await
}

async fn restore_sql_bytes(pool: &AnyPool, kind: &str, schema: &str, bytes: &[u8]) -> DbResult {
    let script = validated_sql_script(bytes)?;
    if script.trim().is_empty() {
        return Err((
            "invalid_import".into(),
            "SQL restore file cannot be empty".into(),
        ));
    }
    drop_database_objects(pool, kind, schema).await?;
    execute_sql_script(pool, script).await
}

async fn import_sql_bytes(pool: &AnyPool, bytes: &[u8]) -> DbResult {
    let script = validated_sql_script(bytes)?;
    execute_sql_script(pool, script).await
}

fn validated_sql_script(bytes: &[u8]) -> Result<&str, (String, String)> {
    if bytes.len() > 256 * 1024 * 1024 {
        return Err((
            "import_too_large".into(),
            "SQL import is limited to 256 MB per request".into(),
        ));
    }
    let script = std::str::from_utf8(&bytes).map_err(|e| {
        (
            "invalid_import".into(),
            format!("SQL file must be UTF-8: {e}"),
        )
    })?;
    Ok(script)
}

async fn execute_sql_script(pool: &AnyPool, script: &str) -> DbResult {
    if script.trim().is_empty() {
        return Ok(json!({"rowsAffected": 0}));
    }
    let result = sqlx::raw_sql(script)
        .execute(pool)
        .await
        .map_err(db_error)?;
    Ok(json!({"rowsAffected": result.rows_affected()}))
}

async fn export_sql(
    pool: &AnyPool,
    direct: &DirectPool,
    kind: &str,
    schema: &str,
    selected: &[String],
    include_structure: bool,
    include_data: bool,
    limit: u32,
) -> DbResult {
    let mut output = Vec::new();
    write_sql_backup(
        &mut output,
        pool,
        direct,
        kind,
        schema,
        selected,
        include_structure,
        include_data,
        limit,
    )
    .await?;
    Ok(json!({"encoding": "base64", "data": BASE64.encode(output)}))
}

async fn write_sql_backup<W: Write>(
    output: &mut W,
    pool: &AnyPool,
    direct: &DirectPool,
    kind: &str,
    schema: &str,
    selected: &[String],
    include_structure: bool,
    include_data: bool,
    limit: u32,
) -> Result<(), (String, String)> {
    let schema = if schema.is_empty() && kind == "postgresql" {
        "public"
    } else {
        schema
    };
    let objects = database_objects(pool, kind, schema).await?;
    let selected_set: std::collections::HashSet<&str> =
        selected.iter().map(String::as_str).collect();
    for name in selected {
        validate_identifier(name)?;
    }
    let objects: Vec<(String, String)> = objects
        .into_iter()
        .filter(|(name, _)| selected_set.is_empty() || selected_set.contains(name.as_str()))
        .collect();
    write_export(
        output,
        "-- Lithe SQL backup\n-- Generated by lithe-db-sidecar\n\n",
    )?;
    match kind {
        "mysql" => write_export(output, "SET FOREIGN_KEY_CHECKS=0;\n\n")?,
        "sqlite" => write_export(output, "PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n\n")?,
        "postgresql" => write_export(output, "BEGIN;\n\n")?,
        _ => {}
    }
    if include_structure {
        write_export(output, "-- Remove existing objects before restore\n")?;
        for (name, object_type) in objects.iter().rev() {
            if let Some(statement) = object_drop_sql(kind, schema, name, object_type)? {
                write_export(output, &statement)?;
                write_export(output, ";\n")?;
            }
        }
        write_export(output, "\n")?;
        for (name, object_type) in &objects {
            let ddl = object_ddl(pool, kind, schema, name, object_type).await?;
            if !ddl.trim().is_empty() {
                write_export(
                    output,
                    &format!(
                        "-- Structure for {name}\n{};\n\n",
                        ddl.trim().trim_end_matches(';')
                    ),
                )?;
            }
        }
        if kind == "postgresql" {
            let table_names: Vec<&str> = objects
                .iter()
                .filter(|(_, object_type)| object_type.eq_ignore_ascii_case("base table"))
                .map(|(name, _)| name.as_str())
                .collect();
            let foreign_keys = postgres_foreign_key_ddls(pool, schema, &table_names).await?;
            if !foreign_keys.is_empty() {
                write_export(output, "-- Foreign key constraints\n")?;
                for statement in foreign_keys {
                    write_export(output, &statement)?;
                    write_export(output, ";\n")?;
                }
                write_export(output, "\n")?;
            }
        }
    }
    if include_data {
        for (name, object_type) in &objects {
            if !object_type.eq_ignore_ascii_case("table")
                && !object_type.eq_ignore_ascii_case("base table")
            {
                continue;
            }
            write_export(output, &format!("-- Data for {name}\n"))?;
            write_table_insert_sql(output, direct, kind, schema, name, limit).await?;
            if kind == "postgresql" {
                write_export(output, &postgres_sequence_sql(pool, schema, name).await?)?;
            }
            write_export(output, "\n")?;
        }
    }
    match kind {
        "mysql" => write_export(output, "SET FOREIGN_KEY_CHECKS=1;\n")?,
        "sqlite" => write_export(output, "COMMIT;\nPRAGMA foreign_keys=ON;\n")?,
        "postgresql" => write_export(output, "COMMIT;\n")?,
        _ => {}
    }
    Ok(())
}

async fn export_sql_to_file(
    pool: &AnyPool,
    direct: &DirectPool,
    kind: &str,
    schema: &str,
    selected: &[String],
    include_structure: bool,
    include_data: bool,
    limit: u32,
    path: &str,
) -> DbResult {
    if path.trim().is_empty() {
        return Err((
            "invalid_export".into(),
            "Output file path is required".into(),
        ));
    }
    let file = File::create(path).map_err(export_io_error)?;
    let mut output = BufWriter::new(file);
    write_sql_backup(
        &mut output,
        pool,
        direct,
        kind,
        schema,
        selected,
        include_structure,
        include_data,
        limit,
    )
    .await?;
    output.flush().map_err(export_io_error)?;
    drop(output);
    let (byte_count, sha256) = sha256_file(path)?;
    Ok(json!({
        "path": path,
        "byteCount": byte_count,
        "sha256": sha256
    }))
}

fn write_export<W: Write>(output: &mut W, text: &str) -> Result<(), (String, String)> {
    output.write_all(text.as_bytes()).map_err(export_io_error)
}

fn export_io_error(error: io::Error) -> (String, String) {
    ("export_failed".into(), error.to_string())
}

fn sha256_file(path: &str) -> Result<(u64, String), (String, String)> {
    let file = File::open(path).map_err(export_io_error)?;
    let mut reader = BufReader::new(file);
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    let mut byte_count = 0u64;
    loop {
        let bytes_read = reader.read(&mut buffer).map_err(export_io_error)?;
        if bytes_read == 0 {
            break;
        }
        digest.update(&buffer[..bytes_read]);
        byte_count += bytes_read as u64;
    }
    Ok((byte_count, hex::encode(digest.finalize())))
}

async fn database_objects(
    pool: &AnyPool,
    kind: &str,
    schema: &str,
) -> Result<Vec<(String, String)>, (String, String)> {
    let (sql, bind_schema) = match kind {
        "mysql" => ("SELECT table_name, table_type FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY CASE WHEN table_type='BASE TABLE' THEN 0 ELSE 1 END, table_name", false),
        "postgresql" => ("SELECT CAST(table_name AS TEXT), CAST(table_type AS TEXT) FROM information_schema.tables WHERE table_schema=$1 ORDER BY CASE WHEN table_type='BASE TABLE' THEN 0 ELSE 1 END, table_name", true),
        _ => ("SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name", false),
    };
    let mut query = sqlx::query(sql);
    if bind_schema {
        query = query.bind(schema);
    }
    let rows = query.fetch_all(pool).await.map_err(db_error)?;
    rows.iter()
        .map(|row| Ok((row_string(row, 0)?, row_string(row, 1)?)))
        .collect()
}

async fn drop_database_objects(
    pool: &AnyPool,
    kind: &str,
    schema: &str,
) -> Result<(), (String, String)> {
    let schema = if schema.is_empty() && kind == "postgresql" {
        "public"
    } else {
        schema
    };
    match kind {
        "mysql" => {
            sqlx::query("SET FOREIGN_KEY_CHECKS=0")
                .execute(pool)
                .await
                .map_err(db_error)?;
        }
        "sqlite" => {
            sqlx::query("PRAGMA foreign_keys=OFF")
                .execute(pool)
                .await
                .map_err(db_error)?;
        }
        _ => {}
    }
    let objects = database_objects(pool, kind, schema).await?;
    for (name, object_type) in objects.iter().rev() {
        if let Some(statement) = object_drop_sql(kind, schema, name, object_type)? {
            sqlx::query(&statement)
                .execute(pool)
                .await
                .map_err(db_error)?;
        }
    }
    Ok(())
}

fn object_drop_sql(
    kind: &str,
    schema: &str,
    name: &str,
    object_type: &str,
) -> Result<Option<String>, (String, String)> {
    let qualified = if kind == "postgresql" {
        format!(
            "{}.{}",
            quote_identifier(kind, schema)?,
            quote_identifier(kind, name)?
        )
    } else {
        quote_identifier(kind, name)?
    };
    if object_type.eq_ignore_ascii_case("view") {
        return Ok(Some(format!("DROP VIEW IF EXISTS {qualified}")));
    }
    if object_type.eq_ignore_ascii_case("table") || object_type.eq_ignore_ascii_case("base table") {
        return Ok(Some(format!(
            "DROP TABLE IF EXISTS {qualified}{}",
            if kind == "postgresql" { " CASCADE" } else { "" }
        )));
    }
    Ok(None)
}

async fn object_ddl(
    pool: &AnyPool,
    kind: &str,
    schema: &str,
    name: &str,
    object_type: &str,
) -> Result<String, (String, String)> {
    validate_identifier(name)?;
    match kind {
        "sqlite" => {
            let row = sqlx::query(
                "SELECT sql FROM sqlite_master WHERE name=? AND type IN ('table','view')",
            )
            .bind(name)
            .fetch_one(pool)
            .await
            .map_err(db_error)?;
            let mut ddl = row_string(&row, 0)?;
            if object_type.eq_ignore_ascii_case("table") {
                let indexes = sqlx::query("SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL ORDER BY name").bind(name).fetch_all(pool).await.map_err(db_error)?;
                for index in indexes {
                    ddl.push_str(";\n");
                    ddl.push_str(&row_string(&index, 0)?);
                }
            }
            Ok(ddl)
        }
        "mysql" => {
            let sql = format!(
                "SHOW CREATE {} {}",
                if object_type.eq_ignore_ascii_case("view") {
                    "VIEW"
                } else {
                    "TABLE"
                },
                quote_identifier(kind, name)?
            );
            let row = sqlx::query(&sql).fetch_one(pool).await.map_err(db_error)?;
            row_string(&row, 1)
        }
        "postgresql" if object_type.eq_ignore_ascii_case("view") => {
            let row = sqlx::query("SELECT 'CREATE OR REPLACE VIEW ' || quote_ident($1) || '.' || quote_ident($2) || ' AS ' || pg_get_viewdef((quote_ident($1)||'.'||quote_ident($2))::regclass, true)")
                .bind(schema).bind(name).fetch_one(pool).await.map_err(db_error)?;
            row_string(&row, 0)
        }
        "postgresql" => postgres_table_ddl(pool, schema, name).await,
        _ => Err(("unsupported_database".into(), kind.into())),
    }
}

async fn postgres_table_ddl(
    pool: &AnyPool,
    schema: &str,
    table: &str,
) -> Result<String, (String, String)> {
    let column_sql = r#"SELECT quote_ident(a.attname) || ' ' || pg_catalog.format_type(a.atttypid,a.atttypmod) ||
        CASE WHEN a.attidentity='a' THEN ' GENERATED ALWAYS AS IDENTITY' WHEN a.attidentity='d' THEN ' GENERATED BY DEFAULT AS IDENTITY'
             WHEN d.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(d.adbin,d.adrelid) ELSE '' END ||
        CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
        FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE n.nspname=$1 AND c.relname=$2 AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum"#;
    let rows = sqlx::query(column_sql)
        .bind(schema)
        .bind(table)
        .fetch_all(pool)
        .await
        .map_err(db_error)?;
    let mut definitions: Vec<String> = rows
        .iter()
        .map(|row| row_string(row, 0))
        .collect::<Result<_, _>>()?;
    let constraints = sqlx::query("SELECT 'CONSTRAINT '||quote_ident(con.conname)||' '||pg_get_constraintdef(con.oid,true) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2 AND con.contype <> 'f' ORDER BY con.conname")
        .bind(schema).bind(table).fetch_all(pool).await.map_err(db_error)?;
    definitions.extend(
        constraints
            .iter()
            .map(|row| row_string(row, 0))
            .collect::<Result<Vec<_>, _>>()?,
    );
    let qualified = format!(
        "{}.{}",
        quote_identifier("postgresql", schema)?,
        quote_identifier("postgresql", table)?
    );
    let sequence_ddl = postgres_table_sequence_ddl(pool, schema, table).await?;
    let mut ddl = String::new();
    if !sequence_ddl.is_empty() {
        ddl.push_str(&sequence_ddl);
        ddl.push_str(";\n");
    }
    ddl.push_str(&format!(
        "CREATE TABLE {qualified} (\n  {}\n)",
        definitions.join(",\n  ")
    ));
    let indexes = sqlx::query("SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname=$1 AND t.relname=$2 AND NOT i.indisprimary AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid=i.indexrelid) ORDER BY i.indexrelid")
        .bind(schema).bind(table).fetch_all(pool).await.map_err(db_error)?;
    for index in indexes {
        ddl.push_str(";\n");
        ddl.push_str(&row_string(&index, 0)?);
    }
    Ok(ddl)
}

async fn postgres_table_sequence_ddl(
    pool: &AnyPool,
    schema: &str,
    table: &str,
) -> Result<String, (String, String)> {
    // Identity columns create their own sequence as part of CREATE TABLE. For
    // legacy serial columns PostgreSQL stores a nextval() default that refers
    // to a separate, owned sequence, so restore must recreate it first.
    let rows = sqlx::query("SELECT quote_ident(sn.nspname)||'.'||quote_ident(seq.relname), quote_ident(a.attname) FROM pg_attribute a JOIN pg_class t ON t.oid=a.attrelid JOIN pg_namespace tn ON tn.oid=t.relnamespace JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum JOIN pg_depend dep ON dep.refobjid=a.attrelid AND dep.refobjsubid=a.attnum AND dep.deptype='a' JOIN pg_class seq ON seq.oid=dep.objid AND seq.relkind='S' JOIN pg_namespace sn ON sn.oid=seq.relnamespace WHERE tn.nspname=$1 AND t.relname=$2 AND a.attnum>0 AND NOT a.attisdropped AND a.attidentity='' ORDER BY a.attnum")
        .bind(schema)
        .bind(table)
        .fetch_all(pool)
        .await
        .map_err(db_error)?;
    let qualified_table = format!(
        "{}.{}",
        quote_identifier("postgresql", schema)?,
        quote_identifier("postgresql", table)?
    );
    let mut statements = Vec::new();
    for row in rows {
        let sequence = row_string(&row, 0)?;
        let column = row_string(&row, 1)?;
        statements.push(format!(
            "CREATE SEQUENCE {sequence};\nALTER SEQUENCE {sequence} OWNED BY {qualified_table}.{column}"
        ));
    }
    Ok(statements.join(";\n"))
}

async fn postgres_foreign_key_ddls(
    pool: &AnyPool,
    schema: &str,
    selected_tables: &[&str],
) -> Result<Vec<String>, (String, String)> {
    if selected_tables.is_empty() {
        return Ok(Vec::new());
    }
    let selected: std::collections::HashSet<&str> = selected_tables.iter().copied().collect();
    let table_rows = sqlx::query("SELECT CAST(c.relname AS TEXT), 'ALTER TABLE '||quote_ident(n.nspname)||'.'||quote_ident(c.relname)||' ADD CONSTRAINT '||quote_ident(con.conname)||' '||pg_get_constraintdef(con.oid,true) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND con.contype='f' ORDER BY c.relname, con.conname")
        .bind(schema).fetch_all(pool).await.map_err(db_error)?;
    let mut statements = Vec::new();
    for row in &table_rows {
        let table = row_string(row, 0)?;
        if selected.contains(table.as_str()) {
            statements.push(row_string(row, 1)?);
        }
    }
    Ok(statements)
}

async fn postgres_sequence_sql(
    pool: &AnyPool,
    schema: &str,
    table: &str,
) -> Result<String, (String, String)> {
    let rows = sqlx::query(r#"SELECT CAST(a.attname AS TEXT), CAST(pg_get_serial_sequence(format('%I.%I',$1,$2),a.attname) AS TEXT)
        FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
        LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE n.nspname=$1 AND c.relname=$2 AND a.attnum>0 AND NOT a.attisdropped
          AND (a.attidentity<>'' OR pg_get_expr(d.adbin,d.adrelid) LIKE 'nextval(%')"#)
        .bind(schema).bind(table).fetch_all(pool).await.map_err(db_error)?;
    let qualified = format!(
        "{}.{}",
        quote_identifier("postgresql", schema)?,
        quote_identifier("postgresql", table)?
    );
    let mut output = String::new();
    for row in &rows {
        let column = row_string(row, 0)?;
        let sequence = row_string(row, 1)?;
        output.push_str(&format!(
            "SELECT setval({}::regclass, COALESCE(MAX({}), 1), COUNT(*) > 0) FROM {};\n",
            sql_literal("postgresql", &Value::String(sequence))?,
            quote_identifier("postgresql", &column)?,
            qualified
        ));
    }
    Ok(output)
}

async fn write_table_insert_sql<W: Write>(
    output: &mut W,
    pool: &DirectPool,
    kind: &str,
    schema: &str,
    table: &str,
    limit: u32,
) -> Result<(), (String, String)> {
    let qualified = if !schema.is_empty() && kind == "postgresql" {
        format!(
            "{}.{}",
            quote_identifier(kind, schema)?,
            quote_identifier(kind, table)?
        )
    } else {
        quote_identifier(kind, table)?
    };
    let sql = if limit == 0 {
        format!("SELECT * FROM {qualified}")
    } else {
        format!(
            "SELECT * FROM {qualified} LIMIT {}",
            limit.clamp(1, 100_000)
        )
    };
    let mut raw_columns = None;
    match pool {
        DirectPool::MySql(pool) => {
            let mut rows = sqlx::query(&sql).fetch(pool);
            while let Some(row) = rows.try_next().await.map_err(db_error)? {
                write_insert_row(
                    output,
                    kind,
                    &qualified,
                    &mut raw_columns,
                    mysql_row_json(&row)?,
                )?;
            }
        }
        DirectPool::Postgres(pool) => {
            let mut rows = sqlx::query(&sql).fetch(pool);
            while let Some(row) = rows.try_next().await.map_err(db_error)? {
                write_insert_row(
                    output,
                    kind,
                    &qualified,
                    &mut raw_columns,
                    postgres_row_json(&row)?,
                )?;
            }
        }
        DirectPool::Sqlite(pool) => {
            let mut rows = sqlx::query(&sql).fetch(pool);
            while let Some(row) = rows.try_next().await.map_err(db_error)? {
                write_insert_row(
                    output,
                    kind,
                    &qualified,
                    &mut raw_columns,
                    sqlite_row_json(&row)?,
                )?;
            }
        }
    }
    Ok(())
}

fn write_insert_row<W: Write>(
    output: &mut W,
    kind: &str,
    qualified: &str,
    raw_columns: &mut Option<Vec<String>>,
    row: Value,
) -> Result<(), (String, String)> {
    let object = row.as_object().ok_or_else(|| {
        (
            "export_failed".into(),
            "A database row could not be represented as an object".into(),
        )
    })?;
    let columns = raw_columns.get_or_insert_with(|| object.keys().cloned().collect());
    let quoted_columns = columns
        .iter()
        .map(|column| quote_identifier(kind, column))
        .collect::<Result<Vec<_>, _>>()?;
    let values = columns
        .iter()
        .map(|column| sql_literal(kind, object.get(column).unwrap_or(&Value::Null)))
        .collect::<Result<Vec<_>, _>>()?;
    write_export(
        output,
        &format!(
            "INSERT INTO {qualified} ({}) VALUES ({});\n",
            quoted_columns.join(", "),
            values.join(", ")
        ),
    )
}

fn sql_literal(kind: &str, value: &Value) -> Result<String, (String, String)> {
    match value {
        Value::Null => Ok("NULL".into()),
        Value::Bool(value) => Ok(if *value { "TRUE" } else { "FALSE" }.into()),
        Value::Number(value) => Ok(value.to_string()),
        Value::String(value) => Ok(format!("'{}'", value.replace('\'', "''"))),
        Value::Object(object) if object.get("base64").and_then(Value::as_str).is_some() => {
            let bytes = BASE64
                .decode(object["base64"].as_str().unwrap())
                .map_err(|e| ("export_failed".into(), e.to_string()))?;
            let hex = bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            Ok(match kind {
                "mysql" => format!("0x{hex}"),
                "postgresql" => format!("decode('{hex}','hex')"),
                _ => format!("X'{hex}'"),
            })
        }
        other => Ok(format!("'{}'", other.to_string().replace('\'', "''"))),
    }
}

fn row_string(row: &sqlx::any::AnyRow, index: usize) -> Result<String, (String, String)> {
    row.try_get::<String, _>(index).map_err(db_error)
}

fn bind_values<'q>(
    mut query: sqlx::query::Query<'q, Any, sqlx::any::AnyArguments<'q>>,
    values: &'q [Value],
) -> Result<sqlx::query::Query<'q, Any, sqlx::any::AnyArguments<'q>>, (String, String)> {
    for value in values {
        query = match value {
            Value::Null => query.bind(Option::<String>::None),
            Value::Bool(v) => query.bind(*v),
            Value::Number(v) if v.is_i64() => query.bind(v.as_i64().unwrap()),
            Value::Number(v) if v.is_u64() => query.bind(v.as_u64().unwrap() as i64),
            Value::Number(v) => query.bind(v.as_f64().unwrap()),
            Value::String(v) => query.bind(v),
            other => query.bind(other.to_string()),
        };
    }
    Ok(query)
}

fn rows_value(rows: Vec<sqlx::any::AnyRow>) -> DbResult {
    Ok(Value::Array(
        rows.iter().map(row_json).collect::<Result<_, _>>()?,
    ))
}

fn metadata_rows_value(rows: Vec<sqlx::any::AnyRow>) -> DbResult {
    let mut values = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut value = row_json(row)?;
        if let Value::Object(object) = &mut value {
            for key in ["data_type", "is_nullable", "column_key", "column_default"] {
                let Some(Value::Object(binary)) = object.get(key) else {
                    continue;
                };
                let Some(encoded) = binary.get("base64").and_then(Value::as_str) else {
                    continue;
                };
                let Ok(bytes) = BASE64.decode(encoded) else {
                    continue;
                };
                let Ok(text) = String::from_utf8(bytes) else {
                    continue;
                };
                object.insert(key.to_string(), Value::String(text));
            }
        }
        values.push(value);
    }
    Ok(Value::Array(values))
}

fn row_json(row: &sqlx::any::AnyRow) -> Result<Value, (String, String)> {
    let mut object = Map::new();
    for (index, column) in row.columns().iter().enumerate() {
        let raw = row.try_get_raw(index).map_err(db_error)?;
        let value = if raw.is_null() {
            Value::Null
        } else {
            typed_value(row, index, column.type_info().name())
        };
        object.insert(column.name().to_string(), value);
    }
    Ok(Value::Object(object))
}

fn typed_value(row: &sqlx::any::AnyRow, index: usize, kind: &str) -> Value {
    match kind.to_ascii_uppercase().as_str() {
        "BOOL" | "BOOLEAN" => row
            .try_get::<bool, _>(index)
            .map(Value::Bool)
            .unwrap_or_else(|_| text_value(row, index)),
        "INT" | "INT2" | "INT4" | "INT8" | "INT16" | "INT32" | "INT64" | "INTEGER" | "BIGINT"
        | "SMALLINT" | "TINYINT" => row
            .try_get::<i64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| text_value(row, index)),
        "FLOAT" | "FLOAT4" | "FLOAT8" | "REAL" | "DOUBLE" | "DOUBLE PRECISION" => row
            .try_get::<f64, _>(index)
            .map(|v| json!(v))
            .unwrap_or_else(|_| text_value(row, index)),
        "BLOB" | "BYTEA" | "BINARY" | "VARBINARY" => row
            .try_get::<Vec<u8>, _>(index)
            .map(|v| json!({"base64": BASE64.encode(v)}))
            .unwrap_or_else(|_| text_value(row, index)),
        _ => text_value(row, index),
    }
}

fn text_value(row: &sqlx::any::AnyRow, index: usize) -> Value {
    row.try_get::<String, _>(index)
        .map(Value::String)
        .unwrap_or_else(|_| Value::String("<unsupported>".into()))
}

fn validate_identifier(value: &str) -> Result<(), (String, String)> {
    if !value.is_empty() && !value.contains('\0') {
        Ok(())
    } else {
        Err((
            "invalid_identifier".into(),
            format!("Invalid SQL identifier: {value}"),
        ))
    }
}
fn quote_identifier(kind: &str, value: &str) -> Result<String, (String, String)> {
    validate_identifier(value)?;
    Ok(if kind == "mysql" {
        format!("`{}`", value.replace('`', "``"))
    } else {
        format!("\"{}\"", value.replace('"', "\"\""))
    })
}
fn require_sql(sql: &str) -> Result<(), (String, String)> {
    if sql.trim().is_empty() {
        Err(("invalid_query".into(), "SQL is required".into()))
    } else {
        Ok(())
    }
}
fn csv_value(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(v) => v.clone(),
        other => other.to_string(),
    }
}
fn db_error(error: sqlx::Error) -> (String, String) {
    ("database_error".into(), error.to_string())
}
fn csv_error(error: csv::Error) -> (String, String) {
    ("export_failed".into(), error.to_string())
}
fn redact(mut message: String, password: &str) -> String {
    if !password.is_empty() {
        message = message.replace(password, "***");
    }
    message
}

impl Response {
    fn success(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }
    fn failure(id: impl Into<String>, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            ok: false,
            result: None,
            error: Some(ErrorBody {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_update_without_key() {
        let mutation = Mutation {
            action: "update".into(),
            table: "items".into(),
            values: Map::from_iter([("name".into(), json!("changed"))]),
            key: Map::new(),
        };
        assert_eq!(
            mutation_sql("mysql", "", &mutation).unwrap_err().0,
            "unsafe_mutation"
        );
    }

    #[test]
    fn postgres_mutations_use_numbered_placeholders() {
        let mutation = Mutation {
            action: "update".into(),
            table: "items".into(),
            values: Map::from_iter([("name".into(), json!("changed"))]),
            key: Map::from_iter([("id".into(), json!(7))]),
        };
        let (sql, values) = mutation_sql("postgresql", "public", &mutation).unwrap();
        assert_eq!(
            sql,
            "UPDATE \"public\".\"items\" SET \"name\" = $1 WHERE \"id\" = $2"
        );
        assert_eq!(values, vec![json!("changed"), json!(7)]);
    }

    #[test]
    fn empty_inserts_use_database_defaults() {
        let mutation = Mutation {
            action: "insert".into(),
            table: "items".into(),
            values: Map::new(),
            key: Map::new(),
        };
        assert_eq!(
            mutation_sql("mysql", "", &mutation).unwrap().0,
            "INSERT INTO `items` () VALUES ()"
        );
        assert_eq!(
            mutation_sql("postgresql", "public", &mutation).unwrap().0,
            "INSERT INTO \"public\".\"items\" DEFAULT VALUES"
        );
        assert_eq!(
            mutation_sql("sqlite", "", &mutation).unwrap().0,
            "INSERT INTO \"items\" DEFAULT VALUES"
        );
    }

    #[test]
    fn filters_quote_identifiers_and_bind_values() {
        let filters = vec![Filter {
            column: "name".into(),
            operator: "contains".into(),
            value: json!("lit"),
            join: "and".into(),
        }];
        let (sql, values) = filter_clause("sqlite", &filters).unwrap();
        assert_eq!(sql, " WHERE (\"name\" LIKE ?)");
        assert_eq!(values, vec![json!("%lit%")]);
        let unusual = vec![Filter {
            column: "显示 \"名称\"".into(),
            operator: "equals".into(),
            value: json!(1),
            join: "and".into(),
        }];
        assert_eq!(
            filter_clause("sqlite", &unusual).unwrap().0,
            " WHERE (\"显示 \"\"名称\"\"\" = ?)"
        );
        assert_eq!(quote_identifier("mysql", "a`b").unwrap(), "`a``b`");
        assert_eq!(quote_identifier("sqlite", "a\"b").unwrap(), "\"a\"\"b\"");
        assert_eq!(
            quote_identifier("sqlite", "bad\0name").unwrap_err().0,
            "invalid_identifier"
        );
    }

    #[test]
    fn filters_support_or_join() {
        let filters = vec![
            Filter {
                column: "name".into(),
                operator: "equals".into(),
                value: json!("missing"),
                join: "and".into(),
            },
            Filter {
                column: "score".into(),
                operator: "equals".into(),
                value: json!(1),
                join: "or".into(),
            },
        ];
        let (sql, values) = filter_clause("sqlite", &filters).unwrap();
        assert_eq!(sql, " WHERE (\"name\" = ? OR \"score\" = ?)");
        assert_eq!(values, vec![json!("missing"), json!(1)]);
    }

    #[test]
    fn sql_literals_preserve_quotes_and_binary_values() {
        assert_eq!(
            sql_literal("mysql", &json!("O'Reilly")).unwrap(),
            "'O''Reilly'"
        );
        assert_eq!(
            sql_literal("sqlite", &json!({"base64":"AP8="})).unwrap(),
            "X'00ff'"
        );
        assert_eq!(
            sql_literal("postgresql", &json!({"base64":"AP8="})).unwrap(),
            "decode('00ff','hex')"
        );
    }

    #[test]
    fn restore_drops_existing_objects_before_replaying_snapshot() {
        assert_eq!(
            object_drop_sql("sqlite", "", "records", "table").unwrap(),
            Some("DROP TABLE IF EXISTS \"records\"".into())
        );
        assert_eq!(
            object_drop_sql("mysql", "", "orders", "BASE TABLE").unwrap(),
            Some("DROP TABLE IF EXISTS `orders`".into())
        );
        assert_eq!(
            object_drop_sql("postgresql", "public", "active_users", "view").unwrap(),
            Some("DROP VIEW IF EXISTS \"public\".\"active_users\"".into())
        );
        assert_eq!(
            object_drop_sql("postgresql", "public", "users", "base table").unwrap(),
            Some("DROP TABLE IF EXISTS \"public\".\"users\" CASCADE".into())
        );
    }

    #[test]
    fn write_protection_classifies_dangerous_sql() {
        assert!(is_dangerous_sql("RESTORE"));
        assert!(is_dangerous_sql("DROP TABLE users"));
        assert!(is_dangerous_sql("UPDATE users SET active = 0"));
        assert!(!is_dangerous_sql(
            "UPDATE users SET active = 0 WHERE id = 1"
        ));
        assert!(!is_dangerous_sql(
            "INSERT INTO users (name) VALUES ('drop table')"
        ));
    }

    #[test]
    fn tls_url_contains_requested_postgres_options_without_password_leakage() {
        let connection = Connection {
            kind: "postgresql".into(),
            host: "db.example".into(),
            port: 5432,
            username: "alice".into(),
            password: "secret".into(),
            database: "app".into(),
            path: String::new(),
            ssl: true,
            ca_certificate_path: "/tmp/ca.pem".into(),
            server_name: "db.example".into(),
            ssh_host: String::new(),
            ssh_port: 0,
            ssh_username: String::new(),
            ssh_key_path: String::new(),
            ssh_local_port: 0,
            proxy_url: String::new(),
            read_only: false,
            production_protection: false,
        };
        let url = connection.url().unwrap();
        assert!(url.contains("sslmode=require"));
        assert!(url.contains("sslrootcert=%2Ftmp%2Fca.pem"));
        assert!(redact("connection failed: secret".to_string(), "secret").contains("***"));
    }
}
