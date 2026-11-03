//! Network proxy policy normalization shared by the macOS and Windows hosts.
//!
//! The user-facing proxy settings (mode, server, credentials, exclusions) are
//! normalized and validated here so both hosts interpret the same stored
//! values identically. Platforms only map the returned policy onto their own
//! network stack: `connectionProxyDictionary` plus an authentication delegate
//! on macOS, and the HTTP client configuration on Windows.

pub(crate) mod proxy;

pub(crate) use proxy::{
    proxy_policy, NetworkProxyMode, NetworkProxyPolicy, NetworkProxyPolicyKind,
    NetworkProxyPolicyRequest, NetworkProxyType,
};

#[cfg(test)]
mod tests;
