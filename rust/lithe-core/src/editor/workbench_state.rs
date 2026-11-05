//! Editor tab group membership rules owned by Rust Core (`editor.workbenchState.reduce`).
//!
//! The reducer owns which group presents each tab, how the binary split tree
//! grows and collapses, which tab each group selects, and which group has the
//! focus after opening, closing, moving, dropping and focusing tabs. Hosts own
//! everything visual: split ratios, pixel geometry, drag hit testing and the
//! per-frame drag target. Tab and group identifiers are opaque host strings;
//! new group and split identities are supplied by the host so the reducer
//! stays deterministic.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::protocol::{CoreError, ErrorCode};

/// Upper bound on tabs in one request; real workbenches hold far fewer and the
/// bound keeps the quadratic order operations cheap.
const MAX_TABS: usize = 10_000;

/// Complete tab group state exchanged with a host. Hosts treat a returned state
/// as the only source for placement, selection and focus.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct WorkbenchState {
    layout: GroupLayout,
    /// Tabs in the host's presentation order. A group presents its tabs in
    /// this relative order.
    tabs: Vec<TabPlacement>,
    /// One entry per group, in layout order. `tab` is null only for an empty group.
    #[serde(default)]
    selections: Vec<GroupSelection>,
    /// Group that receives tabs opened without an explicit target. Null until
    /// the host first focuses a tab.
    focused_group: Option<String>,
}

/// Binary split tree of editor groups.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
enum GroupLayout {
    /// A leaf group identified by its opaque host ID.
    Group(String),
    Split(Box<SplitLayout>),
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SplitLayout {
    /// Opaque host ID; hosts key split ratios by it.
    id: String,
    orientation: Orientation,
    /// Left child for horizontal splits, top child for vertical splits.
    first: GroupLayout,
    second: GroupLayout,
}

/// `horizontal` places the children side by side; `vertical` stacks them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum Orientation {
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TabPlacement {
    id: String,
    /// Owning group. Null or an unknown group places the tab in the focused group.
    group: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GroupSelection {
    group: String,
    tab: Option<String>,
}

/// Drop or insert position relative to a target group.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum DropSide {
    /// Join the target group's tab strip.
    Center,
    Left,
    Right,
    Top,
    Bottom,
}

impl DropSide {
    fn orientation(self) -> Orientation {
        match self {
            Self::Top | Self::Bottom => Orientation::Vertical,
            _ => Orientation::Horizontal,
        }
    }

