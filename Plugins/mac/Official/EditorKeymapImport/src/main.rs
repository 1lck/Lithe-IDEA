//! On-demand editor shortcut providers. All source access uses the host snapshot.
use lithe_plugin_sdk::{Backend, Context, FunctionError, KeymapImportRequest};
use std::collections::BTreeMap;

fn read_sources(
    snapshot: &KeymapImportRequest,
    context: &Context,
) -> Result<BTreeMap<String, String>, FunctionError> {
    let files = snapshot.list_inputs(context.host())?;
    let mut result = BTreeMap::new();
    for file in files {
        context.check_cancelled()?;
        let mut data = Vec::with_capacity(file.byte_count as usize);
        while data.len() < file.byte_count as usize {
            context.check_cancelled()?;
            let remaining = file.byte_count as usize - data.len();
            let chunk = snapshot.read_chunk(
                context.host(),
                &file.id,
                data.len() as u64,
                remaining.min(131_072) as u32,
            )?;
            if chunk.is_empty() {
                return Err(FunctionError::internal("Incomplete source"));
            }
            data.extend_from_slice(&chunk);
        }
        let text = String::from_utf8(data)
            .map_err(|_| FunctionError::internal("Invalid source encoding"))?;
        if result
            .insert(file.path, text.trim_start_matches('\u{feff}').to_string())
            .is_some()
        {
            return Err(FunctionError::internal("Duplicate source"));
        }
    }
    context.check_cancelled()?;
    Ok(result)
}

fn main() {
    let mut backend = Backend::new("editor-keymap-import");
    backend
        .keymap_import_provider("vscode", |snapshot, context| {
            let files = read_sources(&snapshot, context)?;
            let source = files
                .get("keybindings.json")
                .map(String::as_str)
                .unwrap_or("[]");
            lithe_editor_keymap_import::vscode::import(source)
                .map_err(|_| FunctionError::internal("Invalid VS Code keybindings"))
        })
        .expect("valid VS Code provider");
    backend
        .keymap_import_provider("idea", |snapshot, context| {
            let files = read_sources(&snapshot, context)?;
            lithe_editor_keymap_import::idea::import(&files)
                .map_err(|_| FunctionError::internal("Invalid IDEA keymap"))
        })
        .expect("valid IDEA provider");
    std::process::exit(backend.listen());
}
