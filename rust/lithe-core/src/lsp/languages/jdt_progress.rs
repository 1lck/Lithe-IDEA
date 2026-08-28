//! Stateful, throttled diagnostics for JDT LS workspace-import progress.

use super::jdt::JdtImportProgress;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

const JAVA_PROGRESS_LOG_INTERVAL_MS: u64 = 2_000;
const JAVA_PROGRESS_PERCENTAGE_STEP: u64 = 5;

struct JavaDownloadDiagnostics {
    artifact: String,
    repository_host: Option<String>,
    started_at: Instant,
    downloaded_bytes: Option<u64>,
    total_bytes: Option<u64>,
}

/// Java-only preparation observations retained until `ServiceReady` or timeout.
pub(crate) struct JavaPreparationDiagnostics {
    startup_started_at: Instant,
    process_start_elapsed: Duration,
    cache_disposition: &'static str,
    workspace_fingerprint_present: bool,
    readiness_started_at: Option<Instant>,
    last_progress_at: Option<Instant>,
    absolute_deadline: Option<Instant>,
    idle_timeout: Duration,
    last_activity_signature: Option<String>,
    phase: Option<String>,
    progress_percentage: Option<u64>,
    current_project: Option<String>,
    observed_projects: BTreeSet<String>,
    observed_downloads: BTreeMap<String, u64>,
    active_download: Option<JavaDownloadDiagnostics>,
    last_log_at: Option<Instant>,
    last_logged_phase: Option<String>,
    last_logged_project: Option<String>,
    last_logged_percentage: Option<u64>,
    last_logged_download_bytes: Option<u64>,
    initialize_elapsed: Option<Duration>,
}

impl JavaPreparationDiagnostics {
    /// Starts diagnostics with the process-launch and durable-cache observations.
    pub(crate) fn new(
        startup_started_at: Instant,
        process_start_elapsed: Duration,
        cache_disposition: &'static str,
        workspace_fingerprint_present: bool,
    ) -> Self {
        Self {
            startup_started_at,
            process_start_elapsed,
            cache_disposition,
            workspace_fingerprint_present,
            readiness_started_at: None,
            last_progress_at: None,
            absolute_deadline: None,
            idle_timeout: Duration::ZERO,
            last_activity_signature: None,
            phase: None,
            progress_percentage: None,
            current_project: None,
            observed_projects: BTreeSet::new(),
            observed_downloads: BTreeMap::new(),
            active_download: None,
            last_log_at: None,
            last_logged_phase: None,
            last_logged_project: None,
            last_logged_percentage: None,
            last_logged_download_bytes: None,
            initialize_elapsed: None,
        }
    }

    /// Serializes the process-start observation for platform log adapters.
    pub(crate) fn startup_detail(&self) -> String {
        json!({
            "stage": "processStart",
            "processStartMilliseconds": self.process_start_elapsed.as_millis(),
            "cacheDisposition": self.cache_disposition,
            "workspaceFingerprintPresent": self.workspace_fingerprint_present,
        })
        .to_string()
    }

    /// Switches from the standard initialize handshake to post-initialize readiness.
    pub(crate) fn begin_readiness(
        &mut self,
        now: Instant,
        initialize_elapsed: Duration,
        idle_timeout: Duration,
        absolute_timeout: Duration,
    ) -> String {
        self.initialize_elapsed = Some(initialize_elapsed);
        self.readiness_started_at = Some(now);
        self.last_progress_at = Some(now);
        self.absolute_deadline = Some(now + absolute_timeout);
        self.idle_timeout = idle_timeout;
        json!({
            "stage": "serviceReady",
            "initializeMilliseconds": initialize_elapsed.as_millis(),
            "idleTimeoutMilliseconds": idle_timeout.as_millis(),
            "absoluteTimeoutMilliseconds": absolute_timeout.as_millis(),
            "cacheDisposition": self.cache_disposition,
        })
        .to_string()
    }

