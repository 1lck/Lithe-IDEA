use serde_json::{json, Map, Value};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, BufRead, Write},
    path::PathBuf,
    process::{Command, Stdio},
};

fn main() {
    let connections = load_json_env("LITHE_DB_MCP_CONNECTIONS").unwrap_or_else(|| json!({}));
    let policy = load_json_env("LITHE_DB_MCP_POLICY").unwrap_or_else(|| json!({}));
    let audit_path = env::var_os("LITHE_DB_MCP_AUDIT_LOG").map(PathBuf::from);
    let recovery_dir = env::var_os("LITHE_DB_MCP_RECOVERY_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| env::temp_dir().join("lithe-db-mcp-recovery"));

    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) if !line.trim().is_empty() => line,
            _ => continue,
        };
        let request: Value = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                write_response(
                    &mut stdout,
                    &json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":error.to_string()}}),
                );
                continue;
            }
        };
        if request.get("method").and_then(Value::as_str) == Some("notifications/initialized") {
            continue;
        }
        let response = handle_request(
            &request,
            &connections,
            &policy,
            &recovery_dir,
            audit_path.as_ref(),
        );
        if request.get("id").is_some() {
            write_response(&mut stdout, &response);
        }
    }
}

fn handle_request(
    request: &Value,
    connections: &Value,
    policy: &Value,
    recovery_dir: &PathBuf,
    audit_path: Option<&PathBuf>,
) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "lithe-db-mcp", "version": env!("CARGO_PKG_VERSION")}
        })),
        "tools/list" => Ok(tools()),
        "tools/call" => call_tool(&params, connections, policy, recovery_dir, audit_path),
        _ => Err(format!("Unknown MCP method: {method}")),
    };
    match result {
        Ok(value) => json!({"jsonrpc":"2.0","id":id,"result":value}),
        Err(message) => json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":message}}),
    }
}

fn tools() -> Value {
    let tool = |name: &str, description: &str, properties: Value, required: &[&str]| json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required}});
    json!({"tools":[
        tool("db_list_connections", "List configured database aliases without revealing credentials.", json!({}), &[]),
        tool("db_list_tables", "List tables and views for a configured connection.", json!({"connection":{"type":"string"}}), &["connection"]),
        tool("db_describe_table", "Read columns, indexes, and foreign keys for a table.", json!({"connection":{"type":"string"},"table":{"type":"string"}}), &["connection","table"]),
        tool("db_list_objects", "List views, routines, triggers, or sequences.", json!({"connection":{"type":"string"},"kind":{"type":"string","enum":["views","routines","triggers","sequences"]}}), &["connection","kind"]),
        tool("db_plan_sql", "Classify SQL and report whether explicit write confirmation is required.", json!({"sql":{"type":"string"}}), &["sql"]),
        tool("db_query", "Execute a read-only SQL query with a bounded result set.", json!({"connection":{"type":"string"},"sql":{"type":"string"},"values":{"type":"array"},"limit":{"type":"integer"}}), &["connection","sql"]),
        tool("db_explain", "Inspect the database query plan without executing the query.", json!({"connection":{"type":"string"},"sql":{"type":"string"},"format":{"type":"string"}}), &["connection","sql"]),
        tool("db_diagnostics", "Read table size, locks, slow queries, indexes, data quality, or schema impact diagnostics.", json!({"connection":{"type":"string"},"kind":{"type":"string"},"table":{"type":"string"}}), &["connection","kind"]),
        tool("db_backup", "Create a recoverable SQL backup before an approved change.", json!({"connection":{"type":"string"},"tables":{"type":"array"}}), &["connection"]),
        tool("db_execute", "Execute one approved SQL mutation. Requires policy permission and confirmed=true.", json!({"connection":{"type":"string"},"sql":{"type":"string"},"values":{"type":"array"},"confirmed":{"type":"boolean"}}), &["connection","sql","confirmed"]),
        tool("db_transaction", "Execute multiple statements atomically after policy approval.", json!({"connection":{"type":"string"},"statements":{"type":"array"},"confirmed":{"type":"boolean"}}), &["connection","statements","confirmed"]),
        tool("db_schema_change", "Apply a structured schema change after policy approval.", json!({"connection":{"type":"string"},"operation":{"type":"string"},"table":{"type":"string"},"name":{"type":"string"},"confirmed":{"type":"boolean"}}), &["connection","operation","confirmed"]),
        tool("db_restore", "Restore a previously created backup reference after explicit confirmation.", json!({"connection":{"type":"string"},"reference":{"type":"string"},"confirmed":{"type":"boolean"}}), &["connection","reference","confirmed"])
    ]})
}

