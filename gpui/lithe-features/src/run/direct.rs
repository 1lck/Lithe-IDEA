//! JVM 直启：`java -cp <classpath> <MainClass>`。
//!
//! 运行时 classpath 由 Maven 现算：一次 `compile` + `dependency:build-classpath`
//! 只编译并解析依赖，不打包、也不写入本地仓库。任何一步不成立都返回错误，
//! 由 [`super::session::launch`] 回退到 Core 的构建工具启动计划。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};

use async_channel::Sender;
use lithe_core::execution::{
    ClasspathJarPlan, ClasspathJarRequest, ClasspathStyle, LaunchCommandPlan,
    java_feature_version_from_release, plan_classpath_jar_launch, plan_launch_command,
};
use lithe_core_client::CoreClient;

use super::model::{PreparationPhase, RunConfiguration, RunLanguage};
use super::session::{
    LaunchArgumentFile, ProjectToolchains, RunMode, SessionEvent, command_for, emit_downloads,
    maven_install_context, resolve_toolchain_with, send_preparation_phase, send_preparation_ready,
    spawn_session,
};

/// 能否用 JVM 直启代替构建工具目标。
///
/// 只挑 Maven 工程：JVM 直启需要一份运行时 classpath，Maven 负责把它算出来。
pub(super) fn applies(configuration: &RunConfiguration) -> bool {
    configuration.toolchains.contains_key("maven")
        && (configuration.provider.starts_with("spring-boot")
            || configuration.language() == RunLanguage::Java)
}

/// 直启一个 Java / Spring Boot 配置。
///
/// 返回 `Ok(())` 表示主进程已经拉起；返回 `Err` 时调用方负责回退。
pub(super) fn start(
    client: CoreClient,
    root: &Path,
    configuration: &RunConfiguration,
    skip_build: bool,
    sender: &Sender<SessionEvent>,
) -> Result<(), String> {
    let module = configuration
        .module()
        .filter(|module| *module != "." && !module.is_empty());
    let main_class = configuration
        .main_class()
        .filter(|main| !main.is_empty())
        .map(str::to_string)
        .or_else(|| discover_main_class(client, root, module))
        .ok_or_else(|| "The Java main class could not be located".to_string())?;
    let working_directory = module
        .map(|module| root.join(module))
        .unwrap_or_else(|| root.to_path_buf());
    let context = maven_install_context(root, configuration);

    // 1) 一次 Maven 调用：编译源码并解析运行时依赖，不打包也不 install。
    let classpath_file = classpath_file(root, &configuration.id)?;
    let mut goals = Vec::new();
    if !skip_build {
        goals.push("compile".to_string());
    }
    goals.push("dependency:build-classpath".to_string());
    goals.push(format!("-Dmdep.outputFile={}", classpath_file.display()));
    goals.push("-DincludeScope=runtime".to_string());
    let build = crate::maven::plan_goal(client, root, &context, module, &goals)?;
    send_preparation_phase(sender, PreparationPhase::Building);
    run_captured(&build, sender)?;

    // 2) 组合类路径：本模块的编译输出、反应堆里兄弟模块的输出，最后是依赖。
    let mut entries = Vec::new();
    let classes = working_directory.join("target").join("classes");
    if classes.is_dir() {
        entries.push(classes.to_string_lossy().into_owned());
    }
    entries.extend(reactor_classpath(client, root));
    entries.extend(read_classpath(&classpath_file)?);
    let entries = dedupe(entries);

    // 3) 用项目 JDK 直启主类。
    let toolchains = ProjectToolchains::resolve(
        root,
        &working_directory,
        &configuration.java_home_path,
        &configuration.maven_executable_path,
    );
    let executable =
        resolve_toolchain_with(root, &working_directory, "project-jdk", None, &toolchains)?;
    let mut arguments: Vec<String> = configuration.jvm_arguments.clone();
    arguments.extend(encoding_arguments(
        &configuration.jvm_arguments,
        &configuration.program_arguments,
    ));
    arguments.push("-cp".to_string());
    arguments.push(entries.join(classpath_separator()));
    arguments.push(main_class);
    arguments.extend(configuration.program_arguments.iter().cloned());

    // 大工程的运行时 classpath 会超过 Windows 命令行上限；先让 Core 规划
    // argfile 或 pathing JAR，命令行本来就短时原样返回。
    let (arguments, temporary) =
        shortened_launch_arguments(root, &executable, &arguments, &working_directory)?;

    let _ = sender.send_blocking(SessionEvent::LaunchMode(RunMode::JvmDirect));
    let command_line = format!(
        "$ {} {}\n\n",
        executable
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("java"),
        arguments.join(" ")
    );
    let _ = sender.send_blocking(SessionEvent::Output(command_line));

    spawn_session(
        &executable,
        &arguments,
        &working_directory,
        &build.environment,
        sender,
        temporary,
    )?;
    send_preparation_ready(sender);
    Ok(())
}

