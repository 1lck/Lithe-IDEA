use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde_json::{json, Map, Value};
use std::{borrow::Cow, time::Duration};
use tiberius::{AuthMethod, Client, ColumnData, Config, FromSql};
use tokio::net::TcpStream;
use tokio_util::compat::{Compat, TokioAsyncWriteCompatExt};

use super::{
    ensure_mutations_allowed, ensure_transaction_allowed, ensure_write_allowed, open_ssh_tunnel,
    parse_csv, parse_json, scalar_string, validate_identifier, Connection, DbResult, Filter,
    Mutation, Params, Sort,
};

type SqlServerClient = Client<Compat<TcpStream>>;

pub(super) async fn method(method: &str, params: Params) -> DbResult {
    let tunnel = open_ssh_tunnel(&params.connection).await?;
    let connection = if tunnel.is_some() {
        params.connection.with_tunnel()?
    } else {
        params.connection.clone()
    };
    let mut client = connect(&connection).await?;
    match method {
        "testConnection" => {
            query(&mut client, "SELECT 1 AS connected", 1).await?;
            Ok(json!({"connected": true}))
        }
        "listTables" => query(
            &mut client,
            "SELECT TABLE_NAME AS table_name, TABLE_TYPE AS table_type FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' ORDER BY TABLE_NAME",
            10_000,
        ).await,
        "describeTable" => {
            let table = sql_string(&params.table);
            query(&mut client, &format!(
                "SELECT c.COLUMN_NAME AS column_name, c.DATA_TYPE AS data_type, c.IS_NULLABLE AS is_nullable, c.COLUMN_DEFAULT AS column_default, CASE WHEN tc.CONSTRAINT_TYPE='PRIMARY KEY' THEN 'PRI' ELSE '' END AS column_key FROM INFORMATION_SCHEMA.COLUMNS c LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ON kcu.TABLE_SCHEMA=c.TABLE_SCHEMA AND kcu.TABLE_NAME=c.TABLE_NAME AND kcu.COLUMN_NAME=c.COLUMN_NAME LEFT JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc ON tc.CONSTRAINT_NAME=kcu.CONSTRAINT_NAME AND tc.CONSTRAINT_TYPE='PRIMARY KEY' WHERE c.TABLE_SCHEMA='dbo' AND c.TABLE_NAME={table} ORDER BY c.ORDINAL_POSITION"
            ), 10_000).await
        }
        "listIndexes" => {
            let table = sql_string(&params.table);
            query(&mut client, &format!(
                "SELECT i.name AS index_name, i.type_desc AS definition FROM sys.indexes i JOIN sys.tables t ON t.object_id=i.object_id JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='dbo' AND t.name={table} AND i.name IS NOT NULL ORDER BY i.name"
            ), 10_000).await
        }
        "listForeignKeys" => {
            let table = sql_string(&params.table);
            query(&mut client, &format!(
                "SELECT fk.name AS constraint_name, pc.name AS column_name, rt.name AS referenced_table_name, rc.name AS referenced_column_name FROM sys.foreign_key_columns fkc JOIN sys.foreign_keys fk ON fk.object_id=fkc.constraint_object_id JOIN sys.tables pt ON pt.object_id=fkc.parent_object_id JOIN sys.schemas ps ON ps.schema_id=pt.schema_id JOIN sys.columns pc ON pc.object_id=pt.object_id AND pc.column_id=fkc.parent_column_id JOIN sys.tables rt ON rt.object_id=fkc.referenced_object_id JOIN sys.columns rc ON rc.object_id=rt.object_id AND rc.column_id=fkc.referenced_column_id WHERE ps.name='dbo' AND pt.name={table} ORDER BY fk.name, fkc.constraint_column_id"
            ), 10_000).await
        }
        "listObjects" => list_objects(&mut client, &params.object_kind).await,
        "pageTable" => page_table(&mut client, &params).await,
        "query" => {
            if !params.values.is_empty() {
                return Err(("unsupported_parameters".into(), "SQL Server parameter values are not available in this version.".into()));
            }
            query(&mut client, &params.sql, params.limit.clamp(1, 10_000) as usize).await
        }
        "execute" => {
            ensure_write_allowed(&connection, &params.sql, params.confirmed, params.allow_write)?;
            execute(&mut client, &params.sql).await
        }
        "applyChanges" => {
            ensure_mutations_allowed(&connection, &params.mutations, params.confirmed, params.allow_write)?;
            apply_changes(&mut client, &params.mutations).await
        }
        "schemaChange" => {
            ensure_write_allowed(&connection, "ALTER TABLE", params.confirmed, params.allow_write)?;
            let sql = schema_change_sql(&params)?;
            execute(&mut client, &sql).await
        }
        "transaction" => {
            ensure_transaction_allowed(&connection, &params.statements, params.confirmed, params.allow_write)?;
            run_transaction(&mut client, &params).await
        }
        "exportCsv" => export_csv(&mut client, &params.sql, params.limit).await,
        "exportJson" => export_json(&mut client, &params.sql, params.limit).await,
        "importCsv" | "importJson" => {
            ensure_write_allowed(&connection, "INSERT", params.confirmed, params.allow_write)?;
            import_data(&mut client, &params, method == "importCsv").await
        }
        "diagnostics" if params.diagnostic_kind == "tableSize" => query(
            &mut client,
            "SELECT t.name AS table_name, SUM(p.rows) AS estimated_rows, SUM(a.total_pages) * 8192 AS total_bytes FROM sys.tables t JOIN sys.indexes i ON t.object_id=i.object_id JOIN sys.partitions p ON i.object_id=p.object_id AND i.index_id=p.index_id JOIN sys.allocation_units a ON p.partition_id=a.container_id GROUP BY t.name ORDER BY total_bytes DESC",
            1_000,
        ).await,
        _ => Err(("unsupported_operation".into(), format!("{method} is not available for SQL Server in this version."))),
    }
}

