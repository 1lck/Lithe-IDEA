//! Native encoding and execution-owned temporary files for Java launch arguments.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// Owns exactly one execution's file, including cleanup after partial writes.
pub(super) struct LaunchArgumentFile(PathBuf);

impl Drop for LaunchArgumentFile {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Could not remove Java launch argument file: {error}");
            }
        }
    }
}

pub(super) fn prepare(
    executable: &str,
    arguments: &[String],
) -> Result<(Vec<String>, Option<LaunchArgumentFile>), String> {
    let version = java_feature_version(executable);
    // The planner also checks executable identity and requires a known JDK >= 9.
    // No temporary file is created for a direct launch.
    for _ in 0..128 {
        let path = next_argfile_path();
        let lithe_core::execution::LaunchCommandPlan::Argfile {
            arguments: shortened,
            argfile_contents,
        } = lithe_core::execution::plan_launch_command(executable, arguments, &path, None, version)
        else {
            return Ok((arguments.to_vec(), None));
        };
        let bytes = encode_argfile(&argfile_contents)?;
        fs::create_dir_all(path.parent().expect("temporary file has a parent"))
            .map_err(|error| format!("Could not create Java launch argument directory: {error}"))?;
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "Could not create Java launch argument file: {error}"
                ))
            }
        };
        let owner = LaunchArgumentFile(path);
        let written = file.write_all(&bytes);
        // Close before the owner removes the file, including after a write failure.
        drop(file);
        written.map_err(|error| format!("Could not write Java launch argument file: {error}"))?;
        return Ok((shortened, Some(owner)));
    }
    Err("Could not allocate a unique Java launch argument file. Retry the launch.".into())
}

fn next_argfile_path() -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    std::env::temp_dir().join("lithe-run").join(format!(
        "launch-{}-{}.argfile",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ))
}

fn java_feature_version(executable: &str) -> Option<u32> {
    let home = std::path::Path::new(executable).parent()?.parent()?;
    let contents = fs::read_to_string(home.join("release")).ok()?;
    lithe_core::execution::java_feature_version_from_release(&contents)
}

fn encode_argfile(text: &str) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        encode_argfile_in_code_page(text, unsafe { GetACP() })
    }
    #[cfg(not(windows))]
    {
        Ok(text.as_bytes().to_vec())
    }
}

#[cfg(windows)]
fn encode_argfile_in_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(text.len());
    for character in text.chars() {
        if character.is_ascii() {
            output.push(character as u8);
        } else {
            // Core quotes every path value. The native argfile parser is byte-based:
            // a multibyte trailing 0x5c (e.g. Shift-JIS 表) must be escaped too.
            for byte in encode_code_page(&character.to_string(), code_page)? {
                output.push(byte);
                if byte == b'\\' {
                    output.push(byte);
                }
            }
        }
    }
    Ok(output)
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetACP() -> u32;
    fn WideCharToMultiByte(
        code_page: u32,
        flags: u32,
        source: *const u16,
        source_len: i32,
        destination: *mut u8,
        destination_len: i32,
        default_char: *const u8,
        used_default: *mut i32,
    ) -> i32;
    fn MultiByteToWideChar(
        code_page: u32,
        flags: u32,
        source: *const u8,
        source_len: i32,
        destination: *mut u16,
        destination_len: i32,
    ) -> i32;
}

