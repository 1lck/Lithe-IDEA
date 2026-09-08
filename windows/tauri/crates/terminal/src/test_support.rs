use std::{
   fs,
   path::{Path, PathBuf},
};

pub(crate) struct TestDirectory(PathBuf);

impl TestDirectory {
   pub(crate) fn new() -> Self {
      let path = std::env::temp_dir().join(format!("lithe-terminal-test-{}", uuid::Uuid::new_v4()));
      fs::create_dir(&path).expect("create isolated terminal test directory");
      Self(path)
   }

   pub(crate) fn path(&self) -> &Path {
      &self.0
   }
}

impl Drop for TestDirectory {
   fn drop(&mut self) {
      if let Err(error) = fs::remove_dir_all(&self.0) {
         eprintln!("Failed to clean up terminal test directory: {error}");
      }
   }
}
