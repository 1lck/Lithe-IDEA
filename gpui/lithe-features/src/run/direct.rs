//! JVM 直启：`java -cp <classpath> <MainClass>`。
//!
//! 运行时 classpath 由 Maven 现算：一次 `compile` + `dependency:build-classpath`
//! 只编译并解析依赖，不打包、也不写入本地仓库。任何一步不成立都返回错误，
//! 由 [`super::session::launch`] 回退到 Core 的构建工具启动计划。

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use async_channel::Sender;
use lithe_core_client::CoreClient;

use super::model::{RunConfiguration, RunLanguage};
use super::session::{
    ProjectToolchains, RunMode, SessionEvent, command_for, maven_install_context,
    resolve_toolchain_with, spawn_session,
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
    // 控制台按 UTF-8 解码日志；固定编码后中文日志不会因系统代码页变成乱码。
    arguments.push("-Dfile.encoding=UTF-8".to_string());
    arguments.push("-cp".to_string());
    arguments.push(entries.join(classpath_separator()));
    arguments.push(main_class);
    arguments.extend(configuration.program_arguments.iter().cloned());

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
    )
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
        let _ = sender.send_blocking(SessionEvent::Output(text));
    }
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
