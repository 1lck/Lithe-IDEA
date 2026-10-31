//! Deterministic ownership, ordering and physical-geometry regressions.
use super::*;

#[test]
fn cancelled_queued_layout_cannot_start_after_waiting_for_an_owner() {
    let layout = PendingLayout::default();
    assert!(layout.cancel());
    assert!(
        !layout.start(),
        "an expired queued layout must have no native effect"
    );
}

#[test]
fn started_layout_cannot_report_cancellation_before_its_result() {
    let layout = PendingLayout::default();
    assert!(layout.start());
    assert!(
        !layout.cancel(),
        "a started UI turn must deliver its real result"
    );
    assert!(!layout.start(), "a UI turn may start only once");
}

fn owner(id: &str) -> PageOwner {
    let mut owner = PageOwner {
        generation: 1,
        workspace_generation: 0,
        host_label: "main".into(),
        workspace_id: "workspace".into(),
        workspace_path: "fixture".into(),
        plugin_id: "fixture.plugin".into(),
        window_id: "panel".into(),
        state_id: String::new(),
        mount: Some(MountOwner {
            id: id.into(),
            package_identity: "whole-package".into(),
            registration: 1,
            directory: Arc::new(Handle::from_path(env!("CARGO_MANIFEST_DIR")).unwrap()),
            sequence: 1,
            revision: 0,
        }),
    };
    owner.state_id = state_label(&owner);
    owner
}

#[test]
fn dock_bounds_reject_nonfinite_negative_and_offscreen_geometry() {
    let client = tauri::PhysicalSize::new(1000, 700);
    let valid = DockBounds {
        x: 100.0,
        y: 50.0,
        width: 400.0,
        height: 300.0,
    };
    assert!(valid.normalize(client).is_ok());
    for bad in [
        DockBounds {
            x: f64::NAN,
            ..valid
        },
        DockBounds {
            height: f64::INFINITY,
            ..valid
        },
        DockBounds { x: -1.0, ..valid },
        DockBounds {
            width: 0.0,
            ..valid
        },
        DockBounds { x: 1000.0, ..valid },
        DockBounds {
            width: 902.0,
            ..valid
        },
        DockBounds {
            height: 652.0,
            ..valid
        },
    ] {
        assert!(bad.normalize(client).is_err(), "{bad:?}");
    }
}

#[test]
fn fractional_dpi_edge_is_clipped_to_the_client_area() {
    let bounds = DockBounds {
        x: 100.25,
        y: 20.4,
        width: 900.5,
        height: 680.3,
    }
    .normalize(tauri::PhysicalSize::new(1000, 700))
    .unwrap();
    assert_eq!(
        bounds,
        PhysicalBounds {
            x: 100,
            y: 20,
            width: 900,
            height: 680
        }
    );
}

#[test]
fn mount_receipts_separate_native_children_but_preserve_the_saved_slot() {
    let first = owner("request-1");
    let replacement = owner("request-2");
    assert_ne!(owned_label(&first), owned_label(&replacement));
    assert_eq!(state_label(&first), state_label(&replacement));
    assert!(is_docked_label(&owned_label(&first)));
    assert!(!is_docked_label(&state_label(&first)));
    let owners = HashMap::from([(owned_label(&replacement), replacement.clone())]);
    assert!(find_mount(
        &owners,
        "main",
        "workspace",
        "fixture.plugin",
        "panel",
        "request-1"
    )
    .is_err());
    assert!(find_mount(
        &owners,
        "other",
        "workspace",
        "fixture.plugin",
        "panel",
        "request-2"
    )
    .is_err());
    assert!(find_mount(
        &owners,
        "main",
        "other",
        "fixture.plugin",
        "panel",
        "request-2"
    )
    .is_err());
    assert!(find_mount(
        &owners,
        "main",
        "workspace",
        "fixture.plugin",
        "panel",
        "request-2"
    )
    .is_ok());
}

#[test]
fn revocation_retains_only_exact_cleanup_receipts_and_clears_stable_state() {
    let state = WebPageHostState::default();
    let mut first = owner("old-1");
    first.state_id = state_label(&first);
    let replacement = owner("new-2");
    let first_label = owned_label(&first);
    state.states.lock().unwrap().insert(
        state_key(&first.plugin_id, &first.state_id),
        json!({"saved":true}),
    );
    state
        .owners
        .lock()
        .unwrap()
        .insert(first_label.clone(), first);
    state
        .owners
        .lock()
        .unwrap()
        .insert(owned_label(&replacement), replacement.clone());
    assert_eq!(
        revoke_owners(&state, |owner| owned_label(owner) == first_label, false),
        vec![first_label.clone()]
    );
    assert_eq!(state.closing_owners.lock().unwrap().len(), 1);
    assert_eq!(state.states.lock().unwrap().len(), 1);
    assert!(state
        .owners
        .lock()
        .unwrap()
        .contains_key(&owned_label(&replacement)));
    revoke_owners(&state, |_| true, true);
    assert!(state.states.lock().unwrap().is_empty());
}

#[test]
fn request_ids_and_product_hosts_reject_unowned_callers() {
    for invalid in ["", "../token", "token:other", "token\n"] {
        assert!(!valid_request_id(invalid));
    }
    assert!(valid_request_id("request_123-1"));
    assert!(product_host("main").is_ok());
    assert!(product_host("workspace-one").is_ok());
    assert!(product_host("plugin-web-private").is_err());
    let error: Value =
        serde_json::from_str(&cleanup_error("request-native-2", "close failed".into())).unwrap();
    assert_eq!(error["mountId"], "request-native-2");
    assert_eq!(error["code"], "plugin.web.cleanupFailed");
}

