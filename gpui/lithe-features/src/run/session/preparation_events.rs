//! 准备进度事件：从 Maven 输出识别真实进度并推进准备状态条。

use async_channel::Sender;

use super::{PreparationEvent, SessionEvent};
use crate::run::model::PreparationPhase;

/// 推进准备状态条的阶段；导入相关字段在 GPUI 侧没有数据来源，保持 None。
pub(super) fn send_preparation_phase(sender: &Sender<SessionEvent>, phase: PreparationPhase) {
    let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Phase {
        phase,
        import_percent: None,
        current_project: None,
        download_artifact: None,
    }));
}

/// 主进程已经拉起，准备阶段完成。
pub(super) fn send_preparation_ready(sender: &Sender<SessionEvent>) {
    let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Ready));
}

/// 从 Maven 批处理输出里识别正在下载的构件并推进准备状态条。
///
/// `-B` 模式下每条 `Downloading from <仓库>: <URL>`（旧版为 `Downloading: <URL>`）
/// 对应一个构件；连续重复的构件只发一次事件。
pub(super) fn emit_downloads(text: &str, sender: &Sender<SessionEvent>) {
    let mut last = String::new();
    for line in text.lines() {
        let Some(artifact) = maven_download_artifact(line) else {
            continue;
        };
        if artifact == last {
            continue;
        }
        last = artifact.clone();
        let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Phase {
            phase: PreparationPhase::Building,
            import_percent: None,
            current_project: None,
            download_artifact: Some(artifact),
        }));
    }
}

/// 从一行 Maven 下载日志提取构件名；非下载行返回 None。
///
/// 控制台要求 Maven 输出颜色，下载行因此形如
/// `ESC[1m[INFO]ESC[0m Downloading from <仓库>: <URL>`；先剥掉 ANSI 转义与
/// `[INFO] ` 级别标记，再匹配新旧两种格式。
fn maven_download_artifact(line: &str) -> Option<String> {
    let plain = strip_ansi(line);
    let line = plain.strip_prefix("[INFO] ").unwrap_or(&plain);
    let url = line
        .strip_prefix("Downloading from ")
        .and_then(|rest| rest.split_once(": "))
        .map(|(_, url)| url)
        .or_else(|| line.strip_prefix("Downloading: "))?;
    let artifact = url.rsplit('/').next()?;
    (!artifact.is_empty()).then(|| artifact.to_string())
}

/// 去掉文本里的 ANSI 转义序列，只识别 `ESC [` 开头的 CSI 控制序列。
fn strip_ansi(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut characters = text.chars();
    while let Some(character) = characters.next() {
        if character != '\u{1b}' {
            output.push(character);
            continue;
        }
        if characters.next() == Some('[') {
            // CSI 序列以 0x40–0x7E 的最终字节结束，参数字节全部跳过。
            for following in characters.by_ref() {
                if ('\u{40}'..='\u{7e}').contains(&following) {
                    break;
                }
            }
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use async_channel::unbounded;

    use super::{PreparationEvent, SessionEvent, emit_downloads, maven_download_artifact};
    use crate::run::model::PreparationPhase;

    #[test]
    fn maven_download_lines_reveal_the_artifact() {
        assert_eq!(
            maven_download_artifact(
                "Downloading from central: https://repo.maven.apache.org/maven2/org/springframework/spring-core/6.1.1/spring-core-6.1.1.jar"
            ),
            Some("spring-core-6.1.1.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact("Downloading: https://repo.example.org/a/b/c-lib-1.0.jar"),
            Some("c-lib-1.0.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact(
                "\u{1b}[1m[INFO]\u{1b}[0m Downloading from central: https://repo.maven.apache.org/maven2/org/springframework/spring-core/6.1.1/spring-core-6.1.1.jar"
            ),
            Some("spring-core-6.1.1.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact(
                "\u{1b}[36;1m[INFO]\u{1b}[m Downloading: https://repo.example.org/a/b/c-lib-1.0.jar"
            ),
            Some("c-lib-1.0.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact(
                "Downloaded from central: https://repo.maven.apache.org/maven2/x.jar"
            ),
            None
        );
        assert_eq!(
            maven_download_artifact("[INFO] Building tiku-backend 1.0.0"),
            None
        );
        assert_eq!(
            maven_download_artifact("\u{1b}[1m[INFO]\u{1b}[0m Building ruoyi-admin 4.0.0"),
            None
        );
        assert_eq!(
            maven_download_artifact("[INFO] Downloading artifacts requires a profile"),
            None
        );
        assert_eq!(
            maven_download_artifact(
                "Downloading from central: https://repo.maven.apache.org/maven2/"
            ),
            None
        );
    }

    #[test]
    fn download_events_cover_each_artifact_once() {
        let (sender, receiver) = unbounded();
        let text = "\
[INFO] Scanning for projects...\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Progress (1): 4.1/5.6 kB\n\
Downloaded from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/b/b-2.0.pom\n";
        emit_downloads(text, &sender);
        let mut artifacts = Vec::new();
        while let Ok(SessionEvent::Preparation(PreparationEvent::Phase {
            phase,
            download_artifact,
            ..
        })) = receiver.try_recv()
        {
            assert_eq!(phase, PreparationPhase::Building);
            artifacts.push(download_artifact);
        }
        assert_eq!(
            artifacts,
            [Some("a-1.0.jar".to_string()), Some("b-2.0.pom".to_string())]
        );
    }
}
