//! Opens saved HTML through the system's HTTP browser association, not .html.

use std::path::Path;

pub fn open(path: &str) -> Result<(), String> {
    open_with(Path::new(path), |url| {
        webbrowser::open(url).map_err(|_| {
            "Could not open HTML. Configure a default web browser in Windows Settings and retry."
                .to_string()
        })
    })
}

fn open_with(path: &Path, launch: impl FnOnce(&str) -> Result<(), String>) -> Result<(), String> {
    if !path.is_absolute()
        || !path.is_file()
        || !path
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| {
                value.eq_ignore_ascii_case("html") || value.eq_ignore_ascii_case("htm")
            })
    {
        return Err("Select an existing local HTML file to preview.".to_string());
    }
    let url = url::Url::from_file_path(path)
        .map_err(|_| "Could not create the HTML file URL.".to_string())?;
    launch(url.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!(
                "lithe-html-browser-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&root).expect("fixture directory");
            Self(root)
        }

        fn file(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            std::fs::write(&path, "<!doctype html><title>Preview</title>").expect("fixture HTML");
            path
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).expect("fixture cleanup");
        }
    }

    #[test]
    fn browser_receives_encoded_file_url_for_unicode_and_reserved_characters() {
        let fixture = Fixture::new();
        let file = fixture.file("中文 page #1 & two.HTML");
        let mut launched = false;
        open_with(&file, |argument| {
            let url = url::Url::parse(argument).expect("URL");
            assert_eq!(url.to_file_path().expect("file URL"), file);
            assert!(url.fragment().is_none());
            assert!(url.query().is_none());
            launched = true;
            Ok(())
        })
        .expect("open HTML");
        assert!(launched);
    }

    #[test]
    fn missing_files_directories_and_non_html_never_launch() {
        let fixture = Fixture::new();
        for path in [
            fixture.0.clone(),
            fixture.0.join("missing.html"),
            fixture.file("tool.exe"),
            PathBuf::from("relative.html"),
        ] {
            assert!(open_with(&path, |_| panic!("invalid input launched a browser")).is_err());
        }
    }

    #[test]
    fn browser_failure_is_returned_to_the_caller() {
        let fixture = Fixture::new();
        let file = fixture.file("page.htm");
        assert_eq!(
            open_with(&file, |_| Err("No default browser".into())),
            Err("No default browser".into())
        );
    }
}