fn call_tool(
    params: &Value,
    connections: &Value,
    policy: &Value,
    recovery_dir: &PathBuf,
    audit_path: Option<&PathBuf>,
) -> Result<Value, String> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or("tools/call requires a tool name")?;
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let result = match name {
        "db_list_connections" => {
            let rows = connections.as_object().unwrap_or(&Map::new()).iter().map(|(alias, value)| json!({"connection":alias,"kind":value.get("kind").and_then(Value::as_str).unwrap_or("unknown"),"host":value.get("host").and_then(Value::as_str).unwrap_or(""),"database":value.get("database").and_then(Value::as_str).unwrap_or("")})).collect::<Vec<_>>();
            Ok(json!({"rows":rows}))
        }
        "db_plan_sql" => Ok(classify_sql(
            args.get("sql").and_then(Value::as_str).unwrap_or_default(),
        )),
        "db_list_tables" => read_call("listTables", &args, connections, policy, None),
        "db_describe_table" => {
            let table = required_string(&args, "table")?;
            read_call("describeTable", &args, connections, policy, Some(table))
        }
        "db_list_objects" => read_call("listObjects", &args, connections, policy, None),
        "db_query" => read_call("query", &args, connections, policy, None),
        "db_explain" => read_call("explain", &args, connections, policy, None),
        "db_diagnostics" => read_call("diagnostics", &args, connections, policy, None),
        "db_backup" => backup_call(&args, connections, policy, recovery_dir, audit_path),
        "db_execute" => write_call(
            "execute",
            &args,
            connections,
            policy,
            recovery_dir,
            audit_path,
        ),
        "db_transaction" => write_call(
            "transaction",
            &args,
            connections,
            policy,
            recovery_dir,
            audit_path,
        ),
        "db_schema_change" => write_call(
            "schemaChange",
            &args,
            connections,
            policy,
            recovery_dir,
            audit_path,
        ),
        "db_restore" => restore_call(&args, connections, policy, recovery_dir, audit_path),
        _ => Err(format!("Unknown tool: {name}")),
    }?;
    Ok(tool_result(result))
}

fn read_call(
    method: &str,
    args: &Value,
    connections: &Value,
    policy: &Value,
    table: Option<&str>,
) -> Result<Value, String> {
    let alias = required_string(args, "connection")?;
    check_policy(policy, alias, table, "read", false)?;
    let connection = connection_for(connections, alias)?;
    let mut params = args.as_object().cloned().unwrap_or_default();
    params.remove("connection");
    params.insert("connection".into(), connection);
    if method == "listObjects" {
        params
            .entry("objectKind")
            .or_insert_with(|| json!(args.get("kind").and_then(Value::as_str).unwrap_or("views")));
    }
    if method == "diagnostics" {
        params.entry("diagnosticKind").or_insert_with(|| {
            json!(args
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("tableSize"))
        });
    }
    let response = sidecar_call(method, Value::Object(params))?;
    unwrap_sidecar(response)
}

