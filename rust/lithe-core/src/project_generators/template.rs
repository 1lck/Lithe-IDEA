//! Variables of project generator templates.
//!
//! Strings in the manifest use the `${...}` syntax every plugin template
//! uses. Template files in the package use `{{ ... }}` instead, because Maven
//! POMs, Gradle scripts, and Spring properties already contain `${...}` that
//! must reach the project unchanged. In files, only `{{` followed by
//! `project.` or `field.` is a variable; any other `{{` is copied as text.

use crate::plugins::declarative::{parse_template_with, TemplatePart};
use std::collections::BTreeMap;

/// What a variable reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Source {
    /// The project name the user typed.
    ProjectName,
    /// A field's value: text, the chosen option, `true`/`false`, a
    /// comma-separated list, or a runtime's home directory.
    Field(String),
    /// The full version of a runtime field's selection.
    RuntimeVersion(String),
    /// The major version of a runtime field's selection, such as `21`.
    RuntimeMajor(String),
}

/// A transformation applied after the value is read, in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Modifier {
    /// Dots become `/`: a package name as a source directory.
    Path,
    /// A valid Java-style package: lowercase, only letters, digits,
    /// underscores, and single dots, each segment starting with a letter or
    /// underscore. `com.example.my-app` becomes `com.example.myapp`.
    Package,
    /// Lowercase.
    Lower,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Variable {
    pub(crate) source: Source,
    pub(crate) modifiers: Vec<Modifier>,
}

impl Variable {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        let mut parts = text.split('|').map(str::trim);
        let name = parts.next()?;
        let source = if name == "project.name" {
            Source::ProjectName
        } else {
            let rest = name.strip_prefix("field.")?;
            match rest.split_once('.') {
                None => Source::Field(rest.to_string()),
                Some((id, "version")) => Source::RuntimeVersion(id.to_string()),
                Some((id, "major")) => Source::RuntimeMajor(id.to_string()),
                Some(_) => return None,
            }
        };
        let modifiers = parts
            .map(|modifier| match modifier {
                "path" => Some(Modifier::Path),
                "package" => Some(Modifier::Package),
                "lower" => Some(Modifier::Lower),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Self { source, modifiers })
    }

    /// The field the variable reads, if any.
    #[cfg(test)]
    pub(crate) fn field(&self) -> Option<&str> {
        match &self.source {
            Source::ProjectName => None,
            Source::Field(id) | Source::RuntimeVersion(id) | Source::RuntimeMajor(id) => Some(id),
        }
    }
}

/// Parses a manifest string. `None` for an unknown or unterminated variable.
pub(crate) fn parse(value: &str) -> Option<Vec<TemplatePart<Variable>>> {
    parse_template_with(value, Variable::parse)
}

/// A filled-in field, as templates read it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FieldValue {
    Text(String),
    Flag(bool),
    List(Vec<String>),
    Runtime { home: String, version: String },
}

impl FieldValue {
    pub(crate) fn text(&self) -> String {
        match self {
            Self::Text(text) => text.clone(),
            Self::Flag(flag) => flag.to_string(),
            Self::List(items) => items.join(","),
            Self::Runtime { home, .. } => home.clone(),
        }
    }
}

/// Everything a template may read.
pub(crate) struct Values<'a> {
    pub(crate) project_name: &'a str,
    pub(crate) fields: &'a BTreeMap<String, FieldValue>,
}

