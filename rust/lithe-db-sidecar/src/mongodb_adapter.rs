use futures_util::TryStreamExt;
use mongodb::{
    bson::{doc, Bson, Document},
    options::ClientOptions,
    Client, IndexModel,
};
use serde_json::{json, Map, Value};
use std::{collections::BTreeMap, time::Duration};

use super::{
    ensure_mutations_allowed, ensure_write_allowed, open_ssh_tunnel, Connection, DbResult, Filter,
    Mutation, Params, Sort,
};

pub(super) async fn method(method: &str, params: Params) -> DbResult {
    let tunnel = open_ssh_tunnel(&params.connection).await?;
    let connection = if tunnel.is_some() {
        params.connection.with_tunnel()?
    } else {
        params.connection.clone()
    };
    let client = connect(&connection).await?;
    let database_name = if connection.database.trim().is_empty() {
        "admin"
    } else {
        connection.database.trim()
    };
    let database = client.database(database_name);
    match method {
        "testConnection" => {
            database
                .run_command(doc! { "ping": 1 })
                .await
                .map_err(driver_error)?;
            Ok(json!({"connected": true}))
        }
        "listTables" => {
            let names = database
                .list_collection_names()
                .await
                .map_err(driver_error)?;
            Ok(
                json!({"rows": names.into_iter().map(|name| json!({"table_name": name, "table_type": "collection"})).collect::<Vec<_>>(), "truncated": false}),
            )
        }
        "describeTable" => describe_collection(&database, &params.table).await,
        "listIndexes" => list_indexes(&database, &params.table).await,
        "listForeignKeys" => Ok(json!({"rows": [], "truncated": false})),
        "listObjects" => {
            if !params.object_kind.is_empty() && params.object_kind != "tables" {
                return Ok(json!({"rows": [], "truncated": false}));
            }
            let names = database
                .list_collection_names()
                .await
                .map_err(driver_error)?;
            Ok(
                json!({"rows": names.into_iter().map(|name| json!({"object_name": name, "object_kind": "collection"})).collect::<Vec<_>>(), "truncated": false}),
            )
        }
        "pageTable" => page_collection(&database, &params).await,
        "query" => find_json(&database, &params).await,
        "applyChanges" => {
            ensure_mutations_allowed(
                &connection,
                &params.mutations,
                params.confirmed,
                params.allow_write,
            )?;
            apply_changes(&database, &params.mutations).await
        }
        "execute" => {
            ensure_write_allowed(
                &connection,
                &params.sql,
                params.confirmed,
                params.allow_write,
            )?;
            Err((
                "unsupported_operation".into(),
                "Use the MongoDB collection editor for document writes.".into(),
            ))
        }
        _ => Err((
            "unsupported_operation".into(),
            format!("{method} is not available for MongoDB in this version."),
        )),
    }
}

async fn connect(connection: &Connection) -> Result<Client, (String, String)> {
    let host = connection.host.trim();
    let uri = if host.starts_with("mongodb://") || host.starts_with("mongodb+srv://") {
        if connection.ssl && !host.to_ascii_lowercase().contains("tls=") {
            format!(
                "{host}{}tls=true",
                if host.contains('?') { "&" } else { "?" }
            )
        } else {
            host.to_string()
        }
    } else {
        let credentials = if connection.username.is_empty() {
            String::new()
        } else {
            format!(
                "{}:{}@",
                urlencoding::encode(&connection.username),
                urlencoding::encode(&connection.password)
            )
        };
        let port = if connection.port == 0 {
            27017
        } else {
            connection.port
        };
        let database = if connection.database.trim().is_empty() {
            "admin"
        } else {
            connection.database.trim()
        };
        let separator = if connection.ssl { "?tls=true" } else { "" };
        format!("mongodb://{credentials}{host}:{port}/{database}{separator}")
    };
    let timeout = Duration::from_secs(8);
    let mut options = tokio::time::timeout(timeout, ClientOptions::parse(&uri))
        .await
        .map_err(|_| {
            (
                "connection_failed".into(),
                "MongoDB connection timed out.".into(),
            )
        })?
        .map_err(|error| {
            (
                "connection_failed".into(),
                redact(error.to_string(), &connection.password),
            )
        })?;
    options.connect_timeout = Some(timeout);
    options.server_selection_timeout = Some(timeout);
    if !host.starts_with("mongodb+srv://") && !host.contains(',') {
        options.direct_connection = Some(true);
    }
    Client::with_options(options).map_err(|error| {
        (
            "connection_failed".into(),
            redact(error.to_string(), &connection.password),
        )
    })
}