    /// Records changed work-done progress and returns a throttled JSON log detail.
    pub(crate) fn record_progress(
        &mut self,
        progress: JdtImportProgress,
        now: Instant,
    ) -> Option<String> {
        self.readiness_started_at?;
        if self.last_activity_signature.as_deref() == Some(&progress.activity_signature) {
            return None;
        }
        self.last_activity_signature = Some(progress.activity_signature);
        self.last_progress_at = Some(now);

        let phase_changed = progress
            .phase
            .as_ref()
            .is_some_and(|phase| self.last_logged_phase.as_deref() != Some(phase.as_str()));
        let project_changed = progress
            .current_project
            .as_ref()
            .is_some_and(|project| self.last_logged_project.as_deref() != Some(project.as_str()));
        let percentage_advanced = progress.percentage.is_some_and(|percentage| {
            self.last_logged_percentage.is_none_or(|logged| {
                percentage >= logged.saturating_add(JAVA_PROGRESS_PERCENTAGE_STEP)
            })
        });
        let download_finished = progress.download.is_none() && self.active_download.is_some();

        if let Some(phase) = progress.phase {
            self.phase = Some(phase);
        }
        if let Some(percentage) = progress.percentage {
            self.progress_percentage = Some(percentage);
        }
        if let Some(project) = progress.current_project {
            self.observed_projects.insert(project.clone());
            self.current_project = Some(project);
        }

        let mut download_advanced = false;
        if let Some(download) = progress.download {
            let download_key = format!(
                "{}/{}",
                download.repository_host.as_deref().unwrap_or("unknown"),
                download.artifact
            );
            let observed = self.observed_downloads.entry(download_key).or_default();
            if let Some(downloaded_bytes) = download.downloaded_bytes {
                *observed = (*observed).max(downloaded_bytes);
                download_advanced = self
                    .last_logged_download_bytes
                    .is_none_or(|logged| downloaded_bytes > logged);
            }
            let same_download = self.active_download.as_ref().is_some_and(|active| {
                active.artifact == download.artifact
                    && active.repository_host == download.repository_host
            });
            if same_download {
                if let Some(active) = self.active_download.as_mut() {
                    active.downloaded_bytes = download.downloaded_bytes;
                    active.total_bytes = download.total_bytes;
                }
            } else {
                self.active_download = Some(JavaDownloadDiagnostics {
                    artifact: download.artifact,
                    repository_host: download.repository_host,
                    started_at: now,
                    downloaded_bytes: download.downloaded_bytes,
                    total_bytes: download.total_bytes,
                });
                self.last_logged_download_bytes = None;
                download_advanced = true;
            }
        } else {
            self.active_download = None;
            self.last_logged_download_bytes = None;
        }

        let log_interval_elapsed = self.last_log_at.is_none_or(|logged_at| {
            now.saturating_duration_since(logged_at)
                >= Duration::from_millis(JAVA_PROGRESS_LOG_INTERVAL_MS)
        });
        let should_log = phase_changed
            || project_changed
            || percentage_advanced
            || download_finished
            || (download_advanced && log_interval_elapsed);
        if !should_log {
            return None;
        }

        self.last_log_at = Some(now);
        self.last_logged_phase = self.phase.clone();
        self.last_logged_project = self.current_project.clone();
        self.last_logged_percentage = self.progress_percentage;
        self.last_logged_download_bytes = self
            .active_download
            .as_ref()
            .and_then(|download| download.downloaded_bytes);
        Some(self.progress_detail(now))
    }

    fn progress_detail(&self, now: Instant) -> String {
        let (artifact, repository_host, downloaded_bytes, total_bytes, bytes_per_second) = self
            .active_download
            .as_ref()
            .map(|download| {
                let elapsed = now.saturating_duration_since(download.started_at);
                let throughput = download.downloaded_bytes.and_then(|bytes| {
                    (elapsed > Duration::ZERO)
                        .then(|| (bytes as f64 / elapsed.as_secs_f64()).round() as u64)
                });
                (
                    Some(download.artifact.clone()),
                    download.repository_host.clone(),
                    download.downloaded_bytes,
                    download.total_bytes,
                    throughput,
                )
            })
            .unwrap_or((None, None, None, None, None));
        json!({
            "stage": "serviceReady",
            "phase": self.phase,
            "progressPercent": self.progress_percentage,
            "currentProject": self.current_project,
            "observedProjectCount": self.observed_projects.len(),
            "downloadArtifact": artifact,
            "repositoryHost": repository_host,
            "downloadedBytes": downloaded_bytes,
            "totalBytes": total_bytes,
            "bytesPerSecond": bytes_per_second,
            "elapsedMilliseconds": self.readiness_started_at
                .map(|started| now.saturating_duration_since(started).as_millis()),
            "idleMilliseconds": self.last_progress_at
                .map(|progress| now.saturating_duration_since(progress).as_millis()),
            "cacheDisposition": self.cache_disposition,
        })
        .to_string()
    }

    /// Finishes preparation and serializes one aggregate startup summary.
    pub(crate) fn ready_detail(&mut self, now: Instant) -> String {
        let import_elapsed = self
            .readiness_started_at
            .map(|started| now.saturating_duration_since(started));
        self.readiness_started_at = None;
        self.absolute_deadline = None;
        let downloaded_bytes: u64 = self.observed_downloads.values().copied().sum();
        json!({
            "stage": "serviceReady",
            "outcome": "ready",
            "totalMilliseconds": now.saturating_duration_since(self.startup_started_at).as_millis(),
            "processStartMilliseconds": self.process_start_elapsed.as_millis(),
            "initializeMilliseconds": self.initialize_elapsed.map(|elapsed| elapsed.as_millis()),
            "importMilliseconds": import_elapsed.map(|elapsed| elapsed.as_millis()),
            "progressPercent": self.progress_percentage,
            "observedProjectCount": self.observed_projects.len(),
            "downloadedArtifactCount": self.observed_downloads.len(),
            "downloadedBytes": downloaded_bytes,
            "cacheDisposition": self.cache_disposition,
        })
        .to_string()
    }

