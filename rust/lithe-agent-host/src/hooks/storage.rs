//! Bounded, guarded file access shared with the native instruction adapter.

use super::*;
use fs2::FileExt;
use std::fs::{self, File, OpenOptions};
use std::path::Path;

// Reject duplicate object keys instead of silently discarding the earlier
// value while rewriting an unrelated Hook in a user's native settings.
pub(super) fn parse_json(content: &str) -> Result<Value, serde_json::Error> {
    use serde::de::{self, MapAccess, SeqAccess, Visitor};
    struct Unique(Value);
    impl<'de> Deserialize<'de> for Unique {
        fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            struct UniqueVisitor;
            impl<'de> Visitor<'de> for UniqueVisitor {
                type Value = Unique;
                fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                    f.write_str("JSON with unique object keys")
                }
                fn visit_bool<E: de::Error>(self, v: bool) -> Result<Unique, E> {
                    Ok(Unique(Value::Bool(v)))
                }
                fn visit_i64<E: de::Error>(self, v: i64) -> Result<Unique, E> {
                    Ok(Unique(v.into()))
                }
                fn visit_u64<E: de::Error>(self, v: u64) -> Result<Unique, E> {
                    Ok(Unique(v.into()))
                }
                fn visit_f64<E: de::Error>(self, v: f64) -> Result<Unique, E> {
                    serde_json::Number::from_f64(v)
                        .map(|n| Unique(Value::Number(n)))
                        .ok_or_else(|| E::custom("invalid number"))
                }
                fn visit_str<E: de::Error>(self, v: &str) -> Result<Unique, E> {
                    Ok(Unique(Value::String(v.into())))
                }
                fn visit_string<E: de::Error>(self, v: String) -> Result<Unique, E> {
                    Ok(Unique(Value::String(v)))
                }
                fn visit_unit<E: de::Error>(self) -> Result<Unique, E> {
                    Ok(Unique(Value::Null))
                }
                fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Unique, A::Error> {
                    let mut values = Vec::new();
                    while let Some(value) = seq.next_element::<Unique>()? {
                        values.push(value.0);
                    }
                    Ok(Unique(Value::Array(values)))
                }
                fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Unique, A::Error> {
                    let mut values = serde_json::Map::new();
                    while let Some((key, value)) = map.next_entry::<String, Unique>()? {
                        if values.insert(key, value.0).is_some() {
                            return Err(de::Error::custom("duplicate object key"));
                        }
                    }
                    Ok(Unique(Value::Object(values)))
                }
            }
            deserializer.deserialize_any(UniqueVisitor)
        }
    }
    serde_json::from_str::<Unique>(content).map(|value| value.0)
}

pub(super) fn file_error(issue: instructions::InstructionError) -> Error {
    let message = match issue.reason {
        "file_changed" => "Hook configuration changed outside this editor. Reload before saving.",
        "unsafe_file" => {
            "Hook configuration must be a regular file, not a symbolic link or directory."
        }
        "file_too_large" => "Hook configuration must be no larger than 1 MiB.",
        "invalid_utf8" => "Hook configuration must use UTF-8 encoding.",
        _ => "Cannot access Hook configuration. Check the file permissions and Agent profile.",
    };
    error(issue.reason, message)
}

pub(super) fn changed() -> Error {
    error(
        "file_changed",
        "Hook configuration changed outside this editor. Reload before saving.",
    )
}

pub(super) fn read(agent: &str, path: PathBuf) -> Result<InstructionFile, Error> {
    instructions::snapshot(agent, path).map_err(file_error)
}

pub(super) fn write_native(previous: &InstructionFile, content: &str) -> Result<(), Error> {
    instructions::write_snapshot(previous, content, || {
        instructions::snapshot(&previous.agent_id, previous.path.clone())
    })
    .map_err(file_error)
}

pub(super) fn save(previous: &InstructionFile, stored: &Stored) -> Result<InstructionFile, Error> {
    let content = serde_json::to_string_pretty(stored)
        .map_err(|_| error("invalid_library", "Cannot encode the Hook library."))?
        + "\n";
    if previous.content != content {
        write_native(previous, &content)?;
    }
    read("library", previous.path.clone())
}

// The empty lock belongs to user state. Nonblocking OS locking coordinates
// distinct Lithe processes; it never relies on a stale PID or timeout sleep.
pub(super) fn lock(directory: &Path) -> Result<File, Error> {
    let access = |_| {
        error(
            "file_access",
            "Cannot access the Hook library. Check its permissions.",
        )
    };
    let mut directories = fs::DirBuilder::new();
    directories.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directories.mode(0o700);
    }
    directories.create(directory).map_err(access)?;
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let lock = options.open(directory.join(".sync.lock")).map_err(access)?;
    let kind = lock.metadata().map_err(access)?.file_type();
    if !kind.is_file() || kind.is_symlink() {
        return Err(error(
            "unsafe_file",
            "The Hook library lock must be a regular file.",
        ));
    }
    lock.try_lock_exclusive()
        .map_err(|_| error("busy", "Another Hook update is running. Try again."))?;
    Ok(lock)
}
