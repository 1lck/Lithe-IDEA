//! Discovers Git for Windows without confusing WSL or another MSYS Bash with Git Bash.

use std::path::{Path, PathBuf};

#[cfg(target_os = "windows")]
pub(super) fn find_git_bash() -> Option<String> {
   let roots = registry_install_roots()
      .into_iter()
      .chain(known_install_roots(|key| {
         std::env::var_os(key).map(PathBuf::from)
      }));
   let paths = std::env::var_os("PATH")
      .map(|value| std::env::split_paths(&value).collect::<Vec<_>>())
      .unwrap_or_default();

   find_git_bash_in(roots, paths, Path::is_file).map(|path| path.to_string_lossy().into_owned())
}

fn known_install_roots(mut environment: impl FnMut(&str) -> Option<PathBuf>) -> Vec<PathBuf> {
   let mut roots = Vec::new();
   for key in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
      if let Some(base) = environment(key) {
         roots.push(base.join("Git"));
      }
   }
   if let Some(base) = environment("LOCALAPPDATA") {
      roots.push(base.join("Programs").join("Git"));
   }
   for key in ["SCOOP", "SCOOP_GLOBAL"] {
      if let Some(base) = environment(key) {
         roots.push(base.join("apps").join("git").join("current"));
      }
   }
   if let Some(base) = environment("USERPROFILE") {
      roots.push(base.join("scoop").join("apps").join("git").join("current"));
   }
   roots
}

fn find_git_bash_in(
   installed_roots: impl IntoIterator<Item = PathBuf>,
   path_entries: impl IntoIterator<Item = PathBuf>,
   is_file: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
   let shell_in_root = |root: &Path| {
      let bash = root.join("bin").join("bash.exe");
      // The wrapper sets MSYSTEM and PATH before running usr/bin/bash.exe.
      // A bare bash.exe on PATH can instead be the legacy WSL launcher.
      (is_file(&bash) && is_file(&root.join("cmd").join("git.exe"))).then_some(bash)
   };

   for root in installed_roots {
      if let Some(shell) = shell_in_root(&root) {
         return Some(shell);
      }
   }
   for entry in path_entries {
      if !entry.is_absolute()
         || !(is_file(&entry.join("git.exe")) || is_file(&entry.join("bash.exe")))
      {
         continue;
      }
      // Git's installer normally exposes only cmd; portable installations may
      // expose bin, usr/bin, or mingw{32,64}/bin instead.
      for root in entry.ancestors().skip(1).take(2) {
         if let Some(shell) = shell_in_root(root) {
            return Some(shell);
         }
      }
   }
   None
}

#[cfg(target_os = "windows")]
fn registry_install_roots() -> Vec<PathBuf> {
   use std::{ffi::OsString, os::windows::ffi::OsStringExt, ptr};
   use windows_sys::{
      Win32::{
         Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_SUCCESS},
         System::Registry::{
            HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RRF_SUBKEY_WOW6432KEY,
            RRF_SUBKEY_WOW6464KEY, RegGetValueW,
         },
      },
      core::w,
   };

   let mut roots = Vec::new();
   // Query both installation scopes and registry views, including 32-bit Git
   // installed on 64-bit Windows. No subprocess or registry mutation is needed.
   for hive in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
      for view in [RRF_SUBKEY_WOW6464KEY, RRF_SUBKEY_WOW6432KEY] {
         let mut buffer = vec![0u16; 32_768];
         let mut bytes = (buffer.len() * size_of::<u16>()) as u32;
         // SAFETY: predefined hive handles stay valid, names are NUL-terminated,
         // and the writable UTF-16 buffer matches the supplied byte capacity.
         let status = unsafe {
            RegGetValueW(
               hive,
               w!("Software\\GitForWindows"),
               w!("InstallPath"),
               RRF_RT_REG_SZ | view,
               ptr::null_mut(),
               buffer.as_mut_ptr().cast(),
               &mut bytes,
            )
         };
         match status {
            ERROR_SUCCESS => {
               let length = buffer.iter().position(|value| *value == 0).unwrap_or(0);
               let root = PathBuf::from(OsString::from_wide(&buffer[..length]));
               if root.is_absolute() && !roots.contains(&root) {
                  roots.push(root);
               }
            }
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => {}
            _ => log::debug!(
               "Could not read Git for Windows install location: Windows error {status}"
            ),
         }
      }
   }
   roots
}

#[cfg(test)]
mod tests {
   use super::*;
   use std::collections::{HashMap, HashSet};