fn backup_call(
    args: &Value,
    connections: &Value,
    policy: &Value,
    recovery_dir: &PathBuf,
    audit_path: Option<&PathBuf>,
) -> Result<Value, String> {
    let alias = required_string(args, "connection")?;
    check_policy(policy, alias, None, "backup", true)?;
    let connection = connection_for(connections, alias)?;
    let tables = args.get("tables").cloned().unwrap_or_else(|| json!([]));
    fs::create_dir_all(recovery_dir).map_err(|error| error.to_string())?;
    let reference = recovery_dir.join(format!("{}.sql", uuid::Uuid::new_v4()));
    let response = sidecar_call(
        "exportSqlToFile",
        json!({"connection":connection,"selectedTables":tables,"includeStructure":true,"includeData":true,"limit":0,"outputPath":reference}),
    )?;
    let result = unwrap_sidecar(response)?;
    let output_path = result
        .get("path")
        .and_then(Value::as_str)
        .ok_or("Sidecar backup did not return an output path")?;
    if PathBuf::from(output_path) != reference || !reference.is_file() {
        return Err("Sidecar backup did not create the requested recovery file".into());
    }
    let bytes = result
        .get("byteCount")
        .and_then(Value::as_u64)
        .ok_or("Sidecar backup did not return a byte count")?;
    if fs::metadata(&reference)
        .map_err(|error| error.to_string())?
        .len()
        != bytes
    {
        return Err("Sidecar backup size did not match the created recovery file".into());
    }
    let sha256 = result
        .get("sha256")
        .and_then(Value::as_str)
        .ok_or("Sidecar backup did not return a SHA-256 checksum")?;
    append_audit(
        audit_path,
        json!({"action":"backup","connection":alias,"reference":reference,"bytes":bytes,"sha256":sha256,"succeeded":true}),
    )?;
    Ok(json!({"reference":reference,"bytes":bytes,"sha256":sha256}))
}

fn write_call(
    method: &str,
    args: &Value,
    connections: &Value,
    policy: &Value,
    recovery_dir: &PathBuf,
    audit_path: Option<&PathBuf>,
) -> Result<Value, String> {
    let alias = required_string(args, "connection")?;
    let confirmed = args
        .get("confirmed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    check_policy(
        policy,
        alias,
        args.get("table").and_then(Value::as_str),
        "write",
        confirmed,
    )?;
    if !confirmed {
        return Err("Write operations require confirmed=true".into());
    }
    let backup = backup_call(
        &json!({"connection":alias}),
        connections,
        policy,
        recovery_dir,
        audit_path,
    )?;
    let connection = connection_for(connections, alias)?;
    let mut params = args.as_object().cloned().unwrap_or_default();
    params.remove("connection");
    params.insert("connection".into(), connection);
    params.insert("allowWrite".into(), json!(true));
    params.insert("confirmed".into(), json!(true));
    if method == "transaction" {
        if let Some(statements) = params.get_mut("statements") {
            normalize_statements(statements);
        }
    }
    let response = sidecar_call(method, Value::Object(params))?;
    let result = unwrap_sidecar(response)?;
    append_audit(
        audit_path,
        json!({"action":method,"connection":alias,"backup":backup,"succeeded":true}),
    )?;
    Ok(result)
}

