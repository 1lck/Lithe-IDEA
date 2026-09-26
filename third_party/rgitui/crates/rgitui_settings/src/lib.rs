use anyhow::Result;
use chrono::{DateTime, Utc};
use gpui::{App, Global};
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::mpsc::{channel, sync_channel, Sender, SyncSender};
use std::sync::{Mutex, OnceLock, RwLock};
use uuid::Uuid;

/// Controls the compactness of the UI layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Compactness {
    Compact,
    #[default]
    Default,
    Comfortable,
}

/// How diffs are displayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DiffViewMode {
    #[default]
    Unified,
    SideBySide,
}

impl fmt::Display for DiffViewMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DiffViewMode::Unified => write!(f, "Unified"),
            DiffViewMode::SideBySide => write!(f, "Side-by-Side"),
        }
    }
}

/// Controls whether light or dark themes are shown in the theme picker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum AppearanceMode {
    #[default]
    Auto,
    Light,
    Dark,
}

impl fmt::Display for AppearanceMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppearanceMode::Auto => write!(f, "Auto"),
            AppearanceMode::Light => write!(f, "Light"),
            AppearanceMode::Dark => write!(f, "Dark"),
        }
    }
}

impl FromStr for AppearanceMode {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "auto" => Ok(AppearanceMode::Auto),
            "light" => Ok(AppearanceMode::Light),
            "dark" => Ok(AppearanceMode::Dark),
            _ => Err(format!("Unknown appearance mode: {}", s)),
        }
    }
}

impl FromStr for DiffViewMode {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().replace('-', "_").as_str() {
            "unified" => Ok(DiffViewMode::Unified),
            "side_by_side" | "side by side" => Ok(DiffViewMode::SideBySide),
            _ => Err(format!("Unknown diff view mode: {}", s)),
        }
    }
}

/// The visual style used for the commit graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum GraphStyle {
    Rails,
    #[default]
    Curved,
    Angular,
}

impl fmt::Display for GraphStyle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GraphStyle::Rails => write!(f, "Rails"),
            GraphStyle::Curved => write!(f, "Curved"),
            GraphStyle::Angular => write!(f, "Angular"),
        }
    }
}

impl FromStr for GraphStyle {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "rails" => Ok(GraphStyle::Rails),
            "curved" => Ok(GraphStyle::Curved),
            "angular" => Ok(GraphStyle::Angular),
            _ => Err(format!("Unknown graph style: {}", s)),
        }
    }
}

/// How often the application should automatically fetch from remotes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AutoFetchInterval {
    #[default]
    Disabled,
    OneMinute,
    FiveMinutes,
    FifteenMinutes,
    ThirtyMinutes,
}

impl AutoFetchInterval {
    /// Every interval, in the order the settings UI lists them.
    pub const ALL: &'static [AutoFetchInterval] = &[
        AutoFetchInterval::Disabled,
        AutoFetchInterval::OneMinute,
        AutoFetchInterval::FiveMinutes,
        AutoFetchInterval::FifteenMinutes,
        AutoFetchInterval::ThirtyMinutes,
    ];
}

impl fmt::Display for AutoFetchInterval {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AutoFetchInterval::Disabled => write!(f, "Disabled"),
            AutoFetchInterval::OneMinute => write!(f, "1 min"),
            AutoFetchInterval::FiveMinutes => write!(f, "5 min"),
            AutoFetchInterval::FifteenMinutes => write!(f, "15 min"),
            AutoFetchInterval::ThirtyMinutes => write!(f, "30 min"),
        }
    }
}

impl FromStr for AutoFetchInterval {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "disabled" => Ok(AutoFetchInterval::Disabled),
            "1 min" | "one_minute" => Ok(AutoFetchInterval::OneMinute),
            "5 min" | "five_minutes" => Ok(AutoFetchInterval::FiveMinutes),
            "15 min" | "fifteen_minutes" => Ok(AutoFetchInterval::FifteenMinutes),
            "30 min" | "thirty_minutes" => Ok(AutoFetchInterval::ThirtyMinutes),
            _ => Err(format!("Unknown auto-fetch interval: {}", s)),
        }
    }
}

impl Compactness {
    pub fn multiplier(&self) -> f32 {
        match self {
            Compactness::Compact => 0.75,
            Compactness::Default => 1.0,
            Compactness::Comfortable => 1.25,
        }
    }

    pub fn spacing(&self, base: f32) -> f32 {
        base * self.multiplier()
    }
}

impl fmt::Display for Compactness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Compactness::Compact => write!(f, "Compact"),
            Compactness::Default => write!(f, "Default"),
            Compactness::Comfortable => write!(f, "Comfortable"),
        }
    }
}

impl FromStr for Compactness {
    type Err = String;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "compact" => Ok(Compactness::Compact),
            "default" => Ok(Compactness::Default),
            "comfortable" => Ok(Compactness::Comfortable),
            _ => Err(format!("Unknown compactness value: {}", s)),
        }
    }
}

/// Application settings persisted to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    #[serde(default = "default_settings_version")]
    pub version: u32,
    #[serde(default = "default_theme")]
    pub theme: String,
    #[serde(default)]
    pub ui_font: String,
    #[serde(default)]
    pub ai: AiSettings,
    #[serde(default)]
    pub git: GitSettings,
    #[serde(default)]
    pub recent_repos: Vec<PathBuf>,
    #[serde(default = "default_max_recent")]
    pub max_recent_repos: usize,
    #[serde(default)]
    pub last_workspace: Vec<PathBuf>,
    #[serde(default)]
    pub layout: LayoutSettings,
    #[serde(default)]
    pub workspaces: Vec<StoredWorkspace>,
    #[serde(default)]
    pub active_workspace_id: Option<String>,
    #[serde(default)]
    pub clean_exit: bool,
    #[serde(default)]
    pub compactness: Compactness,
    #[serde(default = "default_appearance_mode")]
    pub appearance_mode: AppearanceMode,
    #[serde(default)]
    pub terminal_command: String,
    #[serde(default)]
    pub editor_command: String,
    #[serde(default = "default_font_size")]
    pub font_size: u32,
    #[serde(default = "default_show_line_numbers_in_diff")]
    pub show_line_numbers_in_diff: bool,
    #[serde(default)]
    pub diff_view_mode: DiffViewMode,
    #[serde(default)]
    pub diff_wrap_lines: bool,
    #[serde(default)]
    pub graph_style: GraphStyle,
    #[serde(default = "default_show_subject_column")]
    pub show_subject_column: bool,
    #[serde(default = "default_author_column_width")]
    pub author_column_width: f32,
    #[serde(default = "default_date_column_width")]
    pub date_column_width: f32,
    #[serde(default)]
    pub auto_fetch_interval: AutoFetchInterval,
    #[serde(default = "default_confirm_destructive")]
    pub confirm_destructive_operations: bool,
    #[serde(default = "default_auto_check_updates")]
    pub auto_check_updates: bool,
    /// Timestamp of the most recent successful GitHub release check. Used to
    /// throttle background update polling so restarts don't spam the API.
    #[serde(default)]
    pub last_update_check_at: Option<DateTime<Utc>>,
    #[serde(default = "default_commit_limit")]
    pub commit_limit: usize,
    #[serde(default)]
    pub watch_all_worktrees: bool,
    /// Last known position/size of the standalone Settings window. Restored
    /// on next open if the saved origin still falls within a connected display.
    #[serde(default)]
    pub settings_window_bounds: Option<SavedWindowBounds>,
}

/// Serializable rectangle in screen coordinates. Used to persist window
/// geometry across sessions independently of GPUI's `Bounds<Pixels>`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SavedWindowBounds {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Current settings version. Increment when making breaking changes.
const CURRENT_SETTINGS_VERSION: u32 = 3;

fn default_settings_version() -> u32 {
    CURRENT_SETTINGS_VERSION
}

fn default_theme() -> String {
    "Catppuccin Mocha".into()
}

fn default_appearance_mode() -> AppearanceMode {
    AppearanceMode::Auto
}

fn default_font_size() -> u32 {
    14
}

fn default_show_line_numbers_in_diff() -> bool {
    true
}

fn default_show_subject_column() -> bool {
    true
}

fn default_author_column_width() -> f32 {
    140.0
}

fn default_date_column_width() -> f32 {
    100.0
}

fn default_confirm_destructive() -> bool {
    true
}

fn default_auto_check_updates() -> bool {
    true
}

