//! Deterministic XML field edits selected by an owning provider. This module
//! knows XML syntax and bounded write bindings, never Maven settings semantics.
//! Native file bytes stay inside the host/Core call; provider RPCs carry only
//! non-sensitive fields. Platform storage performs the conditional publication.

use super::configuration::{
    self, ConfigurationSnapshot, NativeEdits, NativeField, NativeFieldKind, XmlRoot,
};
use crate::plugins::declarative::{PluginRejection, Validation};
use quick_xml::events::{BytesEnd, BytesStart, BytesText, Event};
use quick_xml::name::ResolveResult;
use quick_xml::{NsReader, Writer};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const MAX_DOCUMENT_BYTES: usize = 2 * 1024 * 1024;
const MAX_XML_DEPTH: usize = 64;
const MAX_XML_ELEMENTS: usize = 100_000;

/// Internal host operation, never a provider request. Original native bytes may
/// contain credentials and must not be rendered, logged, or sent to a backend.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct EditConfigurationDocumentRequest {
    pub(crate) snapshot: ConfigurationSnapshot,
    pub(crate) edits: NativeEdits,
    /// Absent only while creating a source whose revision is `missing`.
    pub(crate) document: Option<String>,
}

/// Produces replacement bytes only for the exact approved source revision. No
/// filesystem access occurs; hosts must still compare-and-publish these bytes.
pub(crate) fn edit(request: &EditConfigurationDocumentRequest) -> Validation<Value> {
    let (source, changed) = configuration::changed_fields(&request.snapshot, &request.edits)?;
    if request
        .document
        .as_ref()
        .is_some_and(|document| document.len() > MAX_DOCUMENT_BYTES)
    {
        return Err(invalid("The native configuration document is too large."));
    }
    let actual_revision = request
        .document
        .as_ref()
        .map(|document| revision(document))
        .unwrap_or_else(|| "missing".into());
    if actual_revision != source.revision {
        return Err(PluginRejection::new(
            "plugin.build.configurationConflict",
            "The native configuration source changed. Reload before saving.",
        ));
    }
    // A cancelled/unchanged inherited draft cannot create a file or override.
    if changed.is_empty() {
        return Ok(json!({"document":request.document,"revision":actual_revision,"changed":false}));
    }
    let mut document = request
        .document
        .clone()
        .unwrap_or_else(|| empty_document(&source.root_element));
    for field in changed {
        let value = &request.edits.values[&field.id];
        document = edit_field(&document, &source.root_element, field, value)?;
        if document.len() > MAX_DOCUMENT_BYTES {
            return Err(invalid("The edited native document is too large."));
        }
    }
    Ok(json!({"revision":revision(&document),"document":document,"changed":true}))
}

fn invalid(message: &str) -> PluginRejection {
    PluginRejection::new("plugin.build.invalidConfiguration", message)
}

fn revision(document: &str) -> String {
    format!("sha256:{:x}", Sha256::digest(document.as_bytes()))
}

fn empty_document(root: &XmlRoot) -> String {
    let namespace = if root.namespace.is_empty() {
        String::new()
    } else {
        format!(" xmlns=\"{}\"", quick_xml::escape::escape(&root.namespace))
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{}{namespace}></{}>\n",
        root.name, root.name
    )
}

/// Paths include only elements in the root's namespace. A foreign element with
/// the same local name must never become an editable native field.
struct DocumentShape {
    paths: BTreeMap<Vec<String>, usize>,
}

fn namespace(result: ResolveResult<'_>) -> Validation<String> {
    match result {
        ResolveResult::Unbound => Ok(String::new()),
        ResolveResult::Bound(namespace) => std::str::from_utf8(namespace.as_ref())
            .map(String::from)
            .map_err(|_| invalid("The XML namespace is not UTF-8.")),
        ResolveResult::Unknown(_) => Err(invalid(
            "The native XML document uses an undeclared prefix.",
        )),
    }
}

fn local_name(name: &[u8]) -> Validation<String> {
    std::str::from_utf8(name.rsplit(|byte| *byte == b':').next().unwrap_or(name))
        .map(String::from)
        .map_err(|_| invalid("The native XML name is not UTF-8."))
}

