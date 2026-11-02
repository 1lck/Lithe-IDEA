//! Captures untrusted provider replies for the same operation's Core resolver.
//! The callback owns transport and cancellation; native facts are never supplied
//! by the provider and no manager file format is parsed here.
use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static GENERATION: AtomicU64 = AtomicU64::new(1);

pub(super) struct Queries {
    pub generation: u64,
    pub context: Value,
    pub validations: Vec<Value>,
    pub installations: Vec<Value>,
    pub identity: Vec<Value>,
}

pub(super) fn collect(
    request: &Request<'_>,
    plan: &Value,
    definition: &Value,
    root: &str,
    fixed: bool,
    capture: &mut Capture,
    query: &mut impl FnMut(&str, &str, &Value, Duration) -> Result<Value, String>,
) -> Result<Queries, String> {
    let generation = GENERATION.fetch_add(1, Ordering::Relaxed);
    if generation == 0 {
        return Err(LIMIT.into());
    }
    let context =
        json!({"contextID":format!("native-{}-{generation}", std::process::id()), "generation":1});
    let mut result = Queries {
        generation,
        context,
        validations: Vec::new(),
        installations: Vec::new(),
        identity: Vec::new(),
    };
    if fixed {
        return Ok(result);
    }
    let providers: Vec<_> = rows(plan, "providers").collect();
    if providers.len() > 8 {
        return Err(LIMIT.into());
    }
    // The source directory itself is native evidence too, including when absent.
    capture.add(&request.workspace.join(request.directory))?;
    for qualified in providers {
        capture.check()?;
        let qualified = qualified.as_str().ok_or(INVALID)?;
        let (plugin, provider) = qualified.split_once(':').ok_or(INVALID)?;
        let params = json!({"operationID":format!("native-{generation}"),"generation":generation,
            "providerID":provider,"authority":{"kind":"local"},"context":result.context,
            "workspace":{"rootID":"native-root","root":root,"directory":request.directory},"tools":[request.tool]});
        let remaining = capture
            .deadline
            .saturating_duration_since(Instant::now())
            .min(Duration::from_secs(10));
        let wire = query(plugin, provider, &params, remaining)?;
        capture.check()?;
        if serde_json::to_vec(&wire).map_or(true, |bytes| bytes.len() > 1024 * 1024) {
            return Err(LIMIT.into());
        }
        if !(wire["id"].is_number() || wire["id"].is_string()) || !wire["response"].is_object() {
            return Err(INVALID.into());
        }
        let response = &wire["response"];
        for (field, max) in [("installations", 512), ("statements", 256), ("watch", 256)] {
            if response["result"][field]
                .as_array()
                .is_some_and(|values| values.len() > max)
            {
                return Err(LIMIT.into());
            }
        }
        for row in rows(&response["result"], "installations") {
            if row["tool"] != request.tool {
                continue;
            }
            let home = native_absolute(&row["home"])?;
            capture.home(&home, definition)?;
        }
        for row in rows(&response["result"], "statements") {
            capture.add(&native_absolute(&row["source"])?)?;
        }
        for path in rows(&response["result"], "watch") {
            capture.add(&native_absolute(path)?)?;
        }
        let validation = json!({"registry":request.registry,"pluginID":plugin,
            "request":{"jsonrpc":"2.0","id":wire["id"],"method":"toolchains/query","params":params},
            "response":response,"currentGeneration":generation,"filesystem":capture.values(),
            "platform":platform(),"filesystemCaseSensitive":cfg!(not(windows)),"workspaceRoots":[root]});
        let reply: Value = serde_json::from_str(&lithe_core::execute_json(
            &json!({
            "command":"toolchains.decodeReply","payload":validation})
            .to_string(),
        ))
        .map_err(|_| INVALID)?;
        if reply["ok"] != true {
            return Err(INVALID.into());
        }
        let decoded = &reply["data"];
        if decoded["status"] == "ok" {
            let snapshot = &decoded["snapshot"];
            for installation in rows(snapshot, "installations") {
                result.installations.push(json!({"tool":installation["tool"],"home":installation["home"],"provider":qualified}));
            }
            // No operation/generation is retained in the stable model identity.
            result.identity.push(
                json!({"provider":qualified,"installations":snapshot["installations"],
                "statements":snapshot["statements"],"watch":snapshot["watch"]}),
            );
        } else if !matches!(
            decoded["error"]["code"].as_str(),
            Some("plugin.toolchain.timeout" | "plugin.toolchain.providerUnavailable")
        ) {
            return Err(INVALID.into());
        }
        result.validations.push(validation);
    }
    Ok(result)
}

fn native_absolute(value: &Value) -> Result<PathBuf, String> {
    let path = value
        .as_str()
        .filter(|value| value.len() <= 4096 && !value.chars().any(char::is_control))
        .ok_or(INVALID)?;
    let path = PathBuf::from(path);
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err(INVALID.into());
    }
    Ok(path)
}
