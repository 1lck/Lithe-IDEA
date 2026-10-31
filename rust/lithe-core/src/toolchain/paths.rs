//! Lexical native-path policy independent of the machine running Core.

/// Normalizes a bounded absolute path using the target platform's separators.
/// Native adapters must supply canonical filesystem facts separately.
pub(crate) fn normalize(path: &str, platform: &str, case_sensitive: bool) -> Option<String> {
    if path.is_empty() || path.len() > 4096 || path.chars().any(char::is_control) {
        return None;
    }
    let windows = platform == "windows";
    let text = if windows {
        path.replace('\\', "/")
    } else {
        if path.contains('\\') {
            return None;
        }
        path.to_owned()
    };
    let (prefix, remainder) = if windows {
        let bytes = text.as_bytes();
        if bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'/'
        {
            (text[..3].to_owned(), &text[3..])
        } else if let Some(unc) = text.strip_prefix("//") {
            let mut components = unc.splitn(3, '/');
            let server = components.next()?;
            let share = components.next()?;
            if server.is_empty()
                || share.is_empty()
                || [server, share].iter().any(|part| {
                    part.contains([':', '?', '*', '<', '>', '"', '|'])
                        || matches!(*part, "." | "..")
                })
            {
                return None;
            }
            (
                format!("//{server}/{share}/"),
                components.next().unwrap_or(""),
            )
        } else {
            return None;
        }
    } else {
        ("/".to_owned(), text.strip_prefix('/')?)
    };
    let remainder = remainder.strip_suffix('/').unwrap_or(remainder);
    if !remainder.is_empty()
        && remainder.split('/').any(|part| {
            part.is_empty()
                || matches!(part, "." | "..")
                || (windows
                    && (part.contains([':', '?', '*', '<', '>', '"', '|'])
                        || part.ends_with([' ', '.'])))
        })
    {
        return None;
    }
    let result = format!("{prefix}{remainder}");
    Some(if case_sensitive {
        result
    } else {
        // This is an identity key, never a rewritten executable path.
        result.to_lowercase()
    })
}

/// Compares complete native path components with target-platform case rules.
pub(crate) fn within(path: &str, root: &str, platform: &str, case_sensitive: bool) -> bool {
    let Some(path) = normalize(path, platform, case_sensitive) else {
        return false;
    };
    let Some(root) = normalize(root, platform, case_sensitive) else {
        return false;
    };
    path == root || path.starts_with(&format!("{}/", root.trim_end_matches('/')))
}

/// Uses the default target-platform case rules for native containment.
#[cfg(test)]
pub(crate) fn path_within(path: &str, root: &str, platform: &str) -> bool {
    within(path, root, platform, platform != "windows")
}

/// Joins a package-independent relative executable layout beneath a native home.
pub(crate) fn join(home: &str, relative: &str, platform: &str) -> Option<String> {
    if relative.is_empty()
        || relative.contains(['\\', ':'])
        || relative.chars().any(char::is_control)
        || relative
            .split('/')
            .any(|part| part.is_empty() || matches!(part, "." | ".."))
    {
        return None;
    }
    normalize(
        &format!("{}/{relative}", home.trim_end_matches(['/', '\\'])),
        platform,
        true,
    )
}