fn default_commit_limit() -> usize {
    1000
}

/// A persisted local workspace snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredWorkspace {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub repos: Vec<PathBuf>,
    #[serde(default)]
    pub active_repo_index: usize,
    #[serde(default)]
    pub layout: LayoutSettings,
    #[serde(default = "utc_now")]
    pub created_at: DateTime<Utc>,
    #[serde(default = "utc_now")]
    pub last_opened_at: DateTime<Utc>,
}

/// Persisted layout dimensions.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LayoutSettings {
    #[serde(default = "default_sidebar_width")]
    pub sidebar_width: f32,
    #[serde(default = "default_detail_panel_width")]
    pub detail_panel_width: f32,
    #[serde(default = "default_diff_viewer_height")]
    pub diff_viewer_height: f32,
    #[serde(default = "default_commit_input_height")]
    pub commit_input_height: f32,
    /// Whether the commit graph is hidden, handing its space to the bottom
    /// panel. Files written before the option existed load with it off.
    #[serde(default)]
    pub graph_hidden: bool,
}

fn default_sidebar_width() -> f32 {
    276.0
}
fn default_detail_panel_width() -> f32 {
    352.0
}
fn default_diff_viewer_height() -> f32 {
    345.0
}
fn default_commit_input_height() -> f32 {
    385.0
}

impl Default for LayoutSettings {
    fn default() -> Self {
        Self {
            sidebar_width: default_sidebar_width(),
            detail_panel_width: default_detail_panel_width(),
            diff_viewer_height: default_diff_viewer_height(),
            commit_input_height: default_commit_input_height(),
            graph_hidden: false,
        }
    }
}

fn default_max_recent() -> usize {
    20
}

/// The AI providers rgitui can talk to.
///
/// Persisted by its lowercase id, and the single source of truth for endpoint
/// shape, auth style and default model. Dispatching on a bare string is what
/// let a hand-edited `settings.json` reach the network layer before failing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum AiProvider {
    #[default]
    Gemini,
    #[serde(rename = "openai")]
    OpenAi,
    Anthropic,
    #[serde(rename = "deepseek")]
    DeepSeek,
    #[serde(rename = "openrouter")]
    OpenRouter,
}

impl AiProvider {
    /// Every provider, in the order the settings UI lists them.
    pub const ALL: &'static [AiProvider] = &[
        AiProvider::Gemini,
        AiProvider::OpenAi,
        AiProvider::Anthropic,
        AiProvider::DeepSeek,
        AiProvider::OpenRouter,
    ];

    /// The stable id used in `settings.json`, keychain accounts and catalogue
    /// cache filenames. Changing one needs a migration.
    pub fn id(self) -> &'static str {
        match self {
            AiProvider::Gemini => "gemini",
            AiProvider::OpenAi => "openai",
            AiProvider::Anthropic => "anthropic",
            AiProvider::DeepSeek => "deepseek",
            AiProvider::OpenRouter => "openrouter",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            AiProvider::Gemini => "Google Gemini",
            AiProvider::OpenAi => "OpenAI",
            AiProvider::Anthropic => "Anthropic",
            AiProvider::DeepSeek => "DeepSeek",
            AiProvider::OpenRouter => "OpenRouter",
        }
    }

    /// Parse a persisted id. Case- and whitespace-insensitive, so a hand-edited
    /// `"Anthropic"` resolves instead of silently falling back.
    pub fn from_id(value: &str) -> Option<Self> {
        let normalized = value.trim().to_ascii_lowercase();
        Self::ALL
            .iter()
            .copied()
            .find(|provider| provider.id() == normalized)
    }

    /// The GA model a fresh install (or a provider switch with no remembered
    /// choice) uses: cheap, fast and tool-capable, because commit-message
    /// generation does not need a frontier model.
    pub fn default_model(self) -> &'static str {
        match self {
            AiProvider::Gemini => "gemini-3.1-flash-lite",
            AiProvider::OpenAi => "gpt-5.6-luna",
            AiProvider::Anthropic => "claude-haiku-4-5",
            AiProvider::DeepSeek => "deepseek-v4-flash",
            AiProvider::OpenRouter => "google/gemini-3.1-flash-lite",
        }
    }

    /// Where the user creates an API key for this provider.
    pub fn key_url(self) -> &'static str {
        match self {
            AiProvider::Gemini => "https://aistudio.google.com/apikey",
            AiProvider::OpenAi => "https://platform.openai.com/api-keys",
            AiProvider::Anthropic => "https://console.anthropic.com/settings/keys",
            AiProvider::DeepSeek => "https://platform.deepseek.com/api_keys",
            AiProvider::OpenRouter => "https://openrouter.ai/keys",
        }
    }

    /// The host requests reach by default. Shown when warning about a
    /// `base_url_override` so the user sees what they are replacing.
    pub fn default_host(self) -> &'static str {
        match self {
            AiProvider::Gemini => "generativelanguage.googleapis.com",
            AiProvider::OpenAi => "api.openai.com",
            AiProvider::Anthropic => "api.anthropic.com",
            AiProvider::DeepSeek => "api.deepseek.com",
            AiProvider::OpenRouter => "openrouter.ai",
        }
    }

    /// Whether this provider speaks the OpenAI `/chat/completions` shape.
    /// Only these honour `base_url_override`.
    pub fn is_openai_compatible(self) -> bool {
        matches!(
            self,
            AiProvider::OpenAi | AiProvider::DeepSeek | AiProvider::OpenRouter
        )
    }
}

impl fmt::Display for AiProvider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.display_name())
    }
}

/// Deserialize a provider id leniently: an unknown value falls back to the
/// default rather than failing the whole settings file. [`init`] surfaces the
/// unknown value through `load_warnings` so the fallback is never silent.
fn deserialize_ai_provider<'de, D>(deserializer: D) -> std::result::Result<AiProvider, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = String::deserialize(deserializer)?;
    Ok(AiProvider::from_id(&raw).unwrap_or_default())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSettings {
    #[serde(
        default = "default_ai_provider",
        deserialize_with = "deserialize_ai_provider"
    )]
    pub provider: AiProvider,
    #[serde(rename = "api_key", default, skip_serializing)]
    pub legacy_api_key: Option<String>,
    /// Whether the *active* provider holds a key. Derived from
    /// `has_api_key_for`; retained so existing readers keep working.
    #[serde(default)]
    pub has_api_key: bool,
    /// Which providers hold a key in the OS keychain. Flags only — never the
    /// secret itself.
    #[serde(default)]
    pub has_api_key_for: BTreeMap<String, bool>,
    #[serde(default = "default_ai_model")]
    pub model: String,
    /// Per-provider model pin, keyed by provider id. Preserves the user's
    /// choice per provider instead of resetting it on every provider switch.
    #[serde(default)]
    pub models_by_provider: BTreeMap<String, String>,
    /// Override endpoint for OpenAI-compatible providers (LiteLLM, Ollama's
    /// `/v1`, self-hosted gateways). Empty means use the built-in URL — the
    /// default is deliberately not stored here so it cannot freeze at whatever
    /// shipped.
    #[serde(default)]
    pub base_url_override: String,
    /// Send `HTTP-Referer`/`X-Title` to OpenRouter for leaderboard attribution.
    #[serde(default = "default_openrouter_attribution")]
    pub openrouter_attribution: bool,
    #[serde(default = "default_commit_style")]
    pub commit_style: String,
    #[serde(default = "default_ai_enabled")]
    pub enabled: bool,
    #[serde(default = "default_inject_project_context")]
    pub inject_project_context: bool,
    #[serde(default = "default_use_tools")]
    pub use_tools: bool,
}

impl AiSettings {
    /// The model pinned for `provider`, falling back to that provider's GA
    /// default. Never returns another provider's model.
    pub fn model_for(&self, provider: AiProvider) -> String {
        if provider == self.provider && !self.model.trim().is_empty() {
            return self.model.clone();
        }
        self.models_by_provider
            .get(provider.id())
            .filter(|model| !model.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| provider.default_model().to_string())
    }

    /// Whether `provider` has a key in the keychain, according to the persisted
    /// flags. Does not touch the keychain.
    pub fn has_key_for(&self, provider: AiProvider) -> bool {
        self.has_api_key_for
            .get(provider.id())
            .copied()
            .unwrap_or(false)
    }

