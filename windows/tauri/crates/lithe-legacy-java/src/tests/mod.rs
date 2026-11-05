//! Command-level tests, moved or copied from Core's `tests/` together with the
//! commands they exercise. Each test sends a request through [`crate::try_execute`]
//! and checks the JSON, so they pin the contract the Windows frontend relies on.

mod java;
mod maven;
mod mybatis;
mod spring;
mod support;
