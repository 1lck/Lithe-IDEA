//! Synchronize a restored Claude model through the adapter's public ACP API.
//!
//! Claude ACP can report its last transcript model while the SDK query uses a
//! launch default. Re-assert the reported selection before publishing the load;
//! neither transcript files nor installed third-party code belong to the host.

use agent_client_protocol::schema::v1::{
    LoadSessionRequest, LoadSessionResponse, SessionConfigKind, SessionConfigOptionCategory,
    SetSessionConfigOptionRequest,
};
use agent_client_protocol::{Agent, ConnectionTo};

/// Restore history and, for the Claude API-key route, confirm its model before
/// returning. The caller's single load deadline covers both ACP requests.
pub(crate) async fn load_session(
    connection: &ConnectionTo<Agent>,
    request: LoadSessionRequest,
    confirm_model: bool,
) -> Result<LoadSessionResponse, agent_client_protocol::Error> {
    let session_id = request.session_id.clone();
    let mut response = connection.send_request(request).block_task().await?;
    if !confirm_model {
        return Ok(response);
    }
    let selection = response.config_options.as_ref().and_then(|options| {
        options.iter().find_map(|option| {
            if option.category != Some(SessionConfigOptionCategory::Model) {
                return None;
            }
            let SessionConfigKind::Select(select) = &option.kind else {
                return None;
            };
            Some((option.id.clone(), select.current_value.clone()))
        })
    });
    let Some((id, model)) = selection else {
        // Older adapters without a model selector retain standard ACP loading.
        return Ok(response);
    };
    if model.0.trim().is_empty() {
        return Err(super::internal(
            "The Agent did not report a restored model.",
        ));
    }
    // The pinned adapter accepts its current value even when it is outside the
    // picker. Do not substitute another model or skip an unchanged selection:
    // this round-trip repairs a discrepancy between reported and running state.
    let configured = connection
        .send_request(SetSessionConfigOptionRequest::new(
            session_id,
            id.clone(),
            model.0.as_ref(),
        ))
        .block_task()
        .await?;
    let confirmed = configured.config_options.iter().any(|option| {
        option.id == id
            && option.category == Some(SessionConfigOptionCategory::Model)
            && matches!(&option.kind, SessionConfigKind::Select(select) if select.current_value == model)
    });
    if !confirmed {
        return Err(super::internal(
            "The Agent did not confirm the restored model. Retry loading the conversation.",
        ));
    }
    response.config_options = Some(configured.config_options);
    Ok(response)
}
