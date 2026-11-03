//! Component-boundary path comparisons without changing native filesystem or policy keys.

use std::path::Path;

/// Compares identity while leaving canonical native paths unchanged for I/O and registry keys.
pub(crate) fn same(left: &Path, right: &Path) -> bool {
    #[cfg(windows)]
    {
        windows_key(&left.to_string_lossy()) == windows_key(&right.to_string_lossy())
    }
    #[cfg(not(windows))]
    {
        left == right
    }
}

/// Tests ancestry at a complete component boundary using the platform's existing case policy.
pub(crate) fn contains(parent: &Path, child: &Path) -> bool {
    #[cfg(windows)]
    {
        windows_contains(&parent.to_string_lossy(), &child.to_string_lossy())
    }
    #[cfg(not(windows))]
    {
        child.starts_with(parent)
    }
}

/// Extracts native child components using the same identity rules as ancestry checks.
pub(crate) fn relative_to(parent: &Path, child: &Path) -> Option<std::path::PathBuf> {
    #[cfg(windows)]
    {
        contains(parent, child).then(|| {
            child
                .components()
                .skip(parent.components().count())
                .collect()
        })
    }
    #[cfg(not(windows))]
    {
        child.strip_prefix(parent).ok().map(Path::to_path_buf)
    }
}

#[cfg(any(windows, test))]
fn windows_key(path: &str) -> String {
    let path = path.replace('\\', "/");
    let ordinary = if path
        .get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("//?/UNC/"))
    {
        format!("//{}", &path[8..])
    } else if let Some(path) = path.strip_prefix("//?/") {
        path.to_owned()
    } else {
        path
    };
    ordinary.trim_end_matches('/').to_lowercase()
}

#[cfg(any(windows, test))]
fn windows_contains(parent: &str, child: &str) -> bool {
    let parent = windows_key(parent);
    let child = windows_key(child);
    child == parent
        || child
            .strip_prefix(&parent)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn relative_components_follow_windows_case_and_prefix_identity() {
        for (parent, child) in [
            (r"C:\repo\Foo", r"c:\repo\foo\sub"),
            (r"\\?\C:\repo\Foo", r"C:\repo\foo\Sub"),
            (r"\\server\share\Foo", r"\\?\UNC\SERVER\share\foo\Sub"),
        ] {
            let relative = relative_to(Path::new(parent), Path::new(child)).unwrap();
            assert_eq!(relative.components().count(), 1);
            assert!(relative.to_string_lossy().eq_ignore_ascii_case("sub"));
        }
        assert!(
            relative_to(Path::new(r"C:\repo\foo"), Path::new(r"C:\repo\foo-old\sub")).is_none()
        );
    }

    #[test]
    fn windows_prefixes_and_case_preserve_component_boundaries() {
        for (parent, child) in [
            (r"C:\work\Cache", r"\\?\c:\WORK\cache\child"),
            (r"\\?\C:\work", "c:/WORK/child"),
            (r"\\server\share\cache", r"\\?\UNC\SERVER\share\CACHE\child"),
            ("C:/", r"\\?\C:\work"),
        ] {
            assert!(windows_contains(parent, child), "{parent} -> {child}");
        }
        for (parent, child) in [
            ("C:/work/cache", "C:/work/cache-old"),
            (r"\\server\share", r"\\server\share-other\child"),
            ("C:/work", "D:/work/child"),
        ] {
            assert!(!windows_contains(parent, child), "{parent} -> {child}");
        }
    }

    #[cfg(not(windows))]
    #[test]
    fn native_case_sensitive_paths_stay_distinct() {
        assert!(!contains(
            Path::new("/work/cache"),
            Path::new("/work/Cache/child")
        ));
        assert!(!same(Path::new("/work/cache"), Path::new("/work/Cache")));
        assert!(contains(
            Path::new("/work/cache:old"),
            Path::new("/work/cache:old/child")
        ));
    }
}
