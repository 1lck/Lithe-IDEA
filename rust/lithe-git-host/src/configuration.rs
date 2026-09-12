//! Native executable resolution and per-child Git environment configuration.
use std::path::PathBuf;
use std::process::Command;

/// Resolves a user-selected executable or the first runnable Git on PATH.
pub fn executable(selected: Option<&str>) -> Option<PathBuf> {
    let candidates = match selected {
        Some(path) => vec![PathBuf::from(path)],
        None => std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .flat_map(|directory| {
                #[cfg(windows)]
                let names = ["git.exe"];
                #[cfg(not(windows))]
                let names = ["git"];
                names.map(|name| directory.join(name))
            })
            .collect(),
    };
    candidates.into_iter().find(|path| {
        let Ok(metadata) = path.metadata() else {
            return false;
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
        }
        #[cfg(not(unix))]
        {
            metadata.is_file()
        }
    })
}

/// Preserves inherited config entries and appends named invocation overrides.
/// No global process environment or config file is changed.
pub fn configure(command: &mut Command, values: &[(String, String)]) -> std::io::Result<()> {
    let inherited = inherited_count(std::env::var("GIT_CONFIG_COUNT").ok().as_deref())?;
    for (offset, (key, value)) in values.iter().enumerate() {
        command
            .env(format!("GIT_CONFIG_KEY_{}", inherited + offset), key)
            .env(format!("GIT_CONFIG_VALUE_{}", inherited + offset), value);
    }
    command
        .env("GIT_CONFIG_COUNT", (inherited + values.len()).to_string())
        .env("GIT_PAGER", "cat")
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0");
    Ok(())
}

fn inherited_count(value: Option<&str>) -> std::io::Result<usize> {
    match value {
        None => Ok(0),
        Some(value) => value
            .parse::<usize>()
            .ok()
            .filter(|count| *count <= 4096)
            .ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Invalid inherited Git configuration count",
                )
            }),
    }
}

/// Bounded native version probe cached by executable identity; replacement invalidates the cache.
pub fn version(
    program: &std::ffi::OsStr,
    mut cancelled: impl FnMut() -> bool,
) -> std::io::Result<String> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant, SystemTime};
    type Cache = HashMap<PathBuf, (u64, Option<SystemTime>, String)>;
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    let path = PathBuf::from(program);
    let metadata = path.metadata()?;
    let identity = (metadata.len(), metadata.modified().ok());
    let cache = CACHE.get_or_init(Default::default);
    if let Some((size, modified, version)) = cache
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .get(&path)
    {
        if (*size, *modified) == identity {
            return Ok(version.clone());
        }
    }
    let started = Instant::now();
    let output = crate::run(
        &mut Command::new(program).arg("--version"),
        None,
        || cancelled() || started.elapsed() >= Duration::from_secs(5),
        || {},
        |_, _| {},
    );
    if output.failure.is_some() || !output.status.is_some_and(|status| status.success()) {
        return Err(std::io::Error::other(
            "Could not determine Git version within the operation deadline",
        ));
    }
    let version = String::from_utf8(output.stdout)
        .map_err(|_| std::io::Error::other("Git version is not UTF-8"))?
        .trim()
        .to_owned();
    let mut cache = cache.lock().unwrap_or_else(|poison| poison.into_inner());
    if cache.len() >= 16 {
        cache.clear();
    }
    cache.insert(path, (identity.0, identity.1, version.clone()));
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inherited_configuration_rejects_invalid_and_unbounded_counts() {
        assert_eq!(inherited_count(None).unwrap(), 0);
        assert_eq!(inherited_count(Some("2")).unwrap(), 2);
        for value in ["", "-1", "bad", "4097", "18446744073709551615"] {
            assert!(inherited_count(Some(value)).is_err());
        }
    }
}