fn restore_call(
    args: &Value,
    connections: &Value,
    policy: &Value,
    recovery_dir: &PathBuf,
    audit_path: Option<&PathBuf>,
) -> Result<Value, String> {
    let alias = required_string(args, "connection")?;
    let confirmed = args
        .get("confirmed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    check_policy(policy, alias, None, "write", confirmed)?;
    if !confirmed {
        return Err("Restore requires confirmed=true".into());
    }
    let reference = recovery_reference(recovery_dir, required_string(args, "reference")?)?;
    let backup = backup_call(
        &json!({"connection":alias}),
        connections,
        policy,
        recovery_dir,
        audit_path,
    )?;
    let connection = connection_for(connections, alias)?;
    let response = sidecar_call(
        "restoreSqlFile",
        json!({"connection":connection,"outputPath":reference,"allowWrite":true,"confirmed":true}),
    )?;
    let result = unwrap_sidecar(response)?;
    append_audit(
        audit_path,
        json!({"action":"restore","connection":alias,"reference":reference,"backup":backup,"succeeded":true}),
    )?;
    Ok(result)
}

fn normalize_statements(statements: &mut Value) {
    if let Some(items) = statements.as_array_mut() {
        for item in items {
            if item.get("values").is_none() {
                item.as_object_mut()
                    .map(|object| object.insert("values".into(), json!([])));
            }
        }
    }
}

fn check_policy(
    policy: &Value,
    connection: &str,
    table: Option<&str>,
    action: &str,
    confirmed: bool,
) -> Result<(), String> {
    let default = policy.get("default").and_then(Value::as_object);
    let allowed_default = default
        .and_then(|value| value.get(action))
        .and_then(Value::as_bool)
        .unwrap_or(action == "read" || action == "backup");
    let mut allowed = allowed_default;
    if let Some(connection_policy) = policy
        .get("connections")
        .and_then(|value| value.get(connection))
        .and_then(Value::as_object)
    {
        if let Some(value) = connection_policy.get(action).and_then(Value::as_bool) {
            allowed = value;
        }
        if let Some(table_name) = table {
            if let Some(table_policy) = connection_policy
                .get("tables")
                .and_then(|value| value.get(table_name))
                .and_then(Value::as_object)
            {
                if let Some(value) = table_policy.get(action).and_then(Value::as_bool) {
                    allowed = value;
                }
            }
        }
    }
    if !allowed {
        return Err(format!(
            "Policy denied {action} access for connection {connection}"
        ));
    }
    if action == "write" && !confirmed {
        return Err("Write approval is required".into());
    }
    Ok(())
}

fn classify_sql(sql: &str) -> Value {
    let trimmed = sql.trim_start();
    let upper = trimmed.to_ascii_uppercase();
    let kind = if upper.starts_with("SELECT")
        || upper.starts_with("SHOW")
        || upper.starts_with("DESCRIBE")
        || upper.starts_with("EXPLAIN")
        || upper.starts_with("PRAGMA")
    {
        "query"
    } else if upper.starts_with("INSERT")
        || upper.starts_with("UPDATE")
        || upper.starts_with("DELETE")
        || upper.starts_with("MERGE")
        || upper.starts_with("REPLACE")
    {
        "mutation"
    } else if upper.starts_with("CREATE")
        || upper.starts_with("ALTER")
        || upper.starts_with("DROP")
        || upper.starts_with("TRUNCATE")
    {
        "definition"
    } else {
        "unknown"
    };
    let has_where = upper.split_whitespace().any(|token| token == "WHERE");
    let dangerous = upper.starts_with("DROP ")
        || upper.starts_with("TRUNCATE ")
        || (upper.starts_with("UPDATE ") && !has_where)
        || (upper.starts_with("DELETE ") && !has_where);
    json!({"kind":kind,"requiresConfirmation":dangerous || kind == "unknown","dangerous":dangerous,"statementCount":count_sql_statements(sql)})
}

fn count_sql_statements(sql: &str) -> usize {
    let mut count = 0;
    let mut has_content = false;
    let mut quote = None;
    let mut line_comment = false;
    let mut block_comment = false;
    let characters: Vec<char> = sql.chars().collect();
    let mut index = 0;

    while index < characters.len() {
        let character = characters[index];
        let next = characters.get(index + 1).copied();
        if line_comment {
            if character == '\n' {
                line_comment = false;
            }
            index += 1;
            continue;
        }
        if block_comment {
            if character == '*' && next == Some('/') {
                block_comment = false;
                index += 2;
            } else {
                index += 1;
            }
            continue;
        }
        if let Some(active_quote) = quote {
            if character == active_quote {
                if next == Some(active_quote) {
                    index += 2;
                    continue;
                }
                quote = None;
            }
            has_content = true;
            index += 1;
            continue;
        }
        if character == '-' && next == Some('-') {
            line_comment = true;
            index += 2;
            continue;
        }
        if character == '/' && next == Some('*') {
            block_comment = true;
            index += 2;
            continue;
        }
        if matches!(character, '\'' | '"' | '`') {
            quote = Some(character);
            has_content = true;
            index += 1;
            continue;
        }
        if character == ';' {
            if has_content {
                count += 1;
                has_content = false;
            }
        } else if !character.is_whitespace() {
            has_content = true;
        }
        index += 1;
    }
    if has_content {
        count += 1;
    }
    count
}

fn connection_for(connections: &Value, alias: &str) -> Result<Value, String> {
    connections
        .get(alias)
        .cloned()
        .ok_or_else(|| format!("Unknown database connection alias: {alias}"))
}

fn recovery_reference(recovery_dir: &PathBuf, requested: &str) -> Result<PathBuf, String> {
    let root = fs::canonicalize(recovery_dir).map_err(|error| error.to_string())?;
    let reference = fs::canonicalize(requested).map_err(|error| error.to_string())?;
    if !reference.starts_with(&root) {
        return Err("Restore reference is outside the configured recovery directory".into());
    }
    Ok(reference)
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Missing required argument: {key}"))
}

fn sidecar_call(method: &str, params: Value) -> Result<Value, String> {
    let sidecar = env::var_os("LITHE_DB_SIDECAR_EXECUTABLE")
        .map(PathBuf::from)
        .or_else(|| {
            env::current_exe()
                .ok()
                .and_then(|path| path.parent().map(|parent| parent.join("lithe-db-sidecar")))
        })
        .ok_or("Database sidecar executable was not found")?;
    let request = json!({"id":uuid::Uuid::new_v4().to_string(),"method":method,"params":params});
    let mut child = Command::new(sidecar)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    child
        .stdin
        .take()
        .ok_or("Could not open sidecar stdin")?
        .write_all(request.to_string().as_bytes())
        .map_err(|error| error.to_string())?;
    let output = child
        .wait_with_output()
        .map_err(|error| error.to_string())?;
    let response: Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Invalid sidecar response: {error}"))?;
    if !output.status.success() {
        return Err(response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("Sidecar failed")
            .into());
    }
    Ok(response)
}

fn unwrap_sidecar(response: Value) -> Result<Value, String> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(response
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("Sidecar request failed")
            .into());
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| "Sidecar returned no result".into())
}