// ---------------------------------------------------------------------------
// JVM 编码参数
// ---------------------------------------------------------------------------

/// 控制台按 UTF-8 解码 JVM 输出所需的编码参数。
///
/// `file.encoding` 不控制 stdout/stderr，这两路在 JDK 18 之前跟随系统代码页，
/// 中文 Windows 上中文日志会乱码，因此三路一起显式固定。Spring 的 ANSI 开关
/// 只在 Windows 注入；运行配置里已声明该属性时保留用户设置，不重复覆盖。
fn encoding_arguments(jvm_arguments: &[String], program_arguments: &[String]) -> Vec<String> {
    let mut arguments = vec![
        "-Dfile.encoding=UTF-8".to_string(),
        "-Dstdout.encoding=UTF-8".to_string(),
        "-Dstderr.encoding=UTF-8".to_string(),
    ];
    let ansi_configured = jvm_arguments
        .iter()
        .chain(program_arguments)
        .any(|argument| argument.contains("spring.output.ansi.enabled"));
    if cfg!(windows) && !ansi_configured {
        arguments.push("-Dspring.output.ansi.enabled=always".to_string());
    }
    arguments
}

// ---------------------------------------------------------------------------
// 命令行长度保护
// ---------------------------------------------------------------------------

/// 把超长启动参数压进操作系统命令行上限。
///
/// JDK 9+ 由 Core 的共享 argfile 规划器缩短，JDK 8 走 Core 的 pathing JAR
/// 规划器；命令行本来就不长时原样返回，不创建任何文件。规划产物写入
/// `.lithe/run/launch/`，随 [`LaunchArgumentFile`] 在进程退出后删除。
fn shortened_launch_arguments(
    root: &Path,
    executable: &Path,
    arguments: &[String],
    working_directory: &Path,
) -> Result<(Vec<String>, Option<LaunchArgumentFile>), String> {
    let version = java_feature_version(executable);
    let executable_text = executable.to_string_lossy().into_owned();
    let working_directory_text = working_directory.to_string_lossy().into_owned();
    let directory = root.join(".lithe").join("run").join("launch");
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;

    if version.is_some_and(|version| version < 9) {
        // JDK 8 读不了 `@argfile`，由 Core 规划 manifest-only 的 pathing JAR。
        for _ in 0..128 {
            let jar = next_launch_file(&directory, "classpath.jar");
            let ClasspathJarPlan::ClasspathJar {
                arguments: shortened,
                manifest,
            } = plan_classpath_jar_launch(
                ClasspathJarRequest {
                    executable: &executable_text,
                    arguments,
                    working_directory: &working_directory_text,
                    classpath_jar_path: &jar,
                    limit: None,
                    java_feature_version: version,
                    style: classpath_style(),
                },
                |entry| Path::new(entry).is_dir(),
            )
            else {
                return Ok((arguments.to_vec(), None));
            };
            match open_new_file(&jar) {
                Ok(file) => {
                    // 先建所有者再写：写入失败也当场删除半成品。
                    let owner = LaunchArgumentFile(jar);
                    write_classpath_jar(file, &manifest)
                        .map_err(|error| format!("Could not write Java class-path JAR: {error}"))?;
                    return Ok((shortened, Some(owner)));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(format!("Could not create Java class-path JAR: {error}")),
            }
        }
        return Err("Could not allocate a unique Java class-path JAR. Retry the launch.".into());
    }

    for _ in 0..128 {
        let argfile = next_launch_file(&directory, "argfile");
        let LaunchCommandPlan::Argfile {
            arguments: shortened,
            argfile_contents,
        } = plan_launch_command(&executable_text, arguments, &argfile, None, version)
        else {
            return Ok((arguments.to_vec(), None));
        };
        match open_new_file(&argfile) {
            Ok(file) => {
                // 先建所有者再写：写入失败也当场删除半成品。
                let owner = LaunchArgumentFile(argfile);
                write_argfile(file, &argfile_contents).map_err(|error| {
                    format!("Could not write Java launch argument file: {error}")
                })?;
                return Ok((shortened, Some(owner)));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "Could not create Java launch argument file: {error}"
                ));
            }
        }
    }
    Err("Could not allocate a unique Java launch argument file. Retry the launch.".into())
}

