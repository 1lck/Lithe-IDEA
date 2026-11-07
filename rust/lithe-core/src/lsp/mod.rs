//! Language tooling is split by responsibility while this facade keeps the Core command API stable.

pub(crate) mod host_policy;
pub(crate) mod interface;
mod languages;
pub(crate) mod lightweight;
pub(crate) mod navigation_target;
pub(crate) mod workspace_edit_plan;
mod workspace_scope;

pub(crate) use interface::*;
pub(crate) use languages::*;
pub(crate) use lightweight::*;

#[cfg(test)]
pub(crate) fn client_feature_request(
    request: ClientFeatureRequest,
) -> Result<LspClientResponse, crate::protocol::CoreError> {
    interface::client_feature_request_canonical(languages::swift::adapt_feature_request(request))
}

#[cfg(test)]
mod tests;
