//! Plugin marketplace contract v1: index validation, platform and plugin API
//! filtering, source URL resolution, and install reviews.
//!
//! A marketplace source is a JSON index listing plugins and their release
//! archives. Hosts fetch and cache indexes and download archives themselves;
//! this module only decides, deterministically, which entries are valid,
//! which version a platform can install, and which programs a package will
//! start, so macOS and Windows present the same catalog and the same trust
//! prompts. The contract lives in `shared/contracts/plugins/v1/`.

use super::capabilities::{self, HostCapabilities, Requires, CAPABILITIES_API_VERSION};
use super::declarative::{
    is_official_namespace, is_plugin_id, is_semantic_version, validate_manifest_value,
    PluginRejection, Validation, SUPPORTED_PLUGIN_API_VERSIONS,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use url::Url;

/// Marketplace index schema version understood by this Core build.
pub const MARKETPLACE_INDEX_SCHEMA_VERSION: u64 = 1;
/// Index file a GitHub repository URL resolves to.
pub const REPOSITORY_INDEX_FILE_NAME: &str = "lithe-plugin-index.json";
/// Platforms with a Lithe host today. Other well-formed identifiers are
/// accepted so an index can list future platforms without breaking older
/// hosts; they simply never match.
pub const KNOWN_PLATFORMS: &[&str] =
    &["darwin-arm64", "darwin-x64", "windows-arm64", "windows-x64"];

/// Who maintains a marketplace source. Only the host's built-in default
/// source is `official`; every user-added source is `thirdParty`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum SourceKind {
    Official,
    ThirdParty,
}

