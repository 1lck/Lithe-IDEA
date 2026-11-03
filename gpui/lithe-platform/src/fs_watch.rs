//! 项目目录的文件监视。
//!
//! 这一层只回答「哪些路径发生了变化」：不读取内容、不依赖 GPUI 类型，也不
//! 决定项目树和编辑器各自怎么处理。回调在 notify 自己的后台线程触发，调用
//! 方负责切回 UI 线程并做自己的去抖。
//!
//! 保存、构建和 Git 操作会在极短时间内产生成批事件。notify 的回调在这里先
//! 过一个短合并窗口，把同一批事件收成一条 [`WatchEvent`]：UI 线程的处理成本
//! 远高于这里的事件收集，合并能显著减少跨线程唤醒次数。
//!
//! 平台差异全部交给 `notify::RecommendedWatcher`：Windows
//! `ReadDirectoryChangesW`、macOS FSEvents、Linux inotify。

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

/// 同一批事件之间的静默窗口。
const COALESCE_QUIET: Duration = Duration::from_millis(80);
/// 一次合并最多持续多久：持续写入不能无限推迟第一批结果。
const COALESCE_MAX: Duration = Duration::from_millis(250);

/// 一批磁盘变化。
#[derive(Clone, Debug, Default)]
pub struct WatchEvent {
    /// 受影响路径（绝对路径）。删除事件的路径可能已经不存在。
    pub paths: Vec<PathBuf>,
    /// 底层监视器报告丢失事件（队列溢出、回调错误等），调用方应整树重扫。
    pub requires_rescan: bool,
}

impl WatchEvent {
    fn is_empty(&self) -> bool {
        self.paths.is_empty() && !self.requires_rescan
    }

    fn merge(&mut self, other: Self) {
        self.requires_rescan |= other.requires_rescan;
        self.paths.extend(other.paths);
    }
}

enum Message {
    Event(WatchEvent),
    Stop,
}

/// 一个项目的递归监视器；`Drop` 时停止 notify 并结束合并线程。
///
/// 丢弃顺序是有意的：先释放 watcher，让它的回调不再产生新事件；再通知合并
/// 线程退出并等待它结束，避免工作区切换后旧项目的事件还在往新工作区送。
pub struct FileWatcher {
    watcher: Option<RecommendedWatcher>,
    stop: Option<Sender<Message>>,
    worker: Option<JoinHandle<()>>,
}

impl Drop for FileWatcher {
    fn drop(&mut self) {
        self.watcher = None;
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(Message::Stop);
        }
        if let Some(worker) = self.worker.take() {
            // 合并线程只做收集，最多一个合并窗口就会退出。
            let _ = worker.join();
        }
    }
}

/// 递归监视 `root`；每批事件在静默窗口结束后调用一次 `handler`。
///
/// 失败原因直接作为 `Err` 返回给调用方展示；调用方不应因为监视失败就拒绝
/// 打开项目。
pub fn watch_tree(
    root: &Path,
    handler: impl Fn(WatchEvent) + Send + 'static,
) -> Result<FileWatcher, String> {
    let (sender, receiver) = mpsc::channel::<Message>();
    let callback_sender = sender.clone();

    let mut watcher = notify::recommended_watcher(
        move |result: notify::Result<notify::Event>| {
            let event = match result {
                Ok(event) => {
                    // 读取本身不改变文件内容；忽略 Access，避免打开/预览文件
                    // 也触发一次项目树刷新。
                    if matches!(event.kind, notify::EventKind::Access(_)) {
                        return;
                    }
                    WatchEvent {
                        paths: event.paths,
                        requires_rescan: false,
                    }
                }
                // 回调错误通常意味着系统队列溢出：这里无法知道丢了什么，
                // 只能要求调用方重扫。
                Err(_) => WatchEvent {
                    paths: Vec::new(),
                    requires_rescan: true,
                },
            };
            // 接收端已经关闭（工作区切换）时丢弃即可。
            let _ = callback_sender.send(Message::Event(event));
        },
    )
    .map_err(|error| error.to_string())?;

    watcher
        .watch(root, RecursiveMode::Recursive)
        .map_err(|error| error.to_string())?;

    let worker = thread::Builder::new()
        .name("lithe-file-watch".to_string())
        .spawn(move || coalesce_loop(receiver, handler))
        .map_err(|error| error.to_string())?;

    Ok(FileWatcher {
        watcher: Some(watcher),
        stop: Some(sender),
        worker: Some(worker),
    })
}

fn coalesce_loop(receiver: Receiver<Message>, handler: impl Fn(WatchEvent)) {
    loop {
        let mut batch = match receiver.recv() {
            Ok(Message::Event(event)) => event,
            // 发送端全部关闭（监视器已释放）或显式停止。
            Ok(Message::Stop) | Err(_) => return,
        };

        let deadline = Instant::now() + COALESCE_MAX;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match receiver.recv_timeout(COALESCE_QUIET.min(remaining)) {
                Ok(Message::Event(event)) => batch.merge(event),
                Ok(Message::Stop) => {
                    deliver(&handler, batch);
                    return;
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    deliver(&handler, batch);
                    return;
                }
            }
        }
        deliver(&handler, batch);
    }
}

fn deliver(handler: &impl Fn(WatchEvent), mut batch: WatchEvent) {
    if batch.is_empty() {
        return;
    }
    batch.paths.sort();
    batch.paths.dedup();
    handler(batch);
}
