#[cfg(any(target_os = "windows", test))]
mod git_bash;

use serde::{Deserialize, Serialize};
use std::{
   env,
   path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Shell {
   pub id: String,
   pub name: String,
   pub exec_win: Option<String>,
   pub exec_unix: Option<String>,
   pub kind: Option<String>,
   pub wsl_distribution: Option<String>,
}

// Helper function to find appropriate executable for specific os
fn shell_exe_in_path(exe: &str) -> Option<String> {
   #[cfg(target_os = "windows")]
   if exe.eq_ignore_ascii_case("bash.exe") {
      return git_bash::find_git_bash();
   }

   env::var_os("PATH")
      .and_then(|paths| path_from_list(exe, env::split_paths(&paths)))
      .or_else(|| windows_known_shell_path(exe))
}

#[cfg(target_os = "windows")]
fn windows_known_shell_path(exe: &str) -> Option<String> {
   windows_known_shell_candidates(exe)
      .into_iter()
      .find(|path| path.is_file())
      .map(|path| path.to_string_lossy().into_owned())
}

#[cfg(not(target_os = "windows"))]
fn windows_known_shell_path(_exe: &str) -> Option<String> {
   None
}

#[cfg(target_os = "windows")]
fn windows_known_shell_candidates(exe: &str) -> Vec<PathBuf> {
   let mut candidates = Vec::new();

   if matches!(exe, "cmd.exe" | "powershell.exe")
      && let Ok(windows_dir) = env::var("SystemRoot").or_else(|_| env::var("WINDIR"))
   {
      let windows_dir = Path::new(&windows_dir);
      if exe == "cmd.exe" {
         candidates.push(windows_dir.join("System32").join(exe));
      } else {
         candidates.push(
            windows_dir
               .join("System32")
               .join("WindowsPowerShell")
               .join("v1.0")
               .join(exe),
         );
         candidates.push(
            windows_dir
               .join("SysWOW64")
               .join("WindowsPowerShell")
               .join("v1.0")
               .join(exe),
         );
      }
   }

   if exe == "pwsh.exe" {
      for key in ["ProgramFiles", "ProgramW6432", "LOCALAPPDATA"] {
         if let Ok(base_dir) = env::var(key) {
            candidates.push(Path::new(&base_dir).join("PowerShell").join("7").join(exe));
         }
      }
   }

   candidates
}

fn path_from_list<I>(exe: &str, paths: I) -> Option<String>
where
   I: IntoIterator<Item = PathBuf>,
{
   paths.into_iter().find_map(|p| {
      let full_path = p.join(exe);
      if full_path.is_file() {
         Some(full_path.to_string_lossy().into_owned())
      } else {
         None
      }
   })
}

impl Shell {
   // Returns a list of shells and paths for each shell and respective OS exe type
   pub fn get_shell_list() -> Vec<Shell> {
      if cfg!(windows) {
         vec![
            Shell {
               id: "cmd".into(),
               name: "Command Prompt".into(),
               exec_win: shell_exe_in_path("cmd.exe"),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "powershell".into(),
               name: "Windows PowerShell".into(),
               exec_win: shell_exe_in_path("powershell.exe"),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "pwsh".into(),
               name: "PowerShell Core".into(),
               exec_win: shell_exe_in_path("pwsh.exe"),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "nu".into(),
               name: "Nushell".into(),
               exec_win: shell_exe_in_path("nu.exe"),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "bash".into(),
               name: "Git Bash".into(),
               exec_win: shell_exe_in_path("bash.exe"),
               exec_unix: None,
               kind: Some("windows".into()),
               wsl_distribution: None,
            },
         ]
      } else {
         vec![
            Shell {
               id: "bash".into(),
               name: "Bash".into(),
               exec_win: None,
               exec_unix: shell_exe_in_path("bash"),
               kind: Some("unix".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "nu".into(),
               name: "Nushell".into(),
               exec_win: None,
               exec_unix: shell_exe_in_path("nu"),
               kind: Some("unix".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "zsh".into(),
               name: "Zsh".into(),
               exec_win: None,
               exec_unix: shell_exe_in_path("zsh"),
               kind: Some("unix".into()),
               wsl_distribution: None,
            },
            Shell {
               id: "fish".into(),
               name: "Fish".into(),
               exec_win: None,
               exec_unix: shell_exe_in_path("fish"),
               kind: Some("unix".into()),
               wsl_distribution: None,
            },
         ]
      }
   }

   pub fn get_available_shells() -> Vec<Shell> {
      Self::get_shell_list()
         .into_iter()
         .filter(|sh| {
            let path = if cfg!(windows) {
               sh.exec_win.as_deref()
            } else {
               sh.exec_unix.as_deref()
            };
            path.map(|p| Path::new(p).is_file()).unwrap_or(false)
         })
         .collect()
   }
}

pub fn get_shells() -> Vec<Shell> {
   Shell::get_available_shells()
}

pub fn get_shell_by_id(id: &str) -> Option<Shell> {
   get_shells().into_iter().find(|shell| shell.id == id)
}

#[cfg(test)]
mod tests {
   use super::*;
   use std::fs;

   #[test]
   fn shell_path_lookup_finds_files_and_skips_directories() {
      let test_dir = crate::test_support::TestDirectory::new();
      let invalid = test_dir.path().join("invalid");
      fs::create_dir_all(invalid.join("pwsh.exe")).unwrap();
      let executable = test_dir.path().join("pwsh.exe");
      fs::write(&executable, "").unwrap();

      assert_eq!(
         path_from_list("pwsh.exe", [invalid, test_dir.path().to_path_buf()]),
         Some(executable.to_string_lossy().into_owned())
      );
   }

   #[test]
   fn shell_path_lookup_returns_none_when_not_found() {
      assert!(path_from_list("missing-shell.exe", []).is_none());
   }
}
