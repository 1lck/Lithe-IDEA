//! Membership and selection rules for editor tab groups.
//!
//! Both hosts keep a different shape of the same fact: which tabs live in which group, which tab a
//! group shows, and what happens to that when a tab opens, closes or moves. This module defines one
//! canonical group model (the union of what the two hosts track) and one reducer over it. A host
//! maps its own state into [`State`], runs one [`Action`], and maps the result back.
//!
//! Layout trees, split ratios, pixels and dragging stay in the host. The reducer only reports which
//! groups became empty and were removed so the host can prune its own layout tree.
//!
//! Members are opaque strings; ordering inside a group is the tab order. Every action first
//! de-duplicates the members of the groups it touches and finishes by normalizing them, so a group
//! that leaves the reducer always satisfies the invariants described on [`Group`].

use crate::{RuleError, RuleErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

/// Command name of the reducer in the Core command namespace.
pub const REDUCE_WORKBENCH_STATE: &str = "editor.workbenchState.reduce";

/// One editor group.
///
/// After the reducer touches a group: `members` has no duplicates, `selected` is a member (the
/// first one when the previous value was missing or stale) or `null` when the group is empty,
/// `mru` lists `selected` first, then the previous MRU order, then the remaining members, and
/// `pinned` and `preview` only name members.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Group {
    /// Host identifier of the group.
    pub id: String,
    /// Tabs in display order.
    #[serde(default)]
    pub members: Vec<String>,
    /// Tab the group currently shows.
    #[serde(default)]
    pub selected: Option<String>,
    /// Most recently used members, newest first. Hosts without MRU send an empty list.
    #[serde(default)]
    pub mru: Vec<String>,
    /// Pinned members. Hosts without pinning send an empty list.
    #[serde(default)]
    pub pinned: Vec<String>,
    /// Transient preview member, replaced when another tab previews. Hosts without it send `null`.
    #[serde(default)]
    pub preview: Option<String>,
}

/// All groups a host wants the reducer to consider, in layout order.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct State {
    /// Groups in layout order.
    #[serde(default)]
    pub groups: Vec<Group>,
    /// Group that receives new tabs; falls back to the first group when missing or stale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focused_group: Option<String>,
}

/// What happens to a group that became empty.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EmptyGroups {
    /// Empty groups stay; the host may want to fill them next.
    #[default]
    Keep,
    /// Remove them, even when that leaves no group at all.
    Remove,
    /// Remove them, but never leave the state without a group: the first group stays.
    RemoveKeepingFirst,
}

/// How the selection is chosen when the selected member leaves a group.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SelectionFallback {
    /// The member that slides into the vacated position (or the new last one).
    #[default]
    Adjacent,
    /// The first remaining member.
    First,
}

fn yes() -> bool {
    true
}

