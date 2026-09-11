use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;

#[test]
fn mybatis_index_links_mapper_methods_to_xml_statements() {
    let root = temporary_root("mybatis-index");
    let java = root.join("src/main/java/com/example/mapper");
    let resources = root.join("src/main/resources/mapper");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::create_dir_all(&resources).expect("XML fixture directory should be creatable");
    fs::write(
        java.join("UserMapper.java"),
        r#"package com.example.mapper;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface UserMapper {
    User selectById(@Param("id") Long id);

    int insert(User user);

    @Select("SELECT * FROM users WHERE name = #{name}")
    User selectByName(String name);

    default User findOrEmpty(Long id) {
        User user = selectById(id);
        return user == null ? new User() : user;
    }

    void updateById(
        @Param("id") Long id,
        @Param("name") String name
    );
}
"#,
    )
    .expect("mapper interface fixture should be writable");
    fs::write(
        resources.join("UserMapper.xml"),
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN" "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.example.mapper.UserMapper">
    <!-- <select id="commentedSelect">SELECT 1</select> -->
    <select id="selectById" resultType="com.example.User">
        SELECT * FROM users WHERE id = #{id}
    </select>
    <insert
        id="insert"
        useGeneratedKeys="true">
        INSERT INTO users(name) VALUES(#{name})
    </insert>
    <update id="updateById">
        UPDATE users SET name = #{name} WHERE id = #{id}
    </update>
</mapper>
"#,
    )
    .expect("mapper XML fixture should be writable");

    let response = execute_mybatis(
        &root,
        &[
            "src/main/java/com/example/mapper/UserMapper.java",
            "src/main/resources/mapper/UserMapper.xml",
        ],
        serde_json::json!({}),
    );

    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"]
        .as_array()
        .expect("statements should be an array");
    let ids = statements
        .iter()
        .map(|value| value["statementId"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(ids, vec!["insert", "selectById", "updateById"]);
    assert!(
        statements
            .iter()
            .all(|value| value["namespace"] == "com.example.mapper.UserMapper"),
        "{statements:?}"
    );
    let select = statements
        .iter()
        .find(|value| value["statementId"] == "selectById")
        .expect("selectById should be indexed");
    assert_eq!(select["kind"], "select");
    assert_eq!(
        select["javaPath"],
        "src/main/java/com/example/mapper/UserMapper.java"
    );
    assert_eq!(select["javaLine"], 9);
    assert_eq!(select["javaColumn"], 10);
    assert_eq!(select["javaEndColumn"], 20);
    assert_eq!(select["javaEndLine"], 9);
    assert_eq!(
        select["xmlPath"],
        "src/main/resources/mapper/UserMapper.xml"
    );
    assert_eq!(select["xmlLine"], 5);
    assert_eq!(select["xmlColumn"], 17);
    assert_eq!(select["xmlEndColumn"], 27);
    let insert = statements
        .iter()
        .find(|value| value["statementId"] == "insert")
        .expect("insert should be indexed");
    assert_eq!(insert["xmlLine"], 9);
    let update = statements
        .iter()
        .find(|value| value["statementId"] == "updateById")
        .expect("updateById should be indexed");
    assert_eq!(update["javaLine"], 21);
    assert_eq!(update["javaEndColumn"], 20);
    assert_eq!(update["javaEndLine"], 24);

    fs::remove_dir_all(root).expect("MyBatis fixture should be removable");
}

/// Unsaved XML edits must win over disk so a mapper id rename can navigate
/// before the buffer is written.
#[test]
fn mybatis_index_uses_text_overrides_before_disk() {
    let root = temporary_root("mybatis-overrides");
    let java = root.join("src/main/java");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::write(
        java.join("OrderMapper.java"),
        "package demo;\npublic interface OrderMapper {\n    Order find();\n}\n",
    )
    .expect("mapper interface fixture should be writable");
    fs::write(
        root.join("OrderMapper.xml"),
        r#"<mapper namespace="demo.OrderMapper"><select id="stale">SELECT 1</select></mapper>"#,
    )
    .expect("stale XML fixture should be writable");

    let response = execute_mybatis(
        &root,
        &["src/main/java/OrderMapper.java", "OrderMapper.xml"],
        serde_json::json!({
            "textOverrides": {
                "OrderMapper.xml": "<mapper namespace=\"demo.OrderMapper\"><select id=\"find\">SELECT 1</select></mapper>"
            }
        }),
    );

    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"]
        .as_array()
        .expect("statements should be an array");
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert_eq!(statements[0]["statementId"], "find");

    fs::remove_dir_all(root).expect("MyBatis fixture should be removable");
}

#[test]
fn mybatis_index_pairs_nested_generic_and_split_signatures() {
    let root = temporary_root("mybatis-nested-generic");
    fs::create_dir_all(&root).expect("MyBatis fixture directory should be creatable");
    fs::write(
        root.join("UserMapper.java"),
        r#"package demo;
public interface UserMapper {
    List<Map<String, Object>> find();

    List<Map<String, Object>>
    splitFind();
}
"#,
    )
    .expect("mapper interface fixture should be writable");
    fs::write(
        root.join("UserMapper.xml"),
        r#"<mapper namespace="demo.UserMapper">
    <select id="find">SELECT 1</select>
    <select id="splitFind">SELECT 2</select>
</mapper>
"#,
    )
    .expect("mapper XML fixture should be writable");

    let response = execute_mybatis(
        &root,
        &["UserMapper.java", "UserMapper.xml"],
        serde_json::json!({}),
    );
    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"]
        .as_array()
        .expect("statements should be an array");
    let find = statements
        .iter()
        .find(|value| value["statementId"] == "find")
        .expect("nested generic find should be indexed");
    assert_eq!(find["javaLine"], 3);
    assert_eq!(find["javaColumn"], 31);
    assert_eq!(find["javaEndColumn"], 35);
    let split = statements
        .iter()
        .find(|value| value["statementId"] == "splitFind")
        .expect("split signature should be indexed");
    assert_eq!(split["javaLine"], 6);
    assert_eq!(split["javaColumn"], 5);
    assert_eq!(split["javaEndColumn"], 14);

    fs::remove_dir_all(root).expect("MyBatis fixture should be removable");
}

/// Commented-out signatures must not steal the real method location, including
/// when the comment contains braces that a line scanner would treat as scope.
#[test]
fn mybatis_index_ignores_methods_inside_comments() {
    let root = temporary_root("mybatis-commented-method");
    fs::create_dir_all(&root).expect("MyBatis fixture directory should be creatable");
    fs::write(
        root.join("UserMapper.java"),
        [
            "package demo;\npublic interface UserMapper {\n    ",
            "/",
            "*\n    User find();\n    *",
            "/\n    User find();\n\n    // {\n    User listed();\n}\n",
        ]
        .concat(),
    )
    .expect("mapper interface fixture should be writable");
    fs::write(
        root.join("UserMapper.xml"),
        r#"<mapper namespace="demo.UserMapper">
    <select id="find">SELECT 1</select>
    <select id="listed">SELECT 2</select>
</mapper>
"#,
    )
    .expect("mapper XML fixture should be writable");

    let response = execute_mybatis(
        &root,
        &["UserMapper.java", "UserMapper.xml"],
        serde_json::json!({}),
    );
    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"]
        .as_array()
        .expect("statements should be an array");
    let find = statements
        .iter()
        .find(|value| value["statementId"] == "find")
        .expect("real find should be indexed");
    assert_eq!(find["javaLine"], 6);
    let listed = statements
        .iter()
        .find(|value| value["statementId"] == "listed")
        .expect("method after a brace comment should be indexed");
    assert_eq!(listed["javaLine"], 9);

    fs::remove_dir_all(root).expect("MyBatis fixture should be removable");
}

#[test]
fn mybatis_index_skips_unrelated_and_oversized_files_before_reading() {
    let _ = crate::languages::take_mybatis_disk_reads();
    let root = temporary_root("mybatis-skip-reads");
    fs::create_dir_all(&root).expect("MyBatis fixture directory should be creatable");
    fs::write(
        root.join("UserMapper.java"),
        "package demo;\npublic interface UserMapper {\n    User find();\n}\n",
    )
    .expect("mapper interface fixture should be writable");
    fs::write(
        root.join("UserMapper.xml"),
        r#"<mapper namespace="demo.UserMapper"><select id="find">SELECT 1</select></mapper>"#,
    )
    .expect("mapper XML fixture should be writable");
    fs::write(root.join("dump.sql"), "SELECT 1;\n".repeat(8 * 1024))
        .expect("unrelated SQL dump should be writable");
    fs::write(root.join("pom.xml"), "<project></project>").expect("pom should be writable");
    let oversized = vec![b'a'; 2 * 1024 * 1024 + 1];
    fs::write(root.join("Huge.java"), oversized).expect("oversized Java file should be writable");

    let response = execute_mybatis(
        &root,
        &[
            "dump.sql",
            "pom.xml",
            "Huge.java",
            "UserMapper.java",
            "UserMapper.xml",
        ],
        serde_json::json!({}),
    );
    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"]
        .as_array()
        .expect("statements should be an array");
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert_eq!(statements[0]["statementId"], "find");

    let mut reads = crate::languages::take_mybatis_disk_reads();
    reads.sort();
    assert_eq!(
        reads,
        vec!["UserMapper.java".to_string(), "UserMapper.xml".to_string()],
        "{reads:?}"
    );

    fs::remove_dir_all(root).expect("MyBatis fixture should be removable");
}

#[test]
fn mybatis_index_rejects_a_relative_root() {
    let response = execute_json(
        r#"{"id":"mybatis","command":"mybatis.index","payload":{"root":"relative","paths":[]}}"#,
    );
    let parsed: Value = serde_json::from_str(&response).expect("response should be JSON");
    assert_eq!(parsed["ok"], false, "{parsed}");
    assert_eq!(parsed["error"]["code"], "invalid_request");
}

#[test]
fn mybatis_index_handles_deep_expressions_in_unrelated_java() {
    // A small Java file can produce thousands of left-associative AST nodes,
    // even when the mapper itself is shallow and the source is below 2 MiB.
    let deep_java = format!(
        "package demo; class Calculation {{ int value() {{ return 1{}; }} }}",
        " + 1".repeat(8192)
    );
    let response = execute_mybatis(
        &std::env::temp_dir(),
        &["Calculation.java", "UserMapper.java", "UserMapper.xml"],
        serde_json::json!({
            "textOverrides": {
                "Calculation.java": deep_java,
                "UserMapper.java": "package demo;\npublic interface UserMapper {\n    User find();\n}\n",
                "UserMapper.xml": "<mapper namespace=\"demo.UserMapper\"><select id=\"find\">SELECT 1</select></mapper>"
            }
        }),
    );

    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"].as_array().unwrap();
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert_eq!(statements[0]["namespace"], "demo.UserMapper");
    assert_eq!(statements[0]["statementId"], "find");
    assert_eq!(statements[0]["javaPath"], "UserMapper.java");
    assert_eq!(statements[0]["javaLine"], 3);
    assert_eq!(statements[0]["javaColumn"], 10);
    assert_eq!(statements[0]["javaEndColumn"], 14);
}

#[test]
fn mybatis_index_finds_mapper_below_deeply_nested_blocks() {
    // The mapped declaration is below the deep subtree, so truncating traversal
    // or skipping the Java file would lose a statement and fail this regression.
    let deep_java = format!(
        "package demo;\nclass Container {{ void declarations() {{ {}\nabstract class DeepMapper {{\n    abstract java.util.List<String> find();\n}}\n{} }} }}",
        "{".repeat(4096),
        "}".repeat(4096)
    );
    let response = execute_mybatis(
        &std::env::temp_dir(),
        &["Container.java", "DeepMapper.xml"],
        serde_json::json!({
            "textOverrides": {
                "Container.java": deep_java,
                "DeepMapper.xml": "<mapper namespace=\"demo.Container.DeepMapper\"><select id=\"find\">SELECT 1</select></mapper>"
            }
        }),
    );

    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"].as_array().unwrap();
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert_eq!(statements[0]["namespace"], "demo.Container.DeepMapper");
    assert_eq!(statements[0]["statementId"], "find");
    assert_eq!(statements[0]["javaPath"], "Container.java");
    assert_eq!(statements[0]["javaLine"], 4);
    assert_eq!(statements[0]["javaColumn"], 37);
    assert_eq!(statements[0]["javaEndColumn"], 41);
    assert_eq!(statements[0]["javaEndLine"], 4);
}

#[test]
fn mybatis_index_preserves_source_order_for_nested_types_with_same_name() {
    // Local classes in separate method scopes share the index's qualified name.
    // Pairing must keep choosing the first declaration in source order.
    let response = execute_mybatis(
        &std::env::temp_dir(),
        &["Container.java", "Mapper.xml"],
        serde_json::json!({
            "textOverrides": {
                "Container.java": "package demo;\nclass Container {\n    void first() {\n        abstract class Mapper<T> {\n            abstract java.util.List<T> find();\n        }\n    }\n    void second() {\n        abstract class Mapper<T> {\n            abstract java.util.List<T> find();\n        }\n    }\n}\n",
                "Mapper.xml": "<mapper namespace=\"demo.Container.Mapper\"><select id=\"find\">SELECT 1</select></mapper>"
            }
        }),
    );

    assert_eq!(response["ok"], true, "{response}");
    let statements = response["data"]["statements"].as_array().unwrap();
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert_eq!(statements[0]["namespace"], "demo.Container.Mapper");
    assert_eq!(statements[0]["statementId"], "find");
    assert_eq!(statements[0]["javaPath"], "Container.java");
    assert_eq!(statements[0]["javaLine"], 5);
    assert_eq!(statements[0]["javaColumn"], 40);
    assert_eq!(statements[0]["javaEndColumn"], 44);
    assert_eq!(statements[0]["javaEndLine"], 5);
}

fn execute_mybatis(root: &std::path::Path, paths: &[&str], extra: Value) -> Value {
    let mut payload = serde_json::json!({"root": root, "paths": paths});
    payload
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().cloned().unwrap_or_default());
    let request = serde_json::json!({
        "id": "mybatis",
        "command": "mybatis.index",
        "payload": payload
    });
    serde_json::from_str(&execute_json(&request.to_string()))
        .expect("MyBatis response should be JSON")
}
