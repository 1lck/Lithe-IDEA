//! Deterministic policy regressions migrated from the native feature model.
use super::*;
use serde_json::json;

fn state(staged: &[&str], links: &[&str]) -> GitCommitState {
    GitCommitState {
        head: Some("initial".into()),
        branch: Some("refs/heads/main".into()),
        index_entries: staged.join("\0"),
        gitlinks: links
            .iter()
            .map(|p| GitCommitGitlink {
                path: (*p).into(),
                revision: "initial".into(),
            })
            .collect(),
        staged_paths: staged.iter().map(|p| (*p).into()).collect(),
        conflicted_paths: vec![],
    }
}

fn input() -> (PrepareRequest, BTreeMap<String, GitCommitState>) {
    let request: PrepareRequest = serde_json::from_value(json!({
        "repositories": [{"id":"A","root":"/workspace/A"}, {"id":"A/B","root":"/workspace/A/B"},
            {"id":"independent","root":"/workspace/independent"}],
        "message":"commit", "push":true, "includeParentReferences":true
    }))
    .unwrap();
    let states = [
        ("A", state(&[], &["B"])),
        ("A/B", state(&["hello.ts"], &[])),
        ("independent", state(&["file"], &[])),
    ]
    .into_iter()
    .map(|(id, s)| (id.into(), s))
    .collect();
    (request, states)
}

#[test]
fn true_gitlinks_order_children_and_include_clean_ancestors() {
    let (mut request, mut states) = input();
    request.repositories.push(RepositoryBinding {
        id: "A/B/C".into(),
        root: "/workspace/A/B/C".into(),
    });
    states.insert("A/B".into(), state(&[], &["C"]));
    states.insert("A/B/C".into(), state(&["hello.ts"], &[]));
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(
        prepared.session.plan.ordered_ids,
        ["independent", "A/B/C", "A/B", "A"]
    );
    assert_eq!(prepared.session.plan.propagated_relations.len(), 2);
    assert!(prepared.requires_confirmation);
}

#[test]
fn independent_nested_paths_do_not_create_dependencies_and_parent_opt_out_is_honored() {
    let (mut request, states) = input();
    request.include_parent_references = false;
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(prepared.session.plan.ordered_ids, ["A/B", "independent"]);
    assert!(prepared.session.plan.dependency_relations.is_empty());
    let (request, mut states) = input();
    states.insert("A".into(), state(&["parent.txt"], &[]));
    assert_eq!(
        build_plan(request, states)
            .unwrap()
            .session
            .plan
            .ordered_ids,
        ["A", "A/B", "independent"]
    );
}

#[test]
fn changed_index_or_new_selection_requires_reconfirmation() {
    let (request, states) = input();
    let original = build_plan(request, states.clone()).unwrap();
    let (mut request, mut states) = input();
    request.reviewed = Some(original.session.plan);
    states.get_mut("independent").unwrap().index_entries = "new selection".into();
    assert!(build_plan(request, states).unwrap().review_changed);
}

fn failed_push() -> (Session, BTreeMap<String, GitCommitState>) {
    let (request, mut states) = input();
    let mut session = build_plan(request, states.clone()).unwrap().session;
    for id in ["A/B", "independent"] {
        let result = session.results.get_mut(id).unwrap();
        result.committed = true;
        result.pushed = id == "independent";
        states.insert(id.into(), state(&[], &[]));
    }
    session.states = states.clone();
    block_parents(&mut session, "A/B");
    assert_eq!(session.blocked, BTreeSet::from(["A".into()]));
    (session, states)
}

#[test]
fn child_push_failure_blocks_only_ancestors_and_retry_does_not_recommit_successes() {
    let (session, states) = failed_push();
    let (mut request, _) = input();
    request.previous = Some(session);
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(prepared.session.plan.ordered_ids, ["A/B", "A"]);
    assert!(prepared.session.results["A/B"].committed);
    assert!(!prepared.session.results["A/B"].pushed);
    assert!(prepared.session.blocked.is_empty());
    assert!(prepared.requires_confirmation);
}

#[test]
fn parent_pointer_selection_adds_a_push_only_child() {
    let (request, mut states) = input();
    states.insert("A".into(), state(&["B"], &["B"]));
    states.insert("A/B".into(), state(&[], &[]));
    states.insert("independent".into(), state(&[], &[]));
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(prepared.session.plan.ordered_ids, ["A/B", "A"]);
    assert!(prepared.session.plan.propagated_relations.is_empty());
    assert!(prepared.session.results["A/B"].committed);
    assert!(!prepared.session.results["A/B"].pushed);
}

#[test]
fn retry_republishes_an_externally_advanced_child_before_its_clean_parent() {
    let (mut session, mut states) = failed_push();
    session.results.get_mut("A/B").unwrap().pushed = true;
    states.get_mut("A/B").unwrap().head = Some("external".into());
    let (mut request, _) = input();
    request.previous = Some(session);
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(prepared.session.plan.ordered_ids, ["A/B", "A"]);
    assert!(prepared.session.plan.pending_push_ids.contains("A/B"));
    assert!(prepared.session.results["A/B"].committed);
}