    /// Record whether `provider` holds a key, keeping the active-provider
    /// mirror `has_api_key` in step.
    pub fn set_has_key_for(&mut self, provider: AiProvider, has_key: bool) {
        self.has_api_key_for
            .insert(provider.id().to_string(), has_key);
        if provider == self.provider {
            self.has_api_key = has_key;
        }
    }

    /// Point the active provider at `provider`, remembering the model the
    /// previous provider used so switching back restores it.
    pub fn set_active_provider(&mut self, provider: AiProvider) {
        let previous = self.provider;
        if !self.model.trim().is_empty() {
            self.models_by_provider
                .insert(previous.id().to_string(), self.model.clone());
        }
        // Resolve the incoming model *before* reassigning `provider`, so
        // `model_for`'s active-provider shortcut cannot hand back the model the
        // previous provider was using.
        let next_model = self
            .models_by_provider
            .get(provider.id())
            .filter(|model| !model.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| provider.default_model().to_string());
        self.provider = provider;
        self.model = next_model;
        self.has_api_key = self.has_key_for(provider);
    }

    /// Pin `model` for the active provider.
    pub fn set_active_model(&mut self, model: impl Into<String>) {
        let model = model.into();
        self.models_by_provider
            .insert(self.provider.id().to_string(), model.clone());
        self.model = model;
    }
}

fn default_use_tools() -> bool {
    true
}

fn default_ai_enabled() -> bool {
    true
}

fn default_inject_project_context() -> bool {
    true
}

fn default_openrouter_attribution() -> bool {
    true
}

fn default_ai_provider() -> AiProvider {
    AiProvider::Gemini
}

fn default_ai_model() -> String {
    default_ai_provider().default_model().into()
}

fn default_commit_style() -> String {
    "conventional".into()
}

/// Git authentication and signing settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitSettings {
    #[serde(rename = "https_token", default, skip_serializing)]
    pub legacy_https_token: Option<String>,
    #[serde(default)]
    pub has_https_token: bool,
    #[serde(default)]
    pub ssh_key_path: Option<String>,
    #[serde(default)]
    pub gpg_key_id: Option<String>,
    #[serde(default)]
    pub sign_commits: bool,
    #[serde(default = "default_git_providers")]
    pub providers: Vec<GitProviderSettings>,
}

/// A provider-specific HTTPS auth entry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GitProviderSettings {
    pub id: String,
    #[serde(default = "default_git_provider_kind")]
    pub kind: String,
    pub display_name: String,
    pub host: String,
    #[serde(default)]
    pub username: String,
    #[serde(rename = "token", default, skip_serializing)]
    pub legacy_token: Option<String>,
    #[serde(default)]
    pub has_token: bool,
    #[serde(default)]
    pub use_for_https: bool,
}

#[derive(Debug, Clone, Default)]
pub struct AuthRuntimeState {
    /// Resolved AI keys, keyed by provider id. One slot per provider so a
    /// provider switch cannot transmit the previous provider's credential.
    pub ai_api_keys: BTreeMap<String, String>,
    pub git: GitAuthRuntime,
}

#[derive(Debug, Clone, Default)]
pub struct GitAuthRuntime {
    pub default_https_token: Option<String>,
    pub ssh_key_path: Option<PathBuf>,
    pub gpg_key_id: Option<String>,
    pub sign_commits: bool,
    pub providers: Vec<GitProviderRuntime>,
}

#[derive(Debug, Clone, Default)]
pub struct GitProviderRuntime {
    pub id: String,
    pub kind: String,
    pub display_name: String,
    pub host: String,
    pub username: String,
    pub token: Option<String>,
    pub use_for_https: bool,
}

impl Default for GitSettings {
    fn default() -> Self {
        Self {
            legacy_https_token: None,
            has_https_token: false,
            ssh_key_path: None,
            gpg_key_id: None,
            sign_commits: false,
            providers: default_git_providers(),
        }
    }
}

impl Default for AiSettings {
    fn default() -> Self {
        Self {
            provider: default_ai_provider(),
            legacy_api_key: None,
            has_api_key: false,
            has_api_key_for: BTreeMap::new(),
            model: default_ai_model(),
            models_by_provider: BTreeMap::new(),
            base_url_override: String::new(),
            openrouter_attribution: default_openrouter_attribution(),
            commit_style: default_commit_style(),
            enabled: true,
            inject_project_context: default_inject_project_context(),
            use_tools: default_use_tools(),
        }
    }
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            version: default_settings_version(),
            theme: default_theme(),
            ui_font: String::new(),
            ai: AiSettings::default(),
            git: GitSettings::default(),
            recent_repos: Vec::new(),
            max_recent_repos: default_max_recent(),
            last_workspace: Vec::new(),
            layout: LayoutSettings::default(),
            workspaces: Vec::new(),
            active_workspace_id: None,
            clean_exit: true, // First run is considered clean
            compactness: Compactness::default(),
            appearance_mode: default_appearance_mode(),
            terminal_command: String::new(),
            editor_command: String::new(),
            font_size: default_font_size(),
            show_line_numbers_in_diff: default_show_line_numbers_in_diff(),
            diff_view_mode: DiffViewMode::default(),
            diff_wrap_lines: false,
            graph_style: GraphStyle::default(),
            show_subject_column: default_show_subject_column(),
            author_column_width: default_author_column_width(),
            date_column_width: default_date_column_width(),
            auto_fetch_interval: AutoFetchInterval::default(),
            confirm_destructive_operations: default_confirm_destructive(),
            auto_check_updates: default_auto_check_updates(),
            last_update_check_at: None,
            commit_limit: default_commit_limit(),
            watch_all_worktrees: false,
            settings_window_bounds: None,
        }
    }
}

/// Global settings state.
pub struct SettingsState {
    pub settings: AppSettings,
    config_path: PathBuf,
    load_warnings: Vec<String>,
}

impl Global for SettingsState {}

impl SettingsState {
    pub fn settings(&self) -> &AppSettings {
        &self.settings
    }

    pub fn settings_mut(&mut self) -> &mut AppSettings {
        &mut self.settings
    }

    pub fn take_warnings(&mut self) -> Vec<String> {
        std::mem::take(&mut self.load_warnings)
    }

    /// The most recently persisted bounds for the standalone Settings window,
    /// or `None` if the user has never moved/resized it.
    pub fn settings_window_bounds(&self) -> Option<SavedWindowBounds> {
        self.settings.settings_window_bounds
    }

    /// Update the persisted Settings window bounds. Caller is responsible for
    /// invoking [`SettingsState::save`] afterwards if write-through is desired.
    pub fn set_settings_window_bounds(&mut self, bounds: Option<SavedWindowBounds>) {
        self.settings.settings_window_bounds = bounds;
    }

    /// Persist the current settings to disk.
    ///
    /// The JSON is serialized synchronously on the calling thread so the write
    /// reflects the state at the moment of the call, then handed to a single
    /// dedicated writer thread. Because that thread drains its queue in
    /// FIFO order, the on-disk file always reflects the most recent `save`,
    /// eliminating the race where two concurrent writers could land in the
    /// wrong order.
    pub fn save(&self) -> Result<()> {
        sync_auth_runtime(&self.settings);
        let json = serde_json::to_string_pretty(&self.settings)?;
        enqueue_write(WriteRequest {
            config_path: self.config_path.clone(),
            json,
            ack: None,
        });
        Ok(())
    }

    /// Persist the current settings to disk and block until the write has
    /// completed (or failed). Use this on shutdown paths so the final state is
    /// guaranteed to reach disk before the process exits, rather than racing a
    /// detached writer thread that may be killed mid-write.
    pub fn save_blocking(&self) -> Result<()> {
        sync_auth_runtime(&self.settings);
        let json = serde_json::to_string_pretty(&self.settings)?;
        let (ack_tx, ack_rx) = sync_channel::<()>(1);
        enqueue_write(WriteRequest {
            config_path: self.config_path.clone(),
            json,
            ack: Some(ack_tx),
        });
        // The writer always sends the ack, even on write failure, so this only
        // blocks until the queued write (and every write enqueued before it)
        // has drained. A dropped sender (writer thread gone) also unblocks us.
        let _ = ack_rx.recv();
        Ok(())
    }

    pub fn set_last_workspace(&mut self, repos: Vec<PathBuf>) {
        self.settings.last_workspace = dedup_paths(repos);
    }

    /// Record that an update check just completed.
    pub fn mark_update_check_completed(&mut self) {
        self.settings.last_update_check_at = Some(Utc::now());
        if let Err(error) = self.save() {
            log::warn!("Failed to persist update-check timestamp: {}", error);
        }
    }

