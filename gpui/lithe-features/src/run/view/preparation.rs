//! Java 项目准备状态条的事件驱动更新。

use gpui_kit::Context;

use super::RunPanel;
use super::model::{PreparationPhase, PreparationStatus, ProjectPreparation};

/// 准备阶段事件；由运行会话产出，消费入口是
/// [`RunPanel::apply_preparation_event`]。
///
/// 字段语义：
/// - `phase`：当前准备阶段，只有收到事件才推进；
/// - `import_percent`：导入阶段的百分比，仅在 `Importing` 阶段有效；
/// - `current_project`：正在导入的项目名；
/// - `download_artifact`：正在下载的依赖构件名。
#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum PreparationEvent {
    /// 准备阶段推进。
    Phase {
        phase: PreparationPhase,
        import_percent: Option<u8>,
        current_project: Option<String>,
        download_artifact: Option<String>,
    },
    /// 准备完成。
    Ready,
    /// 准备失败。
    Failed,
}

impl RunPanel {
    /// 消费一条准备阶段事件并刷新准备状态条。
    /// 事件数据源待 `run/session.rs` 产出 `PreparationEvent` 后接入。
    #[allow(dead_code)]
    pub(crate) fn apply_preparation_event(
        &mut self,
        event: PreparationEvent,
        cx: &mut Context<Self>,
    ) {
        let Some(prep) = self.preparation.as_mut() else {
            return;
        };
        match event {
            PreparationEvent::Phase {
                phase,
                import_percent,
                current_project,
                download_artifact,
            } => {
                prep.phase = phase;
                prep.import_percent = import_percent;
                prep.current_project = current_project;
                prep.download_artifact = download_artifact;
                if phase == PreparationPhase::Ready {
                    prep.status = PreparationStatus::Ready;
                    prep.blocks_run = false;
                } else {
                    prep.status = PreparationStatus::Loading;
                }
            }
            PreparationEvent::Ready => {
                *prep = ProjectPreparation::ready();
            }
            PreparationEvent::Failed => {
                prep.phase = PreparationPhase::Failed;
                prep.status = PreparationStatus::Failed;
            }
        }
        cx.notify();
    }

    /// 准备进行中被失败或中止打断时，状态条回落到 Failed。
    pub(super) fn mark_preparation_failed(&mut self) {
        let Some(prep) = self.preparation.as_mut() else {
            return;
        };
        if prep.status == PreparationStatus::Loading {
            prep.phase = PreparationPhase::Failed;
            prep.status = PreparationStatus::Failed;
        }
    }
}