async fn describe_collection(database: &mongodb::Database, collection_name: &str) -> DbResult {
    let collection = database.collection::<Document>(collection_name);
    let mut cursor = collection
        .find(doc! {})
        .limit(50)
        .await
        .map_err(driver_error)?;
    let mut fields = BTreeMap::<String, String>::new();
    while let Some(document) = cursor.try_next().await.map_err(driver_error)? {
        for (name, value) in document {
            fields
                .entry(name)
                .or_insert_with(|| bson_type(&value).to_string());
        }
    }
    if fields.is_empty() {
        fields.insert("_id".into(), "objectId".into());
    }
    Ok(json!({
        "rows": fields.into_iter().map(|(name, data_type)| json!({
            "column_name": name,
            "data_type": data_type,
            "is_nullable": "YES",
            "column_default": Value::Null,
            "column_key": if name == "_id" { "PRI" } else { "" }
        })).collect::<Vec<_>>(),
        "truncated": false
    }))
}

async fn list_indexes(database: &mongodb::Database, collection_name: &str) -> DbResult {
    let collection = database.collection::<Document>(collection_name);
    let mut cursor = collection.list_indexes().await.map_err(driver_error)?;
    let mut rows = Vec::new();
    while let Some(index) = cursor.try_next().await.map_err(driver_error)? {
        rows.push(index_json(index));
    }
    Ok(json!({"rows": rows, "truncated": false}))
}

fn index_json(index: IndexModel) -> Value {
    let name = index
        .options
        .as_ref()
        .and_then(|options| options.name.clone())
        .unwrap_or_default();
    json!({"index_name": name, "definition": serde_json::to_string(&index.keys).unwrap_or_default()})
}

async fn page_collection(database: &mongodb::Database, params: &Params) -> DbResult {
    let collection = database.collection::<Document>(&params.table);
    let filter = mongo_filter(&params.filters)?;
    let sort = mongo_sort(&params.sort);
    let limit = params.limit.clamp(1, 1_000);
    let total = collection
        .count_documents(filter.clone())
        .await
        .map_err(driver_error)?;
    let mut action = collection
        .find(filter)
        .skip(params.offset as u64)
        .limit(limit as i64);
    if !sort.is_empty() {
        action = action.sort(sort);
    }
    let mut cursor = action.await.map_err(driver_error)?;
    let mut rows = Vec::new();
    while let Some(document) = cursor.try_next().await.map_err(driver_error)? {
        rows.push(document_json(document));
    }
    Ok(json!({"rows": rows, "truncated": false, "totalRows": total}))
}

async fn find_json(database: &mongodb::Database, params: &Params) -> DbResult {
    let source = params.sql.trim();
    let filter = if source.is_empty() {
        Document::new()
    } else {
        let value: Value = serde_json::from_str(source).map_err(|error| {
            (
                "invalid_query".into(),
                format!("MongoDB filter must be JSON: {error}"),
            )
        })?;
        json_object_to_document(value)?
    };
    let collection_name = params.table.trim();
    if collection_name.is_empty() {
        return Err((
            "invalid_query".into(),
            "Select a MongoDB collection first.".into(),
        ));
    }
    let collection = database.collection::<Document>(collection_name);
    let limit = params.limit.clamp(1, 10_000);
    let mut cursor = collection
        .find(filter)
        .limit(limit as i64)
        .await
        .map_err(driver_error)?;
    let mut rows = Vec::new();
    while let Some(document) = cursor.try_next().await.map_err(driver_error)? {
        rows.push(document_json(document));
    }
    Ok(json!({"rows": rows, "truncated": false}))
}

async fn apply_changes(database: &mongodb::Database, mutations: &[Mutation]) -> DbResult {
    let mut affected = 0_u64;
    for mutation in mutations {
        let collection = database.collection::<Document>(&mutation.table);
        match mutation.action.as_str() {
            "insert" => {
                collection
                    .insert_one(map_to_document(&mutation.values)?)
                    .await
                    .map_err(driver_error)?;
                affected += 1;
            }
            "update" => {
                let result = collection
                    .update_one(
                        map_to_document(&mutation.key)?,
                        doc! { "$set": map_to_document(&mutation.values)? },
                    )
                    .await
                    .map_err(driver_error)?;
                affected += result.modified_count;
            }
            "delete" => {
                let result = collection
                    .delete_one(map_to_document(&mutation.key)?)
                    .await
                    .map_err(driver_error)?;
                affected += result.deleted_count;
            }
            action => {
                return Err((
                    "invalid_mutation".into(),
                    format!("Unsupported MongoDB mutation: {action}"),
                ))
            }
        }
    }
    Ok(json!({"rowsAffected": affected}))
}

