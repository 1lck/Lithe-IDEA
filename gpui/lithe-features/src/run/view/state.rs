//! 会话状态与进程输出的按行存储。

use std::sync::Arc;

use gpui_kit::SharedString;
use lithe_git_host::ProcessTree;

use super::session::RunMode;
use super::MAX_OUTPUT_LINES;

/// 一个配置的当前会话状态。
pub(super) struct SessionState {
    pub(super) tree: Option<Arc<ProcessTree>>,
    /// 已提交的输出行。虚拟化列表按行取用，只排版可视范围内的行。
    pub(super) lines: Vec<SharedString>,
    /// 尚未遇到换行的半行。控制台的字符串拼接边界通常落在行中间，
    /// 直接留在这里等下一块一起补成完整行。
    pub(super) pending_line: String,
    /// 有输出被行数上限淘汰过。界面据此提示历史被截断。
    pub(super) truncated: bool,
    pub(super) starting: bool,
    pub(super) running: bool,
    /// 用户主动停止；退出码不作为失败展示。
    pub(super) stopped: bool,
    pub(super) exit_code: Option<i32>,
    pub(super) service_url: Option<String>,
    /// 本次会话实际采用的启动方式；会话开始前为 `None`。
    pub(super) mode: Option<RunMode>,
}

impl SessionState {
    pub(super) fn starting() -> Self {
        Self {
            tree: None,
            lines: Vec::new(),
            pending_line: String::new(),
            truncated: false,
            starting: true,
            running: false,
            stopped: false,
            exit_code: None,
            service_url: None,
            mode: None,
        }
    }

    pub(super) fn is_active(&self) -> bool {
        self.starting || self.running
    }
}

impl SessionState {
    /// 追加一块输出。
    ///
    /// 完整行进入 `lines`，结尾的半行留在 `pending_line` 等下一块补全。
    /// 这样虚拟化列表的每一行都是稳定的字符串，追加时只需要往尾部 push，
    /// 不必像旧实现那样每帧把整段文本重新排版。
    pub(super) fn append_output(&mut self, chunk: &str) {
        if chunk.is_empty() {
            return;
        }
        // 保留原始 ANSI 序列供控制台渲染；只有服务 URL 识别使用纯文本。
        if self.service_url.is_none() {
            self.service_url = find_service_url(&strip_ansi(chunk));
        }

        self.pending_line.push_str(chunk);
        // 只按换行切分：`str::lines()` 会吞掉结尾空行，控制台需要保留它们。
        let mut start = 0;
        while let Some(offset) = self.pending_line[start..].find('\n') {
            let end = start + offset;
            let line = self.pending_line[start..end].to_string();
            // 去掉行尾的 `\r`：Windows 控制台程序（含 Maven）混用 CRLF。
            let line = line.strip_suffix('\r').unwrap_or(&line).to_string();
            self.lines.push(SharedString::from(line));
            start = end + 1;
        }
        if start > 0 {
            self.pending_line.drain(..start);
        }
        self.trim_lines();
    }

    /// 把残留的半行也显示出来。
    ///
    /// 进程退出时最后一行通常没有换行；不把它并入 `lines` 就会丢最后一条输出。
    pub(super) fn flush_pending_line(&mut self) {
        if self.pending_line.is_empty() {
            return;
        }
        let line = std::mem::take(&mut self.pending_line);
        let line = line.strip_suffix('\r').unwrap_or(&line).to_string();
        self.lines.push(SharedString::from(line));
        self.trim_lines();
    }

    /// 超出上限时从头部整行淘汰。每次只丢头部，避免整段搬运。
    fn trim_lines(&mut self) {
        let excess = self.lines.len().saturating_sub(MAX_OUTPUT_LINES);
        if excess > 0 {
            self.lines.drain(..excess);
            self.truncated = true;
        }
    }

    /// 当前用于展示的行数（含未换行的半行）。
    pub(super) fn display_line_count(&self) -> usize {
        self.lines.len() + usize::from(!self.pending_line.is_empty())
    }

    /// 取第 `index` 行的文本。越界返回空行，保证虚拟化列表不会 panic。
    pub(super) fn line_at(&self, index: usize) -> &str {
        match self.lines.get(index) {
            Some(line) => line.as_ref(),
            None if index == self.lines.len() => self.pending_line.as_str(),
            None => "",
        }
    }

    /// 整段输出文本。复制、打印和诊断需要全文时使用，不做流式渲染。
    ///
    /// 控制台行保留原始 ANSI 序列用于着色，复制与打印必须回到纯文本。
    pub(super) fn full_text(&self) -> String {
        let mut text = self.lines.join("\n");
        if !self.pending_line.is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&self.pending_line);
        }
        strip_ansi(&text)
    }

    pub(super) fn clear(&mut self) {
        self.lines.clear();
        self.pending_line.clear();
        self.truncated = false;
        self.service_url = None;
    }
}

/// 去掉常见 ANSI CSI/OSC 序列；运行控制台只显示文本。
fn strip_ansi(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        if character != '\x1b' {
            output.push(character);
            continue;
        }
        match characters.next() {
            Some('[') => {
                for next in characters.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(next) = characters.next() {
                    if next == '\x07' {
                        break;
                    }
                    if next == '\x1b' && characters.peek() == Some(&'\\') {
                        characters.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    output
}

/// 从输出里找本机服务地址。只接受 localhost/127.0.0.1/0.0.0.0。
fn find_service_url(output: &str) -> Option<String> {
    for token in output.split(|character: char| {
        character.is_whitespace() || matches!(character, '"' | '\'' | '`' | ',' | ')' | '(')
    }) {
        let token = token.trim_matches(|character: char| {
            matches!(character, '.' | ';' | ':' | ']' | '[' | '{' | '}')
        });
        if let Some(rest) = token
            .strip_prefix("http://")
            .or_else(|| token.strip_prefix("https://"))
        {
            let (authority, _) = rest
                .split_once('/')
                .map_or((rest, ""), |(authority, path)| (authority, path));
            if let Some(url) = service_url_from_authority(authority, token.starts_with("https://"))
            {
                return Some(url);
            }
        }
        let lower = token.to_ascii_lowercase();
        for host in ["localhost:", "127.0.0.1:", "0.0.0.0:"] {
            if let Some(rest) = lower.strip_prefix(host) {
                let port = rest
                    .chars()
                    .take_while(|character| character.is_ascii_digit())
                    .collect::<String>();
                if let Ok(port) = port.parse::<u16>() {
                    return Some(format!("http://127.0.0.1:{port}"));
                }
            }
        }
    }
    None
}

fn service_url_from_authority(authority: &str, secure: bool) -> Option<String> {
    let (host, port) = authority.rsplit_once(':')?;
    let port = port.parse::<u16>().ok()?;
    if !matches!(host, "localhost" | "127.0.0.1" | "0.0.0.0") {
        return None;
    }
    let scheme = if secure { "https" } else { "http" };
    Some(format!("{scheme}://127.0.0.1:{port}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_ansi_color_sequences() {
        assert_eq!(strip_ansi("\x1b[31mred\x1b[0m plain"), "red plain");
    }

    #[test]
    fn finds_local_service_urls() {
        assert_eq!(
            find_service_url("Tomcat started on port(s): 8080 (http)\n"),
            None
        );
        assert_eq!(
            find_service_url("Listening on http://localhost:5173/\n"),
            Some("http://127.0.0.1:5173".to_string())
        );
        assert_eq!(
            find_service_url("bound to 0.0.0.0:9000\n"),
            Some("http://127.0.0.1:9000".to_string())
        );
    }
}
