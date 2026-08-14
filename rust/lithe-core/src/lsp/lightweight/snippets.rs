//! Conversion of LSP snippets into insertion-ready plain text.

use super::edits::TextResponse;
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// LSP snippet whose placeholders should be reduced to insertion text.
pub struct PlainSnippetRequest {
    pub value: String,
}

/// Removes snippet control syntax while preserving default placeholder text.
pub fn plain_snippet(request: PlainSnippetRequest) -> TextResponse {
    TextResponse {
        text: snippet_plain_text(&request.value),
    }
}

pub(crate) fn snippet_plain_text(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character != '$' {
            output.push(character);
            continue;
        }
        match chars.peek().copied() {
            Some('{') => {
                chars.next();
                if !consume_digits(&mut chars) {
                    output.push_str("${");
                    continue;
                }
                match chars.peek().copied() {
                    Some(':') => {
                        chars.next();
                        output.push_str(&consume_until_placeholder_end(&mut chars));
                    }
                    Some('}') => {
                        chars.next();
                    }
                    _ => output.push('$'),
                }
            }
            Some(next) if next.is_ascii_digit() => {
                consume_digits(&mut chars);
            }
            _ => output.push('$'),
        }
    }
    output
}

fn consume_digits<I>(chars: &mut std::iter::Peekable<I>) -> bool
where
    I: Iterator<Item = char>,
{
    let mut consumed = false;
    while chars
        .peek()
        .is_some_and(|character| character.is_ascii_digit())
    {
        chars.next();
        consumed = true;
    }
    consumed
}

fn consume_until_placeholder_end<I>(chars: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = char>,
{
    let mut value = String::new();
    for character in chars.by_ref() {
        if character == '}' {
            break;
        }
        value.push(character);
    }
    value
}