fn mongo_filter(filters: &[Filter]) -> Result<Document, (String, String)> {
    let mut result = Document::new();
    for filter in filters {
        let value = json_to_bson(filter.value.clone())?;
        let expression = match filter.operator.as_str() {
            "equals" => value,
            "notEquals" => Bson::Document(doc! { "$ne": value }),
            "greaterThan" => Bson::Document(doc! { "$gt": value }),
            "lessThan" => Bson::Document(doc! { "$lt": value }),
            "contains" => Bson::Document(
                doc! { "$regex": regex_escape(&bson_scalar_text(&value)?), "$options": "i" },
            ),
            "startsWith" => Bson::Document(
                doc! { "$regex": format!("^{}", regex_escape(&bson_scalar_text(&value)?)), "$options": "i" },
            ),
            "isNull" => Bson::Null,
            "isNotNull" => Bson::Document(doc! { "$ne": Bson::Null }),
            operator => {
                return Err((
                    "invalid_filter".into(),
                    format!("Unsupported MongoDB filter operator: {operator}"),
                ))
            }
        };
        result.insert(filter.column.clone(), expression);
    }
    Ok(result)
}

fn mongo_sort(sort: &[Sort]) -> Document {
    sort.iter()
        .map(|item| {
            (
                item.column.clone(),
                if item.descending {
                    Bson::Int32(-1)
                } else {
                    Bson::Int32(1)
                },
            )
        })
        .collect()
}

fn map_to_document(map: &Map<String, Value>) -> Result<Document, (String, String)> {
    map.iter()
        .map(|(key, value)| Ok((key.clone(), json_to_bson(value.clone())?)))
        .collect()
}

fn json_object_to_document(value: Value) -> Result<Document, (String, String)> {
    match json_to_bson(value)? {
        Bson::Document(document) => Ok(document),
        _ => Err((
            "invalid_value".into(),
            "A MongoDB document must be a JSON object.".into(),
        )),
    }
}

fn json_to_bson(value: Value) -> Result<Bson, (String, String)> {
    Bson::try_from(value).map_err(|error| ("invalid_value".into(), error.to_string()))
}

fn document_json(document: Document) -> Value {
    serde_json::to_value(document).unwrap_or_else(|_| Value::Object(Map::new()))
}

fn bson_type(value: &Bson) -> &'static str {
    match value {
        Bson::Double(_) => "double",
        Bson::String(_) => "string",
        Bson::Array(_) => "array",
        Bson::Document(_) => "document",
        Bson::Boolean(_) => "bool",
        Bson::Null => "null",
        Bson::Int32(_) => "int",
        Bson::Int64(_) => "long",
        Bson::ObjectId(_) => "objectId",
        Bson::DateTime(_) => "date",
        Bson::Binary(_) => "binary",
        Bson::Decimal128(_) => "decimal",
        _ => "value",
    }
}

fn regex_escape(value: &str) -> String {
    value
        .chars()
        .flat_map(|character| {
            if ".*+?^${}()|[]\\".contains(character) {
                vec!['\\', character]
            } else {
                vec![character]
            }
        })
        .collect()
}

fn bson_scalar_text(value: &Bson) -> Result<String, (String, String)> {
    match value {
        Bson::String(value) => Ok(value.clone()),
        Bson::Int32(value) => Ok(value.to_string()),
        Bson::Int64(value) => Ok(value.to_string()),
        Bson::Double(value) => Ok(value.to_string()),
        Bson::Boolean(value) => Ok(value.to_string()),
        _ => Err((
            "invalid_filter".into(),
            "MongoDB text filters require a scalar value.".into(),
        )),
    }
}

fn driver_error(error: mongodb::error::Error) -> (String, String) {
    ("mongodb_error".into(), error.to_string())
}
fn redact(mut message: String, password: &str) -> String {
    if !password.is_empty() {
        message = message.replace(password, "***");
    }
    message
}