    pub fn add_recent_repo(&mut self, path: PathBuf) {
        self.settings.recent_repos.retain(|p| p != &path);
        self.settings.recent_repos.insert(0, path);
        self.settings
            .recent_repos
            .truncate(self.settings.max_recent_repos);
    }

    pub fn recent_workspaces(&self, limit: usize) -> Vec<StoredWorkspace> {
        let mut workspaces = self.settings.workspaces.clone();
        workspaces.sort_by_key(|w| std::cmp::Reverse(w.last_opened_at));
        if limit > 0 {
            workspaces.truncate(limit);
        }
        workspaces
    }

    pub fn active_workspace(&self) -> Option<&StoredWorkspace> {
        let active_id = self.settings.active_workspace_id.as_ref()?;
        self.settings
            .workspaces
            .iter()
            .find(|ws| &ws.id == active_id)
    }

    pub fn workspace(&self, id: &str) -> Option<&StoredWorkspace> {
        self.settings.workspaces.iter().find(|ws| ws.id == id)
    }

    pub fn clear_active_workspace(&mut self) {
        self.settings.active_workspace_id = None;
        self.settings.last_workspace.clear();
    }

    /// Mark that the app is exiting cleanly (user-initiated close).
    pub fn mark_clean_exit(&mut self) {
        self.settings.clean_exit = true;
        let _ = self.save_blocking();
    }

    /// Mark that the app is starting up (clear the clean exit flag).
    /// Returns whether the previous session ended cleanly.
    pub fn mark_startup(&mut self) -> bool {
        let was_clean = self.settings.clean_exit;
        self.settings.clean_exit = false;
        let _ = self.save();
        was_clean
    }

    /// Check if the last session ended cleanly without modifying state.
    pub fn was_clean_exit(&self) -> bool {
        self.settings.clean_exit
    }

    pub fn save_workspace_snapshot(
        &mut self,
        workspace_id: Option<&str>,
        repos: Vec<PathBuf>,
        active_repo_index: usize,
        layout: LayoutSettings,
    ) -> Option<String> {
        let repos = dedup_paths(repos);
        if repos.is_empty() {
            self.clear_active_workspace();
            return None;
        }

        let now = Utc::now();
        let existing_index = workspace_id
            .and_then(|id| self.settings.workspaces.iter().position(|ws| ws.id == id))
            .or_else(|| {
                self.settings
                    .workspaces
                    .iter()
                    .position(|ws| ws.repos == repos)
            });

        let active_repo_index = active_repo_index.min(repos.len().saturating_sub(1));
        let id = if let Some(index) = existing_index {
            let workspace = &mut self.settings.workspaces[index];
            workspace.repos = repos.clone();
            workspace.active_repo_index = active_repo_index;
            workspace.layout = layout.clone();
            workspace.last_opened_at = now;
            workspace.id.clone()
        } else {
            let workspace = StoredWorkspace {
                id: Uuid::new_v4().to_string(),
                name: workspace_name_from_repos(&repos),
                repos: repos.clone(),
                active_repo_index,
                layout,
                created_at: now,
                last_opened_at: now,
            };
            let id = workspace.id.clone();
            self.settings.workspaces.push(workspace);
            id
        };

        self.settings.active_workspace_id = Some(id.clone());
        self.settings.last_workspace = repos;
        Some(id)
    }

    pub fn activate_workspace(&mut self, workspace_id: &str) -> bool {
        if let Some(workspace) = self
            .settings
            .workspaces
            .iter_mut()
            .find(|workspace| workspace.id == workspace_id)
        {
            workspace.last_opened_at = Utc::now();
            self.settings.active_workspace_id = Some(workspace.id.clone());
            self.settings.last_workspace = workspace.repos.clone();
            true
        } else {
            false
        }
    }

    pub fn migrate_legacy_workspace_data(&mut self) {
        self.settings.recent_repos = dedup_paths(self.settings.recent_repos.clone());
        self.settings.last_workspace = dedup_paths(self.settings.last_workspace.clone());

        if self.settings.workspaces.is_empty() && !self.settings.last_workspace.is_empty() {
            let now = Utc::now();
            let workspace = StoredWorkspace {
                id: Uuid::new_v4().to_string(),
                name: workspace_name_from_repos(&self.settings.last_workspace),
                repos: self.settings.last_workspace.clone(),
                active_repo_index: 0,
                layout: self.settings.layout.clone(),
                created_at: now,
                last_opened_at: now,
            };
            self.settings.active_workspace_id = Some(workspace.id.clone());
            self.settings.workspaces.push(workspace);
        }

        if let Some(active_id) = self.settings.active_workspace_id.clone() {
            if !self
                .settings
                .workspaces
                .iter()
                .any(|workspace| workspace.id == active_id)
            {
                self.settings.active_workspace_id = self
                    .settings
                    .workspaces
                    .iter()
                    .max_by_key(|workspace| workspace.last_opened_at)
                    .map(|workspace| workspace.id.clone());
            }
        }
    }

    /// Run version-based migrations. Returns true if any migration was applied.
    pub fn migrate_settings(&mut self) -> bool {
        let mut migrated = false;
        let original_version = self.settings.version;

        // Migration 0 -> 1: Settings without version field (serde default)
        // No action needed - serde defaults handle this
        if self.settings.version == 0 {
            self.settings.version = 1;
            migrated = true;
            log::info!("Migrated settings from version 0 to 1");
        }

        // Migration 1 -> 2: Add graph column width settings
        if self.settings.version == 1 {
            self.settings.author_column_width = default_author_column_width();
            self.settings.date_column_width = default_date_column_width();
            self.settings.version = 2;
            migrated = true;
            log::info!("Migrated settings from version 1 to 2");
        }

        // Migration 2 -> 3: AI keys became per-provider, and the shipped
        // default model was a retired id absent from the picker. Remap the
        // known-dead ids to their successors rather than leaving a pin that
        // renders as no selection at all and 404s when used.
        if self.settings.version == 2 {
            if let Some(successor) = retired_model_successor(&self.settings.ai.model) {
                log::info!(
                    "Remapping retired AI model '{}' to '{}'",
                    self.settings.ai.model,
                    successor
                );
                self.settings.ai.model = successor.to_string();
            }
            self.settings.version = 3;
            migrated = true;
            log::info!("Migrated settings from version 2 to 3");
        }

        // Ensure version is current
        if self.settings.version < CURRENT_SETTINGS_VERSION {
            self.settings.version = CURRENT_SETTINGS_VERSION;
            migrated = true;
            log::info!(
                "Updated settings version from {} to {}",
                original_version,
                CURRENT_SETTINGS_VERSION
            );
        }

        migrated
    }

    /// The API key for the active AI provider.
    pub fn ai_api_key(&self) -> Option<String> {
        self.ai_api_key_for(self.settings.ai.provider)
    }

    /// The API key stored for a specific provider, materialized only for the
    /// caller that asked for it.
    pub fn ai_api_key_for(&self, provider: AiProvider) -> Option<String> {
        with_auth_runtime(|runtime| runtime.ai_api_keys.get(provider.id()).cloned())
    }

    /// Whether the active provider has a key, without cloning any secret.
    ///
    /// Render paths must use this rather than `ai_api_key().is_some()`, which
    /// deep-clones every credential the app holds on every frame.
    pub fn has_ai_api_key(&self) -> bool {
        self.settings.ai.has_key_for(self.settings.ai.provider)
    }

    /// Whether `provider` has a key, without cloning any secret.
    pub fn has_ai_api_key_for(&self, provider: AiProvider) -> bool {
        self.settings.ai.has_key_for(provider)
    }

    pub fn git_https_token(&self) -> Option<String> {
        current_auth_runtime().git.default_https_token
    }

    pub fn provider_token(&self, provider_id: &str) -> Option<String> {
        current_auth_runtime()
            .git
            .providers
            .into_iter()
            .find(|provider| provider.id == provider_id)
            .and_then(|provider| provider.token)
    }

    /// Store (or clear) the API key for the active provider.
    pub fn set_ai_api_key(&mut self, value: Option<&str>) -> Result<()> {
        self.set_ai_api_key_for(self.settings.ai.provider, value)
    }

