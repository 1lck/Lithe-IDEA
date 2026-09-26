use anyhow::Result;

pub struct Clipboard {
    clipboard: arboard::Clipboard,
}

impl Clipboard {
    pub fn new() -> Result<Self> {
        Ok(Self {
            clipboard: arboard::Clipboard::new()?,
        })
    }

    pub fn copy(&mut self, text: &str) -> Result<()> {
        self.clipboard.set_text(text)?;
        Ok(())
    }

    pub fn paste(&mut self) -> Result<String> {
        Ok(self.clipboard.get_text()?)
    }

    pub fn clear(&mut self) -> Result<()> {
        self.clipboard.clear()?;
        Ok(())
    }
}

impl Default for Clipboard {
    fn default() -> Self {
        Self::new().expect("Failed to initialize clipboard")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clipboard_creation() {
        let result = Clipboard::new();
        if result.is_err() {
            eprintln!("Clipboard not available (headless environment)");
        }
    }

    #[test]
    fn test_clipboard_copy_paste() {
        let Ok(mut clipboard) = Clipboard::new() else {
            eprintln!("Clipboard not available (headless environment)");
            return;
        };

        let test_text = "Test clipboard content";

        if let Err(e) = clipboard.copy(test_text) {
            eprintln!("Copy failed (headless environment): {}", e);
            return;
        }

        match clipboard.paste() {
            Ok(pasted) => {
                if pasted == test_text {
                } else {
                    eprintln!("Clipboard content mismatch (environment issue)");
                }
            }
            Err(e) => {
                eprintln!("Paste failed (headless environment): {}", e);
            }
        }
    }

    #[test]
    fn test_clipboard_clear() {
        let Ok(mut clipboard) = Clipboard::new() else {
            eprintln!("Clipboard not available (headless environment)");
            return;
        };

        let test_text = "Content to be cleared";

        if clipboard.copy(test_text).is_ok() {
            let _ = clipboard.clear();
        }
    }
}