async fn connect(connection: &Connection) -> Result<SqlServerClient, (String, String)> {
    let mut config = Config::new();
    config.host(connection.host.trim());
    config.port(if connection.port == 0 {
        1433
    } else {
        connection.port
    });
    config.authentication(AuthMethod::sql_server(
        &connection.username,
        &connection.password,
    ));
    if !connection.database.trim().is_empty() {
        config.database(connection.database.trim());
    }
    if connection.ssl {
        config.encryption(tiberius::EncryptionLevel::Required);
        // SQL Server installations commonly use an internal/self-signed leaf.
        // The connection remains encrypted; custom CA verification can be added
        // without changing the persisted profile format.
        config.trust_cert();
    } else {
        config.encryption(tiberius::EncryptionLevel::Off);
    }
    let timeout = Duration::from_secs(8);
    let tcp = tokio::time::timeout(timeout, TcpStream::connect(config.get_addr()))
        .await
        .map_err(|_| {
            (
                "connection_failed".into(),
                "SQL Server connection timed out.".into(),
            )
        })?
        .map_err(|error| {
            (
                "connection_failed".into(),
                redact(error.to_string(), &connection.password),
            )
        })?;
    tokio::time::timeout(timeout, Client::connect(config, tcp.compat_write()))
        .await
        .map_err(|_| {
            (
                "connection_failed".into(),
                "SQL Server handshake timed out.".into(),
            )
        })?
        .map_err(|error| {
            (
                "connection_failed".into(),
                redact(error.to_string(), &connection.password),
            )
        })
}

async fn query(client: &mut SqlServerClient, sql: &str, limit: usize) -> DbResult {
    let stream = client.simple_query(sql).await.map_err(driver_error)?;
    let rows = stream.into_first_result().await.map_err(driver_error)?;
    let truncated = rows.len() > limit;
    let values = rows
        .into_iter()
        .take(limit)
        .map(|row| {
            let mut object = Map::new();
            for (column, cell) in row.cells() {
                object.insert(column.name().to_string(), cell_json(cell));
            }
            Value::Object(object)
        })
        .collect::<Vec<_>>();
    Ok(json!({"rows": values, "truncated": truncated}))
}

async fn execute(client: &mut SqlServerClient, sql: &str) -> DbResult {
    let result = client.execute(sql, &[]).await.map_err(driver_error)?;
    Ok(json!({"rowsAffected": result.total()}))
}