/// 一次启动的缩短参数文件路径；进程号加进程内计数保证并发启动不撞名。
fn next_launch_file(directory: &Path, extension: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    directory.join(format!(
        "launch-{}-{}.{extension}",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ))
}

/// 打开一个还不存在的文件；并发启动撞名时由调用方换名重试。
fn open_new_file(path: &Path) -> std::io::Result<fs::File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

/// 把 argfile 写盘；文件在返回前写完并关闭，所有者随后才能安全删除。
fn write_argfile(mut file: fs::File, text: &str) -> Result<(), String> {
    let bytes = encode_argfile(text)?;
    file.write_all(&bytes)
        .map_err(|error| format!("Could not write Java launch argument file: {error}"))
}

/// 把 manifest-only pathing JAR 写盘；manifest 条目用 Stored 保持 JDK 8 兼容。
fn write_classpath_jar(file: fs::File, manifest: &str) -> std::io::Result<()> {
    let mut writer = zip::ZipWriter::new(file);
    let options =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    writer
        .start_file("META-INF/MANIFEST.MF", options)
        .map_err(std::io::Error::other)?;
    writer.write_all(manifest.as_bytes())?;
    writer.finish().map_err(std::io::Error::other)?.sync_all()
}

/// 读 JDK `release` 文件里的 feature 版本；读不到按未知处理，不缩短。
fn java_feature_version(executable: &Path) -> Option<u32> {
    let home = executable.parent()?.parent()?;
    let contents = fs::read_to_string(home.join("release")).ok()?;
    java_feature_version_from_release(&contents)
}

/// 宿主的路径语法；决定 pathing JAR manifest 的 classpath 分隔符。
fn classpath_style() -> ClasspathStyle {
    if cfg!(windows) {
        ClasspathStyle::Windows
    } else {
        ClasspathStyle::Posix
    }
}

/// argfile 的本机编码字节：Windows 上 JVM 启动器按系统代码页读取参数文件，
/// 其它平台直接写 UTF-8。
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

/// 按 Windows 代码页无损编码 argfile 文本，并把会落到 `0x5c` 的尾字节加倍，
/// 避免多字节字符被启动器当成路径分隔符。
#[cfg(windows)]
fn encode_argfile_in_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(text.len());
    for character in text.chars() {
        if character.is_ascii() {
            output.push(character as u8);
        } else {
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
unsafe extern "system" {
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

/// 编码到指定 Windows 代码页；往返解码不一致（替换字符或最佳适配映射）时报错。
#[cfg(windows)]
fn encode_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let failure = || {
        format!(
            "Java launch paths cannot be represented losslessly in Windows code page {code_page}. \
             Move the project and dependencies to representable paths or use UTF-8 system encoding."
        )
    };
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let wide: Vec<u16> = text.encode_utf16().collect();
    let length = i32::try_from(wide.len()).map_err(|_| failure())?;
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

/// 同步跑完一次 Maven 准备步骤，把输出原样转发到控制台。
fn run_captured(
    launch: &crate::maven::MavenLaunch,
    sender: &Sender<SessionEvent>,
) -> Result<(), String> {
    let command_line = format!(
        "$ {} {}\n\n",
        launch
            .executable
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("mvn"),
        launch.display_arguments()
    );
    let _ = sender.send_blocking(SessionEvent::Output(command_line));

    let mut command = command_for(&launch.executable, &launch.arguments);
    command
        .current_dir(&launch.working_directory)
        .envs(&launch.environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = command.output().map_err(|error| {
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            launch.executable.display()
        )
    })?;
    // Maven 把插件日志写到 stdout；-B 下告警在 stderr。两者都直接回显，
    // 拉直启失败时用户能看到真实的 Maven 诊断。
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if !text.is_empty() {
        let _ = sender.send_blocking(SessionEvent::Output(text.clone()));
    }
    // Maven 拉取依赖的输出里带着构件名；用它推进准备状态条，不造假进度。
    emit_downloads(&text, sender);
    if !output.status.success() {
        return Err(format!(
            "{} ({})",
            lithe_ui::i18n::tr("Could not start configuration"),
            output.status
        ));
    }
    Ok(())
}

/// 驱动的 classpath 输出文件；按配置隔离，避免并发运行互相覆盖。
fn classpath_file(root: &Path, id: &str) -> Result<PathBuf, String> {
    let directory = root.join(".lithe").join("run").join("classpath");
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    Ok(directory.join(format!("{}.txt", sanitize(id))))
}

/// 把配置 id 收敛成一个安全的文件名。
fn sanitize(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '-'
            }
        })
        .collect()
}