    /// Store (or clear) the API key for a specific provider.
    ///
    /// The keychain write happens *before* any settings mutation, so a failed
    /// write leaves the recorded flags and the resolved runtime key agreeing
    /// with what is actually in the keychain.
    pub fn set_ai_api_key_for(&mut self, provider: AiProvider, value: Option<&str>) -> Result<()> {
        let has_key = write_secret(&ai_provider_account(provider.id()), value)?;
        self.settings.ai.legacy_api_key = None;
        self.settings.ai.set_has_key_for(provider, has_key);
        sync_auth_runtime(&self.settings);
        Ok(())
    }

    pub fn set_git_https_token(&mut self, value: Option<&str>) -> Result<()> {
        self.settings.git.legacy_https_token = None;
        self.settings.git.has_https_token = write_secret(GIT_DEFAULT_HTTPS_ACCOUNT, value)?;
        sync_auth_runtime(&self.settings);
        Ok(())
    }

    pub fn replace_git_providers(&mut self, providers: Vec<GitProviderSettings>) {
        let removed_ids: Vec<String> = self
            .settings
            .git
            .providers
            .iter()
            .filter(|existing| !providers.iter().any(|provider| provider.id == existing.id))
            .map(|provider| provider.id.clone())
            .collect();

        self.settings.git.providers = providers;
        for provider_id in removed_ids {
            let _ = delete_secret(&git_provider_account(&provider_id));
        }
        sync_auth_runtime(&self.settings);
    }

    pub fn set_git_provider_token(&mut self, provider_id: &str, value: Option<&str>) -> Result<()> {
        // Write the secret unconditionally, keyed by provider id. A provider that
        // was just added in the settings window is not yet present in
        // `self.settings.git.providers` (it only arrives via
        // `replace_git_providers`), so guarding the keyring write on its presence
        // here would silently drop the token on first save.
        let has_token = write_secret(&git_provider_account(provider_id), value)?;
        if let Some(provider) = self
            .settings
            .git
            .providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
        {
            provider.legacy_token = None;
            provider.has_token = has_token;
        }
        sync_auth_runtime(&self.settings);
        Ok(())
    }

    pub fn migrate_legacy_secrets(&mut self) -> Result<bool> {
        let mut migrated = false;

        if let Some(api_key) = self.settings.ai.legacy_api_key.clone() {
            if !self.settings.ai.has_api_key && write_secret(AI_SECRET_ACCOUNT, Some(&api_key))? {
                self.settings.ai.has_api_key = true;
                self.settings.ai.legacy_api_key = None;
                migrated = true;
            }
        }

        // Promote the single `ai/default` secret into the slot for whichever
        // provider was active when it was written. `ai/default` is left in
        // place so a downgrade still finds its key; a later save of that
        // provider overwrites the new slot. Idempotent: the promotion is
        // skipped once the per-provider slot exists.
        if self.settings.ai.has_api_key {
            let active = self.settings.ai.provider;
            let account = ai_provider_account(active.id());
            if read_secret(&account).is_none() {
                if let Some(key) = read_secret(AI_SECRET_ACCOUNT) {
                    if write_secret(&account, Some(&key))? {
                        self.settings.ai.set_has_key_for(active, true);
                        migrated = true;
                        log::info!(
                            "Promoted the shared AI key into the '{}' provider slot",
                            active.id()
                        );
                    }
                }
            }
        }

        // Re-derive the per-provider flags from what the keychain actually
        // holds. A flag that says "connected" for a provider with no key is
        // exactly the false-connected state the per-provider split fixes.
        for provider in AiProvider::ALL {
            let present = read_secret(&ai_provider_account(provider.id())).is_some();
            if self.settings.ai.has_key_for(*provider) != present {
                self.settings.ai.set_has_key_for(*provider, present);
                migrated = true;
            }
        }

        if let Some(token) = self.settings.git.legacy_https_token.clone() {
            if !self.settings.git.has_https_token
                && write_secret(GIT_DEFAULT_HTTPS_ACCOUNT, Some(&token))?
            {
                self.settings.git.has_https_token = true;
                self.settings.git.legacy_https_token = None;
                migrated = true;
            }
        }

        for provider in &mut self.settings.git.providers {
            if let Some(token) = provider.legacy_token.clone() {
                if !provider.has_token
                    && write_secret(&git_provider_account(&provider.id), Some(&token))?
                {
                    provider.has_token = true;
                    provider.legacy_token = None;
                    migrated = true;
                }
            }
        }

        sync_auth_runtime(&self.settings);
        Ok(migrated)
    }
}

/// Where settings, the keymap, themes and cached avatars live.
pub fn config_dir() -> PathBuf {
    state_root().config.clone()
}

/// Where regenerable caches live — history, and anything else that is an
/// optimisation rather than user data.
pub fn cache_dir() -> PathBuf {
    state_root().cache.clone()
}

/// The two directories rgitui persists to, resolved once per process.
struct StateRoot {
    config: PathBuf,
    cache: PathBuf,
}

static STATE_ROOT: OnceLock<StateRoot> = OnceLock::new();

fn state_root() -> &'static StateRoot {
    STATE_ROOT.get_or_init(|| StateRoot {
        config: dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("rgitui"),
        cache: dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("rgitui"),
    })
}

/// Points config and cache at `root` instead of the user's real directories.
///
/// This exists for measurement. A benchmark that reads and writes the same
/// settings file and history cache as the installed app is measuring whatever
/// the last run happened to leave behind, and leaves its own corpus in the
/// user's recent-repository list on the way out. Redirecting both to a scratch
/// directory is what makes a run start from a known state and end without a
/// trace of itself.
///
/// Call before anything reads either path — first read wins, and this returns
/// `false` if it lost that race rather than pretending to have taken effect.
#[must_use]
pub fn redirect_state_to(root: &Path) -> bool {
    STATE_ROOT
        .set(StateRoot {
            config: root.join("config"),
            cache: root.join("cache"),
        })
        .is_ok()
}

/// File name of the settings file inside [`config_dir`].
const SETTINGS_FILE_NAME: &str = "settings.json";

/// File name of the user keymap inside [`config_dir`].
const KEYMAP_FILE_NAME: &str = "keymap.json";

/// Path of the settings file.
pub fn settings_path() -> PathBuf {
    config_dir().join(SETTINGS_FILE_NAME)
}

/// Path of the user keymap, alongside the settings file.
pub fn keymap_path() -> PathBuf {
    config_dir().join(KEYMAP_FILE_NAME)
}

/// A single queued settings write. `json` is pre-serialized on the caller's
/// thread so the snapshot reflects state at call time; `ack`, when present,
/// is fired after the write attempt completes so a blocking caller can wait.
struct WriteRequest {
    config_path: PathBuf,
    json: String,
    ack: Option<SyncSender<()>>,
}

/// Sender for the dedicated settings writer thread. Wrapped in a `Mutex`
/// because the `Sync`-ness of `Sender` is not guaranteed across toolchains and
/// the sender is shared through a process-wide `OnceLock`.
fn write_sender() -> &'static Mutex<Sender<WriteRequest>> {
    static WRITE_SENDER: OnceLock<Mutex<Sender<WriteRequest>>> = OnceLock::new();
    WRITE_SENDER.get_or_init(|| {
        let (tx, rx) = channel::<WriteRequest>();
        std::thread::Builder::new()
            .name("rgitui-settings-writer".to_string())
            .spawn(move || {
                // A single writer drains the queue in FIFO order, so on-disk
                // state always matches the order saves were requested.
                while let Ok(request) = rx.recv() {
                    write_settings_file(&request.config_path, &request.json);
                    // Fire the ack on every path (including write failure) so a
                    // `save_blocking` caller never deadlocks on a failed write.
                    if let Some(ack) = request.ack {
                        let _ = ack.send(());
                    }
                }
            })
            .expect("failed to spawn settings writer thread");
        Mutex::new(tx)
    })
}

fn enqueue_write(request: WriteRequest) {
    let sender = write_sender()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if sender.send(request).is_err() {
        log::error!("Settings writer thread is no longer running; write dropped");
    }
}

/// Perform the actual atomic write of serialized settings JSON: write to a
/// temp file then rename over the target, falling back to a direct write if the
/// rename fails.
fn write_settings_file(config_path: &Path, json: &str) {
    if let Some(parent) = config_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            log::error!("Failed to create settings directory: {}", e);
            return;
        }
    }
    let tmp_path = config_path.with_extension("json.tmp");
    if let Err(e) = std::fs::write(&tmp_path, json) {
        log::error!("Failed to write settings temp file: {}", e);
        return;
    }
    if let Err(e) = std::fs::rename(&tmp_path, config_path) {
        log::error!("Failed to rename settings file: {}", e);
        if let Err(e2) = std::fs::write(config_path, json) {
            log::error!("Fallback write also failed: {}", e2);
        }
        let _ = std::fs::remove_file(&tmp_path);
    }
}

