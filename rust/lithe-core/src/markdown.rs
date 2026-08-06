use ammonia::Builder;
use comrak::{markdown_to_html, Options};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownRenderRequest {
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownRenderResponse {
    pub html: String,
}

/// Renders the shared Markdown dialect used by every Lithe frontend.
///
/// Raw HTML is deliberately enabled in Comrak so useful document elements such
/// as `<details>` survive parsing, then the complete fragment is passed through
/// Ammonia. This keeps formatting HTML while removing executable content,
/// event handlers, embeds, and unsafe URL schemes.
pub fn render(request: MarkdownRenderRequest) -> MarkdownRenderResponse {
    let mut options = Options::default();
    options.extension.strikethrough = true;
    // The final Ammonia pass is the security boundary. Leaving tagfilter off
    // lets it remove dangerous raw elements together with their contents
    // instead of turning a script body into visible escaped text first.
    options.extension.tagfilter = false;
    options.extension.table = true;
    options.extension.autolink = true;
    options.extension.tasklist = true;
    options.extension.superscript = true;
    options.extension.footnotes = true;
    options.extension.inline_footnotes = true;
    options.extension.description_lists = true;
    options.extension.front_matter_delimiter = Some("---".to_owned());
    options.extension.alerts = true;
    options.extension.math_dollars = true;
    options.extension.math_latex = true;
    options.extension.math_code = true;
    options.extension.shortcodes = true;
    options.extension.header_id_prefix = Some("lithe-heading-".to_owned());
    options.extension.header_id_prefix_in_href = true;
    options.render.r#unsafe = true;
    options.render.sourcepos = true;

    let rendered = markdown_to_html(&request.source, &options);
    let mut sanitizer = Builder::default();
    sanitizer
        .add_tags(&["section", "tfoot", "input", "audio", "video", "source"])
        .add_generic_attributes(&["class", "id"])
        .generic_attribute_prefixes(HashSet::from(["data-", "aria-"]))
        .add_tag_attributes("a", &["target"])
        .add_tag_attributes("details", &["open"])
        .add_tag_attributes("img", &["loading"])
        .add_tag_attributes("input", &["type", "checked", "disabled"])
        .add_tag_attributes(
            "audio",
            &["src", "controls", "autoplay", "loop", "muted", "preload"],
        )
        .add_tag_attributes(
            "video",
            &[
                "src",
                "controls",
                "autoplay",
                "loop",
                "muted",
                "poster",
                "preload",
                "width",
                "height",
                "playsinline",
            ],
        )
        .add_tag_attributes("source", &["src", "type", "media"]);

    MarkdownRenderResponse {
        html: sanitizer.clean(&rendered).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{render, MarkdownRenderRequest};

    fn html(source: &str) -> String {
        render(MarkdownRenderRequest {
            source: source.to_owned(),
        })
        .html
    }

    #[test]
    fn renders_gfm_footnotes_alerts_math_and_shortcodes() {
        let output = html(
            "# Preview\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- [x] Ready\n\n~~old~~ :smile: $x^2$ note[^1]\n\n[^1]: Footnote\n\n> [!NOTE]\n> Local only\n",
        );

        assert!(output.contains("<table"));
        assert!(output.contains("type=\"checkbox\""));
        assert!(output.contains("checked=\"\""));
        assert!(output.contains("<del"));
        assert!(output.contains("😄"));
        assert!(output.contains("data-math-style=\"inline\""));
        assert!(output.contains("class=\"footnotes\""));
        assert!(output.contains("markdown-alert-note"));
        assert!(output.contains("id=\"lithe-heading-preview\""));
    }

    #[test]
    fn preserves_diagram_languages_but_does_not_special_case_plantuml() {
        let output = html(
            "```mermaid\ngraph TD; A-->B\n```\n\n```markmap\n# Root\n```\n\n```plantuml\nAlice -> Bob\n```\n",
        );

        assert!(output.contains("class=\"language-mermaid\""));
        assert!(output.contains("class=\"language-markmap\""));
        assert!(output.contains("class=\"language-plantuml\""));
        assert!(output.contains("Alice -&gt; Bob"));
        assert!(!output.contains("plantuml.com"));
        assert!(!output.contains("plantuml-server"));
    }

    #[test]
    fn strips_executable_html_embeds_and_unsafe_urls() {
        let output = html(
            r#"<script>alert('x')</script>
<style>body { display: none }</style>
<iframe src="https://example.com"></iframe>
<object data="file:///tmp/secret"></object>
<img src="x" onerror="alert(1)">
<a href="javascript:alert(1)" onclick="alert(2)">unsafe</a>
<a href="file:///tmp/secret">file</a>"#,
        );

        assert!(!output.contains("<script"));
        assert!(!output.contains("alert('x')"));
        assert!(!output.contains("<style"));
        assert!(!output.contains("display: none"));
        assert!(!output.contains("<iframe"));
        assert!(!output.contains("<object"));
        assert!(!output.contains("onerror"));
        assert!(!output.contains("onclick"));
        assert!(!output.contains("javascript:"));
        assert!(!output.contains("file:///"));
    }

    #[test]
    fn keeps_safe_raw_html_and_hides_front_matter() {
        let output = html(
            "---\ntitle: Hidden\n---\n\n<details open><summary>More</summary><mark>Safe</mark></details>\n",
        );

        assert!(!output.contains("title: Hidden"));
        assert!(output.contains("<details"));
        assert!(output.contains("<summary>More</summary>"));
        assert!(output.contains("<mark>Safe</mark>"));
    }
}
