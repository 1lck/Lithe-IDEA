//! Windows-owned discovery for WSL distributions, MSYS2, and Cygwin shells.

use super::Shell;
use std::path::{Path, PathBuf};

#[cfg(windows)]
pub(super) fn registered_install_roots(key: &str, value: &str) -> Vec<PathBuf> {
   use winreg::{RegKey, enums::*};
   let mut roots = Vec::new();
   for hive in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
      for view in [KEY_WOW64_64KEY, KEY_WOW64_32KEY] {
         let result = RegKey::predef(hive)
            .open_subkey_with_flags(key, KEY_READ | view)
            .and_then(|key| key.get_value::<String, _>(value));
         match result {
            Ok(value) => {
               let path = PathBuf::from(value);
               if path.is_absolute() && !roots.contains(&path) {
                  roots.push(path);
               }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => log::debug!("Could not read shell installation registry: {error}"),
         }
      }
   }
   roots
}

#[cfg(windows)]
pub(super) fn additional_shells() -> Vec<Shell> {
   use std::env;
   let paths = env::var_os("PATH")
      .map(|path| env::split_paths(&path).collect::<Vec<_>>())
      .unwrap_or_default();
   let mut roots = registered_install_roots(r"Software\Cygwin\setup", "rootdir");
   if let Some(drive) = env::var_os("SystemDrive") {
      let drive = PathBuf::from(format!("{}\\", drive.to_string_lossy()));
      roots.extend([
         drive.join("msys64"),
         drive.join("msys32"),
         drive.join("cygwin64"),
         drive.join("cygwin"),
      ]);
   }
   for key in ["MSYS2_ROOT", "CYGWIN_ROOT"] {
      if let Some(value) = env::var_os(key) {
         roots.push(PathBuf::from(value));
      }
   }
   for path in paths.iter().filter(|path| path.is_absolute()) {
      roots.extend(path.ancestors().skip(1).take(2).map(Path::to_path_buf));
   }
   let mut shells = posix_shells(roots, Path::is_file);
   if let Some(executable) = super::shell_exe_in_path("wsl.exe") {
      shells.extend(wsl_shells(&executable, registered_wsl_distributions()));
   }
   shells
}

fn posix_shells(
   roots: impl IntoIterator<Item = PathBuf>,
   is_file: impl Fn(&Path) -> bool,
) -> Vec<Shell> {
   let mut shells = Vec::new();
   for root in roots {
      if !root.is_absolute() {
         continue;
      }
      for (id, name, executable, marker) in [
         ("msys2", "MSYS2 Bash", "usr/bin/bash.exe", "msys2_shell.cmd"),
         ("cygwin", "Cygwin Bash", "bin/bash.exe", "bin/cygwin1.dll"),
      ] {
         if shells.iter().any(|shell: &Shell| shell.id == id) {
            continue;
         }
         let executable = root.join(executable);
         if is_file(&executable) && is_file(&root.join(marker)) {
            shells.push(Shell {
               id: id.into(),
               name: name.into(),
               exec_win: Some(executable.to_string_lossy().into_owned()),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            });
         }
      }
   }
   shells
}

#[cfg(windows)]
fn registered_wsl_distributions() -> Vec<String> {
   use winreg::{RegKey, enums::*};
   let key = match RegKey::predef(HKEY_CURRENT_USER)
      .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Lxss")
   {
      Ok(key) => key,
      Err(error) => {
         if error.kind() != std::io::ErrorKind::NotFound {
            log::debug!("Could not read WSL registrations: {error}");
         }
         return Vec::new();
      }
   };
   // Read registrations only: opening the profile picker must not start a VM.
   key.enum_keys()
      .take(256)
      .filter_map(|subkey| {
         let result = subkey
            .and_then(|name| key.open_subkey(name))
            .and_then(|key| key.get_value::<String, _>("DistributionName"));
         match result {
            Ok(name) => Some(name),
            Err(error) => {
               log::debug!("Could not read WSL distribution name: {error}");
               None
            }
         }
      })
      .collect()
}

fn wsl_shells(executable: &str, mut distributions: Vec<String>) -> Vec<Shell> {
   distributions.retain(|name| {
      !name.trim().is_empty()
         && !name.starts_with("docker-desktop")
         && !name.starts_with("rancher-desktop")
   });
   distributions.sort();
   distributions.dedup();
   distributions
      .into_iter()
      .map(|name| Shell {
         id: format!("wsl:{name}"),
         name: format!("WSL: {name}"),
         exec_win: Some(executable.into()),
         exec_unix: None,
         kind: Some("wsl".into()),
         wsl_distribution: Some(name),
      })
      .collect()
}

#[cfg(test)]
mod tests {
   use super::*;
   use std::collections::HashSet;

   #[test]
   fn posix_detection_keeps_msys2_cygwin_and_git_distinct() {
      let root = if cfg!(windows) {
         PathBuf::from(r"C:\fixtures")
      } else {
         PathBuf::from("/fixtures")
      };
      let msys = root.join("msys64");
      let cygwin = root.join("cygwin64");
      let git = root.join("Git");
      let files = HashSet::from([
         msys.join("usr/bin/bash.exe"),
         msys.join("msys2_shell.cmd"),
         cygwin.join("bin/bash.exe"),
         cygwin.join("bin/cygwin1.dll"),
         git.join("bin/bash.exe"),
      ]);
      let shells = posix_shells([git, msys.clone(), cygwin, msys], |path| {
         files.contains(path)
      });
      assert_eq!(
         shells
            .iter()
            .map(|shell| shell.id.as_str())
            .collect::<Vec<_>>(),
         ["msys2", "cygwin"]
      );
   }

   #[test]
   fn wsl_profiles_are_stable_unique_and_exclude_service_distributions() {
      let shells = wsl_shells(
         "wsl.exe",
         [
            "Ubuntu",
            "Debian",
            "Ubuntu",
            "",
            "docker-desktop",
            "rancher-desktop-data",
         ]
         .map(str::to_string)
         .to_vec(),
      );
      assert_eq!(
         shells
            .iter()
            .map(|shell| shell.id.as_str())
            .collect::<Vec<_>>(),
         ["wsl:Debian", "wsl:Ubuntu"]
      );
      assert_eq!(shells[1].wsl_distribution.as_deref(), Some("Ubuntu"));
      assert_eq!(shells[1].kind.as_deref(), Some("wsl"));
   }
}