/// One state transition requested by a host.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Action {
    /// Repairs every group. `unplaced` members that belong to no group join the focused group.
    /// Empty groups are removed according to `empty_groups`.
    Normalize {
        /// What to do with groups that are empty.
        #[serde(default)]
        empty_groups: EmptyGroups,
        /// Members the host knows about that no group lists yet.
        #[serde(default)]
        unplaced: Vec<String>,
    },
    /// Adds `member` to the end of `group` if missing and optionally selects it.
    Open {
        /// Target group.
        group: String,
        /// Member to add.
        member: String,
        /// Select the member and make it the most recently used.
        #[serde(default = "yes")]
        activate: bool,
    },
    /// Removes `member` from `group`.
    Close {
        /// Group to remove from.
        group: String,
        /// Member to remove.
        member: String,
        /// What to do if the group is now empty.
        #[serde(default)]
        empty_groups: EmptyGroups,
        /// How to choose the next selection when the closed member was selected.
        #[serde(default)]
        selection_fallback: SelectionFallback,
    },
    /// Selects `member` (or repairs the selection when `null`).
    Activate {
        /// Target group.
        group: String,
        /// Member to select; unknown members leave the selection alone.
        #[serde(default)]
        member: Option<String>,
    },
    /// Moves `member` out of `from` into `to`, at the end or next to an anchor. With `from == to`
    /// the member is only repositioned.
    Move {
        /// Member to move.
        member: String,
        /// Group that loses the member.
        from: String,
        /// Group that receives the member; an unknown group makes the move a no-op.
        to: String,
        /// Insert right before this member of `to`.
        #[serde(default)]
        before: Option<String>,
        /// Insert right after this member of `to`.
        #[serde(default)]
        after: Option<String>,
        /// Select the member in `to`.
        #[serde(default = "yes")]
        activate: bool,
        /// What to do if `from` is now empty.
        #[serde(default)]
        empty_groups: EmptyGroups,
        /// How to choose the next selection in `from`.
        #[serde(default)]
        selection_fallback: SelectionFallback,
    },
    /// Moves the member at `from_index` to `to_index` inside one group.
    Reorder {
        /// Target group.
        group: String,
        /// Current position; out-of-range values (including negative ones) change nothing.
        from_index: i64,
        /// New position; out-of-range values change nothing.
        to_index: i64,
    },
    /// Pins or unpins `member` in one group. Pinning clears a preview of the same member.
    SetPinned {
        /// Target group.
        group: String,
        /// Member to change.
        member: String,
        /// New pinned state.
        pinned: bool,
    },
    /// Pins or unpins `member` in every group that lists it.
    SetPinnedEverywhere {
        /// Member to change.
        member: String,
        /// New pinned state.
        pinned: bool,
    },
    /// Sets or clears the preview member of a group. Previewing clears a pin of the same member.
    SetPreview {
        /// Target group.
        group: String,
        /// Member to preview, or `null` to clear.
        #[serde(default)]
        member: Option<String>,
    },
    /// Clears the preview in every group that previews `member`.
    ClearPreviewEverywhere {
        /// Member whose preview is cleared.
        member: String,
    },
    /// Folds every member of `from` into `into` and removes `from`.
    MergeGroup {
        /// Group that disappears.
        from: String,
        /// Group that receives the members; an unknown group makes the action a no-op.
        into: String,
        /// Select the member `from` was showing inside `into`.
        #[serde(default)]
        activate_selected: bool,
    },
}

/// Payload of `editor.workbenchState.reduce`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    #[serde(default)]
    state: State,
    action: Action,
}

/// Result of one reduction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reduction {
    /// The new state; groups keep their relative order.
    pub state: State,
    /// Ids of groups that left the state, in their previous order.
    pub removed_group_ids: Vec<String>,
}

/// Decodes a command payload, runs the reducer and encodes the result.
pub fn reduce_json(payload: Value) -> Result<Value, RuleError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        RuleError::new(
            RuleErrorCode::InvalidRequest,
            "Invalid workbench state request",
        )
        .with_details(error.to_string())
    })?;
    let reduction = reduce(request.state, request.action);
    serde_json::to_value(reduction).map_err(|error| {
        RuleError::new(
            RuleErrorCode::InvalidRequest,
            "Workbench state could not be encoded",
        )
        .with_details(error.to_string())
    })
}

