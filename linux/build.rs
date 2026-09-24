//! 构建脚本：把 `assets/file-icons/map.json` 编译为静态查找表与 SVG 内嵌字节。
//!
//! 生成物 `$OUT_DIR/file_icons_generated.rs` 提供默认定义 id、各查找表的
//! `match` 查询函数，以及 `svg_bytes_for_def`（`include_bytes!` 内嵌 SVG）。
//! 运行期不再解析 JSON；`map.json` 缺失或形状不符时生成空实现（查询一律
//! 返回 `None`），保证缺资产仍可编译。

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=assets/file-icons/map.json");
    println!("cargo:rerun-if-changed=assets/file-icons/icons");
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let out_path = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR 未设置"))
        .join("file_icons_generated.rs");
    let code = match std::fs::read_to_string(manifest_dir.join("assets/file-icons/map.json")) {
        Ok(json) => generate(&json),
        Err(_) => generate(""),
    };
    std::fs::write(&out_path, code).expect("写入 file_icons_generated.rs 失败");
}

/// 顶层值：字符串或扁平字符串表（`map.json` 的实际形状）。
enum TopValue {
    Str(String),
    Map(Vec<(String, String)>),
}

/// 跳过 JSON 空白。
fn skip_ws(b: &[u8], pos: &mut usize) {
    while *pos < b.len() && matches!(b[*pos], b' ' | b'\t' | b'\n' | b'\r') {
        *pos += 1;
    }
}

/// 解析 `"..."` 字符串，处理常见转义（含 `\uXXXX`）。
fn parse_string(b: &[u8], pos: &mut usize) -> Option<String> {
    if b.get(*pos) != Some(&b'"') {
        return None;
    }
    *pos += 1;
    let mut out = String::new();
    while let Some(&c) = b.get(*pos) {
        *pos += 1;
        match c {
            b'"' => return Some(out),
            b'\\' => {
                let e = *b.get(*pos)?;
                *pos += 1;
                match e {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000C}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let hex = std::str::from_utf8(b.get(*pos..*pos + 4)?).ok()?;
                        let cp = u32::from_str_radix(hex, 16).ok()?;
                        *pos += 4;
                        out.push(char::from_u32(cp)?);
                    }
                    _ => return None,
                }
            }
            _ => {
                // 按 UTF-8 边界收一个字符（键与路径多为 ASCII，该分支只做兜底）。
                let s = std::str::from_utf8(&b[*pos - 1..]).ok()?;
                let ch = s.chars().next()?;
                *pos += ch.len_utf8() - 1;
                out.push(ch);
            }
        }
    }
    None
}

/// 跳过任意 JSON 值（对象/数组/字符串/字面量），单个坏条目不污染整表。
fn skip_value(b: &[u8], pos: &mut usize) -> Option<()> {
    skip_ws(b, pos);
    match *b.get(*pos)? {
        b'"' => {
            parse_string(b, pos)?;
        }
        b'{' | b'[' => {
            let mut stack = vec![b[*pos]];
            *pos += 1;
            while let Some(&top) = stack.last() {
                let c = *b.get(*pos)?;
                if c == b'"' {
                    parse_string(b, pos)?;
                    continue;
                }
                *pos += 1;
                match c {
                    b'{' | b'[' => stack.push(c),
                    b'}' if top == b'{' => {
                        stack.pop();
                    }
                    b']' if top == b'[' => {
                        stack.pop();
                    }
                    _ => {}
                }
            }
        }
        _ => {
            while let Some(&c) = b.get(*pos) {
                if matches!(c, b',' | b'}' | b']') || c.is_ascii_whitespace() {
                    break;
                }
                *pos += 1;
            }
        }
    }
    Some(())
}

/// 解析 `{ "k": "v", ... }` 扁平字符串表；非字符串值跳过该条目。
fn parse_string_map(b: &[u8], pos: &mut usize) -> Option<Vec<(String, String)>> {
    if b.get(*pos) != Some(&b'{') {
        return None;
    }
    *pos += 1;
    let mut pairs = Vec::new();
    loop {
        skip_ws(b, pos);
        if b.get(*pos) == Some(&b'}') {
            *pos += 1;
            return Some(pairs);
        }
        let key = parse_string(b, pos)?;
        skip_ws(b, pos);
        if b.get(*pos) != Some(&b':') {
            return None;
        }
        *pos += 1;
        skip_ws(b, pos);
        if let Some(value) = parse_string(b, pos) {
            pairs.push((key, value));
        } else {
            skip_value(b, pos)?;
        }
        skip_ws(b, pos);
        match b.get(*pos) {
            Some(b',') => *pos += 1,
            Some(b'}') => continue,
            _ => return None,
        }
    }
}

/// 解析顶层对象，只保留字符串与扁平字符串表，其余跳过；形状不符时返回已收部分。
fn parse_top(json: &str) -> Vec<(String, TopValue)> {
    let b = json.as_bytes();
    let mut pos = 0;
    let mut out = Vec::new();
    skip_ws(b, &mut pos);
    if b.get(pos) != Some(&b'{') {
        return out;
    }
    pos += 1;
    loop {
        skip_ws(b, &mut pos);
        if b.get(pos) == Some(&b'}') {
            return out;
        }
        let key = match parse_string(b, &mut pos) {
            Some(k) => k,
            None => return out,
        };
        skip_ws(b, &mut pos);
        if b.get(pos) != Some(&b':') {
            return out;
        }
        pos += 1;
        skip_ws(b, &mut pos);
        if b.get(pos) == Some(&b'{') {
            match parse_string_map(b, &mut pos) {
                Some(map) => out.push((key, TopValue::Map(map))),
                None => return out,
            }
        } else if let Some(s) = parse_string(b, &mut pos) {
            out.push((key, TopValue::Str(s)));
        } else if skip_value(b, &mut pos).is_none() {
            return out;
        }
        skip_ws(b, &mut pos);
        match b.get(pos) {
            Some(b',') => pos += 1,
            Some(b'}') => continue,
            _ => return out,
        }
    }
}