/// One plugin as listed by an index. Unknown fields are refused so an entry
/// written for a newer contract is reported instead of half understood.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IndexEntry {
    id: String,
    name: String,
    author: String,
    /// `https://github.com/<owner>/<repo>` that owns the plugin's releases.
    repository: String,
    #[serde(default)]
    homepage: Option<String>,
    description: String,
    /// Translations of `description` keyed by language tag such as
    /// `zh-Hans`; hosts fall back to `description` when none matches.
    #[serde(default)]
    localized_descriptions: BTreeMap<String, String>,
    #[serde(default)]
    tags: Vec<String>,
    /// License name as published by the plugin, typically an SPDX ID.
    license: String,
    /// Raw file in the plugin's own repository.
    #[serde(default)]
    icon: Option<String>,
    versions: Vec<IndexVersion>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IndexVersion {
    version: String,
    #[serde(rename = "pluginAPIVersion")]
    plugin_api_version: u64,
    /// Capability versions of a level 3 package, copied from its manifest
    /// so hosts can tell before downloading whether they can run it.
    #[serde(default)]
    requires: Option<Value>,
    /// Calendar date `YYYY-MM-DD`, used for sorting and display only.
    release_date: String,
    /// One archive per platform group; a platform may appear only once.
    downloads: Vec<IndexDownload>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IndexDownload {
    platforms: Vec<String>,
    /// GitHub Release asset of the entry's own repository.
    #[serde(rename = "downloadURL")]
    download_url: String,
    /// Lowercase hex SHA-256 of the archive bytes.
    sha256: String,
}

/// `owner/repo` of a GitHub repository, compared case-insensitively because
/// GitHub treats both components that way.
#[derive(Debug, Clone, PartialEq, Eq)]
struct GitHubRepository {
    owner: String,
    name: String,
}

impl GitHubRepository {
    fn same_as(&self, other: &Self) -> bool {
        self.owner.eq_ignore_ascii_case(&other.owner) && self.name.eq_ignore_ascii_case(&other.name)
    }

    fn web_url(&self) -> String {
        format!("https://github.com/{}/{}", self.owner, self.name)
    }
}

// MARK: Index validation

/// Validates a whole index for one platform. Whole-index problems reject the
/// index; a bad entry is reported in `rejected` without hiding the others.
fn validate_index(
    index: Value,
    source: SourceKind,
    platform: &str,
    host_capabilities: Option<&HostCapabilities>,
) -> Validation<Value> {
    if !is_platform(platform) {
        return Err(PluginRejection::at(
            "plugin.index.invalid",
            "platform",
            "The host platform identifier is invalid.",
        ));
    }
    let Value::Object(mut root) = index else {
        return Err(PluginRejection::new(
            "plugin.index.invalid",
            "The plugin index must be a JSON object.",
        ));
    };
    match root.get("schemaVersion").and_then(Value::as_u64) {
        Some(MARKETPLACE_INDEX_SCHEMA_VERSION) => {}
        Some(version) => {
            return Err(PluginRejection::at(
                "plugin.index.schemaUnsupported",
                "schemaVersion",
                format!("Plugin index schema {version} is not supported by this version of Lithe."),
            ))
        }
        None => {
            return Err(PluginRejection::at(
                "plugin.index.invalid",
                "schemaVersion",
                "The plugin index has no schemaVersion.",
            ))
        }
    }
    let Some(Value::Array(entries)) = root.remove("plugins") else {
        return Err(PluginRejection::at(
            "plugin.index.invalid",
            "plugins",
            "The plugin index has no plugin list.",
        ));
    };
    if let Some(unknown) = root.keys().find(|key| key.as_str() != "schemaVersion") {
        return Err(PluginRejection::at(
            "plugin.index.invalid",
            unknown.clone(),
            format!("The plugin index has an unknown field: {unknown}."),
        ));
    }

    let mut seen = BTreeSet::new();
    let mut plugins = Vec::new();
    let mut rejected = Vec::new();
    for (position, raw) in entries.into_iter().enumerate() {
        let field = format!("plugins[{position}]");
        let raw_id = raw.get("id").and_then(Value::as_str).map(str::to_string);
        let result = serde_json::from_value::<IndexEntry>(raw)
            .map_err(|error| {
                PluginRejection::at(
                    "plugin.index.invalid",
                    field.clone(),
                    format!("The plugin entry is invalid: {error}"),
                )
            })
            .and_then(|entry| validate_entry(entry, source, platform, host_capabilities, &field))
            .and_then(|plugin| {
                // The first listing of an ID wins; a later duplicate cannot
                // silently replace the download the user saw first.
                let id = plugin["id"].as_str().unwrap_or_default().to_string();
                if seen.insert(id) {
                    Ok(plugin)
                } else {
                    Err(PluginRejection::at(
                        "plugin.index.duplicate",
                        format!("{field}.id"),
                        "The plugin is listed more than once in this index.",
                    ))
                }
            });
        match result {
            Ok(plugin) => plugins.push(plugin),
            Err(error) => rejected.push(json!({ "id": raw_id, "error": error })),
        }
    }
    plugins.sort_by(|left, right| left["id"].as_str().cmp(&right["id"].as_str()));
    Ok(json!({ "plugins": plugins, "rejected": rejected }))
}

/// Language tag in the `language[-Script][-REGION]` form used by `.lproj`
/// directories, e.g. `zh-Hans` or `en`.
fn is_language_tag(tag: &str) -> bool {
    let mut parts = tag.split('-');
    let Some(language) = parts.next() else {
        return false;
    };
    (2..=3).contains(&language.len())
        && language.chars().all(|c| c.is_ascii_lowercase())
        && parts.all(|part| {
            (2..=8).contains(&part.len()) && part.chars().all(|c| c.is_ascii_alphanumeric())
        })
}

fn validate_entry(
    entry: IndexEntry,
    source: SourceKind,
    platform: &str,
    host_capabilities: Option<&HostCapabilities>,
    field: &str,
) -> Validation<Value> {
    if !is_plugin_id(&entry.id) {
        return Err(index_invalid(
            format!("{field}.id"),
            "The plugin ID must use lowercase letters, digits, dots, and hyphens.",
        ));
    }
    if source == SourceKind::ThirdParty && is_official_namespace(&entry.id) {
        return Err(PluginRejection::at(
            "plugin.index.officialNamespace",
            format!("{field}.id"),
            "Only the official Lithe source may list plugins in the dev.lithe namespace.",
        ));
    }
    for (name, value) in [
        ("name", &entry.name),
        ("author", &entry.author),
        ("description", &entry.description),
        ("license", &entry.license),
    ] {
        if value.trim().is_empty() {
            return Err(index_invalid(
                format!("{field}.{name}"),
                format!("The plugin {name} is empty."),
            ));
        }
    }
    let mut localized_descriptions = BTreeMap::new();
    for (language, text) in &entry.localized_descriptions {
        if !is_language_tag(language) || text.trim().is_empty() {
            return Err(index_invalid(
                format!("{field}.localizedDescriptions.{language}"),
                "Localized descriptions need a language tag such as zh-Hans and non-empty text.",
            ));
        }
        localized_descriptions.insert(language.clone(), text.trim().to_string());
    }
    let repository = parse_repository(&entry.repository).ok_or_else(|| {
        index_invalid(
            format!("{field}.repository"),
            "The repository must be https://github.com/<owner>/<repo>.",
        )
    })?;
    if let Some(homepage) = &entry.homepage {
        if parse_https(homepage).is_none() {
            return Err(index_invalid(
                format!("{field}.homepage"),
                "The homepage must be an https URL.",
            ));
        }
    }
    if let Some(icon) = &entry.icon {
        if !is_repository_raw_file(icon, &repository) {
            return Err(index_invalid(
                format!("{field}.icon"),
                "The icon must be a raw.githubusercontent.com file of the plugin's repository.",
            ));
        }
    }
    let mut tags = BTreeSet::new();
    for tag in &entry.tags {
        let normalized = tag.trim().to_lowercase();
        if normalized.is_empty() || normalized.chars().any(char::is_whitespace) {
            return Err(index_invalid(
                format!("{field}.tags"),
                "Tags must be single non-empty words.",
            ));
        }
        tags.insert(normalized);
    }
    if entry.versions.is_empty() {
        return Err(index_invalid(
            format!("{field}.versions"),
            "The plugin lists no versions.",
        ));
    }

    let mut versions = Vec::new();
    let mut version_numbers = BTreeSet::new();
    for (position, version) in entry.versions.iter().enumerate() {
        let version_field = format!("{field}.versions[{position}]");
        let number = parse_version(&version.version).ok_or_else(|| {
            index_invalid(
                format!("{version_field}.version"),
                "The version must use major.minor.patch.",
            )
        })?;
        if !version_numbers.insert(number) {
            return Err(index_invalid(
                format!("{version_field}.version"),
                "The version is listed more than once.",
            ));
        }
        if !is_calendar_date(&version.release_date) {
            return Err(index_invalid(
                format!("{version_field}.releaseDate"),
                "The release date must use YYYY-MM-DD.",
            ));
        }
        let requires = index_requires(version, &version_field)?;
        if version.downloads.is_empty() {
            return Err(index_invalid(
                format!("{version_field}.downloads"),
                "The version lists no downloads.",
            ));
        }
        let mut platforms = BTreeSet::new();
        for (download_position, download) in version.downloads.iter().enumerate() {
            let download_field = format!("{version_field}.downloads[{download_position}]");
            if download.platforms.is_empty() {
                return Err(index_invalid(
                    format!("{download_field}.platforms"),
                    "The download lists no platforms.",
                ));
            }
            for platform in &download.platforms {
                if !is_platform(platform) {
                    return Err(index_invalid(
                        format!("{download_field}.platforms"),
                        format!("The platform identifier {platform} is invalid."),
                    ));
                }
                if !platforms.insert(platform.clone()) {
                    return Err(index_invalid(
                        format!("{download_field}.platforms"),
                        format!(
                            "The platform {platform} has more than one download in this version."
                        ),
                    ));
                }
            }
            if !is_release_asset(&download.download_url, &repository) {
                return Err(index_invalid(
                    format!("{download_field}.downloadURL"),
                    "The download must be a .zip GitHub Release asset of the plugin's repository.",
                ));
            }
            if !is_sha256(&download.sha256) {
                return Err(index_invalid(
                    format!("{download_field}.sha256"),
                    "The checksum must be 64 lowercase hexadecimal characters.",
                ));
            }
        }
        versions.push(ListedVersion {
            number,
            version,
            requires,
            platforms,
        });
    }
    // Newest first, so "latest" and the version list read the same way on
    // every host regardless of the order an index author used.
    versions.sort_by_key(|listed| std::cmp::Reverse(listed.number));

    let latest = &versions[0];
    let availability = availability(&versions, platform, host_capabilities);
    Ok(json!({
        "id": entry.id,
        "name": entry.name.trim(),
        "author": entry.author.trim(),
        "repository": repository.web_url(),
        "homepage": entry.homepage,
        "description": entry.description.trim(),
        "localizedDescriptions": localized_descriptions,
        "tags": tags,
        "license": entry.license.trim(),
        "icon": entry.icon,
        "platforms": latest.platforms,
        "latestVersion": latest.version.version,
        "latestReleaseDate": latest.version.release_date,
        "availability": availability,
        "versions": versions.iter().map(|listed| {
            let mut value = json!({
                "version": listed.version.version,
                "pluginAPIVersion": listed.version.plugin_api_version,
                "releaseDate": listed.version.release_date,
                "platforms": listed.platforms,
            });
            if let Some(requires) = &listed.requires {
                value["requires"] = json!(requires);
            }
            value
        }).collect::<Vec<_>>(),
    }))
}

/// One validated version of an entry.
struct ListedVersion<'a> {
    number: (u32, u32, u32),
    version: &'a IndexVersion,
    requires: Option<Requires>,
    platforms: BTreeSet<String>,
}

