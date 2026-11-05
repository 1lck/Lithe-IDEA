//! Bounded context parsing and Core-owned truth tables for synchronous key dispatch.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const MAX_SOURCE_BYTES: usize = 4096;
const MAX_TOKENS: usize = 128;
const MAX_DEPTH: usize = 32;
const MAX_CONTEXT_KEYS: usize = 12;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Source compiled outside the native keyboard event path.
pub struct ParseContextRequest {
    pub expression: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Portable boolean table, indexed with the first key as the least significant bit.
pub struct ParsedContext {
    pub keys: Vec<String>,
    pub values: Vec<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// A syntax diagnostic or a complete table; invalid input never produces a partial plan.
pub struct ParseContextResponse {
    pub parsed: Option<ParsedContext>,
    pub error: Option<ContextError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable diagnostic code and zero-based UTF-8 byte offset in the original source.
pub struct ContextError {
    pub code: &'static str,
    pub byte_offset: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Evaluates an already compiled table without reparsing source.
pub struct EvaluateContextRequest {
    pub parsed: ParsedContext,
    pub context: BTreeMap<String, bool>,
}

#[derive(Debug, Serialize)]
/// Result of evaluating one precompiled context.
pub struct EvaluateContextResponse {
    pub matches: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum Value {
    Boolean(bool),
    Text(String),
}

impl Value {
    fn truthy(&self) -> bool {
        match self {
            Self::Boolean(value) => *value,
            Self::Text(value) => !value.is_empty(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Key(String),
    Literal(Value),
    Not,
    And,
    Or,
    Equal,
    NotEqual,
    Open,
    Close,
}

enum Expression {
    Key(String),
    Literal(Value),
    Not(Box<Self>),
    And(Box<Self>, Box<Self>),
    Or(Box<Self>, Box<Self>),
    Equal(Box<Self>, Box<Self>, bool),
}

impl Expression {
    fn value(&self, context: &BTreeMap<String, bool>) -> Value {
        Value::Boolean(match self {
            Self::Key(key) => *context.get(key).unwrap_or(&false),
            Self::Literal(value) => return value.clone(),
            Self::Not(inner) => !inner.value(context).truthy(),
            Self::And(left, right) => left.value(context).truthy() && right.value(context).truthy(),
            Self::Or(left, right) => left.value(context).truthy() || right.value(context).truthy(),
            Self::Equal(left, right, equal) => {
                (left.value(context) == right.value(context)) == *equal
            }
        })
    }
}

fn diagnostic(code: &'static str, byte_offset: usize) -> ContextError {
    ContextError { code, byte_offset }
}

fn key_character(value: char) -> bool {
    value.is_ascii_alphanumeric() || value == '_' || value == '.'
}

fn tokenize(source: &str) -> Result<Vec<(Token, usize)>, ContextError> {
    let mut chars = source.char_indices().peekable();
    let mut tokens = Vec::new();
    while let Some((offset, ch)) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }
        if tokens.len() == MAX_TOKENS {
            return Err(diagnostic("too_complex", offset));
        }
        let token = match ch {
            '(' => Token::Open,
            ')' => Token::Close,
            '!' if chars.peek().is_some_and(|(_, next)| *next == '=') => {
                chars.next();
                Token::NotEqual
            }
            '!' => Token::Not,
            '&' | '|' | '=' => {
                if !chars.peek().is_some_and(|(_, next)| *next == ch) {
                    return Err(diagnostic("invalid_character", offset));
                }
                chars.next();
                match ch {
                    '&' => Token::And,
                    '|' => Token::Or,
                    _ => Token::Equal,
                }
            }
            '\'' | '"' => {
                let mut text = String::new();
                let mut closed = false;
                while let Some((inner_offset, next)) = chars.next() {
                    if next == ch {
                        closed = true;
                        break;
                    }
                    if next == '\\' {
                        text.push(match chars.next() {
                            Some((_, 'n')) => '\n',
                            Some((_, 'r')) => '\r',
                            Some((_, 't')) => '\t',
                            Some((_, escaped @ ('\\' | '\'' | '"'))) => escaped,
                            _ => return Err(diagnostic("invalid_escape", inner_offset)),
                        });
                    } else {
                        text.push(next);
                    }
                }
                if !closed {
                    return Err(diagnostic("unclosed_string", offset));
                }
                Token::Literal(Value::Text(text))
            }
            key if key_character(key) => {
                let mut name = key.to_string();
                while chars.peek().is_some_and(|(_, next)| key_character(*next)) {
                    name.push(chars.next().expect("peeked key character").1);
                }
                match name.as_str() {
                    "true" => Token::Literal(Value::Boolean(true)),
                    "false" => Token::Literal(Value::Boolean(false)),
                    _ => Token::Key(name),
                }
            }
            _ => return Err(diagnostic("invalid_character", offset)),
        };
        tokens.push((token, offset));
    }
    Ok(tokens)
}

struct Parser {
    tokens: Vec<(Token, usize)>,
    cursor: usize,
    source_length: usize,
}

impl Parser {
    fn error(&self, code: &'static str) -> ContextError {
        diagnostic(
            code,
            self.tokens
                .get(self.cursor)
                .map_or(self.source_length, |(_, offset)| *offset),
        )
    }