/// Initialize settings. Must be called during app init.
pub fn init(cx: &mut App) {
    let config_path = settings_path();
    let mut load_warnings = Vec::new();
    let settings = if config_path.exists() {
        match std::fs::read_to_string(&config_path) {
            Ok(json) => match serde_json::from_str::<AppSettings>(&json) {
                Ok(settings) => {
                    // The provider deserializer falls back rather than failing
                    // the whole file, so re-read the raw value to tell the user
                    // which id was not understood. Without this the settings UI
                    // would simply show a different provider selected than the
                    // one in their file.
                    if let Some(raw) = raw_ai_provider(&json) {
                        if AiProvider::from_id(&raw).is_none() {
                            let msg = format!(
                                "Unknown AI provider \"{}\" in settings.json; using {}. Valid values: {}.",
                                raw,
                                settings.ai.provider.id(),
                                AiProvider::ALL
                                    .iter()
                                    .map(|provider| provider.id())
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                            log::warn!("{}", msg);
                            load_warnings.push(msg);
                        }
                    }
                    settings
                }
                Err(e) => {
                    // Preserve the unparseable file so the user can recover any
                    // hand-edited content instead of silently overwriting it with
                    // defaults. The timestamp suffix avoids `:` because that is an
                    // illegal filename character on Windows.
                    let stamp = Utc::now().format("%Y%m%d%H%M%S");
                    let backup_name = format!(
                        "{}.corrupt-{}",
                        config_path
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                            .unwrap_or_else(|| "settings.json".to_string()),
                        stamp
                    );
                    let backup_path = config_path.with_file_name(backup_name);
                    let msg = match std::fs::rename(&config_path, &backup_path) {
                        Ok(()) => format!(
                            "Settings file could not be parsed and was preserved at {}. Defaults are in use: {}",
                            backup_path.display(),
                            e
                        ),
                        Err(rename_err) => format!(
                            "Settings file could not be parsed (using defaults). Failed to back up the original ({}): {}",
                            rename_err, e
                        ),
                    };
                    log::warn!("{}", msg);
                    load_warnings.push(msg);
                    AppSettings::default()
                }
            },
            Err(e) => {
                let msg = format!("Failed to read settings file (using defaults): {}", e);
                log::warn!("{}", msg);
                load_warnings.push(msg);
                AppSettings::default()
            }
        }
    } else {
        AppSettings::default()
    };

    let mut state = SettingsState {
        settings,
        config_path,
        load_warnings,
    };

    // Run version-based migrations first
    state.migrate_settings();

    // Run legacy data migrations
    state.migrate_legacy_workspace_data();
    if let Err(error) = state.migrate_legacy_secrets() {
        log::warn!("Failed to migrate secrets into keychain: {}", error);
    }

    // Resolve secrets from the keyring into the auth runtime on every startup —
    // not only when migration failed. (`save()` below also syncs, but doing it
    // here keeps the runtime correct even if the save is skipped or fails.)
    sync_auth_runtime(state.settings());

    if let Err(error) = state.save() {
        log::warn!("Failed to persist migrated settings: {}", error);
    }
    cx.set_global(state);
}

/// The raw `ai.provider` string as it appears on disk, before the lenient
/// deserializer has had a chance to substitute a fallback.
fn raw_ai_provider(json: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()?
        .get("ai")?
        .get("provider")?
        .as_str()
        .map(str::to_string)
}

/// Install default settings for a test app.
///
/// Any view that reads `cx.global::<SettingsState>()` in `render` needs this
/// before a headless test window draws it. Unlike [`init`], nothing is read
/// from or written to the user's config directory and the OS keychain is left
/// alone, so tests cannot disturb (or be disturbed by) real user state. The
/// config path points into the temp directory purely so a stray `save()` in a
/// view under test cannot land on the real file.
pub fn init_test(cx: &mut App) {
    cx.set_global(SettingsState {
        settings: AppSettings::default(),
        config_path: std::env::temp_dir().join("rgitui-test-settings.json"),
        load_warnings: Vec::new(),
    });
}

/// Borrow the resolved credentials under the lock and return only what the
/// caller needs.
///
/// Prefer this over [`current_auth_runtime`], which deep-clones every secret
/// the app holds — including ones the caller has no use for — into fresh heap
/// allocations that are dropped without zeroization.
pub fn with_auth_runtime<R>(f: impl FnOnce(&AuthRuntimeState) -> R) -> R {
    let guard = auth_runtime().read().expect(
        "git auth runtime RwLock poisoned - a previous thread panicked while holding the lock",
    );
    f(&guard)
}

pub fn current_auth_runtime() -> AuthRuntimeState {
    with_auth_runtime(|runtime| runtime.clone())
}

pub fn current_git_auth_runtime() -> GitAuthRuntime {
    current_auth_runtime().git
}

fn utc_now() -> DateTime<Utc> {
    Utc::now()
}

fn dedup_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut deduped = Vec::new();
    for path in paths {
        if seen.insert(path.clone()) {
            deduped.push(path);
        }
    }
    deduped
}

fn workspace_name_from_repos(repos: &[PathBuf]) -> String {
    match repos {
        [] => "Workspace".to_string(),
        [repo] => repo
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| repo.display().to_string()),
        _ => {
            let names = repos
                .iter()
                .take(2)
                .filter_map(|repo| repo.file_name())
                .map(|name| name.to_string_lossy().to_string())
                .collect::<Vec<_>>();
            if names.is_empty() {
                format!("Workspace ({})", repos.len())
            } else if repos.len() == 2 {
                names.join(" + ")
            } else {
                format!("{} +{}", names.join(", "), repos.len() - names.len())
            }
        }
    }
}

fn default_git_provider_kind() -> String {
    "generic".to_string()
}

fn default_git_providers() -> Vec<GitProviderSettings> {
    vec![]
}

const KEYRING_SERVICE: &str = "rgitui";
/// The pre-v3 single AI key slot. Retained so the v2 -> v3 migration can read
/// it and so a downgrade still finds a key; new writes never target it.
const AI_SECRET_ACCOUNT: &str = "ai/default";
const GIT_DEFAULT_HTTPS_ACCOUNT: &str = "git/default-https";

fn git_provider_account(provider_id: &str) -> String {
    format!("git/provider/{}", provider_id)
}

fn ai_provider_account(provider_id: &str) -> String {
    format!("ai/provider/{}", provider_id)
}

/// Model ids that are retired or fabricated, mapped to the successor a user
/// pinned to them should land on. Applied once, by the v2 -> v3 migration.
fn retired_model_successor(model: &str) -> Option<&'static str> {
    match model.trim() {
        // Retired 2026-06-01, and the shipped default that appeared in no
        // picker, so a fresh install rendered the Model row with nothing
        // selected.
        "gemini-2.0-flash" | "gemini-1.5-flash" | "gemini-1.5-pro" => Some("gemini-3.1-flash-lite"),
        // `20241022` is the Claude 3.5 snapshot date on a 4.5 name: a
        // guaranteed 404 that was offered in the picker.
        "claude-sonnet-4-5-20241022" => Some("claude-haiku-4-5"),
        // o-series rejects `max_tokens` and a non-default `temperature`, and
        // both are being retired.
        "o3" | "o4-mini" | "o1" | "o1-mini" => Some("gpt-5.6-luna"),
        _ => None,
    }
}

fn auth_runtime() -> &'static RwLock<AuthRuntimeState> {
    static AUTH_RUNTIME: OnceLock<RwLock<AuthRuntimeState>> = OnceLock::new();
    AUTH_RUNTIME.get_or_init(|| RwLock::new(AuthRuntimeState::default()))
}

fn sync_auth_runtime(settings: &AppSettings) {
    let runtime = AuthRuntimeState {
        ai_api_keys: resolve_ai_api_keys(&settings.ai),
        git: GitAuthRuntime {
            default_https_token: resolve_git_https_token(&settings.git),
            ssh_key_path: settings.git.ssh_key_path.as_ref().map(PathBuf::from),
            gpg_key_id: settings.git.gpg_key_id.clone(),
            sign_commits: settings.git.sign_commits,
            providers: settings
                .git
                .providers
                .iter()
                .map(|provider| GitProviderRuntime {
                    id: provider.id.clone(),
                    kind: provider.kind.clone(),
                    display_name: provider.display_name.clone(),
                    host: provider.host.clone(),
                    username: provider.username.clone(),
                    token: resolve_provider_token(provider),
                    use_for_https: provider.use_for_https,
                })
                .collect(),
        },
    };

    *auth_runtime().write().expect(
        "git auth runtime RwLock poisoned - a previous thread panicked while holding the lock",
    ) = runtime;
}