/// Reads a version's `requires`, which level 3 lists and earlier levels do
/// not. Unknown capability IDs are kept: they make the version unavailable
/// on this host instead of rejecting the whole entry.
fn index_requires(version: &IndexVersion, field: &str) -> Validation<Option<Requires>> {
    let field = format!("{field}.requires");
    match (&version.requires, version.plugin_api_version) {
        (None, level) if level == u64::from(CAPABILITIES_API_VERSION) => Err(index_invalid(
            field,
            "A pluginAPIVersion 3 version lists the capabilities it uses in requires.",
        )),
        (Some(_), level) if level < u64::from(CAPABILITIES_API_VERSION) => Err(index_invalid(
            field,
            "Capability versions require pluginAPIVersion 3.",
        )),
        (None, _) => Ok(None),
        (Some(requires), _) => {
            capabilities::parse_requires(requires, &field, "plugin.index.invalid").map(Some)
        }
    }
}

/// Picks the newest version this host can install. When none qualifies, an
/// API mismatch is reported in preference to a missing platform, because a
/// Lithe update is then enough to install the plugin.
fn availability(
    versions: &[ListedVersion<'_>],
    platform: &str,
    host_capabilities: Option<&HostCapabilities>,
) -> Value {
    let mut platform_listed = false;
    for listed in versions {
        let version = listed.version;
        if !listed.platforms.contains(platform) {
            continue;
        }
        platform_listed = true;
        if !SUPPORTED_PLUGIN_API_VERSIONS
            .iter()
            .any(|supported| u64::from(*supported) == version.plugin_api_version)
        {
            continue;
        }
        let hosted = match &listed.requires {
            // A level 3 version runs where the host implements every
            // capability version it requires, whatever else it lacks.
            Some(requires) => capabilities::hosts(requires, host_capabilities),
            // Core validates level 2 UI declarations on every platform, but
            // only macOS has the level 2 UI host. Do not advertise an adapter
            // Windows cannot run merely because validation succeeded.
            None => version.plugin_api_version < 2 || platform.starts_with("darwin-"),
        };
        if !hosted {
            continue;
        }
        let download = version
            .downloads
            .iter()
            .find(|download| download.platforms.iter().any(|value| value == platform))
            .expect("platform set was built from the downloads");
        return json!({
            "status": "available",
            "version": version.version,
            "pluginAPIVersion": version.plugin_api_version,
            "releaseDate": version.release_date,
            "downloadURL": download.download_url,
            "sha256": download.sha256,
        });
    }
    if platform_listed {
        json!({
            "status": "unsupported",
            "code": "plugin.index.apiUnsupported",
            "platform": platform,
            "message": "This plugin requires a newer version of Lithe.",
        })
    } else {
        json!({
            "status": "unsupported",
            "code": "plugin.index.platformUnsupported",
            "platform": platform,
            "message": format!("This plugin is not available for {platform}."),
        })
    }
}

// MARK: Source resolution

/// Resolves what a user pasted into the index URL Lithe will fetch.
fn resolve_source(input: &str) -> Validation<Value> {
    let url = parse_https(input.trim()).ok_or_else(|| {
        PluginRejection::new(
            "plugin.source.invalid",
            "Enter an https URL of a plugin index or a GitHub repository.",
        )
    })?;
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    let segments: Vec<&str> = url
        .path_segments()
        .map(|segments| segments.filter(|segment| !segment.is_empty()).collect())
        .unwrap_or_default();

    if host == "github.com" || host == "www.github.com" {
        let repository = segments
            .first()
            .zip(segments.get(1))
            .and_then(|(owner, name)| repository_from_parts(owner, name.trim_end_matches(".git")))
            .ok_or_else(|| {
                PluginRejection::new(
                    "plugin.source.invalid",
                    "The GitHub URL does not name a repository.",
                )
            })?;
        let index_url = match &segments[2..] {
            [] => format!(
                "https://raw.githubusercontent.com/{}/{}/HEAD/{REPOSITORY_INDEX_FILE_NAME}",
                repository.owner, repository.name
            ),
            // A file page (`/blob/<ref>/<path>`) maps one-to-one to its raw
            // URL, whatever slashes the ref contains.
            ["blob", rest @ ..] if rest.len() >= 2 => format!(
                "https://raw.githubusercontent.com/{}/{}/{}",
                repository.owner,
                repository.name,
                rest.join("/")
            ),
            _ => {
                return Err(PluginRejection::new(
                    "plugin.source.invalid",
                    "Use the repository URL or the URL of its plugin index file.",
                ))
            }
        };
        return Ok(json!({
            "indexURL": index_url,
            "repository": repository.web_url(),
            "displayName": format!("{}/{}", repository.owner, repository.name),
        }));
    }

    let mut index_url = url.clone();
    index_url.set_fragment(None);
    let repository = if host == "raw.githubusercontent.com" && segments.len() >= 4 {
        repository_from_parts(segments[0], segments[1])
    } else {
        None
    };
    Ok(json!({
        "indexURL": index_url.as_str(),
        "repository": repository.as_ref().map(GitHubRepository::web_url),
        "displayName": repository
            .map(|repository| format!("{}/{}", repository.owner, repository.name))
            .unwrap_or(host),
    }))
}

// MARK: Install review

/// Summarizes what installing a package lets it do, and which programs are
/// new compared with what the user already approved for this plugin.
fn install_review(
    manifest: Value,
    expected_id: Option<&str>,
    expected_version: Option<&str>,
    approved_programs: Option<&[Value]>,
    host_capabilities: Option<&HostCapabilities>,
) -> Validation<Value> {
    let manifest = validate_manifest_value(manifest)?;
    if let Some(host) = host_capabilities {
        capabilities::check_hosted(manifest.requires(), host)?;
    }
    if expected_id.is_some_and(|id| id != manifest.id())
        || expected_version.is_some_and(|version| version != manifest.version())
    {
        return Err(PluginRejection::new(
            "plugin.package.mismatch",
            "The downloaded package does not match the plugin and version listed in the index.",
        ));
    }
    let programs = manifest.programs();
    let new_programs: Vec<&Value> = match approved_programs {
        Some(approved) => programs
            .iter()
            .filter(|program| !approved.contains(program))
            .collect(),
        None => programs.iter().collect(),
    };
    Ok(json!({
        "id": manifest.id(),
        "version": manifest.version(),
        "permissions": manifest.permissions(),
        "programs": programs,
        "newPrograms": new_programs,
    }))
}

// MARK: Value checks

fn index_invalid(field: impl Into<String>, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.index.invalid", field, message)
}

fn parse_version(value: &str) -> Option<(u32, u32, u32)> {
    if !is_semantic_version(value) {
        return None;
    }
    let mut parts = value.split('.').map(|part| part.parse::<u32>().ok());
    Some((parts.next()??, parts.next()??, parts.next()??))
}

fn is_platform(value: &str) -> bool {
    let mut parts = value.split('-');
    let valid_part = |part: Option<&str>| {
        part.is_some_and(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|character| character.is_ascii_lowercase() || character.is_ascii_digit())
        })
    };
    valid_part(parts.next()) && valid_part(parts.next()) && parts.next().is_none()
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .chars()
            .all(|character| character.is_ascii_digit() || ('a'..='f').contains(&character))
}