    fn leading(self) -> bool {
        matches!(self, Self::Left | Self::Top)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum MovePosition {
    Before,
    After,
}

/// One user-level tab action. Every action is followed by the same
/// normalization, so membership, selection and focus rules have one owner.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
enum WorkbenchAction {
    /// Replaces the set and order of open tabs; existing placements are kept
    /// and new tabs join the focused group.
    Sync { tabs: Vec<String> },
    /// Moves an open tab into a group, or into a new group split off it.
    #[serde(rename_all = "camelCase")]
    Drop {
        tab: String,
        group: String,
        side: DropSide,
        new_group: Option<String>,
        new_split: Option<String>,
    },
    /// Reports whether the matching `drop` would apply, without changing state.
    CanDrop {
        tab: String,
        group: String,
        side: DropSide,
    },
    /// Opens a tab that is not yet presented. A null group targets the
    /// focused group and ignores `side`.
    #[serde(rename_all = "camelCase")]
    Insert {
        tab: String,
        group: Option<String>,
        side: DropSide,
        new_group: Option<String>,
        new_split: Option<String>,
    },
    /// Reorders a tab next to another tab and adopts that tab's group.
    Move {
        tab: String,
        target: String,
        position: MovePosition,
    },
    /// Selects a tab and focuses its group.
    Focus { tab: String },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    state: WorkbenchState,
    action: WorkbenchAction,
}

/// Reduction outcome. `applied` is false for rejected or no-op actions, which
/// return the normalized input state.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    applied: bool,
    state: WorkbenchState,
}

/// Entry point for `editor.workbenchState.reduce`.
///
/// Returns `invalid_request` for malformed payloads, structurally invalid
/// layouts (duplicate group or split IDs), oversized tab lists, and edge
/// drops whose new group or split identity is missing or already in use.
pub(crate) fn reduce_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid workbench state request")
            .with_details(error.to_string())
    })?;
    let response = reduce(request.state, request.action)?;
    Ok(serde_json::to_value(response).expect("workbench state response should encode"))
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn reduce(state: WorkbenchState, action: WorkbenchAction) -> Result<Response, CoreError> {
    validate_layout(&state.layout)?;
    if state.tabs.len() > MAX_TABS {
        return Err(invalid("Too many workbench tabs"));
    }
    let current = normalize(&state, state.clone());
    let unchanged = |current: WorkbenchState| Response {
        applied: false,
        state: current,
    };
    let next = match action {
        WorkbenchAction::Sync { tabs } => {
            if tabs.len() > MAX_TABS {
                return Err(invalid("Too many workbench tabs"));
            }
            let mut draft = current.clone();
            draft.tabs = tabs
                .into_iter()
                .map(|id| {
                    let group = group_of(&current, &id).map(str::to_owned);
                    TabPlacement { id, group }
                })
                .collect();
            Some(normalize(&current, draft))
        }
        WorkbenchAction::CanDrop { tab, group, side } => {
            let allowed = can_drop(&current, &tab, &group, side);
            return Ok(Response {
                applied: allowed,
                state: current,
            });
        }
        WorkbenchAction::Drop {
            tab,
            group,
            side,
            new_group,
            new_split,
        } => {
            if !can_drop(&current, &tab, &group, side) {
                return Ok(unchanged(current));
            }
            let mut draft = current.clone();
            if side == DropSide::Center {
                place_after_group(&mut draft.tabs, &tab, &group);
            } else {
                let created = split_group(&mut draft, &group, side, new_group, new_split)?;
                set_group(&mut draft.tabs, &tab, created);
            }
            let mut next = normalize(&current, draft);
            focus(&mut next, &tab);
            Some(next)
        }
        WorkbenchAction::Insert {
            tab,
            group,
            side,
            new_group,
            new_split,
        } => {
            if group_of(&current, &tab).is_some() {
                return Ok(unchanged(current));
            }
            let mut draft = current.clone();
            match group {
                None => draft.tabs.push(TabPlacement {
                    id: tab.clone(),
                    group: Some(destination(&current).to_owned()),
                }),
                Some(group) if !current.layout.groups().contains(&group.as_str()) => {
                    return Ok(unchanged(current));
                }
                Some(group) if side == DropSide::Center => {
                    draft.tabs.push(TabPlacement {
                        id: tab.clone(),
                        group: None,
                    });
                    place_after_group(&mut draft.tabs, &tab, &group);
                }
                Some(group) => {
                    let created = split_group(&mut draft, &group, side, new_group, new_split)?;
                    draft.tabs.push(TabPlacement {
                        id: tab.clone(),
                        group: Some(created),
                    });
                }
            }
            let mut next = normalize(&current, draft);
            focus(&mut next, &tab);
            Some(next)
        }
        WorkbenchAction::Move {
            tab,
            target,
            position,
        } => {
            let target_group = group_of(&current, &target).map(str::to_owned);
            match target_group {
                Some(target_group) if tab != target => {
                    let mut draft = current.clone();
                    draft.tabs.retain(|placement| placement.id != tab);
                    let index = draft
                        .tabs
                        .iter()
                        .position(|placement| placement.id == target)
                        .expect("target remains after removing a different tab");
                    let index = index + usize::from(position == MovePosition::After);
                    draft.tabs.insert(
                        index,
                        TabPlacement {
                            id: tab.clone(),
                            group: Some(target_group.clone()),
                        },
                    );
                    let same_order = draft
                        .tabs
                        .iter()
                        .map(|placement| &placement.id)
                        .eq(current.tabs.iter().map(|placement| &placement.id));
                    if same_order && group_of(&current, &tab) == Some(target_group.as_str()) {
                        None
                    } else {
                        Some(normalize(&current, draft))
                    }
                }
                _ => None,
            }
        }
        WorkbenchAction::Focus { tab } => {
            let mut next = current.clone();
            focus(&mut next, &tab);
            Some(next)
        }
    };
    Ok(match next {
        Some(next) if next != current => Response {
            applied: true,
            state: next,
        },
        _ => unchanged(current),
    })
}

impl GroupLayout {
    fn groups(&self) -> Vec<&str> {
        let mut groups = Vec::new();
        self.collect_groups(&mut groups);
        groups
    }