/// 读取 Maven 写出的运行时依赖列表。
fn read_classpath(path: &Path) -> Result<Vec<String>, String> {
    let text = fs::read_to_string(path).map_err(|error| error.to_string())?;
    let entries: Vec<String> = text
        .split(classpath_separator())
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(str::to_string)
        .collect();
    if entries.is_empty() {
        return Err("Maven resolved an empty runtime classpath".to_string());
    }
    Ok(entries)
}

fn classpath_separator() -> &'static str {
    if cfg!(windows) { ";" } else { ":" }
}

/// 保持原有顺序去重；重复目录只会让命令行更长。
fn dedupe(entries: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::BTreeSet::new();
    entries
        .into_iter()
        .filter(|entry| seen.insert(entry.clone()))
        .collect()
}

/// 反应堆里各模块已编译的 `target/classes`。
///
/// `dependency:build-classpath` 只列出依赖工件；同一反应堆的兄弟模块在没有
/// install 时还没有可用的 jar，把它们已经编译好的输出目录补进类路径。
fn reactor_classpath(client: CoreClient, root: &Path) -> Vec<String> {
    let Ok(data) = client.execute_raw(
        "maven.scan",
        serde_json::json!({ "root": root.to_string_lossy() }),
    ) else {
        return Vec::new();
    };
    let Some(project) = crate::maven::MavenProject::from_json(&data) else {
        return Vec::new();
    };
    let reactor_root = if project.relative_path == "." {
        root.to_path_buf()
    } else {
        root.join(&project.relative_path)
    };
    let mut directories = Vec::new();
    collect_module_classes(&reactor_root, &project.modules, &mut directories);
    directories
}

fn collect_module_classes(
    reactor_root: &Path,
    modules: &[crate::maven::Module],
    directories: &mut Vec<String>,
) {
    for module in modules {
        let classes = reactor_root
            .join(&module.relative_path)
            .join("target")
            .join("classes");
        if classes.is_dir() {
            directories.push(classes.to_string_lossy().into_owned());
        }
        collect_module_classes(reactor_root, &module.modules, directories);
    }
}

/// 单次启动最多检查的源码文件数，避免在超大工程里无界遍历。
const MAIN_CLASS_SCAN_BUDGET: usize = 400;
/// 主源码根下的最大递归深度。
const MAIN_CLASS_SCAN_DEPTH: usize = 24;

/// 配置里没有主类时，从模块主源码里找 Spring Boot 启动类。
///
/// Core 的 Java 入口点来自 JDT，而这个构建没有 Java 语言服务，所以只按注解和
/// `main` 方法挑出候选，再用 Core 的 `java.className` 把简单类名解析成全限定名。
/// 多个候选时取路径最浅的那个：启动类通常就在根包。
fn discover_main_class(client: CoreClient, root: &Path, module: Option<&str>) -> Option<String> {
    let source_root = module
        .map(|module| root.join(module))
        .unwrap_or_else(|| root.to_path_buf())
        .join("src")
        .join("main")
        .join("java");
    let mut candidates = Vec::new();
    let mut budget = MAIN_CLASS_SCAN_BUDGET;
    collect_spring_boot_sources(&source_root, 0, &mut candidates, &mut budget);
    candidates.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
    let (_, path) = candidates.into_iter().next()?;
    let simple_name = path.file_stem()?.to_str()?.to_string();
    let source = fs::read_to_string(&path).ok()?;
    let resolved = client
        .execute_raw(
            "java.className",
            serde_json::json!({ "source": source, "simpleName": simple_name }),
        )
        .ok()?;
    resolved
        .get("className")
        .and_then(|value| value.as_str())
        .map(str::to_string)
}

