//! Consent-bound archive fetches; ZIP interpretation remains in shared Core.
use super::super::marketplace_download::{
    fetch_controlled, CancelToken, FetchFailure, FetchLimits, FetchPolicy, HttpResponse,
    HttpTransport, MAX_ARTIFACT_BYTES, MAX_REDIRECT_HOPS,
};
use super::{Error, Result};
use serde_json::{json, Value};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const DOWNLOAD_BUDGET: Duration = Duration::from_secs(120);

struct RedirectBudget<'a> {
    transport: &'a dyn HttpTransport,
    remaining: AtomicU64,
}
impl HttpTransport for RedirectBudget<'_> {
    fn get<'a>(
        &'a self,
        url: &'a str,
        max_bytes: u64,
        deadline: Instant,
        cancel: &'a CancelToken,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = std::result::Result<HttpResponse, FetchFailure>>
                + Send
                + 'a,
        >,
    > {
        Box::pin(async move {
            let remaining = self.remaining.load(Ordering::Acquire).min(max_bytes);
            let response = self.transport.get(url, remaining, deadline, cancel).await?;
            if response.body.len() as u64 > remaining {
                return Err(FetchFailure::BudgetExceeded { limit: max_bytes });
            }
            self.remaining
                .store(remaining - response.body.len() as u64, Ordering::Release);
            Ok(response)
        })
    }
}

/// Runs on the generation worker. Its caller retains staging until every
/// synchronous Core write has returned, including cancellation and timeout.
pub(super) fn execute(
    transport: &dyn HttpTransport,
    url: &str,
    stage: &Path,
    operation_id: &str,
    cancel: &CancelToken,
    deadline: Instant,
    checkpoint: &dyn Fn() -> Result<()>,
) -> Result<()> {
    let check = || {
        cancel.check(deadline).map_err(fetch_error)?;
        checkpoint()
    };
    check()?;
    let transport = RedirectBudget {
        transport,
        remaining: AtomicU64::new(MAX_ARTIFACT_BYTES),
    };
    let downloaded = tauri::async_runtime::block_on(fetch_controlled(
        &transport,
        url,
        FetchLimits {
            max_bytes: MAX_ARTIFACT_BYTES,
            max_redirects: MAX_REDIRECT_HOPS,
        },
        FetchPolicy::https_only(),
        cancel,
        deadline.min(Instant::now() + DOWNLOAD_BUDGET),
    ))
    .map_err(fetch_error)?;
    // The transaction callback also revalidates staging identity after the
    // network wait, before any path-based ZIP creation or Core extraction.
    check()?;
    // No digest is declared for project archives. The controlled HTTPS body is
    // untrusted ZIP input, never a marketplace artifact or approved package.
    // Keeping its create_new file inside this private transaction also makes
    // failed removal retryable through the original staging owner.
    let path = stage.join(format!(
        ".lithe-project-archive-{}.zip",
        super::super::install::uuid_like_suffix()
    ));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)
        .map_err(Error::io)?;
    let extracted = (|| {
        for chunk in downloaded.body.chunks(64 * 1024) {
            check()?;
            file.write_all(chunk).map_err(Error::io)?;
        }
        file.sync_all().map_err(Error::io)?;
        drop(file);
        check()?;
        let timeout = deadline
            .saturating_duration_since(Instant::now())
            .as_millis()
            .min(u64::MAX as u128)
            .max(1) as u64;
        let request = json!({"command":"project.extractArchive", "operationId":operation_id,
            "timeoutMilliseconds":timeout, "payload":{"archivePath":path,"destination":stage}});
        let response: Value = serde_json::from_str(&lithe_core::execute_json(&request.to_string()))
            .map_err(|_| Error::new("generator.coreFailed"))?;
        if response["ok"] != true {
            return Err(Error::new(match response["error"]["code"].as_str() {
                Some("cancelled") => "generator.cancelled",
                Some("timed_out") => "generator.timeout",
                _ => "generator.coreFailed",
            }));
        }
        if response["data"]["status"] != "ok" {
            return Err(Error::new("generator.archiveInvalid"));
        }
        check()
    })();
    // The archive descriptor and Core's entry descriptors have closed before
    // removal. A failure belongs to the surrounding Transaction's cleanup.
    std::fs::remove_file(&path).map_err(Error::io)?;
    extracted
}