fn is_calendar_date(value: &str) -> bool {
    let parts: Vec<&str> = value.split('-').collect();
    let [year, month, day] = parts.as_slice() else {
        return false;
    };
    let number = |part: &str, length: usize| {
        (part.len() == length && part.chars().all(|character| character.is_ascii_digit()))
            .then(|| part.parse::<u32>().ok())
            .flatten()
    };
    matches!(
        (number(year, 4), number(month, 2), number(day, 2)),
        (Some(_), Some(1..=12), Some(1..=31))
    )
}

/// Accepts only absolute https URLs without embedded credentials, which
/// would otherwise be stored in source lists and sent to arbitrary hosts.
fn parse_https(value: &str) -> Option<Url> {
    let url = Url::parse(value).ok()?;
    (url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none())
    .then_some(url)
}

fn repository_from_parts(owner: &str, name: &str) -> Option<GitHubRepository> {
    let valid = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
    };
    (valid(owner) && valid(name)).then(|| GitHubRepository {
        owner: owner.to_string(),
        name: name.to_string(),
    })
}

fn parse_repository(value: &str) -> Option<GitHubRepository> {
    let url = parse_https(value)?;
    if !url.host_str()?.eq_ignore_ascii_case("github.com")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let segments: Vec<&str> = url
        .path_segments()?
        .filter(|segment| !segment.is_empty())
        .collect();
    match segments.as_slice() {
        [owner, name] => repository_from_parts(owner, name),
        _ => None,
    }
}