/// 递归收集声明了 Spring Boot 应用的源码，同时记下目录深度用于排序。
fn collect_spring_boot_sources(
    directory: &Path,
    depth: usize,
    candidates: &mut Vec<(usize, PathBuf)>,
    budget: &mut usize,
) {
    if *budget == 0 || depth > MAIN_CLASS_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        if *budget == 0 {
            return;
        }
        let path = entry.path();
        if path.is_dir() {
            collect_spring_boot_sources(&path, depth + 1, candidates, budget);
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("java") {
            continue;
        }
        *budget -= 1;
        let Ok(source) = fs::read_to_string(&path) else {
            continue;
        };
        if declares_spring_boot_application(&source) {
            candidates.push((depth, path));
        }
    }
}

/// Spring Boot 启动类：类上有 `@SpringBootApplication`，并且声明了 `main`。
///
/// 先去掉 `import` 行，否则只导入注解却没用它的类也会被当成候选。
fn declares_spring_boot_application(source: &str) -> bool {
    let body = source
        .lines()
        .filter(|line| !line.trim_start().starts_with("import "))
        .collect::<Vec<_>>()
        .join("\n");
    body.contains("SpringBootApplication") && body.contains("static void main")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 一个带 `release` 文件的假 JDK home，供版本识别与缩短规划使用。
    struct JdkFixture(PathBuf);

    impl JdkFixture {
        fn with_java_version(version: &str) -> Self {
            let fixture = Self::empty();
            fs::write(
                fixture.0.join("release"),
                format!("JAVA_VERSION=\"{version}\"\n"),
            )
            .unwrap();
            fixture
        }

        fn without_java_version() -> Self {
            let fixture = Self::empty();
            fs::write(fixture.0.join("release"), "MODULES=\"java.base\"\n").unwrap();
            fixture
        }

        fn empty() -> Self {
            static NEXT_ID: AtomicU64 = AtomicU64::new(0);
            let root = std::env::temp_dir().join(format!(
                "lithe-direct-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("bin")).unwrap();
            fs::create_dir_all(root.join("classes")).unwrap();
            let fixture = Self(root);
            let classes = fixture.0.join("classes");
            // pathing JAR 的 manifest 需要知道这个目录真实存在。
            assert!(classes.is_dir());
            fixture
        }

        fn executable(&self) -> PathBuf {
            self.0
                .join("bin")
                .join(if cfg!(windows) { "java.exe" } else { "java" })
        }

        fn working_directory(&self) -> PathBuf {
            self.0.clone()
        }

        fn launch_directory(&self) -> PathBuf {
            self.0.join(".lithe").join("run").join("launch")
        }

        /// 超出 Windows 命令行上限的运行时 classpath，首位是真实存在的 classes 目录。
        fn long_classpath(&self, entries: usize) -> String {
            std::iter::once(self.0.join("classes").to_string_lossy().into_owned())
                .chain((0..entries).map(|index| {
                    self.0
                        .join(format!(
                            "repository/artifact-{index}/1.0/artifact-{index}.jar"
                        ))
                        .to_string_lossy()
                        .into_owned()
                }))
                .collect::<Vec<_>>()
                .join(classpath_separator())
        }
    }

    impl Drop for JdkFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn arguments_for(classpath: String) -> Vec<String> {
        vec![
            "-Dfile.encoding=UTF-8".to_string(),
            "-cp".to_string(),
            classpath,
            "com.example.Main".to_string(),
        ]
    }

    #[test]
    fn encoding_arguments_fix_all_three_streams() {
        let arguments = encoding_arguments(&[], &[]);
        assert!(arguments.contains(&"-Dfile.encoding=UTF-8".to_string()));
        assert!(arguments.contains(&"-Dstdout.encoding=UTF-8".to_string()));
        assert!(arguments.contains(&"-Dstderr.encoding=UTF-8".to_string()));
        assert_eq!(
            arguments.contains(&"-Dspring.output.ansi.enabled=always".to_string()),
            cfg!(windows)
        );
    }

    #[test]
    fn an_explicit_ansi_setting_is_not_overridden() {
        for existing in [
            vec!["-Dspring.output.ansi.enabled=never".to_string()],
            vec!["--spring.output.ansi.enabled=always".to_string()],
        ] {
            let from_jvm = encoding_arguments(&existing, &[]);
            let from_program = encoding_arguments(&[], &existing);
            for arguments in [from_jvm, from_program] {
                assert!(!arguments.contains(&"-Dspring.output.ansi.enabled=always".to_string()));
                assert!(arguments.contains(&"-Dstdout.encoding=UTF-8".to_string()));
            }
        }
    }

    #[test]
    fn short_launches_keep_the_command_line_unchanged() {
        let jdk = JdkFixture::with_java_version("21.0.2");
        let arguments = arguments_for(jdk.long_classpath(3));
        let (shortened, file) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        assert_eq!(shortened, arguments);
        assert!(file.is_none());
    }

    #[test]
    fn an_oversized_jdk9_classpath_moves_into_an_argfile_under_the_project() {
        let jdk = JdkFixture::with_java_version("17.0.9");
        let arguments = arguments_for(jdk.long_classpath(600));
        let (shortened, file) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        let owner = file.expect("an oversized JDK 9 classpath must be shortened");
        let argfile = owner.path().to_path_buf();
        assert!(argfile.starts_with(jdk.launch_directory()));
        assert!(argfile.to_string_lossy().ends_with(".argfile"));
        let reference = format!("@{}", argfile.display());
        assert!(shortened.contains(&reference));
        assert_eq!(shortened.last(), Some(&"com.example.Main".to_string()));
        let contents = fs::read_to_string(&argfile).unwrap();
        assert!(contents.starts_with("-cp\n"));
        // 文件里只有 classpath 的引号值，主类与程序参数仍留在命令行上。
        assert!(contents.trim_end().ends_with('"'));
        drop(owner);
        assert!(!argfile.exists(), "the owner deletes the argfile");
    }

    #[test]
    fn an_oversized_jdk8_classpath_moves_into_a_pathing_jar() {
        let jdk = JdkFixture::with_java_version("1.8.0_392");
        let arguments = arguments_for(jdk.long_classpath(600));
        let (shortened, file) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        let owner = file.expect("an oversized JDK 8 classpath must be shortened");
        let jar = owner.path().to_path_buf();
        assert!(jar.starts_with(jdk.launch_directory()));
        assert!(jar.to_string_lossy().ends_with(".classpath.jar"));
        assert_eq!(
            shortened,
            [
                "-cp".to_string(),
                jar.to_string_lossy().into_owned(),
                "com.example.Main".to_string()
            ]
        );
        let mut archive = zip::ZipArchive::new(fs::File::open(&jar).unwrap()).unwrap();
        assert_eq!(archive.len(), 1, "the JAR holds only its manifest");
        let mut manifest = String::new();
        std::io::Read::read_to_string(
            &mut archive.by_name("META-INF/MANIFEST.MF").unwrap(),
            &mut manifest,
        )
        .unwrap();
        assert!(manifest.starts_with("Manifest-Version: 1.0\r\nClass-Path: file:"));
        drop(owner);
        assert!(!jar.exists(), "the owner deletes the JAR");
        assert!(
            jdk.0.join("classes").exists(),
            "only the temporary JAR is removed"
        );
    }

    #[test]
    fn an_unknown_jdk_version_keeps_the_command_line_unchanged() {
        let jdk = JdkFixture::without_java_version();
        let arguments = arguments_for(jdk.long_classpath(600));
        let (shortened, file) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        assert_eq!(shortened, arguments);
        assert!(file.is_none());
    }

    #[test]
    fn replacement_launches_own_distinct_files() {
        let jdk = JdkFixture::with_java_version("21.0.2");
        let arguments = arguments_for(jdk.long_classpath(600));
        let (_, first) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        let (_, second) = shortened_launch_arguments(
            &jdk.0,
            &jdk.executable(),
            &arguments,
            &jdk.working_directory(),
        )
        .unwrap();
        let first = first.unwrap();
        let second = second.unwrap();
        assert_ne!(first.path(), second.path());
        assert!(first.path().exists());
        assert!(second.path().exists());
    }
}
