//! 窗格树纯逻辑：对齐 Tauri `features/panes` 的拆分与路由语义。
//!
//! 窗格树可任意嵌套左右/上下拆分（[`SplitDir::Horizontal`] 为左右并排，
//! [`SplitDir::Vertical`] 为上下堆叠）。锁定窗格不接收新文件：
//! [`PaneTree::route_target`] 在 active 未锁定时返回 active，否则返回
//! 第一个未锁定叶，全锁定时返回 `None`（对齐 `pane-routing.ts`
//! `resolveWritablePaneForBuffer` 的回退语义）。
//!
//! 本模块不依赖 gpui，只表达树形结构与路由规则，方便单测。

use std::collections::HashSet;

/// 窗格标识：[`PaneTree::new`] 从 0 起按拆分顺序递增分配。
pub type PaneId = u64;

/// 拆分方向：`Horizontal` 为左右并排，`Vertical` 为上下堆叠。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// 左右并排。
    Horizontal,
    /// 上下堆叠。
    Vertical,
}

/// 窗格树节点：叶为单个窗格，`Split` 为一次拆分（`first` 为原叶所在侧，
/// `second` 为新叶所在侧，`ratio` 为 `first` 所占比例）。
#[derive(Debug, Clone, PartialEq)]
pub enum PaneNode {
    /// 单个窗格。
    Leaf(PaneId),
    /// 一次拆分。
    Split {
        /// 拆分方向。
        dir: SplitDir,
        /// 原叶所在侧。
        first: Box<PaneNode>,
        /// 新叶所在侧。
        second: Box<PaneNode>,
        /// `first` 所占比例，写入时钳制在 `0.1..=0.9`。
        ratio: f32,
    },
}

/// 比例下界：所有写入 [`PaneNode::Split::ratio`] 的值都钳制到
/// `MIN_RATIO..=MAX_RATIO`。
const MIN_RATIO: f32 = 0.1;
/// 比例上界，见 [`MIN_RATIO`]。
const MAX_RATIO: f32 = 0.9;

/// 窗格树：持有根节点、下个待分配 id、活动窗格与锁定集合。
#[derive(Debug, Clone)]
pub struct PaneTree {
    root: Option<PaneNode>,
    next_id: u64,
    active: Option<PaneId>,
    locked: HashSet<PaneId>,
}

impl PaneTree {
    /// 新建单叶树：叶 id 为 0，active 为 `Some(0)`。
    pub fn new() -> Self {
        Self {
            root: Some(PaneNode::Leaf(0)),
            next_id: 1,
            active: Some(0),
            locked: HashSet::new(),
        }
    }

    /// 当前活动窗格（关闭后会自动跟随到存活叶）。
    pub fn active(&self) -> Option<PaneId> {
        self.active
    }

    /// 根节点只读视图（渲染层递归用）。
    pub fn root(&self) -> Option<&PaneNode> {
        self.root.as_ref()
    }

    /// 先序收集所有叶 id（`Split` 先 `first` 后 `second`）。
    pub fn leaves(&self) -> Vec<PaneId> {
        let mut out = Vec::new();
        if let Some(root) = &self.root {
            collect_leaves(root, &mut out);
        }
        out
    }

    /// 拆分叶 `id`：原叶变为 `Split` 的 `first`，新叶为 `second`，
    /// 比例为 0.5；返回新叶 id，叶不存在时返回 `None`。
    pub fn split_leaf(&mut self, id: PaneId, dir: SplitDir) -> Option<PaneId> {
        let slot = self
            .root
            .as_mut()
            .and_then(|root| find_leaf_mut(root, id))?;
        let new_id = self.next_id;
        self.next_id += 1;
        *slot = PaneNode::Split {
            dir,
            first: Box::new(PaneNode::Leaf(id)),
            second: Box::new(PaneNode::Leaf(new_id)),
            ratio: 0.5,
        };
        Some(new_id)
    }

    /// 关闭叶 `id`：兄弟子树顶替父 `Split`；只剩根叶时保留不删返回
    /// `false`，叶不存在时同样返回 `false`。关闭的叶若为 active，
    /// active 指向顶替兄弟的首叶（就近存活叶）。
    pub fn close_leaf(&mut self, id: PaneId) -> bool {
        if matches!(self.root, Some(PaneNode::Leaf(root_id)) if root_id == id) {
            return false;
        }
        let fallback = match self.root.as_mut() {
            Some(root) => delete_leaf(root, id),
            None => None,
        };
        let Some(fallback) = fallback else {
            return false;
        };
        self.locked.remove(&id);
        if self.active == Some(id) {
            self.active = Some(fallback);
        }
        true
    }