async fn list_objects(client: &mut SqlServerClient, requested: &str) -> DbResult {
    let sql = match requested {
        "views" => "SELECT v.name AS object_name, 'view' AS object_kind, OBJECT_DEFINITION(v.object_id) AS definition FROM sys.views v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE s.name='dbo' ORDER BY v.name",
        "routines" => "SELECT o.name AS object_name, o.type_desc AS object_kind, OBJECT_DEFINITION(o.object_id) AS definition FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name='dbo' AND o.type IN ('P','FN','IF','TF') ORDER BY o.name",
        "triggers" => "SELECT tr.name AS object_name, 'trigger' AS object_kind, OBJECT_DEFINITION(tr.object_id) AS definition FROM sys.triggers tr WHERE tr.parent_class=1 ORDER BY tr.name",
        "sequences" => "SELECT seq.name AS object_name, 'sequence' AS object_kind, CAST(NULL AS nvarchar(max)) AS definition FROM sys.sequences seq JOIN sys.schemas s ON s.schema_id=seq.schema_id WHERE s.name='dbo' ORDER BY seq.name",
        _ => "SELECT TABLE_NAME AS object_name, TABLE_TYPE AS object_kind, CAST(NULL AS nvarchar(max)) AS definition FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='dbo' ORDER BY TABLE_NAME",
    };
    query(client, sql, 10_000).await
}

