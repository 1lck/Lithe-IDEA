//! Language tooling is split by responsibility while this facade keeps the Core command API stable.

pub(crate) mod interface;
mod languages;
pub(crate) mod lightweight;

pub(crate) use interface::*;
pub(crate) use languages::*;
pub(crate) use lightweight::*;

pub(crate) fn client_feature_request(
    request: ClientFeatureRequest,
) -> Result<LspClientResponse, crate::protocol::CoreError> {
    interface::client_feature_request_canonical(languages::swift::adapt_feature_request(request))
}

pub(crate) fn session_execute(
    request: LspSessionCommandRequest,
) -> Result<LspSessionResponse, crate::protocol::CoreError> {
    interface::session_execute_canonical(languages::swift::adapt_session_request(request))
}

#[cfg(test)]
mod tests;