   fn root(name: &str) -> PathBuf {
      // Pure discovery tests use a virtual filesystem and no machine environment.
      if cfg!(windows) {
         PathBuf::from(r"C:\test-fixtures").join(name)
      } else {
         PathBuf::from("/test-fixtures").join(name)
      }
   }

   fn git_files(root: &Path) -> HashSet<PathBuf> {
      ["bin/bash.exe", "usr/bin/bash.exe", "cmd/git.exe"]
         .map(|path| root.join(path))
         .into_iter()
         .collect()
   }

   #[test]
   fn finds_custom_registered_install_without_path_entries() {
      let install = root("自定义 Git");
      let files = git_files(&install);
      assert_eq!(
         find_git_bash_in([install.clone()], [], |path| files.contains(path)),
         Some(install.join("bin/bash.exe"))
      );
   }

   #[test]
   fn finds_portable_git_from_each_supported_path_layout() {
      let install = root("Portable Git");
      for entry in [
         "cmd",
         "bin",
         "usr/bin",
         "mingw64/bin",
         "mingw32/bin",
         "clangarm64/bin",
      ] {
         let path_entry = install.join(entry);
         let mut files = git_files(&install);
         files.insert(path_entry.join("git.exe"));
         assert_eq!(
            find_git_bash_in([], [path_entry], |path| files.contains(path)),
            Some(install.join("bin/bash.exe")),
            "PATH layout: {entry}"
         );
      }
   }

   #[test]
   fn skips_stale_registry_entries_and_prefers_install_over_path_shims() {
      let install = root("Scoop/apps/git/current");
      let shim = root("Scoop/shims");
      let other = root("other-git");
      let mut files = git_files(&install);
      files.extend(git_files(&other));
      files.insert(shim.join("bash.exe"));
      assert_eq!(
         find_git_bash_in(
            [root("removed-git"), install.clone()],
            [shim, other.join("bin")],
            |path| files.contains(path)
         ),
         Some(install.join("bin/bash.exe"))
      );
   }

   #[test]
   fn ignores_wsl_and_unrelated_bash_before_git_on_path() {
      let system = root("Windows/System32");
      let msys = root("msys64/usr/bin");
      let install = root("custom-git");
      let mut files = git_files(&install);
      files.extend([system.join("bash.exe"), msys.join("bash.exe")]);
      assert_eq!(
         find_git_bash_in([], [system, msys, install.join("cmd")], |path| files
            .contains(path)),
         Some(install.join("bin/bash.exe"))
      );
   }

   #[test]
   fn does_not_offer_wsl_mingit_or_bash_without_git_wrapper() {
      let system = root("Windows/System32");
      let mingit = root("MinGit");
      let unwrapped = root("unwrapped-git");
      let files = HashSet::from([
         system.join("bash.exe"),
         mingit.join("cmd/git.exe"),
         unwrapped.join("usr/bin/bash.exe"),
         unwrapped.join("cmd/git.exe"),
      ]);
      assert_eq!(
         find_git_bash_in(
            [mingit.clone(), unwrapped.clone()],
            [system, mingit.join("cmd"), unwrapped.join("usr/bin")],
            |path| files.contains(path)
         ),
         None
      );
   }

   #[test]
   fn preserves_path_order_between_portable_installs() {
      let first = root("first-git");
      let second = root("second-git");
      let mut files = git_files(&first);
      files.extend(git_files(&second));
      assert_eq!(
         find_git_bash_in([], [first.join("cmd"), second.join("cmd")], |path| files
            .contains(path)),
         Some(first.join("bin/bash.exe"))
      );
   }

   #[test]
   fn retains_standard_user_and_scoop_install_locations() {
      let environment: HashMap<_, _> = [
         "ProgramFiles",
         "ProgramW6432",
         "ProgramFiles(x86)",
         "LOCALAPPDATA",
         "SCOOP",
         "SCOOP_GLOBAL",
         "USERPROFILE",
      ]
      .map(|key| (key, root(key)))
      .into_iter()
      .collect();
      let roots = known_install_roots(|key| environment.get(key).cloned());
      assert_eq!(
         roots,
         vec![
            root("ProgramFiles/Git"),
            root("ProgramW6432/Git"),
            root("ProgramFiles(x86)/Git"),
            root("LOCALAPPDATA/Programs/Git"),
            root("SCOOP/apps/git/current"),
            root("SCOOP_GLOBAL/apps/git/current"),
            root("USERPROFILE/scoop/apps/git/current"),
         ]
      );
      assert!(known_install_roots(|_| None).is_empty());
   }
}
