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
    assert_eq!(select["javaEndLine"], 9);
    assert_eq!(
        select["xmlPath"],
        "src/main/resources/mapper/UserMapper.xml"
    );
    assert_eq!(select["xmlLine"], 5);
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
fn mybatis_index_rejects_a_relative_root() {
    let response = execute_json(
        r#"{"id":"mybatis","command":"mybatis.index","payload":{"root":"relative","paths":[]}}"#,
    );
    let parsed: Value = serde_json::from_str(&response).expect("response should be JSON");
    assert_eq!(parsed["ok"], false, "{parsed}");
    assert_eq!(parsed["error"]["code"], "invalid_request");
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