/// Applies `action` to `state`.
///
/// Groups an action does not touch are returned unchanged, so a host can send only the groups an
/// action involves. Actions that name an unknown group leave the state as it is.
pub fn reduce(mut state: State, action: Action) -> Reduction {
    let mut empty_groups = EmptyGroups::Keep;
    let mut affected: Vec<String> = Vec::new();
    let mut removed: Vec<String> = Vec::new();
    let all_ids: Vec<String> = state.groups.iter().map(|group| group.id.clone()).collect();
    // Hosts that never send a focused group (Windows) get no focus bookkeeping back.
    let tracks_focus = state.focused_group.is_some() || matches!(action, Action::Normalize { .. });
    let focus_destination = destination_group(&state);

    match action {
        Action::Normalize {
            empty_groups: policy,
            unplaced,
        } => {
            for group in &mut state.groups {
                normalize(group);
            }
            if let Some(destination) = focus_destination.clone() {
                let placed: HashSet<&str> = state
                    .groups
                    .iter()
                    .flat_map(|group| group.members.iter().map(String::as_str))
                    .collect();
                let missing: Vec<String> = unplaced
                    .into_iter()
                    .filter(|member| !placed.contains(member.as_str()))
                    .collect();
                if let Some(group) = group_mut(&mut state, &destination) {
                    for member in missing {
                        if !group.members.contains(&member) {
                            group.members.push(member);
                        }
                    }
                    normalize(group);
                }
            }
            empty_groups = policy;
            affected = all_ids.clone();
        }
        Action::Open {
            group,
            member,
            activate,
        } => {
            if let Some(target) = group_mut(&mut state, &group) {
                add_member(target, &member, None, activate);
            }
        }
        Action::Close {
            group,
            member,
            empty_groups: policy,
            selection_fallback,
        } => {
            if let Some(target) = group_mut(&mut state, &group) {
                remove_member(target, &member, selection_fallback);
            }
            empty_groups = policy;
            affected = vec![group];
        }
        Action::Activate { group, member } => {
            if let Some(target) = group_mut(&mut state, &group) {
                dedupe(&mut target.members);
                if let Some(member) = member {
                    if target.members.contains(&member) {
                        target.selected = Some(member.clone());
                        target.mru.retain(|id| id != &member);
                        target.mru.insert(0, member);
                    }
                } else {
                    target.selected = None;
                }
                normalize(target);
            }
        }
        Action::Move {
            member,
            from,
            to,
            before,
            after,
            activate,
            empty_groups: policy,
            selection_fallback,
        } => {
            if group_mut(&mut state, &to).is_some() {
                let anchor = before
                    .map(|id| (id, false))
                    .or_else(|| after.map(|id| (id, true)));
                if from == to {
                    // Repositioning inside one group is not a close and an open: the selection,
                    // pins and preview stay unless the caller asks to activate the member.
                    if let Some(target) = group_mut(&mut state, &to) {
                        reposition_member(target, &member, anchor, activate);
                    }
                } else {
                    if let Some(source) = group_mut(&mut state, &from) {
                        remove_member(source, &member, selection_fallback);
                    }
                    if let Some(target) = group_mut(&mut state, &to) {
                        add_member(target, &member, anchor, activate);
                    }
                    affected = vec![from];
                }
                empty_groups = policy;
            }
        }
        Action::Reorder {
            group,
            from_index,
            to_index,
        } => {
            if let Some(target) = group_mut(&mut state, &group) {
                let count = target.members.len() as i64;
                let in_range = |index: i64| (0..count).contains(&index);
                if in_range(from_index) && in_range(to_index) && from_index != to_index {
                    let moved = target.members.remove(from_index as usize);
                    target.members.insert(to_index as usize, moved);
                }
            }
        }
        Action::SetPinned {
            group,
            member,
            pinned,
        } => {
            if let Some(target) = group_mut(&mut state, &group) {
                set_pinned(target, &member, pinned);
            }
        }
        Action::SetPinnedEverywhere { member, pinned } => {
            for group in &mut state.groups {
                if group.members.contains(&member) {
                    set_pinned(group, &member, pinned);
                }
            }
        }
        Action::SetPreview { group, member } => {
            if let Some(target) = group_mut(&mut state, &group) {
                dedupe(&mut target.members);
                match member {
                    Some(member) if !target.members.contains(&member) => {}
                    Some(member) => {
                        target.pinned.retain(|id| id != &member);
                        target.preview = Some(member);
                    }
                    None => target.preview = None,
                }
                normalize(target);
            }
        }
        Action::ClearPreviewEverywhere { member } => {
            for group in &mut state.groups {
                if group.preview.as_deref() == Some(member.as_str()) {
                    group.preview = None;
                    normalize(group);
                }
            }
        }
        Action::MergeGroup {
            from,
            into,
            activate_selected,
        } => {
            if from != into && group_mut(&mut state, &into).is_some() {
                if let Some(source) = state.groups.iter().find(|group| group.id == from).cloned() {
                    let mut source = source;
                    dedupe(&mut source.members);
                    if let Some(target) = group_mut(&mut state, &into) {
                        for member in &source.members {
                            add_member(target, member, None, false);
                        }
                        if let Some(selected) =
                            source.selected.as_ref().filter(|_| activate_selected)
                        {
                            if target.members.contains(selected) {
                                target.selected = Some(selected.clone());
                                target.mru.retain(|id| id != selected);
                                target.mru.insert(0, selected.clone());
                                normalize(target);
                            }
                        }
                    }
                    state.groups.retain(|group| group.id != from);
                    removed.push(from);
                }
            }
        }
    }

    removed.extend(prune_empty(&mut state, empty_groups, &affected));
    if let Some(destination) = focus_destination.filter(|_| tracks_focus) {
        if !state.groups.iter().any(|group| group.id == destination) {
            state.focused_group = state.groups.first().map(|group| group.id.clone());
        }
    }
    let removed_group_ids = all_ids
        .into_iter()
        .filter(|id| removed.contains(id))
        .collect();
    Reduction {
        state,
        removed_group_ids,
    }
}

