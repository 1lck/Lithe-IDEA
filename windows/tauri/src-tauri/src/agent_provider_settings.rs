use serde::Deserialize;
use serde_json::Value;
use std::sync::Mutex;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

// All Agent settings writers use this guard, including credential operations.
static TRANSACTION: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialChange {
    agent_id: String,
    provider_id: Option<String>,
    value: String,
}

fn matches_revision(current: &Option<Value>, expected: &Option<Value>) -> Result<(), String> {
    if current != expected {
        return Err("agent.settings.conflict".into());
    }
    Ok(())
}

#[tauri::command]
pub async fn commit_agent_panel_settings(
    app: AppHandle,
    expected: Option<Value>,
    next: Value,
    credential: Option<CredentialChange>,
) -> Result<(), String> {
    crate::blocking::run_blocking(move || {
        let _guard = TRANSACTION
            .lock()
            .map_err(|_| "agent.settings.saveFailed")?;
        let store = app
            .store("settings.json")
            .map_err(|_| "agent.settings.saveFailed")?;
        let current = store.get("agentPanel");
        matches_revision(&current, &expected)?;
        if !next.is_object() {
            return Err("agent.settings.saveFailed".into());
        }
        let mut previous_secret = None;
        let mut secret_key = None;
        if let Some(change) = credential {
            if next.get("agentId").and_then(Value::as_str) != Some(change.agent_id.as_str()) {
                return Err("agent.settings.conflict".into());
            }
            let provider_id = next
                .get("provider")
                .and_then(|v| v.get("id"))
                .and_then(Value::as_str);
            // Removal may delete the selected provider; its credential still belongs
            // to the expected revision rather than whichever provider is now selected.
            let old_id = expected
                .as_ref()
                .and_then(|v| v.get("provider"))
                .and_then(|v| v.get("id"))
                .and_then(Value::as_str);
            if change.provider_id.as_deref() != provider_id
                && change.provider_id.as_deref() != old_id
            {
                return Err("agent.settings.conflict".into());
            }
            let mut key = format!("agent-provider-api-key/{}", change.agent_id);
            if let Some(id) = change.provider_id {
                key.push('/');
                key.push_str(&id);
            }
            previous_secret = crate::secure_storage::get_secure_secret(app.clone(), key.clone())?;
            if change.value.trim().is_empty() {
                crate::secure_storage::remove_secure_secret(app.clone(), key.clone())?;
            } else {
                crate::secure_storage::store_secure_secret(
                    app.clone(),
                    key.clone(),
                    change.value.trim().into(),
                )?;
            }
            secret_key = Some(key);
        }
        store.set("agentPanel", next);
        if store.save().is_err() {
            if let Some(value) = current {
                store.set("agentPanel", value);
            } else {
                store.delete("agentPanel");
            }
            if let Some(key) = secret_key {
                match previous_secret {
                    Some(value) => crate::secure_storage::store_secure_secret(app, key, value)?,
                    None => crate::secure_storage::remove_secure_secret(app, key)?,
                }
            }
            return Err("agent.settings.saveFailed".into());
        }
        Ok(())
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn stale_revision_is_rejected_before_credentials_or_settings_are_touched() {
        let original = Some(json!({"provider": {"id": "one", "model": "old"}}));
        let changed = Some(json!({"provider": {"id": "one", "model": "new"}}));
        assert!(matches_revision(&changed, &original).is_err());
        assert!(matches_revision(&None, &original).is_err());
        assert!(matches_revision(&original, &original).is_ok());
    }
}