    fn take(&mut self, token: &Token) -> bool {
        if self
            .tokens
            .get(self.cursor)
            .is_some_and(|(next, _)| next == token)
        {
            self.cursor += 1;
            true
        } else {
            false
        }
    }

    fn or(&mut self, depth: usize) -> Result<Expression, ContextError> {
        let mut expression = self.and(depth)?;
        while self.take(&Token::Or) {
            expression = Expression::Or(Box::new(expression), Box::new(self.and(depth)?));
        }
        Ok(expression)
    }

    fn and(&mut self, depth: usize) -> Result<Expression, ContextError> {
        let mut expression = self.equality(depth)?;
        while self.take(&Token::And) {
            expression = Expression::And(Box::new(expression), Box::new(self.equality(depth)?));
        }
        Ok(expression)
    }

    fn equality(&mut self, depth: usize) -> Result<Expression, ContextError> {
        let left = self.unary(depth)?;
        let equal = if self.take(&Token::Equal) {
            Some(true)
        } else if self.take(&Token::NotEqual) {
            Some(false)
        } else {
            None
        };
        match equal {
            Some(equal) => Ok(Expression::Equal(
                Box::new(left),
                Box::new(self.unary(depth)?),
                equal,
            )),
            None => Ok(left),
        }
    }

    fn unary(&mut self, depth: usize) -> Result<Expression, ContextError> {
        if depth > MAX_DEPTH {
            return Err(self.error("too_complex"));
        }
        if self.take(&Token::Not) {
            return Ok(Expression::Not(Box::new(self.unary(depth + 1)?)));
        }
        if self.take(&Token::Open) {
            let expression = self.or(depth + 1)?;
            if !self.take(&Token::Close) {
                return Err(self.error("expected_closing_paren"));
            }
            return Ok(expression);
        }
        match self.tokens.get(self.cursor).map(|(token, _)| token.clone()) {
            Some(Token::Key(key)) => {
                self.cursor += 1;
                Ok(Expression::Key(key))
            }
            Some(Token::Literal(value)) => {
                self.cursor += 1;
                Ok(Expression::Literal(value))
            }
            _ => Err(self.error("expected_operand")),
        }
    }
}

fn compile(source: &str) -> Result<ParsedContext, ContextError> {
    if source.len() > MAX_SOURCE_BYTES {
        return Err(diagnostic("too_long", MAX_SOURCE_BYTES));
    }
    let tokens = tokenize(source)?;
    let keys: Vec<String> = tokens
        .iter()
        .filter_map(|(token, _)| match token {
            Token::Key(key) => Some(key.clone()),
            _ => None,
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if keys.len() > MAX_CONTEXT_KEYS {
        return Err(diagnostic("too_complex", 0));
    }
    if tokens.is_empty() {
        return Ok(ParsedContext {
            keys,
            values: vec![true],
        });
    }
    let mut parser = Parser {
        tokens,
        cursor: 0,
        source_length: source.len(),
    };
    let expression = parser.or(0)?;
    if parser.cursor != parser.tokens.len() {
        return Err(parser.error("trailing_token"));
    }
    // Core computes every boolean outcome once. Hosts only project their native
    // focus snapshot to a table index, without duplicating expression semantics.
    let values = (0..(1usize << keys.len()))
        .map(|index| {
            let context = keys
                .iter()
                .enumerate()
                .map(|(bit, key)| (key.clone(), index & (1 << bit) != 0))
                .collect();
            expression.value(&context).truthy()
        })
        .collect();
    Ok(ParsedContext { keys, values })
}

/// Compiles complete source or returns a stable syntax diagnostic within fixed budgets.
pub fn parse_context(request: ParseContextRequest) -> ParseContextResponse {
    match compile(&request.expression) {
        Ok(parsed) => ParseContextResponse {
            parsed: Some(parsed),
            error: None,
        },
        Err(error) => ParseContextResponse {
            parsed: None,
            error: Some(error),
        },
    }
}

/// Evaluates a portable precompiled table, rejecting malformed or oversized tables.
pub fn evaluate_context(
    request: EvaluateContextRequest,
) -> Result<EvaluateContextResponse, crate::CoreError> {
    let parsed = request.parsed;
    if parsed.keys.len() > MAX_CONTEXT_KEYS
        || parsed.values.len() != 1usize << parsed.keys.len()
        || parsed.keys.windows(2).any(|keys| keys[0] >= keys[1])
        || parsed.keys.iter().any(|key| {
            key.is_empty() || key.len() > MAX_SOURCE_BYTES || !key.chars().all(key_character)
        })
    {
        return Err(crate::CoreError::new(
            crate::ErrorCode::InvalidRequest,
            "Invalid compiled keymap context",
        ));
    }
    let index = parsed.keys.iter().enumerate().fold(0, |index, (bit, key)| {
        index | (usize::from(*request.context.get(key).unwrap_or(&false)) << bit)
    });
    Ok(EvaluateContextResponse {
        matches: parsed.values[index],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_limits_include_the_last_valid_source_depth_tokens_and_keys() {
        assert!(compile(&" ".repeat(MAX_SOURCE_BYTES)).is_ok());
        assert!(compile(&format!(
            "{}true{}",
            "(".repeat(MAX_DEPTH),
            ")".repeat(MAX_DEPTH)
        ))
        .is_ok());
        assert_eq!(
            compile(&vec!["true"; 65].join(" && ")).unwrap_err().code,
            "too_complex"
        );
        let parsed = compile(
            &(0..12)
                .map(|i| format!("key{i:02}"))
                .collect::<Vec<_>>()
                .join(" || "),
        )
        .unwrap();
        assert_eq!(parsed.values.len(), 4096);
        assert!(!parsed.values[0]);
        assert!(parsed.values[4095]);
    }

    #[test]
    fn context_diagnostics_preserve_utf8_byte_offsets_after_unicode_literals() {
        let error = compile("'😀' && @").unwrap_err();
        assert_eq!(error.code, "invalid_character");
        assert_eq!(error.byte_offset, 10);
    }

    #[test]
    fn context_rejects_every_unsupported_ascii_character_without_losing_progress() {
        for byte in 0u8..=127 {
            let character = char::from(byte);
            if key_character(character)
                || character.is_whitespace()
                || "!&|=()'\"".contains(character)
            {
                continue;
            }
            assert_eq!(
                compile(&format!("true || {character}")).unwrap_err().code,
                "invalid_character"
            );
        }
    }
}