    fn collect_groups<'a>(&'a self, groups: &mut Vec<&'a str>) {
        match self {
            Self::Group(id) => groups.push(id),
            Self::Split(split) => {
                split.first.collect_groups(groups);
                split.second.collect_groups(groups);
            }
        }
    }

    fn collect_ids<'a>(&'a self, ids: &mut Vec<&'a str>) {
        match self {
            Self::Group(id) => ids.push(id),
            Self::Split(split) => {
                ids.push(&split.id);
                split.first.collect_ids(ids);
                split.second.collect_ids(ids);
            }
        }
    }

    /// Replaces the leaf `group` with a split holding it and `created`.
    fn splitting(self, group: &str, side: DropSide, created: &str, split_id: &str) -> Self {
        match self {
            Self::Group(id) if id == group => {
                let old = Self::Group(id);
                let new = Self::Group(created.to_owned());
                let (first, second) = if side.leading() {
                    (new, old)
                } else {
                    (old, new)
                };
                Self::Split(Box::new(SplitLayout {
                    id: split_id.to_owned(),
                    orientation: side.orientation(),
                    first,
                    second,
                }))
            }
            Self::Group(id) => Self::Group(id),
            Self::Split(split) => {
                let SplitLayout {
                    id,
                    orientation,
                    first,
                    second,
                } = *split;
                Self::Split(Box::new(SplitLayout {
                    id,
                    orientation,
                    first: first.splitting(group, side, created, split_id),
                    second: second.splitting(group, side, created, split_id),
                }))
            }
        }
    }

    /// Removes groups outside `occupied`; a split with one surviving child is
    /// replaced by that child, keeping the surviving subtree's identities.
    fn keeping(self, occupied: &BTreeSet<&str>) -> Option<Self> {
        match self {
            Self::Group(id) => occupied.contains(id.as_str()).then_some(Self::Group(id)),
            Self::Split(split) => {
                let SplitLayout {
                    id,
                    orientation,
                    first,
                    second,
                } = *split;
                match (first.keeping(occupied), second.keeping(occupied)) {
                    (Some(first), Some(second)) => Some(Self::Split(Box::new(SplitLayout {
                        id,
                        orientation,
                        first,
                        second,
                    }))),
                    (first, second) => first.or(second),
                }
            }
        }
    }
}

fn validate_layout(layout: &GroupLayout) -> Result<(), CoreError> {
    let mut ids = Vec::new();
    layout.collect_ids(&mut ids);
    let mut seen = HashSet::new();
    if ids.iter().all(|id| seen.insert(*id)) {
        Ok(())
    } else {
        Err(invalid("Workbench layout repeats a group or split ID"))
    }
}

fn group_of<'a>(state: &'a WorkbenchState, tab: &str) -> Option<&'a str> {
    state
        .tabs
        .iter()
        .find(|placement| placement.id == tab)
        .and_then(|placement| placement.group.as_deref())
}

/// Group receiving tabs without a valid placement: the focused group while it
/// exists, otherwise the first group in layout order.
fn destination(state: &WorkbenchState) -> &str {
    let groups = state.layout.groups();
    state
        .focused_group
        .as_deref()
        .filter(|focused| groups.contains(focused))
        .unwrap_or(groups[0])
}

fn can_drop(state: &WorkbenchState, tab: &str, group: &str, side: DropSide) -> bool {
    let Some(source) = group_of(state, tab) else {
        return false;
    };
    if !state.layout.groups().contains(&group) {
        return false;
    }
    // Moving into another group always applies; within the owning group only
    // an edge split of a group that keeps another tab changes anything.
    source != group
        || (side != DropSide::Center
            && state
                .tabs
                .iter()
                .filter(|placement| placement.group.as_deref() == Some(group))
                .count()
                > 1)
}

/// Moves `tab` into `group`, right after the group's last tab in
/// presentation order (or to the end when the group has none).
fn place_after_group(tabs: &mut Vec<TabPlacement>, tab: &str, group: &str) {
    tabs.retain(|placement| placement.id != tab);
    let index = tabs
        .iter()
        .rposition(|placement| placement.group.as_deref() == Some(group))
        .map_or(tabs.len(), |last| last + 1);
    tabs.insert(
        index,
        TabPlacement {
            id: tab.to_owned(),
            group: Some(group.to_owned()),
        },
    );
}

fn set_group(tabs: &mut [TabPlacement], tab: &str, group: String) {
    if let Some(placement) = tabs.iter_mut().find(|placement| placement.id == tab) {
        placement.group = Some(group);
    }
}