/// Resolve every provider's key from the keychain in one pass.
///
/// Mirrors the git-provider loop: one read per provider that claims a key, and
/// none for the rest, so adding a provider does not multiply the cost of an
/// unrelated save.
fn resolve_ai_api_keys(settings: &AiSettings) -> BTreeMap<String, String> {
    let mut keys = BTreeMap::new();
    for provider in AiProvider::ALL {
        if !settings.has_key_for(*provider) {
            continue;
        }
        if let Some(secret) = read_secret(&ai_provider_account(provider.id())) {
            keys.insert(provider.id().to_string(), secret);
        }
    }

    // Pre-v3 files, and any install whose migration could not write to the
    // keychain, still resolve through the shared slot for the active provider.
    if !keys.contains_key(settings.provider.id()) {
        let legacy = if settings.has_api_key {
            read_secret(AI_SECRET_ACCOUNT).or_else(|| settings.legacy_api_key.clone())
        } else {
            settings.legacy_api_key.clone()
        };
        if let Some(secret) = legacy {
            keys.insert(settings.provider.id().to_string(), secret);
        }
    }

    keys
}

fn resolve_git_https_token(settings: &GitSettings) -> Option<String> {
    if settings.has_https_token {
        read_secret(GIT_DEFAULT_HTTPS_ACCOUNT).or_else(|| settings.legacy_https_token.clone())
    } else {
        settings.legacy_https_token.clone()
    }
}

fn resolve_provider_token(provider: &GitProviderSettings) -> Option<String> {
    if provider.has_token {
        read_secret(&git_provider_account(&provider.id)).or_else(|| provider.legacy_token.clone())
    } else {
        provider.legacy_token.clone()
    }
}

fn secret_entry(account: &str) -> Result<Entry> {
    Ok(Entry::new(KEYRING_SERVICE, account)?)
}

fn write_secret(account: &str, value: Option<&str>) -> Result<bool> {
    let entry = secret_entry(account)?;
    match value {
        Some(secret) if !secret.trim().is_empty() => {
            entry.set_password(secret)?;
            Ok(true)
        }
        _ => {
            let _ = entry.delete_credential();
            Ok(false)
        }
    }
}

fn read_secret(account: &str) -> Option<String> {
    let entry = match secret_entry(account) {
        Ok(e) => e,
        Err(e) => {
            log::warn!("Failed to create keyring entry for '{}': {}", account, e);
            return None;
        }
    };
    match entry.get_password() {
        Ok(password) => Some(password),
        Err(keyring::Error::NoEntry) => None,
        Err(e) => {
            log::warn!("Failed to read secret for '{}': {}", account, e);
            None
        }
    }
}