fn group_mut<'a>(state: &'a mut State, id: &str) -> Option<&'a mut Group> {
    state.groups.iter_mut().find(|group| group.id == id)
}

/// Group that receives members without a home: the focused group, or the first one.
fn destination_group(state: &State) -> Option<String> {
    state
        .focused_group
        .as_ref()
        .filter(|id| state.groups.iter().any(|group| &group.id == *id))
        .cloned()
        .or_else(|| state.groups.first().map(|group| group.id.clone()))
}

fn dedupe(items: &mut Vec<String>) {
    let mut seen = HashSet::new();
    items.retain(|item| seen.insert(item.clone()));
}

/// Restores the invariants documented on [`Group`].
fn normalize(group: &mut Group) {
    dedupe(&mut group.members);
    let members: HashSet<&str> = group.members.iter().map(String::as_str).collect();
    let selected = group
        .selected
        .clone()
        .filter(|id| members.contains(id.as_str()))
        .or_else(|| group.members.first().cloned());

    let mut mru: Vec<String> = Vec::with_capacity(group.members.len());
    let mut seen: HashSet<String> = HashSet::new();
    let ordered = selected
        .iter()
        .chain(group.mru.iter())
        .chain(group.members.iter());
    for id in ordered {
        if members.contains(id.as_str()) && seen.insert(id.clone()) {
            mru.push(id.clone());
        }
    }

    group.pinned.retain(|id| members.contains(id.as_str()));
    dedupe(&mut group.pinned);
    if group
        .preview
        .as_deref()
        .is_some_and(|id| !members.contains(id))
    {
        group.preview = None;
    }
    group.selected = selected;
    group.mru = mru;
}

fn add_member(group: &mut Group, member: &str, anchor: Option<(String, bool)>, activate: bool) {
    dedupe(&mut group.members);
    if !group.members.iter().any(|id| id == member) {
        let position = anchor
            .and_then(|(id, after)| {
                group
                    .members
                    .iter()
                    .position(|candidate| candidate == &id)
                    .map(|index| if after { index + 1 } else { index })
            })
            .unwrap_or(group.members.len());
        group.members.insert(position, member.to_string());
    }
    if activate {
        group.selected = Some(member.to_string());
        group.mru.retain(|id| id != member);
        group.mru.insert(0, member.to_string());
    }
    normalize(group);
}

fn reposition_member(
    group: &mut Group,
    member: &str,
    anchor: Option<(String, bool)>,
    activate: bool,
) {
    dedupe(&mut group.members);
    group.members.retain(|id| id != member);
    add_member(group, member, anchor, activate);
}

fn remove_member(group: &mut Group, member: &str, fallback: SelectionFallback) {
    dedupe(&mut group.members);
    let index = group.members.iter().position(|id| id == member);
    group.members.retain(|id| id != member);
    if group.selected.as_deref() == Some(member) {
        group.selected = match (fallback, index) {
            _ if group.members.is_empty() => None,
            (SelectionFallback::Adjacent, Some(index)) => group
                .members
                .get(index.min(group.members.len() - 1))
                .cloned(),
            _ => group.members.first().cloned(),
        };
    }
    group.mru.retain(|id| id != member);
    group.pinned.retain(|id| id != member);
    if group.preview.as_deref() == Some(member) {
        group.preview = None;
    }
    normalize(group);
}

fn set_pinned(group: &mut Group, member: &str, pinned: bool) {
    dedupe(&mut group.members);
    if group.members.iter().any(|id| id == member) {
        if pinned {
            group.pinned.push(member.to_string());
            if group.preview.as_deref() == Some(member) {
                group.preview = None;
            }
        } else {
            group.pinned.retain(|id| id != member);
        }
    }
    normalize(group);
}

/// Removes empty groups among `affected` according to `policy`; returns their ids.
fn prune_empty(state: &mut State, policy: EmptyGroups, affected: &[String]) -> Vec<String> {
    if policy == EmptyGroups::Keep {
        return Vec::new();
    }
    let first = state.groups.first().map(|group| group.id.clone());
    let mut doomed: Vec<String> = state
        .groups
        .iter()
        .filter(|group| group.members.is_empty() && affected.contains(&group.id))
        .map(|group| group.id.clone())
        .collect();
    if policy == EmptyGroups::RemoveKeepingFirst && doomed.len() == state.groups.len() {
        doomed.retain(|id| Some(id) != first.as_ref());
    }
    state.groups.retain(|group| !doomed.contains(&group.id));
    doomed
}
