//! Run 启动编排。
//!
//! 对齐 macOS `AppModel+RunConfiguration.swift` 的启动入口：
//! 保存所有脏文档并通知语言服务 → 解析 Java 源文件 → 让 JDT 选主类、构建并
//! 解析运行时 classpath → 构建失败时先让用户决策 → 最后才拉起进程。

use std::path::PathBuf;

use gpui_kit::{AppContext as _, Context, SharedString};

use super::java_decision::JavaLaunchDecision;
use super::model::{RunConfiguration, RunExecution};
use super::state::SessionState;
use super::RunPanel;
use crate::run::source;

impl RunPanel {
    /// 启动一个配置。所有入口（顶栏 Run、F5、Maven 工具窗、批量运行）都走这里。
    pub(super) fn start_configuration(&mut self, id: String, cx: &mut Context<Self>) {
        let Some(configuration) = self
            .configurations
            .iter()
            .find(|configuration| configuration.id == id)
            .filter(|configuration| configuration.execution != RunExecution::Group)
            .cloned()
        else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        if self.sessions.get(&id).is_some_and(SessionState::is_active) {
            self.selected_id = Some(id);
            self.show_details = false;
            self.emit(cx);
            cx.notify();
            return;
        }

        // JDT 还没导入完时主类与 classpath 都没有可靠答案；和 macOS 一样把
        // 启动挂起，等准备状态变化后再继续。
        if configuration.uses_java_project_preparation()
            && self.java_language.read(cx).blocks_run()
        {
            self.pending_java_launch = Some(id.clone());
            self.selected_id = Some(id);
            self.show_details = false;
            self.emit(cx);
            cx.notify();
            return;
        }

        self.selected_id = Some(id.clone());
        self.show_details = false;
        self.launch_decision = None;
        self.launch_decision_target = None;
        self.error = None;
        self.pending_output.remove(&id);
        self.emit(cx);
        cx.notify();

        let generation = self.generation;
        // 与 macOS 一致：JDT 必须编译当前工作区，包括未保存的依赖模块。
        // 保存失败时结束本次启动，而不是带着旧内容去构建。
        let save = self.on_before_launch.as_ref().map(|handler| handler(cx));
        cx.spawn(async move |this, cx| {
            let active_document = match save {
                Some(task) => match task.await {
                    Ok(active) => active,
                    Err(error) => {
                        let message = format!(
                            "{}: {error}",
                            lithe_ui::i18n::tr(
                                "Java launch stopped because modified files could not be saved."
                            )
                        );
                        let _ = this.update(cx, |this, cx| {
                            if this.generation != generation {
                                return;
                            }
                            this.fail_launch(message, cx);
                        });
                        return;
                    }
                },
                None => None,
            };

            let java_project = configuration.uses_java_project_preparation();
            // 配置已经带可用的 source 时只把它作为候选，避免每次启动都遍历
            // 整个工作区；否则按 macOS 的 `projectFiles` 语义扫描磁盘。
            let files = if java_project {
                match configuration.source_path().map(|source| {
                    let path = std::path::Path::new(source);
                    if path.is_absolute() {
                        path.to_path_buf()
                    } else {
                        root.join(path)
                    }
                }) {
                    Some(source) if source.is_file() => vec![source],
                    _ => {
                        let root = root.clone();
                        cx.background_spawn(async move { source::collect_java_files(&root) })
                            .await
                    }
                }
            } else {
                Vec::new()
            };

            let current_file = if configuration.uses_current_editor_file() {
                match active_document.clone() {
                    Some(path) => Some(path),
                    None => {
                        let message = lithe_ui::i18n::tr(
                            "The current file is unavailable for this launch.",
                        )
                        .to_string();
                        let _ = this.update(cx, |this, cx| {
                            if this.generation != generation {
                                return;
                            }
                            this.fail_launch(message, cx);
                        });
                        return;
                    }
                }
            } else {
                // 非 Current File 配置不使用编辑器标签，避免源码解析意外选中
                // 当前打开但与本配置无关的文件。
                None
            };

            if !java_project {
                let configuration = configuration.clone();
                let root = root.clone();
                let _ = this.update(cx, |this, cx| {
                    if this.generation != generation {
                        return;
                    }
                    this.launch_configuration(
                        configuration,
                        root,
                        current_file,
                        None,
                        cx,
                    );
                });
                return;
            }

            let Some(source_path) =
                source::resolve(&configuration, active_document.as_deref(), &files, &root)
            else {
                let message = lithe_ui::i18n::tr("The Java source for {name} could not be resolved.")
                    .replace("{name}", &configuration.name);
                let _ = this.update(cx, |this, cx| {
                    if this.generation != generation {
                        return;
                    }
                    this.fail_launch(message, cx);
                });
                return;
            };

            let main_class = configuration.main_class().map(str::to_string);
            crate::logging::log_info(
                "run",
                format!(
                    "Java launch source: {} (mainClass={})",
                    source_path.display(),
                    main_class.as_deref().unwrap_or("")
                ),
            );
            let source_for_retry = source_path.clone();
            let main_for_retry = main_class.clone();
            let prepared = this
                .update(cx, |this, cx| {
                    if this.generation != generation {
                        return None;
                    }
                    Some(
                        this.java_language
                            .update(cx, |model, cx| model.prepare_launch(source_path, main_class, cx)),
                    )
                })
                .ok()
                .flatten();
            let Some(prepared) = prepared else {
                return;
            };
            let mut result = prepared.await;
            // 重建索引或刚完成导入时 JDT 可能还在后台构建，resolveMainClass 会
            // 撞上 30 秒请求超时；等一会儿再试一次，行为仍是“准备失败则中止”。
            if result
                .as_ref()
                .err()
                .is_some_and(|error| error.contains("timed out"))
            {
                crate::logging::log_info(
                    "run",
                    "Java launch preparation timed out; retrying once",
                );
                cx.background_executor()
                    .timer(std::time::Duration::from_secs(3))
                    .await;
                let retry = this
                    .update(cx, |this, cx| {
                        if this.generation != generation {
                            return None;
                        }
                        Some(this.java_language.update(cx, |model, cx| {
                            model.prepare_launch(source_for_retry, main_for_retry, cx)
                        }))
                    })
                    .ok()
                    .flatten();
                if let Some(retry) = retry {
                    result = retry.await;
                }
            }
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                match result {
                    Ok(target) => {
                        if let Some(failure) = target.build_failure.clone() {
                            let always = this
                                .java_build_policy
                                .as_ref()
                                .is_some_and(|policy| policy(cx, &root));
                            if !always {
                                crate::logging::log_info(
                                    "run",
                                    format!(
                                        "Java launch build failed: {} ({})",
                                        failure.message, failure.code
                                    ),
                                );
                                this.launch_decision = Some(JavaLaunchDecision::from_failure(
                                    configuration.clone(),
                                    failure,
                                    current_file.clone(),
                                ));
                                this.launch_decision_target = Some(target);
                                this.emit(cx);
                                cx.notify();
                                return;
                            }
                        }
                        this.launch_configuration(
                            configuration,
                            root,
                            current_file,
                            Some(target),
                            cx,
                        );
                    }
                    Err(error) => {
                        crate::logging::log_info(
                            "run",
                            format!("Java launch preparation failed: {error}"),
                        );
                        this.fail_launch(error, cx);
                    }
                }
            });
        })
        .detach();
    }

    /// 真正启动一个配置。`java_launch` 是 JDT 已解析的运行时 classpath。
    pub(super) fn launch_configuration(
        &mut self,
        configuration: RunConfiguration,
        root: PathBuf,
        current_file: Option<PathBuf>,
        java_launch: Option<crate::language::JavaLaunchTarget>,
        cx: &mut Context<Self>,
    ) {
        let id = configuration.id.clone();
        crate::logging::log_info("run", format!("launching run configuration {id}"));
        self.selected_id = Some(id.clone());
        self.show_details = false;
        self.sessions.insert(id.clone(), SessionState::starting());
        self.pending_output.remove(&id);
        self.console.reset();
        self.console_follow_tail = true;
        self.emit(cx);
        cx.notify();

        let client = self.client;
        let session_id = id;
        cx.spawn(async move |this, cx| {
            let receiver = cx
                .background_spawn(async move {
                    crate::run::session::start(
                        client,
                        root,
                        configuration,
                        java_launch,
                        current_file,
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.watch_session(session_id, receiver, cx);
            });
        })
        .detach();
    }

    /// 启动失败：写入面板错误并通知，不留下半启动的会话状态。
    pub(super) fn fail_launch(&mut self, message: String, cx: &mut Context<Self>) {
        crate::logging::log_info("run", format!("run launch failed: {message}"));
        self.error = Some(SharedString::from(message));
        self.emit(cx);
        cx.notify();
    }

    /// 准备完成后继续被闸门拦下的启动。
    pub(super) fn resume_pending_java_launch(&mut self, cx: &mut Context<Self>) {
        let blocked = self.java_language.read(cx).blocks_run();
        let Some(id) = self.pending_java_launch.take() else {
            return;
        };
        if blocked {
            self.pending_java_launch = Some(id);
            return;
        }
        self.start_configuration(id, cx);
    }
}
