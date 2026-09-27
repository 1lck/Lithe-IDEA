//! Reads the optional local repository from a Maven settings document.
//!
//! Maven still owns effective settings and interpolation. This read-only hint
//! uses the same XML library as Core instead of interpreting XML as tag text.

use quick_xml::{events::Event, Reader};

pub(super) fn parse_local_repository(settings: &str) -> Option<String> {
    let mut reader = Reader::from_str(settings);
    reader.config_mut().expand_empty_elements = true;
    reader.config_mut().check_comments = true;
    let mut depth: usize = 0;
    let mut root_seen = false;
    let mut collecting = false;
    let mut repository: Option<String> = None;

    // Read through EOF: a valid-looking path before an incomplete closing tag
    // must not be presented as a valid settings value.
    loop {
        match reader.read_event().ok()? {
            Event::Start(element) => {
                for attribute in element.attributes() {
                    attribute.ok()?;
                }
                if depth == 0 {
                    if root_seen || element.local_name().as_ref() != b"settings" {
                        return None;
                    }
                    root_seen = true;
                } else if collecting {
                    return None;
                } else if depth == 1 && element.local_name().as_ref() == b"localRepository" {
                    if repository.is_some() {
                        return None;
                    }
                    repository = Some(String::new());
                    collecting = true;
                }
                depth += 1;
            }
            Event::End(_) => {
                depth = depth.checked_sub(1)?;
                if depth == 1 {
                    collecting = false;
                }
            }
            Event::Text(text) => {
                let text = text.unescape().ok()?;
                if collecting {
                    repository.as_mut()?.push_str(&text);
                } else if depth == 0 && !text.trim().is_empty() {
                    return None;
                }
            }
            Event::CData(text) => {
                if depth == 0 {
                    return None;
                }
                if collecting {
                    repository.as_mut()?.push_str(&text.decode().ok()?);
                }
            }
            // Do not expand external entities or attempt to read a DTD.
            Event::DocType(_) => return None,
            Event::Eof => break,
            _ => {}
        }
    }
    if depth != 0 || !root_seen {
        return None;
    }
    repository
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::parse_local_repository;

    #[test]
    fn decodes_xml_entities_in_repository_paths() {
        assert_eq!(
            parse_local_repository(
                "<settings><localRepository> D:/R&amp;D/&#x4ED3;&#24211; </localRepository></settings>"
            ),
            Some("D:/R&D/仓库".into())
        );
    }

    #[test]
    fn reads_cdata_and_adjacent_text_without_losing_spaces() {
        assert_eq!(
            parse_local_repository(
                "<settings><localRepository><![CDATA[D:/R&D]]> /repo</localRepository></settings>"
            ),
            Some("D:/R&D /repo".into())
        );
    }

    #[test]
    fn reads_namespaced_settings_and_ignores_comment_examples() {
        assert_eq!(
            parse_local_repository(
                r#"<?xml version="1.0"?><s:settings xmlns:s="http://maven.apache.org/SETTINGS/1.2.0">
                <!-- <localRepository>D:/example</localRepository> -->
                <s:localRepository>${user.home}/.m2/team</s:localRepository></s:settings>"#
            ),
            Some("${user.home}/.m2/team".into())
        );
    }

    #[test]
    fn only_reads_the_direct_settings_child() {
        assert_eq!(parse_local_repository(
            "<settings><profiles><profile><properties><localRepository>D:/other</localRepository></properties></profile></profiles></settings>"
        ), None);
        assert_eq!(
            parse_local_repository("<settings><localRepository/></settings>"),
            None
        );
    }

    #[test]
    fn rejects_incomplete_or_malformed_documents() {
        for xml in [
            "<settings><localRepository>D:/repo",
            "<settings><localRepository>D:/repo</settings>",
            "<settings><localRepository>D:/repo</localRepository>",
            "<settings><localRepository>D:/repo</localRepository></settings><broken",
            "<settings><localRepository>D:/repo</localRepository></settings><settings/>",
            "<settings><localRepository>D:/repo</localRepository></settings>trailing text",
            "<settings><localRepository>D:/&unknown;</localRepository></settings>",
            "<settings><localRepository><nested/>D:/repo</localRepository></settings>",
            "<settings><localRepository>D:/repo</localRepository><localRepository>D:/other</localRepository></settings>",
        ] {
            assert_eq!(parse_local_repository(xml), None, "accepted {xml}");
        }
    }
}