fn tool_result(value: Value) -> Value {
    json!({"content":[{"type":"text","text":serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string())}]})
}

fn append_audit(path: Option<&PathBuf>, value: Value) -> Result<(), String> {
    let Some(path) = path else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| error.to_string())?;
    writeln!(file, "{}", value).map_err(|error| error.to_string())
}

fn load_json_env(key: &str) -> Option<Value> {
    env::var(key)
        .ok()
        .and_then(|value| serde_json::from_str(&value).ok())
}

fn write_response(stdout: &mut impl Write, response: &Value) {
    let _ = writeln!(stdout, "{}", response);
    let _ = stdout.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_planning_counts_real_statements_and_protects_writes() {
        let select = classify_sql("SELECT 'a;b';");
        assert_eq!(select["statementCount"], 1);
        assert_eq!(select["requiresConfirmation"], false);

        let update = classify_sql("UPDATE items SET name = 'x'\nWHERE id = 1");
        assert_eq!(update["statementCount"], 1);
        assert_eq!(update["dangerous"], false);

        let delete = classify_sql("DELETE FROM items");
        assert_eq!(delete["dangerous"], true);
        assert_eq!(delete["requiresConfirmation"], true);

        let multiple = classify_sql("SELECT 1; /* ; */ SELECT 2;");
        assert_eq!(multiple["statementCount"], 2);
    }

    #[test]
    fn policy_defaults_to_read_and_can_scope_writes() {
        let policy = json!({
            "default": {"read": true, "write": false},
            "connections": {
                "local": {
                    "write": true,
                    "tables": {"audit": {"write": false}}
                }
            }
        });
        assert!(check_policy(&policy, "local", Some("items"), "read", false).is_ok());
        assert!(check_policy(&policy, "local", Some("items"), "write", true).is_ok());
        assert!(check_policy(&policy, "local", Some("audit"), "write", true).is_err());
        assert!(check_policy(&policy, "unknown", None, "write", true).is_err());
    }

    #[test]
    fn tools_expose_automation_only_database_operations() {
        let listed = tools();
        let names = listed["tools"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|tool| tool["name"].as_str())
            .collect::<Vec<_>>();
        assert!(names.contains(&"db_query"));
        assert!(names.contains(&"db_execute"));
        assert!(!names.iter().any(|name| name.contains("chat")));
        assert!(!names.iter().any(|name| name.contains("agent")));
    }

    #[test]
    fn recovery_reference_rejects_paths_outside_recovery_directory() {
        let root =
            std::env::temp_dir().join(format!("lithe-mcp-recovery-{}", uuid::Uuid::new_v4()));
        let nested = root.join("nested");
        let outside = root.parent().unwrap().join(format!(
            "{}-outside",
            root.file_name().unwrap().to_string_lossy()
        ));
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("ok.sql"), "SELECT 1;").unwrap();
        std::fs::write(&outside, "SELECT 2;").unwrap();

        let valid = recovery_reference(&root, nested.join("ok.sql").to_str().unwrap()).unwrap();
        assert!(valid.starts_with(std::fs::canonicalize(&root).unwrap()));
        let escape = nested
            .join("..")
            .join("..")
            .join(outside.file_name().unwrap());
        assert!(recovery_reference(&root, escape.to_str().unwrap()).is_err());

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_file(outside);
    }
}