#[test]
fn missing_unfinished_roots_and_cycles_fail_closed() {
    let (session, mut states) = failed_push();
    let (mut request, _) = input();
    request.previous = Some(session);
    request.repositories.retain(|b| b.id != "A/B");
    states.remove("A/B");
    assert!(build_plan(request, states).is_err());
    let cycle = vec![
        Relation {
            parent: "A".into(),
            child: "B".into(),
            path: "B".into(),
        },
        Relation {
            parent: "B".into(),
            child: "A".into(),
            path: "A".into(),
        },
    ];
    assert!(commit_order(vec!["A".into(), "B".into()], &cycle).is_err());
}

#[test]
fn shared_workflow_fixture_is_the_complete_portable_contract() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/git/workspace-commit-workflow-v1.json"
    ))
    .unwrap();
    let request = serde_json::from_value(fixture["request"].clone()).unwrap();
    let states = serde_json::from_value(fixture["states"].clone()).unwrap();
    let prepared = build_plan(request, states).unwrap();
    assert_eq!(
        serde_json::to_value(prepared).unwrap(),
        fixture["preparation"]
    );
}

#[test]
fn changelist_scope_rejects_staged_files_and_automatic_parent_updates() {
    let (mut request, states) = input();
    request.path_scope = Some(
        serde_json::from_value(json!({"include":false,"paths":{"independent":["file"]}})).unwrap(),
    );
    assert!(build_plan(request, states)
        .unwrap_err()
        .message
        .contains("outside the active changelist"));
    let (mut request, states) = input();
    request.path_scope =
        Some(serde_json::from_value(json!({"include":false,"paths":{"A":["B"]}})).unwrap());
    assert!(build_plan(request, states)
        .unwrap_err()
        .message
        .contains("parent reference"));
    let (mut request, states) = input();
    request.include_parent_references = false;
    request.path_scope = Some(
        serde_json::from_value(
            json!({"include":true,"paths":{"A/B":["hello.ts"],"independent":["file"]}}),
        )
        .unwrap(),
    );
    let plan = build_plan(request, states).unwrap().session.plan;
    assert_eq!(plan.ordered_ids, ["A/B", "independent"]);
    assert!(plan.path_scope.unwrap().include);
}

#[test]
fn changelist_scope_survives_retry_and_rejects_scope_changes_or_new_staged_files() {
    let (mut request, states) = input();
    request.path_scope = Some(
        serde_json::from_value(json!({"include":false,"paths":{"A":["local.yaml"]}})).unwrap(),
    );
    let previous = build_plan(request, states.clone()).unwrap().session;
    let (mut request, _) = input();
    request.previous = Some(previous.clone());
    let retried = build_plan(request, states.clone()).unwrap().session;
    assert_eq!(retried.plan.path_scope, previous.plan.path_scope);
    let (mut request, _) = input();
    request.previous = Some(previous.clone());
    request.path_scope = Some(PathScope {
        include: false,
        paths: BTreeMap::new(),
    });
    assert!(build_plan(request, states.clone())
        .unwrap_err()
        .message
        .contains("changing its commit scope"));
    let (mut request, mut states) = input();
    request.previous = Some(previous);
    states
        .get_mut("A")
        .unwrap()
        .staged_paths
        .push("local.yaml".into());
    assert!(build_plan(request, states).is_err());
}

#[test]
fn changelist_scope_is_checked_on_continuations_and_compared_during_review() {
    let (mut request, states) = input();
    request.path_scope = Some(PathScope {
        include: false,
        paths: BTreeMap::new(),
    });
    let original = build_plan(request, states.clone()).unwrap().session;
    let (mut request, _) = input();
    request.reviewed = Some(original.plan.clone());
    request.path_scope = Some(
        serde_json::from_value(json!({"include":false,"paths":{"A":["protected.yaml"]}})).unwrap(),
    );
    assert!(build_plan(request, states).unwrap().review_changed);
    let mut changed = original;
    changed
        .plan
        .path_scope
        .as_mut()
        .unwrap()
        .paths
        .insert("A/B".into(), BTreeSet::from(["hello.ts".into()]));
    assert!(validate_session(&changed).is_err());
}

#[test]
fn local_changelist_scope_fixture_defines_default_and_custom_membership() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/git/local-changelist-scope-v1.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let scope = fixture[case["scope"].as_str().unwrap()].clone();
        let request = serde_json::from_value(json!({
            "repositories":[{"id":"A","root":"/workspace/A"}], "message":"scoped",
            "includeParentReferences":false, "pathScope":scope
        }))
        .unwrap();
        let paths = case["stagedPaths"]
            .as_array()
            .unwrap()
            .iter()
            .map(|path| path.as_str().unwrap())
            .collect::<Vec<_>>();
        let states = BTreeMap::from([("A".into(), state(&paths, &[]))]);
        assert_eq!(
            build_plan(request, states).is_ok(),
            case["allowed"].as_bool().unwrap(),
            "{case}"
        );
    }
}