/// 去重：后出现的覆盖先出现（与 Windows `normalizeLookupMap` 一致），保留首次出现顺序。
fn dedupe(pairs: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for (k, v) in pairs {
        if let Some(slot) = out.iter_mut().find(|(ek, _)| *ek == k) {
            slot.1 = v;
        } else {
            out.push((k, v));
        }
    }
    out
}

/// 生成 `fn name(key: &str) -> Option<&'static str>` 形式的 `match` 查找函数。
fn emit_lookup_fn(name: &str, pairs: &[(String, String)]) -> String {
    let mut s = format!("fn {name}(key: &str) -> Option<&'static str> {{\n    match key {{\n");
    for (k, v) in pairs {
        s.push_str(&format!("        {k:?} => Some({v:?}),\n"));
    }
    s.push_str("        _ => None,\n    }\n}\n");
    s
}

/// 生成 `svg_bytes_for_def`：深色取深色 definition，浅色取浅色 definition。
/// 浅色缺专属路径时的回退由调用方处理，此处只生成精确分支。
fn emit_svg_fn(dark: &[(String, String)], light: &[(String, String)]) -> String {
    let mut s = String::from(
        "fn svg_bytes_for_def(def: &str, is_dark: bool) -> Option<&'static [u8]> {\n    match (def, is_dark) {\n",
    );
    for (id, path) in dark {
        s.push_str(&format!(
            "        ({id:?}, true) => Some(include_bytes!(concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/assets/file-icons/\", {path:?})) as &'static [u8]),\n"
        ));
    }
    for (id, path) in light {
        s.push_str(&format!(
            "        ({id:?}, false) => Some(include_bytes!(concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/assets/file-icons/\", {path:?})) as &'static [u8]),\n"
        ));
    }
    s.push_str("        _ => None,\n    }\n}\n");
    s
}

/// 生成 `$OUT_DIR/file_icons_generated.rs` 全文；输入为空或形状不符时退化为空实现。
fn generate(json: &str) -> String {
    let top = parse_top(json);
    let str_field = |key: &str| -> &str {
        top.iter()
            .find_map(|(k, v)| match v {
                TopValue::Str(s) if k == key => Some(s.as_str()),
                _ => None,
            })
            .unwrap_or("")
    };
    let raw_table = |key: &str| -> Vec<(String, String)> {
        top.iter()
            .find_map(|(k, v)| match v {
                TopValue::Map(m) if k == key => Some(m.clone()),
                _ => None,
            })
            .unwrap_or_default()
    };
    // 键统一转小写（对齐 Windows `normalizeLookupMap`），扩展名保证前导 `.`。
    let lower = |pairs: Vec<(String, String)>| {
        dedupe(
            pairs
                .into_iter()
                .map(|(k, v)| (k.to_lowercase(), v))
                .collect(),
        )
    };
    let filenames = lower(raw_table("filenames"));
    let file_extensions = dedupe(
        raw_table("fileExtensions")
            .into_iter()
            .map(|(k, v)| {
                let k = k.to_lowercase();
                let k = if k.starts_with('.') {
                    k
                } else {
                    format!(".{k}")
                };
                (k, v)
            })
            .collect(),
    );
    let folders = lower(raw_table("folders"));
    let expanded_folders = lower(raw_table("expandedFolders"));
    // definition 路径去掉 `./` 后拼到 `linux/assets/file-icons/` 即真实文件。
    let strip_dot = |pairs: Vec<(String, String)>| {
        dedupe(
            pairs
                .into_iter()
                .map(|(k, v)| {
                    let v = v.strip_prefix("./").unwrap_or(&v).to_string();
                    (k, v)
                })
                .collect(),
        )
    };
    let dark = strip_dot(raw_table("iconDefinitions"));
    // 浅色表与深色表是同一批 id 的两套路径：每个 id 生成 `(id, true)` 与
    // `(id, false)` 两支（元组第二元不同，不冲突）；深色独有的 id 浅色分支由调用方回退深色。
    let light = strip_dot(raw_table("lightIconDefinitions"));

    let mut s =
        String::from("// 由 linux/build.rs 按 assets/file-icons/map.json 生成，不要手改。\n");
    s.push_str(&format!(
        "fn default_file_def() -> &'static str {{ {:?} }}\n",
        str_field("defaultFile")
    ));
    s.push_str(&format!(
        "fn default_folder_def() -> &'static str {{ {:?} }}\n",
        str_field("defaultFolder")
    ));
    s.push_str(&format!(
        "fn default_folder_open_def() -> &'static str {{ {:?} }}\n",
        str_field("defaultFolderOpen")
    ));
    s.push_str(&emit_lookup_fn("filename_def", &filenames));
    s.push_str(&emit_lookup_fn("file_extension_def", &file_extensions));
    s.push_str(&emit_lookup_fn("folder_def", &folders));
    s.push_str(&emit_lookup_fn("expanded_folder_def", &expanded_folders));
    s.push_str(&emit_svg_fn(&dark, &light));
    s
}