fn delete_secret(account: &str) -> Result<()> {
    let entry = secret_entry(account)?;
    let _ = entry.delete_credential();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_settings_state() -> SettingsState {
        SettingsState {
            settings: AppSettings::default(),
            config_path: PathBuf::from("/tmp/rgitui-test-settings.json"),
            load_warnings: Vec::new(),
        }
    }

    // ── Layout ────────────────────────────────────────────────────

    /// A layout saved before the graph could be hidden must keep showing it.
    #[test]
    fn layout_without_graph_hidden_shows_the_graph() {
        let layout: LayoutSettings = serde_json::from_str(
            r#"{"sidebar_width":300.0,"detail_panel_width":400.0,"diff_viewer_height":500.0,"commit_input_height":350.0}"#,
        )
        .expect("legacy layout parses");
        assert!(!layout.graph_hidden);
        assert_eq!(layout.diff_viewer_height, 500.0);
    }

    #[test]
    fn graph_hidden_round_trips() {
        let layout = LayoutSettings {
            graph_hidden: true,
            ..LayoutSettings::default()
        };
        let json = serde_json::to_string(&layout).expect("layout serializes");
        let restored: LayoutSettings = serde_json::from_str(&json).expect("layout parses");
        assert_eq!(restored, layout);
    }

    // ── AI provider catalogue coherence ───────────────────────────

    /// The bug this guards is not hypothetical: the shipped default was
    /// `gemini-2.0-flash`, which appeared in no picker, so a fresh install
    /// rendered the Model row with nothing selected at all.
    #[test]
    fn default_model_is_the_default_provider_model() {
        assert_eq!(default_ai_model(), default_ai_provider().default_model());
    }

    #[test]
    fn every_provider_has_a_distinct_id_and_a_default_model() {
        let mut ids: Vec<&str> = AiProvider::ALL.iter().map(|p| p.id()).collect();
        let count = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), count, "provider ids must be unique");

        for provider in AiProvider::ALL {
            assert!(!provider.default_model().is_empty());
            assert!(provider.key_url().starts_with("https://"));
            assert!(!provider.display_name().is_empty());
            assert_eq!(AiProvider::from_id(provider.id()), Some(*provider));
        }
    }

    #[test]
    fn no_default_model_is_a_retired_id() {
        for provider in AiProvider::ALL {
            assert_eq!(
                retired_model_successor(provider.default_model()),
                None,
                "{} ships a retired default",
                provider.id()
            );
        }
    }

    #[test]
    fn provider_id_parsing_is_lenient_about_case_and_whitespace() {
        assert_eq!(
            AiProvider::from_id("Anthropic"),
            Some(AiProvider::Anthropic)
        );
        assert_eq!(AiProvider::from_id("  OpenAI "), Some(AiProvider::OpenAi));
        assert_eq!(
            AiProvider::from_id("openrouter"),
            Some(AiProvider::OpenRouter)
        );
        assert_eq!(AiProvider::from_id("bard"), None);
    }

    #[test]
    fn only_openai_compatible_providers_accept_a_base_url_override() {
        assert!(AiProvider::OpenAi.is_openai_compatible());
        assert!(AiProvider::DeepSeek.is_openai_compatible());
        assert!(AiProvider::OpenRouter.is_openai_compatible());
        assert!(!AiProvider::Gemini.is_openai_compatible());
        assert!(!AiProvider::Anthropic.is_openai_compatible());
    }

    // ── AiSettings model memory ───────────────────────────────────

    #[test]
    fn switching_provider_preserves_each_providers_model_choice() {
        let mut ai = AiSettings::default();
        ai.set_active_model("gemini-3.1-pro-preview");

        ai.set_active_provider(AiProvider::OpenAi);
        assert_eq!(ai.model, AiProvider::OpenAi.default_model());
        ai.set_active_model("gpt-5.4");

        ai.set_active_provider(AiProvider::Gemini);
        assert_eq!(ai.model, "gemini-3.1-pro-preview");

        ai.set_active_provider(AiProvider::OpenAi);
        assert_eq!(ai.model, "gpt-5.4");
    }

    #[test]
    fn model_for_never_returns_another_providers_model() {
        let mut ai = AiSettings::default();
        ai.set_active_model("gemini-3.1-pro-preview");
        assert_eq!(
            ai.model_for(AiProvider::Anthropic),
            AiProvider::Anthropic.default_model()
        );
    }

    #[test]
    fn key_flags_are_tracked_per_provider() {
        let mut ai = AiSettings::default();
        ai.set_has_key_for(AiProvider::Gemini, true);
        assert!(ai.has_key_for(AiProvider::Gemini));
        assert!(ai.has_api_key, "the active provider mirror must follow");
        assert!(!ai.has_key_for(AiProvider::Anthropic));

        // Switching to a provider with no key must not keep asserting
        // "connected" — that false state is what enabled the AI button for a
        // provider the app had no credential for.
        ai.set_active_provider(AiProvider::Anthropic);
        assert!(!ai.has_api_key);
    }

    // ── settings file compatibility ───────────────────────────────

    #[test]
    fn v2_settings_load_with_every_new_field_defaulted() {
        let json = r#"{
            "version": 2,
            "ai": { "provider": "openai", "model": "gpt-5.4", "has_api_key": true }
        }"#;
        let settings: AppSettings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.ai.provider, AiProvider::OpenAi);
        assert_eq!(settings.ai.model, "gpt-5.4");
        assert!(settings.ai.has_api_key_for.is_empty());
        assert!(settings.ai.models_by_provider.is_empty());
        assert!(settings.ai.base_url_override.is_empty());
        assert!(settings.ai.openrouter_attribution);
    }

    #[test]
    fn an_unknown_provider_falls_back_instead_of_failing_the_file() {
        let json = r#"{ "version": 3, "ai": { "provider": "bard" } }"#;
        let settings: AppSettings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.ai.provider, AiProvider::default());
        // And the raw value is still recoverable, which is what lets `init`
        // tell the user which id it did not understand.
        assert_eq!(raw_ai_provider(json).as_deref(), Some("bard"));
    }

    #[test]
    fn a_miscased_provider_resolves_rather_than_falling_back() {
        let json = r#"{ "ai": { "provider": "Anthropic" } }"#;
        let settings: AppSettings = serde_json::from_str(json).unwrap();
        assert_eq!(settings.ai.provider, AiProvider::Anthropic);
    }

    #[test]
    fn the_api_key_never_reaches_the_settings_file() {
        let mut settings = AppSettings::default();
        settings.ai.legacy_api_key = Some("sk-should-never-be-written".into());
        let json = serde_json::to_string(&settings).unwrap();
        assert!(!json.contains("sk-should-never-be-written"));
    }

    #[test]
    fn v2_to_v3_remaps_retired_model_ids() {
        let mut state = test_settings_state();
        state.settings.version = 2;
        state.settings.ai.model = "gemini-2.0-flash".into();

        assert!(state.migrate_settings());

        assert_eq!(state.settings.version, CURRENT_SETTINGS_VERSION);
        assert_eq!(state.settings.ai.model, "gemini-3.1-flash-lite");
    }

    #[test]
    fn v2_to_v3_leaves_a_live_model_alone() {
        let mut state = test_settings_state();
        state.settings.version = 2;
        state.settings.ai.model = "gemini-2.5-pro".into();

        state.migrate_settings();

        assert_eq!(state.settings.ai.model, "gemini-2.5-pro");
    }

    #[test]
    fn retired_ids_map_to_a_successor_of_the_same_provider_family() {
        assert_eq!(
            retired_model_successor("claude-sonnet-4-5-20241022"),
            Some("claude-haiku-4-5")
        );
        assert_eq!(retired_model_successor("o4-mini"), Some("gpt-5.6-luna"));
        assert_eq!(retired_model_successor("deepseek-v4-flash"), None);
    }

    #[test]
    fn ai_provider_accounts_are_distinct_and_namespaced() {
        let accounts: Vec<String> = AiProvider::ALL
            .iter()
            .map(|p| ai_provider_account(p.id()))
            .collect();
        assert_eq!(accounts[0], "ai/provider/gemini");
        for account in &accounts {
            assert!(account.starts_with("ai/provider/"));
            assert_ne!(account, AI_SECRET_ACCOUNT);
            assert!(!account.starts_with("git/"));
        }
    }

    #[test]
    fn migrates_legacy_last_workspace_into_workspace_snapshot() {
        let mut state = test_settings_state();
        state.settings.last_workspace =
            vec![PathBuf::from("/tmp/repo-a"), PathBuf::from("/tmp/repo-b")];

        state.migrate_legacy_workspace_data();

        assert_eq!(state.settings.workspaces.len(), 1);
        assert_eq!(state.settings.workspaces[0].repos.len(), 2);
        assert_eq!(
            state.settings.active_workspace_id,
            Some(state.settings.workspaces[0].id.clone())
        );
    }

    #[test]
    fn save_workspace_snapshot_updates_existing_workspace() {
        let mut state = test_settings_state();
        let first_id = state
            .save_workspace_snapshot(
                None,
                vec![PathBuf::from("/tmp/repo-a")],
                0,
                LayoutSettings::default(),
            )
            .expect("save_workspace_snapshot should return an id for non-empty repo lists");

        let second_id = state
            .save_workspace_snapshot(
                Some(&first_id),
                vec![PathBuf::from("/tmp/repo-a"), PathBuf::from("/tmp/repo-b")],
                1,
                LayoutSettings::default(),
            )
            .expect("save_workspace_snapshot should return an id for non-empty repo lists");

        assert_eq!(first_id, second_id);
        assert_eq!(state.settings.workspaces.len(), 1);
        assert_eq!(state.settings.workspaces[0].repos.len(), 2);
        assert_eq!(state.settings.workspaces[0].active_repo_index, 1);
    }

    #[test]
    fn recent_workspaces_are_sorted_newest_first() {
        let mut state = test_settings_state();
        let now = Utc::now();
        state.settings.workspaces = vec![
            StoredWorkspace {
                id: "older".into(),
                name: "Older".into(),
                repos: vec![PathBuf::from("/tmp/older")],
                active_repo_index: 0,
                layout: LayoutSettings::default(),
                created_at: now,
                last_opened_at: now,
            },
            StoredWorkspace {
                id: "newer".into(),
                name: "Newer".into(),
                repos: vec![PathBuf::from("/tmp/newer")],
                active_repo_index: 0,
                layout: LayoutSettings::default(),
                created_at: now,
                last_opened_at: now + chrono::TimeDelta::seconds(10),
            },
        ];

        let recent = state.recent_workspaces(10);

        assert_eq!(recent[0].id, "newer");
        assert_eq!(recent[1].id, "older");
    }

    #[test]
    fn migrate_settings_updates_version() {
        let mut state = test_settings_state();
        // Simulate old settings without version (defaults to 1 via serde)
        state.settings.version = 0;

        let migrated = state.migrate_settings();

        assert!(migrated);
        assert_eq!(state.settings.version, CURRENT_SETTINGS_VERSION);
    }

    #[test]
    fn migrate_settings_no_migration_needed_for_current_version() {
        let mut state = test_settings_state();
        state.settings.version = CURRENT_SETTINGS_VERSION;

        let migrated = state.migrate_settings();

        assert!(!migrated);
        assert_eq!(state.settings.version, CURRENT_SETTINGS_VERSION);
    }

    // --- dedup_paths ---

    #[test]
    fn dedup_paths_removes_duplicates() {
        let paths = vec![
            PathBuf::from("/a"),
            PathBuf::from("/b"),
            PathBuf::from("/a"),
        ];
        let result = dedup_paths(paths);
        assert_eq!(result, vec![PathBuf::from("/a"), PathBuf::from("/b")]);
    }

    #[test]
    fn dedup_paths_preserves_order() {
        let paths = vec![
            PathBuf::from("/c"),
            PathBuf::from("/a"),
            PathBuf::from("/b"),
            PathBuf::from("/a"),
        ];
        let result = dedup_paths(paths);
        assert_eq!(
            result,
            vec![
                PathBuf::from("/c"),
                PathBuf::from("/a"),
                PathBuf::from("/b")
            ]
        );
    }

    #[test]
    fn dedup_paths_empty_input() {
        let result = dedup_paths(vec![]);
        assert!(result.is_empty());
    }

    #[test]
    fn dedup_paths_no_duplicates() {
        let paths = vec![PathBuf::from("/x"), PathBuf::from("/y")];
        let result = dedup_paths(paths.clone());
        assert_eq!(result, paths);
    }

    // --- workspace_name_from_repos ---

    #[test]
    fn workspace_name_empty_repos_is_workspace() {
        assert_eq!(workspace_name_from_repos(&[]), "Workspace");
    }

    #[test]
    fn workspace_name_single_repo_uses_dir_name() {
        let repos = vec![PathBuf::from("/home/user/my-project")];
        assert_eq!(workspace_name_from_repos(&repos), "my-project");
    }

    #[test]
    fn workspace_name_two_repos_joined_with_plus() {
        let repos = vec![PathBuf::from("/repos/alpha"), PathBuf::from("/repos/beta")];
        assert_eq!(workspace_name_from_repos(&repos), "alpha + beta");
    }

    #[test]
    fn workspace_name_three_repos_shows_overflow() {
        let repos = vec![
            PathBuf::from("/repos/alpha"),
            PathBuf::from("/repos/beta"),
            PathBuf::from("/repos/gamma"),
        ];
        // takes first 2, then "+N" for the rest
        let name = workspace_name_from_repos(&repos);
        assert!(name.contains("alpha"));
        assert!(name.contains("beta"));
        assert!(name.contains("+1"));
    }
}