/// `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>.zip`
/// of exactly the entry's repository, so an index cannot point a plugin at
/// another project's release.
fn is_release_asset(value: &str, repository: &GitHubRepository) -> bool {
    let Some(url) = parse_https(value) else {
        return false;
    };
    if !url
        .host_str()
        .is_some_and(|host| host.eq_ignore_ascii_case("github.com"))
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return false;
    }
    let Some(segments) = url.path_segments().map(Iterator::collect::<Vec<_>>) else {
        return false;
    };
    match segments.as_slice() {
        [owner, name, "releases", "download", tag, asset] => {
            repository_from_parts(owner, name)
                .is_some_and(|candidate| candidate.same_as(repository))
                && is_path_component(tag)
                && is_path_component(asset)
                && asset.to_ascii_lowercase().ends_with(".zip")
        }
        _ => false,
    }
}

fn is_repository_raw_file(value: &str, repository: &GitHubRepository) -> bool {
    let Some(url) = parse_https(value) else {
        return false;
    };
    if !url
        .host_str()
        .is_some_and(|host| host.eq_ignore_ascii_case("raw.githubusercontent.com"))
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return false;
    }
    let Some(segments) = url.path_segments().map(Iterator::collect::<Vec<_>>) else {
        return false;
    };
    segments.len() >= 4
        && segments.iter().all(|segment| is_path_component(segment))
        && repository_from_parts(segments[0], segments[1])
            .is_some_and(|candidate| candidate.same_as(repository))
}

