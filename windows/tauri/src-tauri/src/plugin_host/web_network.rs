//! WebView2 request boundary installed before a plugin document can execute.
//!
//! NavigationStarting prevents document commit but can arrive after a network
//! request has started. WebResourceRequested completes foreign requests locally
//! instead, so cancelling navigation cannot leak page state in a request URL.

use std::time::Duration;
use tauri::WebviewWindow;
use webview2_com::{Microsoft::Web::WebView2::Win32::*, WebResourceRequestedEventHandler};
use windows::{
    core::{w, PWSTR},
    Win32::System::Com::CoTaskMemFree,
};

fn request_is_allowed(raw: &str, plugin_id: &str) -> bool {
    let Ok(url) = url::Url::parse(raw) else {
        return false;
    };
    super::is_package_url(&url, plugin_id)
        || url.scheme() == "data"
        || (url.scheme() == "http"
            && url.host_str() == Some("ipc.localhost")
            && url.port().is_none()
            && url.username().is_empty()
            && url.password().is_none())
}

pub(super) async fn restrict_requests(
    view: &WebviewWindow,
    plugin_id: String,
) -> Result<(), String> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    view.with_webview(move |platform| {
        // SAFETY: Tauri runs this closure on the controller's UI thread. All
        // interfaces remain on that thread; the view owns the event subscription.
        let result =
            unsafe { install_filter(platform, plugin_id).map_err(|error| error.to_string()) };
        let _ = sender.send(result);
    })
    .map_err(|error| error.to_string())?;
    tokio::time::timeout(Duration::from_secs(5), receiver)
        .await
        .map_err(|_| "plugin page request-filter setup timed out".to_string())?
        .map_err(|_| "plugin page request-filter setup was cancelled".to_string())?
}

unsafe fn install_filter(
    platform: tauri::webview::PlatformWebview,
    plugin_id: String,
) -> windows::core::Result<()> {
    let core = platform.controller().CoreWebView2()?;
    let environment = platform.environment();
    core.AddWebResourceRequestedFilter(w!("*"), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)?;
    let mut token = 0;
    core.add_WebResourceRequested(
        &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else {
                return Ok(());
            };
            let request = args.Request()?;
            let mut uri = PWSTR::null();
            request.Uri(&mut uri)?;
            // WebView2 allocates this string with CoTaskMemAlloc. Free it even if
            // URL decoding fails; no request URI is retained in a diagnostic.
            let raw = if uri.0.is_null() {
                None
            } else {
                uri.to_string().ok()
            };
            CoTaskMemFree(Some(uri.0.cast()));
            if !raw
                .as_deref()
                .is_some_and(|value| request_is_allowed(value, &plugin_id))
            {
                let response = environment.CreateWebResourceResponse(
                    None,
                    403,
                    w!("Forbidden"),
                    w!("Content-Type: text/plain\r\nCache-Control: no-store"),
                )?;
                args.SetResponse(&response)?;
            }
            Ok(())
        })),
        &mut token,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_package_assets_and_native_ipc_can_reach_the_request_layer() {
        for allowed in [
            "http://lithe-plugin.acme.php/ui/index.html",
            "http://ipc.localhost/",
            "data:image/png;base64,AA==",
        ] {
            assert!(request_is_allowed(allowed, "acme.php"), "{allowed}");
        }
        for refused in [
            "https://example.test/",
            "http://127.0.0.1/foreign",
            "http://lithe-plugin.other/ui/index.html",
            "http://user@ipc.localhost/",
            "http://ipc.localhost:1234/",
            "file:///outside.txt",
        ] {
            assert!(!request_is_allowed(refused, "acme.php"), "{refused}");
        }
    }
}