async fn page_table(client: &mut SqlServerClient, params: &Params) -> DbResult {
    validate_identifier(&params.table)?;
    let table = quote_identifier(&params.table);
    let where_sql = filter_clause(&params.filters)?;
    let order_sql = sort_clause(&params.sort)?;
    let limit = params.limit.clamp(1, 1_000);
    let sql = format!("SELECT * FROM [dbo].{table}{where_sql}{order_sql} OFFSET {} ROWS FETCH NEXT {limit} ROWS ONLY", params.offset);
    let mut result = query(client, &sql, limit as usize).await?;
    let count_sql = format!("SELECT COUNT_BIG(*) AS total_rows FROM [dbo].{table}{where_sql}");
    let count = query(client, &count_sql, 1).await?;
    let total = count
        .get("rows")
        .and_then(Value::as_array)
        .and_then(|rows| rows.first())
        .and_then(|row| row.get("total_rows"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    result
        .as_object_mut()
        .expect("query result")
        .insert("totalRows".into(), json!(total));
    Ok(result)
}

async fn apply_changes(client: &mut SqlServerClient, mutations: &[Mutation]) -> DbResult {
    execute(client, "BEGIN TRANSACTION").await?;
    let mut affected = 0_u64;
    for mutation in mutations {
        let sql = mutation_sql(mutation)?;
        match client.execute(sql, &[]).await {
            Ok(result) => affected += result.total(),
            Err(error) => {
                let _ = client.execute("ROLLBACK TRANSACTION", &[]).await;
                return Err(driver_error(error));
            }
        }
    }
    client
        .execute("COMMIT TRANSACTION", &[])
        .await
        .map_err(driver_error)?;
    Ok(json!({"rowsAffected": affected}))
}

async fn run_transaction(client: &mut SqlServerClient, params: &Params) -> DbResult {
    client
        .execute("BEGIN TRANSACTION", &[])
        .await
        .map_err(driver_error)?;
    let mut affected = 0_u64;
    for statement in &params.statements {
        if !statement.values.is_empty() {
            let _ = client.execute("ROLLBACK TRANSACTION", &[]).await;
            return Err((
                "unsupported_parameters".into(),
                "SQL Server transaction parameters are not available in this version.".into(),
            ));
        }
        match client.execute(&statement.sql, &[]).await {
            Ok(result) => affected += result.total(),
            Err(error) => {
                let _ = client.execute("ROLLBACK TRANSACTION", &[]).await;
                return Err(driver_error(error));
            }
        }
    }
    client
        .execute("COMMIT TRANSACTION", &[])
        .await
        .map_err(driver_error)?;
    Ok(json!({"rowsAffected": affected}))
}

async fn export_csv(client: &mut SqlServerClient, sql: &str, limit: u32) -> DbResult {
    let result = query(client, sql, limit.clamp(1, 100_000) as usize).await?;
    let rows = result["rows"].as_array().cloned().unwrap_or_default();
    let headers: Vec<String> = rows
        .first()
        .and_then(Value::as_object)
        .map(|row| row.keys().cloned().collect())
        .unwrap_or_default();
    let mut writer = csv::Writer::from_writer(Vec::new());
    writer.write_record(&headers).map_err(super::csv_error)?;
    for row in rows {
        let object = row
            .as_object()
            .ok_or_else(|| ("export_failed".into(), "Invalid SQL Server row.".into()))?;
        writer
            .write_record(
                headers
                    .iter()
                    .map(|key| super::csv_value(object.get(key).unwrap_or(&Value::Null))),
            )
            .map_err(super::csv_error)?;
    }
    let bytes = writer
        .into_inner()
        .map_err(|error| ("export_failed".into(), error.to_string()))?;
    Ok(json!({"encoding": "base64", "data": BASE64.encode(bytes)}))
}

async fn export_json(client: &mut SqlServerClient, sql: &str, limit: u32) -> DbResult {
    let result = query(client, sql, limit.clamp(1, 100_000) as usize).await?;
    let bytes = serde_json::to_vec_pretty(&result["rows"])
        .map_err(|error| ("export_failed".into(), error.to_string()))?;
    Ok(json!({"encoding": "base64", "data": BASE64.encode(bytes)}))
}

async fn import_data(client: &mut SqlServerClient, params: &Params, is_csv: bool) -> DbResult {
    let bytes = BASE64.decode(&params.data).map_err(|error| {
        (
            "invalid_import".into(),
            format!("Invalid base64 data: {error}"),
        )
    })?;
    let rows = if is_csv {
        parse_csv(&bytes)?
    } else {
        parse_json(&bytes)?
    };
    let mutations = rows
        .into_iter()
        .map(|values| Mutation {
            action: "insert".into(),
            table: params.table.clone(),
            values,
            key: Map::new(),
        })
        .collect::<Vec<_>>();
    apply_changes(client, &mutations).await
}

fn schema_change_sql(params: &Params) -> Result<String, (String, String)> {
    validate_identifier(&params.table)?;
    let table = format!("[dbo].{}", quote_identifier(&params.table));
    match params.operation.as_str() {
        "addColumn" => {
            validate_identifier(&params.name)?;
            let data_type = super::safe_sql_fragment(&params.data_type, "column type")?;
            Ok(format!(
                "ALTER TABLE {table} ADD {} {data_type}{}{}",
                quote_identifier(&params.name),
                if params.nullable {
                    " NULL"
                } else {
                    " NOT NULL"
                },
                if params.default_value.is_empty() {
                    String::new()
                } else {
                    format!(
                        " DEFAULT {}",
                        super::safe_sql_fragment(&params.default_value, "default")?
                    )
                }
            ))
        }
        "renameColumn" => {
            validate_identifier(&params.old_name)?;
            validate_identifier(&params.name)?;
            Ok(format!(
                "EXEC sp_rename N'dbo.{}.{}', {}, 'COLUMN'",
                params.table.replace('\'', "''"),
                params.old_name.replace('\'', "''"),
                sql_string(&params.name)
            ))
        }
        "dropColumn" => {
            validate_identifier(&params.name)?;
            Ok(format!(
                "ALTER TABLE {table} DROP COLUMN {}",
                quote_identifier(&params.name)
            ))
        }
        "createIndex" => {
            validate_identifier(&params.index_name)?;
            let columns = params
                .index_columns
                .iter()
                .map(|column| {
                    validate_identifier(column)?;
                    Ok(quote_identifier(column))
                })
                .collect::<Result<Vec<_>, (String, String)>>()?;
            if columns.is_empty() {
                return Err((
                    "invalid_schema_change".into(),
                    "At least one index column is required.".into(),
                ));
            }
            Ok(format!(
                "CREATE INDEX {} ON {table} ({})",
                quote_identifier(&params.index_name),
                columns.join(", ")
            ))
        }
        "dropIndex" => {
            validate_identifier(&params.index_name)?;
            Ok(format!(
                "DROP INDEX {} ON {table}",
                quote_identifier(&params.index_name)
            ))
        }
        "addForeignKey" => {
            validate_identifier(&params.constraint_name)?;
            validate_identifier(&params.referenced_table)?;
            let columns = quoted_names(&params.index_columns)?;
            let referenced = quoted_names(&params.referenced_columns)?;
            if columns.is_empty() || columns.len() != referenced.len() {
                return Err((
                    "invalid_schema_change".into(),
                    "Foreign-key columns must be paired.".into(),
                ));
            }
            Ok(format!(
                "ALTER TABLE {table} ADD CONSTRAINT {} FOREIGN KEY ({}) REFERENCES [dbo].{} ({})",
                quote_identifier(&params.constraint_name),
                columns.join(", "),
                quote_identifier(&params.referenced_table),
                referenced.join(", ")
            ))
        }
        "dropForeignKey" => {
            validate_identifier(&params.constraint_name)?;
            Ok(format!(
                "ALTER TABLE {table} DROP CONSTRAINT {}",
                quote_identifier(&params.constraint_name)
            ))
        }
        operation => Err((
            "invalid_schema_change".into(),
            format!("Unsupported SQL Server schema operation: {operation}"),
        )),
    }
}

fn quoted_names(values: &[String]) -> Result<Vec<String>, (String, String)> {
    values
        .iter()
        .map(|value| {
            validate_identifier(value)?;
            Ok(quote_identifier(value))
        })
        .collect()
}

fn mutation_sql(mutation: &Mutation) -> Result<String, (String, String)> {
    validate_identifier(&mutation.table)?;
    let table = quote_identifier(&mutation.table);
    match mutation.action.as_str() {
        "insert" => {
            if mutation.values.is_empty() {
                return Ok(format!("INSERT INTO [dbo].{table} DEFAULT VALUES"));
            }
            let columns = mutation
                .values
                .keys()
                .map(|name| {
                    validate_identifier(name)?;
                    Ok(quote_identifier(name))
                })
                .collect::<Result<Vec<_>, (String, String)>>()?;
            let values = mutation
                .values
                .values()
                .map(sql_value)
                .collect::<Result<Vec<_>, _>>()?;
            Ok(format!(
                "INSERT INTO [dbo].{table} ({}) VALUES ({})",
                columns.join(", "),
                values.join(", ")
            ))
        }
        "update" => {
            let values = assignments(&mutation.values)?;
            let keys = predicates(&mutation.key)?;
            Ok(format!("UPDATE [dbo].{table} SET {values} WHERE {keys}"))
        }
        "delete" => Ok(format!(
            "DELETE FROM [dbo].{table} WHERE {}",
            predicates(&mutation.key)?
        )),
        action => Err((
            "invalid_mutation".into(),
            format!("Unsupported mutation: {action}"),
        )),
    }
}

fn assignments(values: &Map<String, Value>) -> Result<String, (String, String)> {
    if values.is_empty() {
        return Err((
            "invalid_mutation".into(),
            "Update values are required.".into(),
        ));
    }
    values
        .iter()
        .map(|(name, value)| {
            validate_identifier(name)?;
            Ok(format!(
                "{} = {}",
                quote_identifier(name),
                sql_value(value)?
            ))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|items| items.join(", "))
}

fn predicates(values: &Map<String, Value>) -> Result<String, (String, String)> {
    if values.is_empty() {
        return Err(("invalid_mutation".into(), "A row key is required.".into()));
    }
    values
        .iter()
        .map(|(name, value)| {
            validate_identifier(name)?;
            Ok(if value.is_null() {
                format!("{} IS NULL", quote_identifier(name))
            } else {
                format!("{} = {}", quote_identifier(name), sql_value(value)?)
            })
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|items| items.join(" AND "))
}

fn filter_clause(filters: &[Filter]) -> Result<String, (String, String)> {
    let mut predicates = Vec::new();
    for filter in filters {
        validate_identifier(&filter.column)?;
        let column = quote_identifier(&filter.column);
        let predicate = match filter.operator.as_str() {
            "equals" => format!("{column} = {}", sql_value(&filter.value)?),
            "notEquals" => format!("{column} <> {}", sql_value(&filter.value)?),
            "greaterThan" => format!("{column} > {}", sql_value(&filter.value)?),
            "lessThan" => format!("{column} < {}", sql_value(&filter.value)?),
            "contains" => format!(
                "{column} LIKE {}",
                sql_string(&format!("%{}%", scalar_string(&filter.value)?))
            ),
            "startsWith" => format!(
                "{column} LIKE {}",
                sql_string(&format!("{}%", scalar_string(&filter.value)?))
            ),
            "isNull" => format!("{column} IS NULL"),
            "isNotNull" => format!("{column} IS NOT NULL"),
            value => {
                return Err((
                    "invalid_filter".into(),
                    format!("Unsupported filter operator: {value}"),
                ))
            }
        };
        predicates.push(predicate);
    }
    Ok(if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    })
}

fn sort_clause(sort: &[Sort]) -> Result<String, (String, String)> {
    if sort.is_empty() {
        return Ok(" ORDER BY (SELECT NULL)".into());
    }
    let items = sort
        .iter()
        .map(|item| {
            validate_identifier(&item.column)?;
            Ok(format!(
                "{} {}",
                quote_identifier(&item.column),
                if item.descending { "DESC" } else { "ASC" }
            ))
        })
        .collect::<Result<Vec<_>, (String, String)>>()?;
    Ok(format!(" ORDER BY {}", items.join(", ")))
}

fn quote_identifier(value: &str) -> String {
    format!("[{}]", value.replace(']', "]]"))
}
fn sql_string(value: &str) -> String {
    format!("N'{}'", value.replace('\'', "''"))
}
fn sql_value(value: &Value) -> Result<String, (String, String)> {
    Ok(match value {
        Value::Null => "NULL".into(),
        Value::Bool(value) => {
            if *value {
                "1".into()
            } else {
                "0".into()
            }
        }
        Value::Number(value) => value.to_string(),
        Value::String(value) => sql_string(value),
        Value::Object(object) if object.len() == 1 && object.contains_key("datetime") => {
            sql_string(object["datetime"].as_str().unwrap_or(""))
        }
        Value::Object(object) if object.len() == 1 && object.contains_key("uuid") => {
            sql_string(object["uuid"].as_str().unwrap_or(""))
        }
        _ => {
            return Err((
                "invalid_value".into(),
                "SQL Server table edits require scalar values.".into(),
            ))
        }
    })
}

fn cell_json(cell: &ColumnData<'static>) -> Value {
    if let Ok(Some(value)) = <&str as FromSql>::from_sql(cell) {
        return Value::String(value.to_string());
    }
    if let Ok(Some(value)) = <i64 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <i32 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <i16 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <u8 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <f64 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <f32 as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <bool as FromSql>::from_sql(cell) {
        return json!(value);
    }
    if let Ok(Some(value)) = <uuid::Uuid as FromSql>::from_sql(cell) {
        return Value::String(value.to_string());
    }
    if let Ok(Some(value)) = <chrono::NaiveDateTime as FromSql>::from_sql(cell) {
        return Value::String(value.to_string());
    }
    if let Ok(Some(value)) = <chrono::NaiveDate as FromSql>::from_sql(cell) {
        return Value::String(value.to_string());
    }
    if let Ok(Some(value)) = <chrono::NaiveTime as FromSql>::from_sql(cell) {
        return Value::String(value.to_string());
    }
    if let ColumnData::Numeric(Some(value)) = cell {
        return Value::String(format_numeric(value.value(), value.scale()));
    }
    if let ColumnData::Binary(Some(value)) = cell {
        return Value::String(BASE64.encode(value.as_ref()));
    }
    if let ColumnData::String(Some(Cow::Borrowed(value))) = cell {
        return Value::String((*value).to_string());
    }
    Value::Null
}

fn format_numeric(value: i128, scale: u8) -> String {
    if scale == 0 {
        return value.to_string();
    }
    let digits = value.unsigned_abs().to_string();
    let scale = scale as usize;
    let sign = if value < 0 { "-" } else { "" };
    if digits.len() > scale {
        let (integer, fraction) = digits.split_at(digits.len() - scale);
        format!("{sign}{integer}.{fraction}")
    } else {
        format!("{sign}0.{digits:0>scale$}")
    }
}

fn driver_error(error: tiberius::error::Error) -> (String, String) {
    ("sqlserver_error".into(), error.to_string())
}
fn redact(mut message: String, password: &str) -> String {
    if !password.is_empty() {
        message = message.replace(password, "***");
    }
    message
}