fn split_group(
    draft: &mut WorkbenchState,
    group: &str,
    side: DropSide,
    new_group: Option<String>,
    new_split: Option<String>,
) -> Result<String, CoreError> {
    let (Some(created), Some(split_id)) = (new_group, new_split) else {
        return Err(invalid(
            "Workbench edge drops require new group and split IDs",
        ));
    };
    let mut ids = Vec::new();
    draft.layout.collect_ids(&mut ids);
    if created == split_id || ids.contains(&created.as_str()) || ids.contains(&split_id.as_str()) {
        return Err(invalid("Workbench split identities must be new"));
    }
    let layout = std::mem::replace(&mut draft.layout, GroupLayout::Group(String::new()));
    draft.layout = layout.splitting(group, side, &created, &split_id);
    Ok(created)
}

fn focus(state: &mut WorkbenchState, tab: &str) {
    let Some(group) = group_of(state, tab).map(str::to_owned) else {
        return;
    };
    if let Some(selection) = state
        .selections
        .iter_mut()
        .find(|selection| selection.group == group)
    {
        selection.tab = Some(tab.to_owned());
    }
    state.focused_group = Some(group);
}

/// Applies the shared invariants to `draft`, using `previous` to keep each
/// group's selection near its former position.
///
/// - Tab IDs are unique; the first occurrence wins.
/// - Tabs without a valid group join the focused group (else the first group).
/// - Empty groups are removed and their splits collapse; when every group is
///   empty, the first group remains as the single reusable group.
/// - A focused group that disappeared falls back to the first remaining group.
/// - A group keeps its selected tab while the tab stays in the group;
///   otherwise it selects the tab now at the former selection's index, or the
///   last tab when the index passed the end, or its first tab when it had no
///   selection.
fn normalize(previous: &WorkbenchState, mut draft: WorkbenchState) -> WorkbenchState {
    let groups: Vec<String> = draft
        .layout
        .groups()
        .into_iter()
        .map(str::to_owned)
        .collect();
    let fallback = destination(&draft).to_owned();
    let mut seen = HashSet::new();
    draft
        .tabs
        .retain(|placement| seen.insert(placement.id.clone()));
    for placement in &mut draft.tabs {
        if !placement
            .group
            .as_ref()
            .is_some_and(|group| groups.contains(group))
        {
            placement.group = Some(fallback.clone());
        }
    }

    let occupied: BTreeSet<&str> = draft
        .tabs
        .iter()
        .filter_map(|placement| placement.group.as_deref())
        .collect();
    let layout = draft
        .layout
        .clone()
        .keeping(&occupied)
        .unwrap_or_else(|| GroupLayout::Group(groups[0].clone()));
    let remaining: Vec<String> = layout.groups().into_iter().map(str::to_owned).collect();
    draft.layout = layout;
    if draft
        .focused_group
        .as_ref()
        .is_some_and(|focused| !remaining.contains(focused))
    {
        draft.focused_group = Some(remaining[0].clone());
    }

    let members = members_by_group(&draft);
    let previous_members = members_by_group(previous);
    let previous_selection: BTreeMap<&str, &str> = previous
        .selections
        .iter()
        .filter_map(|selection| Some((selection.group.as_str(), selection.tab.as_deref()?)))
        .collect();
    let selections = remaining
        .iter()
        .map(|group| {
            let tabs = members.get(group.as_str()).cloned().unwrap_or_default();
            let selected = previous_selection.get(group.as_str()).copied();
            let tab = match selected {
                Some(selected) if tabs.contains(&selected) => Some(selected),
                Some(selected) => previous_members
                    .get(group.as_str())
                    .and_then(|old| old.iter().position(|tab| *tab == selected))
                    .and_then(|index| tabs.get(index.min(tabs.len().saturating_sub(1))))
                    .or(tabs.first())
                    .copied(),
                None => tabs.first().copied(),
            };
            GroupSelection {
                group: group.clone(),
                tab: tab.map(str::to_owned),
            }
        })
        .collect();
    draft.selections = selections;
    draft
}

fn members_by_group(state: &WorkbenchState) -> BTreeMap<&str, Vec<&str>> {
    let mut members: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for placement in &state.tabs {
        if let Some(group) = placement.group.as_deref() {
            members.entry(group).or_default().push(&placement.id);
        }
    }
    members
}
