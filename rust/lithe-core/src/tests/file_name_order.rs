use super::support::temporary_root;
use crate::execute_json;
use crate::project::file_name_order::compare_file_names;
use serde_json::Value;
use std::cmp::Ordering;
use std::fs;

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/workspace/file-name-order-v1.json"
    ))
    .expect("file-name order fixture should be JSON")
}

#[test]
fn shared_fixture_groups_sort_strictly_in_the_listed_order() {
    let fixture = fixture();
    for group in fixture["orderedGroups"].as_array().unwrap() {
        let names = group["names"]
            .as_array()
            .unwrap()
            .iter()
            .map(|name| name.as_str().unwrap())
            .collect::<Vec<_>>();
        for (index, earlier) in names.iter().enumerate() {
            for later in &names[index + 1..] {
                assert_eq!(
                    compare_file_names(earlier, later),
                    Ordering::Less,
                    "{}: {earlier:?} should precede {later:?}",
                    group["id"]
                );
                assert_eq!(
                    compare_file_names(later, earlier),
                    Ordering::Greater,
                    "{}: {later:?} should follow {earlier:?}",
                    group["id"]
                );
            }
        }
    }
}

// Rust's sort may panic on an inconsistent order, so the port must stay a total
// preorder even for the characters upstream treats specially: spaces, zeroes,
// digits, '#', '-', '_' and mixed-case letters. The generator is a fixed LCG,
// so a failure reproduces exactly.
#[test]
fn comparison_is_antisymmetric_and_transitive_for_special_characters() {
    const ALPHABET: [char; 11] = [' ', '0', '1', '2', 'a', 'A', 'b', '-', '_', '#', '.'];
    let mut state = 0x2545_F491_4F6C_DD1Du64;
    let mut next = |bound: usize| {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((state >> 33) as usize) % bound
    };
    let names = (0..72)
        .map(|_| {
            let length = next(6);
            (0..length)
                .map(|_| ALPHABET[next(ALPHABET.len())])
                .collect::<String>()
        })
        .collect::<Vec<_>>();

    for left in &names {
        for right in &names {
            assert_eq!(
                compare_file_names(left, right),
                compare_file_names(right, left).reverse(),
                "{left:?} against {right:?}"
            );
        }
    }
    for first in &names {
        for second in &names {
            if compare_file_names(first, second) == Ordering::Greater {
                continue;
            }
            for third in &names {
                if compare_file_names(second, third) != Ordering::Greater {
                    assert_ne!(
                        compare_file_names(first, third),
                        Ordering::Greater,
                        "{first:?} <= {second:?} <= {third:?}"
                    );
                }
            }
        }
    }
}

#[test]
fn list_directories_orders_versioned_names_by_number_with_directories_first() {
    let root = temporary_root("natural-directory-order");
    for name in [
        "v0.1.12.md",
        "v0.1.4.md",
        "v0.1.14.md",
        "TEMPLATE.md",
        "v0.1.13.md",
        "v0.2.0.md",
    ] {
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(name), "").unwrap();
    }
    fs::create_dir_all(root.join("zeta/part10")).unwrap();
    fs::create_dir_all(root.join("zeta/part2")).unwrap();
    fs::create_dir_all(root.join("Alpha")).unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "natural-directory-order",
            "command": "workspace.listDirectories",
            "payload": {"root": root, "paths": ["", "zeta"]}
        })
        .to_string(),
    ))
    .expect("core response should be JSON");
    let removed = fs::remove_dir_all(&root);
    assert_eq!(response["ok"], true, "{response}");
    removed.expect("temporary fixture should be removable");

    let names = |index: usize| {
        response["data"]["directories"][index]["children"]
            .as_array()
            .unwrap()
            .iter()
            .map(|child| child["name"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        names(0),
        [
            "Alpha",
            "zeta",
            "TEMPLATE.md",
            "v0.1.4.md",
            "v0.1.12.md",
            "v0.1.13.md",
            "v0.1.14.md",
            "v0.2.0.md",
        ]
    );
    assert_eq!(names(1), ["part2", "part10"]);
}

/// The snapshot `files` sequence is not a display order: Windows Quick Open keeps the
/// first 100 matches of it, so the natural tree order must not leak into it.
#[test]
fn workspace_snapshot_keeps_its_traversal_order_while_the_tree_rows_are_natural() {
    let root = temporary_root("snapshot-traversal-order");
    fs::create_dir_all(&root).unwrap();
    for name in ["v0.1.12.md", "v0.1.4.md", "v0.1.14.md", "TEMPLATE.md"] {
        fs::write(root.join(name), "").unwrap();
    }
    for part in ["part10", "part2"] {
        fs::create_dir_all(root.join("zeta").join(part)).unwrap();
        fs::write(root.join("zeta").join(part).join("a.md"), "").unwrap();
    }

    let files = |include_tree: bool| {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "snapshot-traversal-order",
                "command": "workspace.snapshot",
                "payload": {"root": root, "includeTree": include_tree}
            })
            .to_string(),
        ))
        .expect("core response should be JSON");
        assert_eq!(response["ok"], true, "{response}");
        response["data"]["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|file| file.as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    let with_tree = files(true);
    let without_tree = files(false);
    let removed = fs::remove_dir_all(&root);
    removed.expect("temporary fixture should be removable");

    let expected = [
        "zeta/part10/a.md",
        "zeta/part2/a.md",
        "TEMPLATE.md",
        "v0.1.12.md",
        "v0.1.14.md",
        "v0.1.4.md",
    ];
    assert_eq!(with_tree, expected);
    assert_eq!(without_tree, expected);
}
