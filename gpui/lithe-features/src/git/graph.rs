//! Git Log 提交表左侧的分支图（车道布局 + 弯曲连线）。
//!
//! 之前提交表每个行首只画了一条按行号循环取色的竖直线，多分支时完全看不出
//! 分叉与合并。这里按 IntelliJ / VSCode 的规则分配车道（lane）：
//!
//! - 车道里记录「下一个将出现在该车道的提交哈希」；
//! - 提交落在等待它的车道上；没有任何车道在等它就是新的分支头；
//! - 第一个还没被别的车道占用的父提交继承节点车道与颜色，其余父提交新开
//!   车道（分叉）；多个车道同时等待同一个提交时汇入同一节点（合并）。
//!
//! 连线用三次贝塞尔绘制，因此在分叉 / 合并处是弯曲的 S 形折线，而不是一条
//! 直线。颜色沿用 macOS `GitGraphColor.color(for:isDark:)` 的 IDEA 默认色
//! 生成器：由颜色 id 推出色相，再按深浅主题取饱和度与明度。

use gpui_kit::{
    AnyElement, App, Bounds, Hsla, IntoElement, ParentElement as _, PathBuilder, Pixels,
    Styled as _, Window, canvas, div, hsla, point, px,
};

use super::model::CoreCommit;

/// 提交表行高。图线的端点按行中心计算，因此行高必须与提交行一致。
pub(crate) const COMMIT_ROW_HEIGHT: f32 = 24.0;

/// 相邻车道的水平间距（对齐 macOS `GitGraphGeometry.laneSpacing`）。
const LANE_SPACING: f32 = 14.0;
/// 第一条车道中心到图列左边缘的距离。
const LANE_INSET: f32 = 8.0;
/// 车道数上限。超过后复用最右车道，避免图列无限变宽。
const MAX_LANES: usize = 12;
/// 连线宽度。
const LINE_WIDTH: f32 = 1.5;
/// 节点直径。
const NODE_DIAMETER: f32 = 7.0;

/// 整张分支图：每行一份几何数据。
pub(crate) struct GraphLayout {
    pub(crate) rows: Vec<GraphRow>,
    /// 图列的车道数（取所有行里最宽的一行，受 [`MAX_LANES`] 限制）。
    pub(crate) lane_count: usize,
}

/// 一行的图形：节点位置、节点颜色与需要绘制的线段。
pub(crate) struct GraphRow {
    node_lane: usize,
    node_color: Hsla,
    lines: Vec<GraphLine>,
}

impl GraphRow {
    /// 该行节点的颜色；装饰胶囊与节点、图线保持同色。
    pub(crate) fn node_color(&self) -> Hsla {
        self.node_color
    }

    /// 渲染该行的图列。`ring` 是节点描边色（通常是编辑器背景），让节点从
    /// 连线上"扣"出来，与 macOS 的节点描边一致。
    pub(crate) fn render(&self, height: f32, lane_count: usize, ring: Hsla) -> AnyElement {
        let width = lane_width(lane_count);
        let lines = self.lines.clone();
        let node_x = LANE_INSET + clamp_lane(self.node_lane) * LANE_SPACING;
        let node_center = height / 2.0;

        div()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .relative()
            .child(
                canvas(
                    move |bounds, _window, _cx| bounds.size,
                    move |bounds: Bounds<Pixels>, _size, window: &mut Window, _cx: &mut App| {
                        let origin = bounds.origin;
                        let row_height = bounds.size.height;
                        for line in &lines {
                            let start = point(
                                origin.x + px(LANE_INSET + line.start_lane * LANE_SPACING),
                                origin.y + line.start_y * row_height,
                            );
                            let end = point(
                                origin.x + px(LANE_INSET + line.end_lane * LANE_SPACING),
                                origin.y + line.end_y * row_height,
                            );
                            let mut builder = PathBuilder::stroke(px(LINE_WIDTH));
                            builder.move_to(start);
                            if (line.start_lane - line.end_lane).abs() < f32::EPSILON {
                                builder.line_to(end);
                            } else {
                                // 控制点落在起止高度的中段，形成 IDEA 那种平滑的
                                // S 形分叉 / 合并线。
                                let half = (end.y - start.y) * 0.5;
                                builder.cubic_bezier_to(
                                    end,
                                    point(start.x, start.y + half),
                                    point(end.x, end.y - half),
                                );
                            }
                            if let Ok(path) = builder.build() {
                                window.paint_path(path, line.color);
                            }
                        }
                    },
                )
                // Canvas 本身没有内容尺寸，必须显式给出宽高，否则 paint 收到
                // 的是 0×0 的 bounds，连线不会出现。
                .w(px(width))
                .h(px(height)),
            )
            .child(
                div()
                    .absolute()
                    .left(px(node_x - NODE_DIAMETER / 2.0))
                    .top(px(node_center - NODE_DIAMETER / 2.0))
                    .size(px(NODE_DIAMETER))
                    .rounded_full()
                    .bg(self.node_color)
                    .border_1()
                    .border_color(ring),
            )
            .into_any_element()
    }
}

