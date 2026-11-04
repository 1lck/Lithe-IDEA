//! 终端状态机模型。
//!
//! 封装 `alacritty_terminal` 的 `Term` 与 VT 解析器 `Processor`，
//! 负责维护终端二维字符网格、回滚缓冲、光标状态以及滚动位置。

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::term::{Config, RenderableContent, Term};
use alacritty_terminal::vte::ansi::Processor;

/// 终端尺寸描述。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TermSize {
    pub columns: usize,
    pub screen_lines: usize,
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

/// 终端状态机核心。
pub struct TerminalModel {
    term: Term<VoidListener>,
    parser: Processor,
    size: TermSize,
}

impl TerminalModel {
    /// 创建新的终端模型。
    pub fn new(columns: usize, screen_lines: usize, scrollback: u32) -> Self {
        let size = TermSize {
            columns: columns.max(2),
            screen_lines: screen_lines.max(1),
        };
        let mut config = Config::default();
        config.scrolling_history = scrollback as usize;

        let term = Term::new(config, &size, VoidListener);
        let parser = Processor::new();

        Self { term, parser, size }
    }

    /// 接收从 PTY 读出的原始字节并进行 VT100/ANSI 解析。
    pub fn process_bytes(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    /// 改变终端尺寸（行数与列数）。
    pub fn resize(&mut self, columns: usize, screen_lines: usize) -> bool {
        let columns = columns.max(2);
        let screen_lines = screen_lines.max(1);
        if self.size.columns == columns && self.size.screen_lines == screen_lines {
            return false;
        }

        self.size = TermSize {
            columns,
            screen_lines,
        };
        self.term.resize(self.size);
        true
    }

    /// 调整滚动位置。正数为向上回滚，负数为向下滚动。
    pub fn scroll(&mut self, delta: i32) {
        self.term.scroll_display(Scroll::Delta(delta));
    }

    /// 清空终端屏幕。
    pub fn clear(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
        // 清理当前视口内容
        self.parser.advance(&mut self.term, b"\x1b[2J\x1b[H");
    }

    /// 获取当前屏幕上需要渲染的内容快照。
    pub fn renderable_content(&self) -> RenderableContent<'_> {
        self.term.renderable_content()
    }

    /// 当前终端列数。
    pub fn columns(&self) -> usize {
        self.size.columns
    }

    /// 当前终端屏幕行数。
    pub fn screen_lines(&self) -> usize {
        self.size.screen_lines
    }

    /// 更新回滚行数配置。
    ///
    /// `alacritty_terminal` 没有单独的 setter，但 `Term::set_options` 会按新的
    /// `scrolling_history` 重建历史长度（缩小时裁剪旧行），因此设置页改动
    /// 能立即作用于已有会话，而不只是下一个新会话。
    pub fn set_scrollback(&mut self, scrollback: u32) {
        let mut config = Config::default();
        config.scrolling_history = scrollback as usize;
        self.term.set_options(config);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_terminal_model_advance_and_resize() {
        let mut model = TerminalModel::new(80, 24, 1000);
        assert_eq!(model.columns(), 80);
        assert_eq!(model.screen_lines(), 24);

        // 解析基本文本
        model.process_bytes(b"Hello Lithe Terminal\r\n");

        // 调整大小
        assert!(model.resize(100, 30));
        assert_eq!(model.columns(), 100);
        assert_eq!(model.screen_lines(), 30);

        // 重复大小不触发重新计算
        assert!(!model.resize(100, 30));
    }
}