    /// Takes an idle or absolute timeout once and returns its diagnostic snapshot.
    pub(crate) fn take_timeout(&mut self, now: Instant) -> Option<String> {
        let started_at = self.readiness_started_at?;
        let last_progress_at = self.last_progress_at.unwrap_or(started_at);
        let idle = now.saturating_duration_since(last_progress_at);
        let timeout_kind = if self
            .absolute_deadline
            .is_some_and(|deadline| now >= deadline)
        {
            "absolute"
        } else if idle >= self.idle_timeout {
            "idle"
        } else {
            return None;
        };
        let classification = match (timeout_kind, self.active_download.is_some()) {
            ("idle", true) => "networkDownloadStalled",
            ("idle", false) => "noProgressStall",
            ("absolute", true) => "networkTransferActive",
            _ => "projectImportActive",
        };
        self.readiness_started_at = None;
        self.absolute_deadline = None;
        Some(
            json!({
                "stage": "serviceReady",
                "timeoutKind": timeout_kind,
                "classification": classification,
                "elapsedMilliseconds": now.saturating_duration_since(started_at).as_millis(),
                "idleMilliseconds": idle.as_millis(),
                "progressPercent": self.progress_percentage,
                "phase": self.phase,
                "currentProject": self.current_project,
                "observedProjectCount": self.observed_projects.len(),
                "downloadArtifact": self.active_download.as_ref().map(|download| &download.artifact),
                "downloadedBytes": self.active_download.as_ref().and_then(|download| download.downloaded_bytes),
                "totalBytes": self.active_download.as_ref().and_then(|download| download.total_bytes),
                "cacheDisposition": self.cache_disposition,
            })
            .to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn progress(signature: &str, percentage: u64) -> JdtImportProgress {
        JdtImportProgress {
            activity_signature: signature.to_string(),
            phase: Some("Importing Maven project(s)".to_string()),
            percentage: Some(percentage),
            current_project: Some("module-a".to_string()),
            download: None,
        }
    }

    #[test]
    fn meaningful_progress_refreshes_the_idle_deadline() {
        let started = Instant::now();
        let mut diagnostics =
            JavaPreparationDiagnostics::new(started, Duration::from_millis(5), "new", true);
        diagnostics.begin_readiness(
            started,
            Duration::from_millis(10),
            Duration::from_millis(100),
            Duration::from_secs(1),
        );
        diagnostics.record_progress(progress("first", 20), started + Duration::from_millis(80));

        assert!(
            diagnostics
                .take_timeout(started + Duration::from_millis(150))
                .is_none(),
            "changed progress should extend the original idle deadline"
        );
        diagnostics.record_progress(progress("second", 25), started + Duration::from_millis(160));
        assert!(
            diagnostics
                .take_timeout(started + Duration::from_millis(240))
                .is_none(),
            "each changed progress event should refresh the idle deadline"
        );

        let timeout = diagnostics
            .take_timeout(started + Duration::from_millis(261))
            .expect("silence after the refreshed deadline should still time out");
        assert!(timeout.contains("\"timeoutKind\":\"idle\""));
    }

    #[test]
    fn duplicate_progress_does_not_refresh_the_idle_deadline() {
        let started = Instant::now();
        let mut diagnostics =
            JavaPreparationDiagnostics::new(started, Duration::from_millis(5), "new", true);
        diagnostics.begin_readiness(
            started,
            Duration::from_millis(10),
            Duration::from_millis(45),
            Duration::from_secs(10),
        );
        diagnostics.record_progress(progress("same", 20), started + Duration::from_millis(10));
        diagnostics.record_progress(progress("same", 20), started + Duration::from_millis(30));

        let timeout = diagnostics
            .take_timeout(started + Duration::from_millis(56))
            .expect("unchanged progress must not keep preparation alive");
        assert!(timeout.contains("\"timeoutKind\":\"idle\""));
    }

    #[test]
    fn absolute_deadline_still_caps_continuously_active_imports() {
        let started = Instant::now();
        let mut diagnostics =
            JavaPreparationDiagnostics::new(started, Duration::from_millis(5), "reused", true);
        diagnostics.begin_readiness(
            started,
            Duration::from_millis(10),
            Duration::from_secs(1),
            Duration::from_millis(100),
        );
        diagnostics.record_progress(progress("first", 20), started + Duration::from_millis(40));
        diagnostics.record_progress(progress("second", 25), started + Duration::from_millis(90));

        let timeout = diagnostics
            .take_timeout(started + Duration::from_millis(100))
            .expect("the absolute deadline must remain a final safety cap");
        assert!(timeout.contains("\"timeoutKind\":\"absolute\""));
        assert!(timeout.contains("\"classification\":\"projectImportActive\""));
    }
}