/// 一段图线。`*_y` 是行高的归一化位置：`0.0` 行顶、`0.5` 行中心、`1.0` 行底。
#[derive(Clone, Copy)]
struct GraphLine {
    start_lane: f32,
    start_y: f32,
    end_lane: f32,
    end_y: f32,
    color: Hsla,
}

impl GraphLine {
    fn new(start_lane: f32, start_y: f32, end_lane: f32, end_y: f32, color: Hsla) -> Self {
        Self {
            start_lane,
            start_y,
            end_lane,
            end_y,
            color,
        }
    }
}

/// 车道状态：下一个出现在该车道的提交，以及该车道的颜色。
struct Lane {
    hash: String,
    color: Hsla,
}

/// 计算整张分支图。
///
/// `commit` 顺序必须与提交表一致（新 → 旧）；`fallback` 是无颜色 id 时使用的
/// 前景色（IDEA 的 labelColor）。
pub(crate) fn layout(commits: &[&CoreCommit], is_dark: bool, fallback: Hsla) -> GraphLayout {
    let mut lanes: Vec<Option<Lane>> = Vec::new();
    let mut next_color: i32 = 1;
    let mut rows: Vec<GraphRow> = Vec::with_capacity(commits.len());
    let mut widest = 1usize;
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();

    for commit in commits {
        // 分页重叠等情况下同一个 hash 可能出现两次：只画一个不推进车道的
        // 节点，避免车道被同一条历史重复占用。
        if !seen.insert(commit.hash.as_str()) {
            rows.push(GraphRow {
                node_lane: 0,
                node_color: fallback,
                lines: Vec::new(),
            });
            continue;
        }

        let existing = lanes
            .iter()
            .position(|lane| lane.as_ref().is_some_and(|lane| lane.hash == commit.hash));
        let is_new_head = existing.is_none();
        let node_lane = match existing {
            Some(index) => index,
            None => {
                let lane = Lane {
                    hash: commit.hash.clone(),
                    color: idea_color(next_color, is_dark, fallback),
                };
                next_color = next_color.saturating_add(1);
                let index = match lanes.iter().position(Option::is_none) {
                    Some(index) => index,
                    None => {
                        lanes.push(None);
                        lanes.len() - 1
                    }
                };
                lanes[index] = Some(lane);
                index
            }
        };
        let node_lane_f = clamp_lane(node_lane);
        let node_color = lanes[node_lane]
            .as_ref()
            .map(|lane| lane.color)
            .unwrap_or(fallback);

        let mut lines: Vec<GraphLine> = Vec::new();

        // 行顶 → 行底：其他车道直通；等待本提交的车道汇入节点中心。
        for (index, lane) in lanes.iter().enumerate() {
            let Some(lane) = lane else { continue };
            let lane_x = clamp_lane(index);
            if lane.hash == commit.hash {
                // 新分支头没有从上方来的线，否则会凭空出现在第一行上方。
                if index != node_lane || !is_new_head {
                    lines.push(GraphLine::new(lane_x, 0.0, node_lane_f, 0.5, lane.color));
                }
            } else {
                lines.push(GraphLine::new(lane_x, 0.0, lane_x, 1.0, lane.color));
            }
        }

        // 其他等待本提交的车道已经汇入，释放它们。
        for index in 0..lanes.len() {
            if index != node_lane
                && lanes[index]
                    .as_ref()
                    .is_some_and(|lane| lane.hash == commit.hash)
            {
                lanes[index] = None;
            }
        }

        // 出边：父提交。第一个需要新车道的父提交继承节点车道与颜色。
        let mut node_lane_reused = false;
        let mut parents: Vec<&str> = Vec::new();
        for parent in &commit.parent_hashes {
            if parent.is_empty() || parents.contains(&parent.as_str()) {
                continue;
            }
            parents.push(parent.as_str());
        }
        for parent in parents {
            let existing = lanes
                .iter()
                .position(|lane| lane.as_ref().is_some_and(|lane| lane.hash == parent));
            let target = match existing {
                Some(index) => index,
                None if !node_lane_reused => {
                    lanes[node_lane] = Some(Lane {
                        hash: parent.to_string(),
                        color: node_color,
                    });
                    node_lane_reused = true;
                    node_lane
                }
                None => {
                    let lane = Lane {
                        hash: parent.to_string(),
                        color: idea_color(next_color, is_dark, fallback),
                    };
                    next_color = next_color.saturating_add(1);
                    let index = match lanes.iter().position(Option::is_none) {
                        Some(index) => index,
                        None => {
                            lanes.push(None);
                            lanes.len() - 1
                        }
                    };
                    lanes[index] = Some(lane);
                    index
                }
            };
            let color = lanes[target]
                .as_ref()
                .map(|lane| lane.color)
                .unwrap_or(node_color);
            lines.push(GraphLine::new(
                node_lane_f,
                0.5,
                clamp_lane(target),
                1.0,
                color,
            ));
        }
        if !node_lane_reused {
            // 根提交（没有父提交）或所有父提交都已有车道：节点车道到此结束。
            lanes[node_lane] = None;
        }

        widest = widest.max(lanes.len());
        rows.push(GraphRow {
            node_lane,
            node_color,
            lines,
        });
    }

    GraphLayout {
        rows,
        lane_count: widest.clamp(1, MAX_LANES),
    }
}