#[test]
fn layout_revision_orders_visibility_and_preserves_failed_retry() {
    use std::cell::Cell;
    let mut current = owner("current");
    let effects = Cell::new(0);
    apply_layout_revision(&mut current, "current", 2, || {
        effects.set(1);
        Ok(())
    })
    .unwrap();
    apply_layout_revision(&mut current, "current", 1, || {
        effects.set(99);
        Ok(())
    })
    .unwrap();
    apply_layout_revision(&mut current, "current", 2, || {
        effects.set(99);
        Ok(())
    })
    .unwrap();
    assert_eq!(effects.get(), 1, "late show must not undo a newer hide");
    assert!(apply_layout_revision(&mut current, "old", 3, || {
        effects.set(99);
        Ok(())
    })
    .is_err());
    assert!(apply_layout_revision(&mut current, "current", 3, || Err(
        "controlled native layout failure".into()
    ))
    .is_err());
    assert_eq!(current.mount.as_ref().unwrap().revision, 2);
    apply_layout_revision(&mut current, "current", 3, || {
        effects.set(2);
        Ok(())
    })
    .unwrap();
    assert_eq!(effects.get(), 2);
}

#[test]
fn stale_unmount_cannot_revoke_a_replacement_or_another_workspace() {
    let state = WebPageHostState::default();
    let old = owner("old");
    let replacement = owner("replacement");
    let mut other = owner("other");
    other.workspace_id = "other-workspace".into();
    let old_label = owned_label(&old);
    state
        .owners
        .lock()
        .unwrap()
        .insert(owned_label(&replacement), replacement.clone());
    state
        .owners
        .lock()
        .unwrap()
        .insert(owned_label(&other), other.clone());
    assert!(revoke_owners(&state, |owner| owned_label(owner) == old_label, false).is_empty());
    let owners = state.owners.lock().unwrap();
    assert!(owners.contains_key(&owned_label(&replacement)));
    assert!(owners.contains_key(&owned_label(&other)));
}

#[test]
fn late_creation_cannot_replace_a_newer_mount_even_after_unmount() {
    let state = WebPageHostState::default();
    let old = owner("old");
    let mut newer = owner("newer");
    newer.mount.as_mut().unwrap().sequence = 2;
    reserve_request(&state, &newer).unwrap();
    assert!(reserve_request(&state, &old).is_err());
    assert!(check_request(&state, &old).is_err());
    check_request(&state, &newer).unwrap();
    state
        .owners
        .lock()
        .unwrap()
        .insert(owned_label(&newer), newer.clone());
    revoke_owners(&state, |_| true, false);
    assert!(state.owners.lock().unwrap().is_empty());
    assert!(
        reserve_request(&state, &old).is_err(),
        "unmount must retain the newest request tombstone"
    );
}

#[test]
fn workspace_generation_revokes_pending_mount_requests() {
    let state = WebPageHostState::default();
    let owner = owner("pending");
    reserve_request(&state, &owner).unwrap();
    check_request(&state, &owner).unwrap();
    state.workspace_generations.lock().unwrap().insert(
        workspace_label_suffix(&owner.host_label, &owner.workspace_id),
        1,
    );
    assert!(check_request(&state, &owner).is_err());
}

#[test]
fn mount_slot_budget_allows_replacement_but_bounds_new_slots() {
    let state = WebPageHostState::default();
    let first = owner("first");
    for index in 0..MAX_MOUNT_SLOTS {
        let mut next = first.clone();
        next.window_id = format!("panel-{index}");
        reserve_request(&state, &next).unwrap();
    }
    assert!(reserve_request(&state, &first).is_err());
    let mut replacement = first;
    replacement.window_id = "panel-0".into();
    replacement.mount.as_mut().unwrap().sequence = 2;
    reserve_request(&state, &replacement).unwrap();
    assert_eq!(state.mount_requests.lock().unwrap().len(), MAX_MOUNT_SLOTS);
}

#[test]
fn late_verification_for_closed_workspaces_cannot_exhaust_mount_slots() {
    let state = WebPageHostState::default();
    for index in 0..=MAX_MOUNT_SLOTS {
        let mut pending = owner("late-verification");
        pending.workspace_id = format!("closed-{index}");
        state.workspace_generations.lock().unwrap().insert(
            workspace_label_suffix(&pending.host_label, &pending.workspace_id),
            1,
        );
        assert!(reserve_request(&state, &pending).is_err());
    }
    assert!(state.mount_requests.lock().unwrap().is_empty());
    let old = owner("old-registration");
    reserve_request(&state, &old).unwrap();
    let mut replacement = owner("replacement-registration");
    replacement.mount.as_mut().unwrap().sequence = 2;
    reserve_request(&state, &replacement).unwrap();
    forget_request(&state, &old);
    check_request(&state, &replacement).unwrap();
    forget_request(&state, &replacement);
    assert!(state.mount_requests.lock().unwrap().is_empty());
    reserve_request(&state, &owner("valid-project")).unwrap();
}

#[test]
fn package_identity_detects_same_version_byte_replacement_and_origin_changes() {
    let root = Path::new("fixture-package");
    let original = package_identity_for(root, "installed", "1.0.0", "original-content");
    assert_eq!(
        original,
        package_identity_for(root, "installed", "1.0.0", "original-content")
    );
    assert_ne!(
        original,
        package_identity_for(root, "installed", "1.0.0", "replacement-content")
    );
    assert_ne!(
        original,
        package_identity_for(root, "bundled", "1.0.0", "original-content")
    );
    assert_ne!(
        original,
        package_identity_for(
            Path::new("other-package"),
            "installed",
            "1.0.0",
            "original-content"
        )
    );
}
