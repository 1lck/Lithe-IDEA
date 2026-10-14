//! Lossy text reading for Core's classification passes.

use std::fs;
use std::io;
use std::path::Path;

/// Reads a file as text, replacing bytes that are not valid UTF-8 with the
/// Unicode replacement character instead of failing. The markers Core scans
/// for (Spring Boot annotations, launch class names) are ASCII and survive
/// replacement, so a GBK-encoded source never fails a whole run-configuration
/// batch. The native file adapters remain the only byte-to-text converters for
/// documents; this lossy view never guesses a legacy charset and only backs
/// analysis, not editing.
pub fn read_text(path: &Path) -> io::Result<String> {
    fs::read(path).map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::read_text;
    use std::fs;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("lithe-text-{name}"))
    }

    #[test]
    fn passes_through_valid_utf8_without_change() {
        let dir = temp_dir("utf8-test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app.java");
        let source = "public class App {}\n";
        fs::write(&path, source).unwrap();
        assert_eq!(read_text(&path).unwrap(), source);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn replaces_invalid_utf8_bytes_instead_of_failing() {
        // GBK bytes for a Chinese greeting are not valid UTF-8. The ASCII
        // structure that classification depends on must survive.
        let dir = temp_dir("gbk-test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("gbk.java");
        let gbk: &[u8] =
            b"public class Gbk { public static void main(String[] args) { System.out.println(\"\xC4\xE3\xBA\xC3\"); } }";
        fs::write(&path, gbk).unwrap();
        let decoded = read_text(&path).unwrap();
        assert!(decoded.contains("public class Gbk"));
        assert!(decoded.contains("main(String[] args)"));
        fs::remove_dir_all(&dir).unwrap();
    }
}