fn clamp_lane(index: usize) -> f32 {
    index.min(MAX_LANES - 1) as f32
}

fn lane_width(lane_count: usize) -> f32 {
    let lanes = lane_count.clamp(1, MAX_LANES) as f32;
    LANE_INSET * 2.0 + (lanes - 1.0) * LANE_SPACING
}

/// IDEA `DefaultColorGenerator` 的 GPUI 版本。
///
/// 与 macOS `GitGraphColor.color(for:isDark:)` 一致：id 为 0 用前景色；
/// 其余由三次取模得到 RGB 基色，取出色相后按主题固定饱和度 / 明度。
fn idea_color(id: i32, is_dark: bool, fallback: Hsla) -> Hsla {
    if id == 0 {
        return fallback;
    }
    let component = |multiplier: i32, offset: i32| -> f32 {
        let value = id.wrapping_mul(multiplier).wrapping_add(offset);
        ((value.unsigned_abs() % 100) as f32 + 70.0) / 255.0
    };
    let (red, green, blue) = (component(200, 30), component(130, 50), component(90, 100));
    let hue = rgb_hue(red, green, blue);
    // Swift 侧用的是 HSV 的 saturation / brightness；gpui 的 Hsla 是 HSL，
    // 这里按标准公式换算，保证深浅主题下亮度与 macOS 视觉一致。
    let value: f32 = if is_dark { 0.6 } else { 0.7 };
    let saturation: f32 = 0.6;
    let lightness: f32 = value * (1.0 - saturation / 2.0);
    let hsl_saturation = if lightness <= 0.0 || lightness >= 1.0 {
        0.0
    } else {
        (value - lightness) / lightness.min(1.0 - lightness)
    };
    hsla(hue, hsl_saturation, lightness, 1.0)
}

fn rgb_hue(red: f32, green: f32, blue: f32) -> f32 {
    let max = red.max(green).max(blue);
    let min = red.min(green).min(blue);
    let delta = max - min;
    if delta <= f32::EPSILON {
        return 0.0;
    }
    let hue = if (max - red).abs() < f32::EPSILON {
        ((green - blue) / delta).rem_euclid(6.0)
    } else if (max - green).abs() < f32::EPSILON {
        (blue - red) / delta + 2.0
    } else {
        (red - green) / delta + 4.0
    };
    hue / 6.0
}
