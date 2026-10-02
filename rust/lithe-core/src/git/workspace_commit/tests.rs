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

fn amend_input(target: Option<(&str, &str)>) -> (PrepareRequest, BTreeMap<String, GitCommitState>) {
    let (mut request, mut states) = input();
    request.amend = true;
    request.push = false;
    request.amend_target = target.map(|(id, head)| AmendTarget {
        repository_id: id.into(),
        expected_head: head.into(),
    });
    // Only A/B has staged changes; "independent" is clean until a test stages it.
    states.insert("independent".into(), state(&[], &[]));
    (request, states)
}

#[test]
fn amend_rejects_a_second_repository_with_staged_changes() {
    // Regression: the UI showed only A staged, then B was staged outside the UI.
    // Core reads every repository, so both would have been amended with A's message.
    let (request, mut states) = amend_input(Some(("A/B", "initial")));
    states.insert("independent".into(), state(&["file"], &[]));
    let error = build_plan(request, states).unwrap_err();
    assert!(
        error.message.contains("one repository at a time"),
        "{error:?}"
    );
}

#[test]
fn amend_without_a_target_still_rejects_several_staged_repositories() {
    // Clients that omit amendTarget keep a safe floor: never amend two repositories.
    let (request, mut states) = amend_input(None);
    states.insert("independent".into(), state(&["file"], &[]));
    assert!(build_plan(request, states).is_err());
}

#[test]
fn amend_accepts_one_staged_repository_with_or_without_a_target() {
    for target in [None, Some(("A/B", "initial"))] {
        let (request, states) = amend_input(target);
        let prepared = build_plan(request, states).unwrap();
        assert!(prepared.session.plan.amend);
    }
}

#[test]
fn amend_rejects_a_target_other_than_the_staged_repository() {
    let (request, states) = amend_input(Some(("independent", "initial")));
    let error = build_plan(request, states).unwrap_err();
    assert!(
        error.message.contains("one repository at a time"),
        "{error:?}"
    );
}

#[test]
fn amend_rejects_a_head_that_moved_after_the_message_was_loaded() {
    let (request, states) = amend_input(Some(("A/B", "an-older-head")));
    let error = build_plan(request, states).unwrap_err();
    assert!(
        error
            .message
            .contains("changed after its message was loaded"),
        "{error:?}"
    );
}

#[test]
fn amend_rejects_an_unknown_target_repository() {
    let (request, states) = amend_input(Some(("missing", "initial")));
    assert!(build_plan(request, states).is_err());
}

#[test]
fn a_regular_commit_may_span_several_staged_repositories() {
    let (mut request, mut states) = amend_input(None);
    request.amend = false;
    states.insert("independent".into(), state(&["file"], &[]));
    assert!(build_plan(request, states).is_ok());
}

#[test]
fn a_continuation_that_amends_several_staged_repositories_is_invalid() {
    // A forged or stale continuation must not reach step with several amend targets.
    let (request, mut states) = amend_input(None);
    let mut session = build_plan(request, states.clone()).unwrap().session;
    // A client that drops unknown fields returns the plan without its amend repository.
    session.plan.amend_repository_id = None;
    states.insert("independent".into(), state(&["file"], &[]));
    session.plan.states = states.clone();
    session.states = states;
    session.plan.ordered_ids = vec!["independent".into(), "A/B".into()];
    session.results.entry("independent".into()).or_default();
    assert!(validate_session(&session).is_err());
}

#[test]
fn amend_records_the_repository_it_rewrites() {
    for target in [None, Some(("A/B", "initial"))] {
        let (request, states) = amend_input(target);
        let plan = build_plan(request, states).unwrap().session.plan;
        assert_eq!(plan.amend_repository_id.as_deref(), Some("A/B"));
    }
    // A regular commit records nothing, so existing plan payloads stay unchanged.
    let (mut request, states) = amend_input(None);
    request.amend = false;
    let plan = build_plan(request, states).unwrap().session.plan;
    assert_eq!(plan.amend_repository_id, None);
    assert!(!serde_json::to_string(&plan)
        .unwrap()
        .contains("amendRepositoryId"));
}

/// A child amend that succeeded while its parent's commit failed: the parent now holds
/// the staged submodule pointer and the child is committed.
fn parent_failed_after_child_amend() -> Session {
    let (request, states) = amend_input(Some(("A/B", "initial")));
    let mut session = build_plan(request, states).unwrap().session;
    assert_eq!(session.plan.ordered_ids, ["A/B", "A"]);
    session.results.get_mut("A/B").unwrap().committed = true;
    session
}

fn retry_states() -> BTreeMap<String, GitCommitState> {
    let mut states = BTreeMap::new();
    states.insert("A".into(), state(&["B"], &["B"]));
    states.insert("A/B".into(), state(&[], &[]));
    states.insert("independent".into(), state(&[], &[]));
    states
}

#[test]
fn a_retry_keeps_the_amend_repository_and_commits_the_parent_normally() {
    // Regression: re-deriving the amend target from the retry-time index selected the
    // parent, because its staged submodule pointer made it the only staged repository.
    let session = parent_failed_after_child_amend();
    let (mut request, _) = amend_input(None);
    request.previous = Some(session);
    let states = retry_states();
    let plan = build_plan(request, states.clone()).unwrap().session.plan;
    assert_eq!(plan.amend_repository_id.as_deref(), Some("A/B"));
    assert!(plan.ordered_ids.contains(&"A".to_string()));
    assert!(!amends_repository(&plan, "A", &states["A"]));
}

#[test]
fn a_retry_may_not_switch_the_amend_repository() {
    let session = parent_failed_after_child_amend();
    let (mut request, _) = amend_input(Some(("A", "initial")));
    request.previous = Some(session);
    let error = build_plan(request, retry_states()).unwrap_err();
    assert!(
        error.message.contains("changed since the first attempt"),
        "{error:?}"
    );
}

#[test]
fn only_the_recorded_repository_with_staged_paths_is_amended() {
    let (request, states) = amend_input(Some(("A/B", "initial")));
    let plan = build_plan(request, states.clone()).unwrap().session.plan;
    assert!(amends_repository(&plan, "A/B", &states["A/B"]));
    assert!(!amends_repository(&plan, "A", &state(&["B"], &[])));
    assert!(!amends_repository(&plan, "A/B", &state(&[], &[])));

    // Plans from clients that drop unknown fields keep the staged-paths rule.
    let mut unrecorded = plan;
    unrecorded.amend_repository_id = None;
    assert!(amends_repository(&unrecorded, "A", &state(&["B"], &[])));
}

#[test]
fn a_continuation_must_name_a_known_amend_repository() {
    let (request, states) = amend_input(Some(("A/B", "initial")));
    let mut session = build_plan(request, states).unwrap().session;
    session.plan.amend_repository_id = Some("missing".into());
    assert!(validate_session(&session).is_err());

    let (request, states) = amend_input(Some(("A/B", "initial")));
    let mut session = build_plan(request, states).unwrap().session;
    session.plan.amend = false;
    assert!(validate_session(&session).is_err());
}