fn is_path_component(value: &str) -> bool {
    !value.is_empty() && value != "." && value != ".." && !value.contains('\\')
}

// MARK: Command entry points

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidateIndexPayload {
    index: Value,
    source_kind: SourceKind,
    platform: String,
    /// Capability versions the host runs; without them no level 3 version
    /// is offered.
    #[serde(default)]
    host_capabilities: Option<HostCapabilities>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveSourcePayload {
    url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallReviewPayload {
    manifest: Value,
    #[serde(default, rename = "expectedID")]
    expected_id: Option<String>,
    #[serde(default)]
    expected_version: Option<String>,
    /// Programs the user approved for the installed version; absent for a
    /// first installation.
    #[serde(default)]
    approved_programs: Option<Vec<Value>>,
    /// Capability versions the host runs. When sent, a level 3 package that
    /// requires anything else is refused.
    #[serde(default)]
    host_capabilities: Option<HostCapabilities>,
}

fn decode_payload<T: for<'de> Deserialize<'de>>(
    payload: Value,
    command: &str,
) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            format!("Invalid {command} payload"),
        )
        .with_details(error.to_string())
    })
}

fn outcome(key: &str, result: Validation<Value>) -> Value {
    match result {
        Ok(value) => {
            let mut object = serde_json::Map::new();
            object.insert("status".to_string(), json!("ok"));
            object.insert(key.to_string(), value);
            Value::Object(object)
        }
        Err(rejection) => json!({ "status": "rejected", "error": rejection }),
    }
}

