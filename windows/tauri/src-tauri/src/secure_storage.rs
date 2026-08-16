use tauri::AppHandle;

fn entry(app: &AppHandle, key: &str) -> Result<keyring::Entry, String> {
    if key.trim().is_empty() {
        return Err("Secure storage key cannot be empty".to_string());
    }

    keyring::Entry::new(app.config().identifier.as_str(), key)
        .map_err(|error| format!("Failed to initialize secure storage entry: {error}"))
}

#[tauri::command]
pub fn store_secure_secret(app: AppHandle, key: String, value: String) -> Result<(), String> {
    entry(&app, &key)?
        .set_password(&value)
        .map_err(|error| format!("Failed to store secret: {error}"))
}

#[tauri::command]
pub fn get_secure_secret(app: AppHandle, key: String) -> Result<Option<String>, String> {
    match entry(&app, &key)?.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("Failed to read secret: {error}")),
    }
}

#[tauri::command]
pub fn remove_secure_secret(app: AppHandle, key: String) -> Result<(), String> {
    match entry(&app, &key)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("Failed to remove secret: {error}")),
    }
}