fn shape(document: &str, root: &XmlRoot) -> Validation<DocumentShape> {
    let mut reader = NsReader::from_str(document);
    let mut path = Vec::new();
    let mut matching = Vec::new();
    let mut paths = BTreeMap::new();
    let mut elements = 0;
    let mut roots = 0;
    loop {
        let (resolved, event) = reader
            .read_resolved_event()
            .map_err(|_| invalid("The native XML document is invalid."))?;
        let ns = namespace(resolved)?;
        match event {
            Event::Start(ref element) | Event::Empty(ref element) => {
                elements += 1;
                if elements > MAX_XML_ELEMENTS || path.len() >= MAX_XML_DEPTH {
                    return Err(invalid(
                        "The native XML document exceeds its structural limit.",
                    ));
                }
                let name = local_name(element.name().as_ref())?;
                if path.is_empty() {
                    roots += 1;
                    if roots != 1 || name != root.name || ns != root.namespace {
                        return Err(invalid("The native XML root or namespace changed."));
                    }
                }
                let same = ns == root.namespace && matching.last().copied().unwrap_or(true);
                path.push(name);
                matching.push(same);
                if same {
                    *paths.entry(path.clone()).or_insert(0) += 1;
                }
                if matches!(event, Event::Empty(_)) {
                    path.pop();
                    matching.pop();
                }
            }
            Event::End(_) => {
                path.pop();
                matching.pop();
            }
            Event::DocType(_) => {
                return Err(invalid("Native configuration XML must not contain a DTD."))
            }
            Event::Decl(ref declaration) => {
                if let Some(encoding) = declaration.encoding() {
                    let encoding =
                        encoding.map_err(|_| invalid("The native XML encoding is invalid."))?;
                    if !encoding.eq_ignore_ascii_case(b"UTF-8")
                        && !encoding.eq_ignore_ascii_case(b"UTF8")
                    {
                        return Err(invalid(
                            "Native configuration editing currently requires UTF-8 XML.",
                        ));
                    }
                }
            }
            Event::Text(ref text)
                if path.is_empty() && !text.iter().all(u8::is_ascii_whitespace) =>
            {
                return Err(invalid(
                    "The native XML document has text outside its root.",
                ));
            }
            Event::CData(_) if path.is_empty() => {
                return Err(invalid(
                    "The native XML document has text outside its root.",
                ))
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if roots != 1 || !path.is_empty() {
        return Err(invalid("The native XML document has no complete root."));
    }
    Ok(DocumentShape { paths })
}

fn edit_field(
    document: &str,
    root: &XmlRoot,
    field: &NativeField,
    value: &Value,
) -> Validation<String> {
    let shape = shape(document, root)?;
    let mut target = vec![root.name.clone()];
    target.extend(field.path.clone());
    for length in 1..=target.len() {
        if shape.paths.get(&target[..length]).copied().unwrap_or(0) > 1 {
            return Err(invalid(
                "The native XML field has an ambiguous duplicate path.",
            ));
        }
    }
    let exists = shape.paths.contains_key(&target);
    if !exists && value.is_null() {
        return Ok(document.into());
    }
    // Pick the nearest existing ancestor; adding a leaf never duplicates its
    // already-present parents or replaces unrelated siblings.
    let parent_length = (1..target.len())
        .rev()
        .find(|length| shape.paths.contains_key(&target[..*length]))
        .unwrap_or(1);
    let parent = target[..parent_length].to_vec();
    let mut reader = NsReader::from_str(document);
    let mut writer = Writer::new(Vec::new());
    let mut path = Vec::new();
    let mut matching = Vec::new();
    let mut replacing = false;
    let mut removing = false;
    let mut written_text = false;
    let mut list_depth = None;
    let mut skipping_list_item = false;
    let mut inserted = false;
    loop {
        let (resolved, event) = reader
            .read_resolved_event()
            .map_err(|_| invalid("The native XML document is invalid."))?;
        let ns = namespace(resolved)?;
        match event {
            Event::Start(ref element) | Event::Empty(ref element) => {
                let name = local_name(element.name().as_ref())?;
                let same = ns == root.namespace && matching.last().copied().unwrap_or(true);
                path.push(name);
                matching.push(same);
                let empty = matches!(event, Event::Empty(_));
                let at_target = same && path == target;
                let qname = String::from_utf8_lossy(element.name().as_ref()).into_owned();
                let prefix = qname
                    .rsplit_once(':')
                    .map(|(prefix, _)| format!("{prefix}:"))
                    .unwrap_or_default();
                if removing || skipping_list_item {
                    // The matching end event releases this bounded subtree.
                } else if at_target && value.is_null() {
                    removing = true;
                } else if at_target && field.kind == NativeFieldKind::StringList {
                    write(&mut writer, Event::Start(element.borrow()))?;
                    list_depth = Some(path.len());
                    if empty {
                        write_list(&mut writer, field, value, &prefix)?;
                        write(&mut writer, Event::End(BytesEnd::new(qname)))?;
                        list_depth = None;
                    }
                } else if list_depth.is_some_and(|depth| path.len() == depth + 1)
                    && same
                    && path.last() == field.item_element.as_ref()
                {
                    if !inserted {
                        write_list(&mut writer, field, value, &prefix)?;
                        inserted = true;
                    }
                    skipping_list_item = !empty;
                } else if at_target {
                    write(&mut writer, Event::Start(element.borrow()))?;
                    replacing = true;
                    if empty {
                        write_value(&mut writer, value)?;
                        write(&mut writer, Event::End(BytesEnd::new(qname)))?;
                        replacing = false;
                    }
                } else if replacing {
                    return Err(invalid("A scalar native field contains child elements."));
                } else if !exists && same && path == parent && empty {
                    write(&mut writer, Event::Start(element.borrow()))?;
                    write_missing(&mut writer, &target[parent_length..], field, value, &prefix)?;
                    write(&mut writer, Event::End(BytesEnd::new(qname)))?;
                    inserted = true;
                } else {
                    write(&mut writer, event.borrow())?;
                }
                if empty {
                    if at_target {
                        removing = false;
                    }
                    path.pop();
                    matching.pop();
                }
            }
            Event::End(ref element) => {
                let at_target = path == target && matching.last() == Some(&true);
                if removing {
                    if at_target {
                        removing = false;
                    }
                } else if skipping_list_item {
                    if list_depth.is_some_and(|depth| path.len() == depth + 1) {
                        skipping_list_item = false;
                    }
                } else {
                    if at_target && replacing {
                        if !written_text {
                            write_value(&mut writer, value)?;
                        }
                        replacing = false;
                    }
                    let qname = String::from_utf8_lossy(element.name().as_ref()).into_owned();
                    let prefix = qname
                        .rsplit_once(':')
                        .map(|(prefix, _)| format!("{prefix}:"))
                        .unwrap_or_default();
                    if list_depth == Some(path.len()) {
                        if !inserted {
                            write_list(&mut writer, field, value, &prefix)?;
                        }
                        list_depth = None;
                    }
                    if !exists && !inserted && path == parent && matching.last() == Some(&true) {
                        write_missing(
                            &mut writer,
                            &target[parent_length..],
                            field,
                            value,
                            &prefix,
                        )?;
                        inserted = true;
                    }
                    write(&mut writer, event.borrow())?;
                }
                path.pop();
                matching.pop();
            }
            Event::Text(_) | Event::CData(_) if replacing => {
                if !written_text {
                    write_value(&mut writer, value)?;
                    written_text = true;
                }
            }
            Event::Eof => break,
            _ if removing || skipping_list_item => {}
            // Comments, processing instructions, declarations, attributes and
            // unrelated nodes retain their original bytes through quick-xml.
            other => write(&mut writer, other)?,
        }
    }
    String::from_utf8(writer.into_inner())
        .map_err(|_| invalid("The edited native XML is not UTF-8."))
}

fn write(writer: &mut Writer<Vec<u8>>, event: Event<'_>) -> Validation<()> {
    writer
        .write_event(event)
        .map_err(|_| invalid("Could not encode the native XML edit."))
}

fn write_value(writer: &mut Writer<Vec<u8>>, value: &Value) -> Validation<()> {
    let text = value
        .as_str()
        .map(String::from)
        .unwrap_or_else(|| value.to_string());
    write(writer, Event::Text(BytesText::new(&text)))
}

fn write_list(
    writer: &mut Writer<Vec<u8>>,
    field: &NativeField,
    value: &Value,
    prefix: &str,
) -> Validation<()> {
    let name = format!(
        "{prefix}{}",
        field.item_element.as_deref().unwrap_or_default()
    );
    for item in value.as_array().into_iter().flatten() {
        write(writer, Event::Start(BytesStart::new(&name)))?;
        write_value(writer, item)?;
        write(writer, Event::End(BytesEnd::new(&name)))?;
    }
    Ok(())
}

fn write_missing(
    writer: &mut Writer<Vec<u8>>,
    path: &[String],
    field: &NativeField,
    value: &Value,
    prefix: &str,
) -> Validation<()> {
    for component in path {
        write(
            writer,
            Event::Start(BytesStart::new(format!("{prefix}{component}"))),
        )?;
    }
    if field.kind == NativeFieldKind::StringList {
        write_list(writer, field, value, prefix)?;
    } else {
        write_value(writer, value)?;
    }
    for component in path.iter().rev() {
        write(
            writer,
            Event::End(BytesEnd::new(format!("{prefix}{component}"))),
        )?;
    }
    Ok(())
}