/// `plugins.marketplace.validateIndex`: returns `{status: "ok", index:
/// {plugins, rejected}}` or a whole-index `rejected` outcome.
pub fn validate_index_command(payload: Value) -> Result<Value, CoreError> {
    let payload: ValidateIndexPayload =
        decode_payload(payload, "plugins.marketplace.validateIndex")?;
    Ok(outcome(
        "index",
        validate_index(
            payload.index,
            payload.source_kind,
            &payload.platform,
            payload.host_capabilities.as_ref(),
        ),
    ))
}

/// `plugins.marketplace.resolveSource`: returns `{status: "ok", source:
/// {indexURL, repository?, displayName}}`.
pub fn resolve_source_command(payload: Value) -> Result<Value, CoreError> {
    let payload: ResolveSourcePayload =
        decode_payload(payload, "plugins.marketplace.resolveSource")?;
    Ok(outcome("source", resolve_source(&payload.url)))
}

/// `plugins.marketplace.installReview`: returns `{status: "ok", review:
/// {id, version, permissions, programs, newPrograms}}`.
pub fn install_review_command(payload: Value) -> Result<Value, CoreError> {
    let payload: InstallReviewPayload =
        decode_payload(payload, "plugins.marketplace.installReview")?;
    Ok(outcome(
        "review",
        install_review(
            payload.manifest,
            payload.expected_id.as_deref(),
            payload.expected_version.as_deref(),
            payload.approved_programs.as_deref(),
            payload.host_capabilities.as_ref(),
        ),
    ))
}