fn fetch_error(error: FetchFailure) -> Error {
    Error::new(match error {
        FetchFailure::Cancelled => "generator.cancelled",
        FetchFailure::DeadlineExceeded => "generator.timeout",
        FetchFailure::BudgetExceeded { .. } => "generator.outputLimit",
        _ => "generator.downloadFailed",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    struct OversizedRedirect;
    impl HttpTransport for OversizedRedirect {
        fn get<'a>(
            &'a self,
            url: &'a str,
            _: u64,
            _: Instant,
            _: &'a CancelToken,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<Output = std::result::Result<HttpResponse, FetchFailure>>
                    + Send
                    + 'a,
            >,
        > {
            Box::pin(async move {
                Ok(if url.ends_with("first") {
                    HttpResponse {
                        status: 302,
                        headers: HashMap::from([("location".into(), "/second".into())]),
                        body: vec![0; 6],
                    }
                } else {
                    HttpResponse {
                        status: 200,
                        headers: HashMap::new(),
                        body: vec![0; 6],
                    }
                })
            })
        }
    }
    #[tokio::test]
    async fn redirects_share_one_total_download_byte_budget() {
        let transport = RedirectBudget {
            transport: &OversizedRedirect,
            remaining: AtomicU64::new(10),
        };
        let result = fetch_controlled(
            &transport,
            "https://fixture.invalid/first",
            FetchLimits {
                max_bytes: 10,
                max_redirects: 5,
            },
            FetchPolicy::https_only(),
            &CancelToken::new(),
            Instant::now() + Duration::from_secs(2),
        )
        .await;
        assert!(matches!(result, Err(FetchFailure::BudgetExceeded { .. })));
    }

    struct ExactRedirect {
        calls: std::sync::Mutex<Vec<(u64, Instant)>>,
    }
    impl HttpTransport for ExactRedirect {
        fn get<'a>(
            &'a self,
            url: &'a str,
            max_bytes: u64,
            deadline: Instant,
            _: &'a CancelToken,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<Output = std::result::Result<HttpResponse, FetchFailure>>
                    + Send
                    + 'a,
            >,
        > {
            self.calls.lock().unwrap().push((max_bytes, deadline));
            Box::pin(async move {
                Ok(if url.ends_with("first") {
                    HttpResponse {
                        status: 302,
                        headers: HashMap::from([("location".into(), "/second".into())]),
                        body: vec![0; 6],
                    }
                } else {
                    HttpResponse {
                        status: 200,
                        headers: HashMap::new(),
                        body: vec![0; 4],
                    }
                })
            })
        }
    }

    #[tokio::test]
    async fn exact_total_download_budget_preserves_the_original_absolute_deadline() {
        let fixture = ExactRedirect {
            calls: std::sync::Mutex::new(Vec::new()),
        };
        let transport = RedirectBudget {
            transport: &fixture,
            remaining: AtomicU64::new(10),
        };
        let deadline = Instant::now() + Duration::from_secs(2);
        let result = fetch_controlled(
            &transport,
            "https://fixture.invalid/first",
            FetchLimits {
                max_bytes: 10,
                max_redirects: 5,
            },
            FetchPolicy::https_only(),
            &CancelToken::new(),
            deadline,
        )
        .await
        .unwrap();
        assert_eq!(result.body.len(), 4);
        assert_eq!(result.hops, 1);
        assert_eq!(
            fixture.calls.lock().unwrap().as_slice(),
            &[(10, deadline), (4, deadline)]
        );
    }
}