impl Values<'_> {
    pub(crate) fn read(&self, variable: &Variable) -> String {
        let raw = match &variable.source {
            Source::ProjectName => self.project_name.to_string(),
            Source::Field(id) => self
                .fields
                .get(id)
                .map(FieldValue::text)
                .unwrap_or_default(),
            Source::RuntimeVersion(id) => match self.fields.get(id) {
                Some(FieldValue::Runtime { version, .. }) => version.clone(),
                _ => String::new(),
            },
            Source::RuntimeMajor(id) => match self.fields.get(id) {
                Some(FieldValue::Runtime { version, .. }) => major_version(version),
                _ => String::new(),
            },
        };
        variable
            .modifiers
            .iter()
            .fold(raw, |value, modifier| apply(*modifier, &value))
    }

    pub(crate) fn expand(&self, parts: &[TemplatePart<Variable>]) -> String {
        parts
            .iter()
            .map(|part| match part {
                TemplatePart::Text(text) => text.clone(),
                TemplatePart::Variable(variable) => self.read(variable),
            })
            .collect()
    }

    /// Expands a template file. Fails with the offending text when a
    /// `{{ project.… }}` or `{{ field.… }}` variable cannot be read.
    pub(crate) fn expand_file(
        &self,
        contents: &str,
        known_field: impl Fn(&Variable) -> bool,
    ) -> Result<String, String> {
        let mut output = String::with_capacity(contents.len());
        let mut rest = contents;
        while let Some(start) = rest.find("{{") {
            output.push_str(&rest[..start]);
            let after = &rest[start + 2..];
            let inner_start = after.trim_start();
            if !(inner_start.starts_with("project.") || inner_start.starts_with("field.")) {
                output.push_str("{{");
                rest = after;
                continue;
            }
            let Some(end) = after.find("}}") else {
                return Err(format!("{{{{{}", first_line(after)));
            };
            let inner = &after[..end];
            match Variable::parse(inner).filter(|variable| known_field(variable)) {
                Some(variable) => output.push_str(&self.read(&variable)),
                None => return Err(format!("{{{{{inner}}}}}")),
            }
            rest = &after[end + 2..];
        }
        output.push_str(rest);
        Ok(output)
    }
}

fn first_line(text: &str) -> &str {
    text.lines().next().unwrap_or_default()
}

fn apply(modifier: Modifier, value: &str) -> String {
    match modifier {
        Modifier::Path => value.replace('.', "/"),
        Modifier::Lower => value.to_lowercase(),
        Modifier::Package => package_name(value),
    }
}

/// `1.8.0_412` → `8`, `21.0.2` → `21`, `25` → `25`.
pub(crate) fn major_version(version: &str) -> String {
    let mut numbers = version
        .split(|character: char| !character.is_ascii_digit())
        .filter(|part| !part.is_empty());
    match (numbers.next(), numbers.next()) {
        (Some("1"), Some(minor)) => minor.to_string(),
        (Some(major), _) => major.to_string(),
        _ => String::new(),
    }
}

fn package_name(value: &str) -> String {
    value
        .to_lowercase()
        .split('.')
        .map(|segment| {
            segment
                .chars()
                .filter(|character| character.is_ascii_alphanumeric() || *character == '_')
                .collect::<String>()
        })
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            if segment.starts_with(|character: char| character.is_ascii_digit()) {
                format!("_{segment}")
            } else {
                segment
            }
        })
        .collect::<Vec<_>>()
        .join(".")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values(fields: &[(&str, FieldValue)]) -> BTreeMap<String, FieldValue> {
        fields
            .iter()
            .map(|(id, value)| (id.to_string(), value.clone()))
            .collect()
    }

    #[test]
    fn parses_sources_and_modifiers() {
        assert_eq!(
            Variable::parse("field.packageName | path"),
            Some(Variable {
                source: Source::Field("packageName".into()),
                modifiers: vec![Modifier::Path],
            })
        );
        assert_eq!(
            Variable::parse("field.jdk.major").map(|variable| variable.source),
            Some(Source::RuntimeMajor("jdk".into()))
        );
        assert!(Variable::parse("field.jdk.home").is_none());
        assert!(Variable::parse("project.path").is_none());
        assert!(Variable::parse("field.name|upper").is_none());
    }

    #[test]
    fn package_modifier_makes_a_valid_package() {
        assert_eq!(package_name("com.Example.my-app"), "com.example.myapp");
        assert_eq!(package_name("org..2fa.demo"), "org._2fa.demo");
    }

    #[test]
    fn major_versions_follow_java_numbering() {
        assert_eq!(major_version("1.8.0_412"), "8");
        assert_eq!(major_version("25.0.3"), "25");
        assert_eq!(major_version(""), "");
    }

    #[test]
    fn files_only_expand_project_and_field_variables() {
        let fields = values(&[("groupId", FieldValue::Text("com.example".into()))]);
        let values = Values {
            project_name: "demo",
            fields: &fields,
        };
        let expanded = values
            .expand_file(
                "<groupId>{{ field.groupId }}</groupId>${project.version} {{other}} {{project.name}}",
                |_| true,
            )
            .unwrap();
        assert_eq!(
            expanded,
            "<groupId>com.example</groupId>${project.version} {{other}} demo"
        );
        assert_eq!(
            values.expand_file("{{ field.missing }}", |variable| variable.field()
                != Some("missing")),
            Err("{{ field.missing }}".into())
        );
    }
}