    /// 按叶子归属定位其父 `Split` 并更新比例（钳制在 `0.1..=0.9`）；
    /// 根叶或叶不存在时返回 `false`。
    pub fn set_ratio(&mut self, leaf: PaneId, ratio: f32) -> bool {
        let parent = self
            .root
            .as_mut()
            .and_then(|root| find_parent_split_mut(root, leaf));
        match parent {
            Some(PaneNode::Split { ratio: slot, .. }) => {
                *slot = clamp_ratio(ratio);
                true
            }
            _ => false,
        }
    }

    /// 叶存在时设为 active 并返回 `true`，否则保持原值返回 `false`。
    pub fn set_active(&mut self, id: PaneId) -> bool {
        if self.leaves().contains(&id) {
            self.active = Some(id);
            true
        } else {
            false
        }
    }

    /// 翻转叶 `id` 的锁定态并返回翻转后状态；叶不存在时不记录返回 `false`。
    pub fn toggle_lock(&mut self, id: PaneId) -> bool {
        if !self.leaves().contains(&id) {
            return false;
        }
        if self.locked.contains(&id) {
            self.locked.remove(&id);
            false
        } else {
            self.locked.insert(id);
            true
        }
    }

    /// 叶 `id` 是否被锁定（不存在的叶返回 `false`）。
    pub fn is_locked(&self, id: PaneId) -> bool {
        self.locked.contains(&id)
    }

    /// 新文件路由目标：active 存在且未锁定时返回 active，否则返回
    /// 第一个未锁定叶；全部锁定时返回 `None`。
    pub fn route_target(&self) -> Option<PaneId> {
        let leaves = self.leaves();
        if let Some(active) = self.active {
            if leaves.contains(&active) && !self.locked.contains(&active) {
                return Some(active);
            }
        }
        leaves.into_iter().find(|id| !self.locked.contains(id))
    }
}

/// 空树默认值（`root` 为空，`active` 为空）；常规入口仍用 [`PaneTree::new`]。
impl Default for PaneTree {
    fn default() -> Self {
        Self {
            root: None,
            next_id: 0,
            active: None,
            locked: HashSet::new(),
        }
    }
}

/// 比例钳制到 `MIN_RATIO..=MAX_RATIO`。
fn clamp_ratio(ratio: f32) -> f32 {
    ratio.clamp(MIN_RATIO, MAX_RATIO)
}

/// 先序收集叶 id。
fn collect_leaves(node: &PaneNode, out: &mut Vec<PaneId>) {
    match node {
        PaneNode::Leaf(id) => out.push(*id),
        PaneNode::Split { first, second, .. } => {
            collect_leaves(first, out);
            collect_leaves(second, out);
        }
    }
}

/// 子树首叶（先序第一个叶）。
fn first_leaf(node: &PaneNode) -> Option<PaneId> {
    match node {
        PaneNode::Leaf(id) => Some(*id),
        PaneNode::Split { first, .. } => first_leaf(first),
    }
}

/// 在子树中定位叶 `id` 的可写槽。
fn find_leaf_mut(node: &mut PaneNode, id: PaneId) -> Option<&mut PaneNode> {
    match node {
        PaneNode::Leaf(leaf_id) if *leaf_id == id => Some(node),
        PaneNode::Leaf(_) => None,
        PaneNode::Split { first, second, .. } => {
            find_leaf_mut(first, id).or_else(|| find_leaf_mut(second, id))
        }
    }
}

/// 叶 `id` 的父 `Split`（根叶无父，返回 `None`）。
///
/// 先用不可变借用判直属（借用即时结束），再决定返回 `node` 或向下递归，
/// 避免可变借用与返回值的生命周期冲突。
fn find_parent_split_mut(node: &mut PaneNode, leaf: PaneId) -> Option<&mut PaneNode> {
    fn is_leaf_id(node: &PaneNode, leaf: PaneId) -> bool {
        matches!(node, PaneNode::Leaf(id) if *id == leaf)
    }
    let is_direct_child = match node {
        PaneNode::Leaf(_) => return None,
        PaneNode::Split { first, second, .. } => {
            is_leaf_id(first, leaf) || is_leaf_id(second, leaf)
        }
    };
    if is_direct_child {
        return Some(node);
    }
    match node {
        PaneNode::Leaf(_) => None,
        PaneNode::Split { first, second, .. } => {
            find_parent_split_mut(first, leaf).or_else(|| find_parent_split_mut(second, leaf))
        }
    }
}