#[cfg(windows)]
fn encode_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let failure = || {
        format!("Java launch paths cannot be represented losslessly in Windows code page {code_page}. Move the project and dependencies to representable paths or use UTF-8 system encoding.")
    };
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let wide: Vec<u16> = text.encode_utf16().collect();
    let length = i32::try_from(wide.len()).map_err(|_| failure())?;
    // Native launcher options use the system code page even on JDK 18+.
    // Round-trip verification rejects replacement characters and best-fit mappings.
    unsafe {
        let size = WideCharToMultiByte(
            code_page,
            0,
            wide.as_ptr(),
            length,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
            std::ptr::null_mut(),
        );
        if size <= 0 {
            return Err(failure());
        }
        let mut bytes = vec![0; size as usize];
        if WideCharToMultiByte(
            code_page,
            0,
            wide.as_ptr(),
            length,
            bytes.as_mut_ptr(),
            size,
            std::ptr::null(),
            std::ptr::null_mut(),
        ) != size
        {
            return Err(failure());
        }
        let decoded_len =
            MultiByteToWideChar(code_page, 0, bytes.as_ptr(), size, std::ptr::null_mut(), 0);
        if decoded_len <= 0 {
            return Err(failure());
        }
        let mut decoded = vec![0; decoded_len as usize];
        if MultiByteToWideChar(
            code_page,
            0,
            bytes.as_ptr(),
            size,
            decoded.as_mut_ptr(),
            decoded_len,
        ) != decoded_len
            || decoded != wide
        {
            return Err(failure());
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct JdkFixture(PathBuf);
    impl JdkFixture {
        fn new() -> Self {
            let root = next_argfile_path().with_extension("jdk");
            fs::create_dir_all(root.join("bin")).unwrap();
            let fixture = Self(root);
            fs::write(fixture.0.join("release"), "JAVA_VERSION=\"21.0.2\"\n").unwrap();
            fixture
        }
        fn executable(&self) -> String {
            self.0.join("bin/java.exe").to_string_lossy().into_owned()
        }
    }
    impl Drop for JdkFixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn long_arguments() -> Vec<String> {
        vec![
            "-cp".into(),
            (0..600)
                .map(|i| format!("C:/repository/example/artifact-{i}/1.0/artifact-{i}.jar"))
                .collect::<Vec<_>>()
                .join(";"),
            "Main".into(),
        ]
    }

    #[test]
    fn replacement_execution_owns_a_distinct_file() {
        let jdk = JdkFixture::new();
        let (first_args, first) = prepare(&jdk.executable(), &long_arguments()).unwrap();
        let (second_args, second) = prepare(&jdk.executable(), &long_arguments()).unwrap();
        let first = first.unwrap();
        let second = second.unwrap();
        assert_ne!(first_args, second_args);
        let first_path = first.0.clone();
        let second_path = second.0.clone();
        drop(first);
        assert!(!first_path.exists());
        assert!(fs::read_to_string(&second_path)
            .unwrap()
            .starts_with("-cp\n"));
        drop(second);
        assert!(!second_path.exists());
    }

    #[test]
    fn short_non_java_and_unknown_jdk_launches_stay_direct() {
        let jdk = JdkFixture::new();
        let short = vec!["-cp".into(), "classes".into(), "Main".into()];
        let (actual, file) = prepare(&jdk.executable(), &short).unwrap();
        assert_eq!(actual, short);
        assert!(file.is_none());
        for executable in ["node.exe", "C:/missing/bin/java.exe"] {
            let args = long_arguments();
            let (actual, file) = prepare(executable, &args).unwrap();
            assert_eq!(actual, args);
            assert!(file.is_none());
        }
        assert_eq!(java_feature_version(&jdk.executable()), Some(21));
    }

    #[cfg(windows)]
    #[test]
    fn native_encoding_handles_chinese_and_rejects_lossy_paths() {
        assert_eq!(encode_code_page("中", 936).unwrap(), [0xd6, 0xd0]);
        assert_eq!(
            encode_argfile_in_code_page("\"表\"", 932).unwrap(),
            [b'"', 0x95, 0x5c, 0x5c, b'"']
        );
        assert_eq!(encode_code_page("中", 65001).unwrap(), "中".as_bytes());
        assert!(encode_code_page("中", 1252).is_err());
        assert_eq!(
            encode_code_page("-cp classes", 1252).unwrap(),
            b"-cp classes"
        );
    }
}