/// 删除子树中的叶 `id`，兄弟子树顶替父 `Split`；成功返回顶替兄弟的首叶。
fn delete_leaf(node: &mut PaneNode, id: PaneId) -> Option<PaneId> {
    let PaneNode::Split { first, second, .. } = node else {
        return None;
    };
    if matches!(**first, PaneNode::Leaf(leaf_id) if leaf_id == id) {
        let fallback = first_leaf(second);
        let mut empty = PaneNode::Leaf(0);
        std::mem::swap(&mut empty, second);
        *node = empty;
        return fallback;
    }
    if matches!(**second, PaneNode::Leaf(leaf_id) if leaf_id == id) {
        let fallback = first_leaf(first);
        let mut empty = PaneNode::Leaf(0);
        std::mem::swap(&mut empty, first);
        *node = empty;
        return fallback;
    }
    delete_leaf(first, id).or_else(|| delete_leaf(second, id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 拆分：原叶变 `first`，新叶为 `second`，比例 0.5。
    #[test]
    fn split_leaf_appends_second_leaf() {
        let mut tree = PaneTree::new();
        assert_eq!(tree.split_leaf(0, SplitDir::Horizontal), Some(1));
        assert_eq!(tree.leaves(), vec![0, 1]);
        assert!(matches!(
            tree.root,
            Some(PaneNode::Split {
                dir: SplitDir::Horizontal,
                ratio,
                ..
            }) if ratio == 0.5
        ));
        assert_eq!(tree.split_leaf(99, SplitDir::Vertical), None);
    }

    /// 关闭：兄弟顶替父节点；只剩根叶时保留不删返回 `false`。
    #[test]
    fn close_leaf_collapses_sibling_and_keeps_last_root() {
        let mut tree = PaneTree::new();
        let second = tree.split_leaf(0, SplitDir::Vertical).unwrap();
        assert!(!tree.close_leaf(99));
        assert!(tree.close_leaf(second));
        assert_eq!(tree.leaves(), vec![0]);
        assert!(!tree.close_leaf(0));
        assert_eq!(tree.leaves(), vec![0]);
    }

    /// 关闭 active 叶时 active 跟随到就近存活叶。
    #[test]
    fn close_active_leaf_moves_active_to_survivor() {
        let mut tree = PaneTree::new();
        let second = tree.split_leaf(0, SplitDir::Horizontal).unwrap();
        assert!(tree.set_active(second));
        assert!(tree.close_leaf(second));
        assert_eq!(tree.active(), Some(0));
        assert_eq!(tree.route_target(), Some(0));
    }

    /// 路由：active 未锁定返回 active；锁定后回退首个未锁叶；全锁返回 `None`。
    #[test]
    fn route_target_prefers_unlocked_active_then_falls_back() {
        let mut tree = PaneTree::new();
        let second = tree.split_leaf(0, SplitDir::Horizontal).unwrap();
        assert_eq!(tree.route_target(), Some(0));
        assert!(tree.toggle_lock(0));
        assert!(tree.is_locked(0));
        assert_eq!(tree.route_target(), Some(second));
        tree.toggle_lock(second);
        assert_eq!(tree.route_target(), None);
    }

    /// 比例钳制在 `0.1..=0.9`。
    #[test]
    fn set_ratio_clamps_to_bounds() {
        let mut tree = PaneTree::new();
        tree.split_leaf(0, SplitDir::Horizontal).unwrap();
        assert!(tree.set_ratio(0, 10.0));
        assert_eq!(root_ratio(&tree), Some(0.9));
        assert!(tree.set_ratio(1, -2.0));
        assert_eq!(root_ratio(&tree), Some(0.1));
        assert!(tree.set_ratio(0, 0.3));
        assert_eq!(root_ratio(&tree), Some(0.3));
    }

    /// 测试辅助：读取根 `Split` 的比例（只读私有字段，单测内可访问）。
    fn root_ratio(tree: &PaneTree) -> Option<f32> {
        match &tree.root {
            Some(PaneNode::Split { ratio, .. }) => Some(*ratio),
            _ => None,
        }
    }
}
