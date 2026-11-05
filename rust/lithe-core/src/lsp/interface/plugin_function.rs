//! Plugin functions: plugin-private actions a backend registers and the host
//! invokes on behalf of the same plugin, next to the typed domain protocols.
//!
//! The protocol is negotiated in `initialize` under
//! `capabilities.experimental.litheFunctions`, independently of `litheBuild`,
//! so a backend can speak either one. Functions never replace a domain
//! operation: a build model, dependency tree, or task still travels over its
//! typed `lithe/build/*` method and Core's plan and decode commands. This
//! module holds the deterministic rules (identifiers, registration, invocation
//! planning, outcome and progress normalization, and the refusal of requests a
//! backend may not make); the session engine applies them to live traffic.
//! The rules live in the plugin contract
//! (`shared/contracts/plugins/v1/README.md`, "Plugin functions").

use crate::plugins::language_server_sessions::{self, is_protocol_name};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Key under `capabilities.experimental` on both sides of the exchange.
const EXPERIMENTAL_KEY: &str = "litheFunctions";

/// Plugin-function protocol versions this client speaks. Version 2 keeps
/// every rule of version 1 and adds the host services of `host_request`.
/// Version 3 keeps version 2 and adds `lithe/host/getCapabilities`,
/// subscription disposal, workspace contexts, a workspace context on
/// invocations, and typed host failure codes.
/// Version 4 keeps version 3 and adds the cross-plugin function relay
/// (`lithe/host/functions/*`) and the Core-written `caller` of an invocation.
const SUPPORTED_VERSIONS: [u64; 4] = [1, 2, 3, 4];
/// First protocol version that offers host services.
const HOST_SERVICES_VERSION: u64 = 2;
/// First protocol version whose invocations may carry a workspace context
/// and whose host offers capability discovery and workspace contexts.
pub(crate) const CONTEXT_VERSION: u64 = 3;
/// First protocol version whose backend may call the functions other plugins
/// export, and whose invocations carry the Core-written `caller`.
pub(crate) const RELAY_VERSION: u64 = 4;

/// Feature name recorded in the session's server capabilities once a backend
/// answered a supported version with a valid function list.
pub(crate) const FUNCTIONS_FEATURE: &str = "litheFunctions";

/// Host-to-backend request that runs one registered function.
pub(crate) const INVOKE_METHOD: &str = "lithe/function/invoke";
/// Backend-to-host request adding functions after `initialize`.
pub(crate) const REGISTER_METHOD: &str = "lithe/function/register";
/// Backend-to-host request withdrawing functions; running calls are revoked.
pub(crate) const UNREGISTER_METHOD: &str = "lithe/function/unregister";
/// Backend-to-host notification reporting progress of one running call.
pub(crate) const PROGRESS_METHOD: &str = "lithe/function/progress";

/// Upper bound of functions one session may have registered at a time.
const MAX_FUNCTIONS: usize = 256;
const MAX_FUNCTION_ID_BYTES: usize = 128;
const MAX_PLUGIN_ID_BYTES: usize = 128;
const MAX_PLUGIN_ERROR_CODE_BYTES: usize = 64;
/// Bound of a backend-supplied failure or progress message, in UTF-8 bytes.
const MAX_MESSAGE_BYTES: usize = 1024;
/// Bound of one serialized function result. Larger documents belong in a
/// domain protocol with its own decoder, not in a plugin-private reply.
pub(crate) const MAX_RESULT_BYTES: usize = 1 << 20;
/// Upper bound of one invocation's deadline, matching build-provider requests.
pub(crate) const MAX_FUNCTION_TIMEOUT_MS: u64 = 60 * 60_000;

/// Host service that keeps secrets for the plugin, private to its ID.
pub(crate) const HOST_SERVICE_CREDENTIALS: &str = "credentials";
/// Host service listing open workspace contexts and their folders, granted
/// by `workspace.metadata` to a `backend` 2 process.
pub(crate) const HOST_SERVICE_WORKSPACE: &str = "workspace";
/// Capability discovery. Every plugin-owned session of version 3 has it;
/// Core answers it without involving the host.
const HOST_SERVICE_HOST: &str = "host";
/// Ending subscriptions other services created. Every plugin-owned session
/// of version 3 has it, because only the session that holds a subscription
/// can name it.
const HOST_SERVICE_SUBSCRIPTIONS: &str = "subscriptions";
/// Calls into the functions other plugins export. The grant comes from the
/// manifest's `requires.pluginFunctions.calls`, not from a permission: the
/// caller's declaration plus the provider's `exports` is the consent, and
/// Core's relay checks both on every call.
pub(crate) const HOST_SERVICE_FUNCTIONS: &str = "functions";
/// Legacy aggregate grants. New methods are granted individually so adding a
/// method to `workspace` or `editor` never widens an existing permission.
pub(crate) const GRANTABLE_HOST_SERVICES: &[&str] = &[
    HOST_SERVICE_CREDENTIALS,
    HOST_SERVICE_WORKSPACE,
    HOST_SERVICE_FUNCTIONS,
];

/// Whether a launch grant names an implemented legacy service or host method.
pub(crate) fn is_host_grant(grant: &str) -> bool {
    GRANTABLE_HOST_SERVICES.contains(&grant)
        || HOST_METHODS
            .iter()
            .any(|entry| entry.method == grant && entry.permission.is_some())
}

/// Methods admitted by one manifest permission. The platform intersects these
/// with its registered method handlers before starting the backend.
pub(crate) fn methods_for_permission(permission: &str) -> Vec<&'static str> {
    HOST_METHODS
        .iter()
        .filter(|entry| entry.permission == Some(permission))
        .map(|entry| entry.method)
        .collect()
}

/// Permissions for the additive host services of backend 2.
pub(crate) const HOST_PERMISSIONS: &[&str] = &[
    "workspace.files.read",
    "workspace.files.watch",
    "workspace.search",
    "documents.read",
    "editor.edit",
    "editor.actions",
    "editor.providers",
    "editor.open",
    "preview.open",
    "browser.open",
    "window.messages",
    "terminal.create",
    "keymaps.readSelectedSources",
    PERMISSION_LANGUAGE_SERVER_REQUEST,
    PERMISSION_DOCUMENTS_CONTENT_PROVIDER,
];

/// Permission of the `languageServer` host service (plan API-25): a backend
/// may send requests and notifications to, and report the status of, the
/// language servers its own plugin declares.
pub(crate) const PERMISSION_LANGUAGE_SERVER_REQUEST: &str = "languageServer.request";
/// Permission of `documents/registerContentProvider` (plan API-12): the
/// backend supplies the read-only text of URIs of a scheme it registers.
pub(crate) const PERMISSION_DOCUMENTS_CONTENT_PROVIDER: &str = "documents.contentProvider";

const CREDENTIALS_GET: &str = "lithe/host/credentials/get";
const CREDENTIALS_SET: &str = "lithe/host/credentials/set";
const CREDENTIALS_DELETE: &str = "lithe/host/credentials/delete";
pub(crate) const GET_CAPABILITIES: &str = "lithe/host/getCapabilities";
const SUBSCRIPTIONS_DISPOSE: &str = "lithe/host/subscriptions/dispose";
const WORKSPACE_LIST_CONTEXTS: &str = "lithe/host/workspace/listContexts";
const WORKSPACE_GET_CONTEXT: &str = "lithe/host/workspace/getContext";
const WORKSPACE_GET_FOLDERS: &str = "lithe/host/workspace/getFolders";
/// Backend request listing the plugins that export a function it may call.
pub(crate) const FUNCTIONS_PROVIDERS: &str = "lithe/host/functions/providers";
/// Backend request calling a function another plugin exports.
pub(crate) const FUNCTIONS_INVOKE: &str = "lithe/host/functions/invoke";
const MAX_CREDENTIAL_KEY_BYTES: usize = 128;
/// Bound of one stored secret, in UTF-8 bytes; enough for a password, a
/// token, or a private key, not for documents.
pub(crate) const MAX_CREDENTIAL_SECRET_BYTES: usize = 16 * 1024;
/// Host requests one session may have awaiting the host's answer.
pub(crate) const MAX_PENDING_HOST_REQUESTS: usize = 16;
/// Bound of the serialized `details` object of one host failure; enough
/// for a few numbers and identifiers, not for documents.
pub(crate) const MAX_HOST_DETAILS_BYTES: usize = 4 * 1024;
/// Bound of the serialized params of one host-to-backend notification,
/// the same as one function result.
pub(crate) const MAX_HOST_NOTIFICATION_BYTES: usize = MAX_RESULT_BYTES;

/// Stable codes of the plugin-function contract. Synchronous refusals carry
/// them in `CoreError::details`; asynchronous outcomes in the runtime error's
/// `code`; refused backend requests in the JSON-RPC error's `data.code`.
pub(crate) mod codes {
    /// The session cannot serve plugin functions: it belongs to no plugin, or
    /// its backend did not negotiate the protocol.
    pub const UNAVAILABLE: &str = "plugin.function.unavailable";
    /// The function is not registered on the session.
    pub const UNKNOWN: &str = "plugin.function.unknown";
    /// The reference names another plugin than the one owning the session.
    pub const WRONG_PLUGIN: &str = "plugin.function.wrongPlugin";
    /// The plugin or function ID of the reference is malformed.
    pub const INVALID_REFERENCE: &str = "plugin.function.invalidReference";
    /// Invocation params are not a JSON object.
    pub const INVALID_PARAMS: &str = "plugin.function.invalidParams";
    /// A register or unregister request was refused as a whole.
    pub const INVALID_REGISTRATION: &str = "plugin.function.invalidRegistration";
    /// The backend answered the invocation with an error.
    pub const FAILED: &str = "plugin.function.failed";
    /// The backend's answer has no result or exceeds the result bound.
    pub const INVALID_RESULT: &str = "plugin.function.invalidResult";
    /// The function was unregistered while the call was running.
    pub const REVOKED: &str = "plugin.function.revoked";
    /// The backend asked the host to dispatch a domain operation or function,
    /// which could route back to the backend itself.
    pub const RECURSIVE_CALL: &str = "plugin.function.recursiveCall";
    /// The backend asked for a host capability this host does not offer.
    pub const HOST_UNAVAILABLE: &str = "plugin.host.unavailable";
    /// The host offers the service, but the plugin's permissions do not
    /// grant it to this session.
    pub const HOST_PERMISSION_DENIED: &str = "plugin.host.permissionDenied";
    /// A host-service request has malformed or unknown params.
    pub const HOST_INVALID_PARAMS: &str = "plugin.host.invalidParams";
    /// The host could not perform the service, or too many requests of
    /// the session were already waiting for it.
    pub const HOST_FAILED: &str = "plugin.host.failed";
    /// The request names a workspace context that was closed or replaced
    /// by a newer generation.
    pub const HOST_CONTEXT_EXPIRED: &str = "plugin.host.contextExpired";
    /// The context's authority (for example a remote workspace) does not
    /// implement the requested file or process operation. The host never
    /// falls back to the local placeholder directory.
    pub const HOST_AUTHORITY_UNSUPPORTED: &str = "plugin.host.authorityUnsupported";
    /// A versioned write found a newer version than the one it names.
    pub const HOST_VERSION_CONFLICT: &str = "plugin.host.versionConflict";
    /// The request exceeds a host limit on size or count. Retrying the same
    /// request fails again; rate limits are `HOST_RATE_LIMITED`.
    pub const HOST_LIMIT_EXCEEDED: &str = "plugin.host.limitExceeded";
    /// The backend cancelled the request, or the host stopped it.
    pub const HOST_CANCELLED: &str = "plugin.host.cancelled";
    /// The host's own deadline for the operation passed.
    pub const HOST_TIMEOUT: &str = "plugin.host.timeout";
    /// The resource the request names (a file, a document, a window) does
    /// not exist or is no longer open.
    pub const HOST_NOT_FOUND: &str = "plugin.host.notFound";
    /// The resource exists but may not be changed.
    pub const HOST_READ_ONLY: &str = "plugin.host.readOnly";
    /// The params are well formed, but this host does not implement an
    /// option they ask for.
    pub const HOST_UNSUPPORTED_OPTION: &str = "plugin.host.unsupportedOption";
    /// The resource is not in the state the operation needs, for example a
    /// document with unsaved changes or of another kind; the backend changes
    /// the state or the request, not merely retries.
    pub const HOST_PRECONDITION_FAILED: &str = "plugin.host.preconditionFailed";
    /// The host cannot serve the request at the moment, for example while
    /// the user composes text or an index loads; the same request may
    /// succeed later.
    pub const HOST_BUSY: &str = "plugin.host.busy";
    /// The plugin made too many requests of this kind recently; the same
    /// request may succeed after a while.
    pub const HOST_RATE_LIMITED: &str = "plugin.host.rateLimited";
    /// The language server a `languageServer` request names is not running
    /// in the context: it is starting, stopped, crashed, or not started.
    pub const HOST_LANGUAGE_SERVER_UNAVAILABLE: &str = "plugin.host.languageServerUnavailable";
    /// The language server answered a forwarded request with an error; the
    /// failure's `details` carry the server's `code` and `message`.
    pub const HOST_LANGUAGE_SERVER_ERROR: &str = "plugin.host.languageServerError";
    /// The method or command is not in the language server's declared
    /// `requestMethods`, `commands`, or allowed notifications.
    pub const HOST_METHOD_NOT_DECLARED: &str = "plugin.host.methodNotDeclared";
    /// The request names a contribution, such as a language server, that
    /// another plugin owns.
    pub const HOST_FOREIGN_CONTRIBUTION: &str = "plugin.host.foreignContribution";
    /// A page's call or a host operation ended because the backend process
    /// exited. Reported by hosts to pages, never sent to a backend.
    pub const BACKEND_EXITED: &str = "plugin.backend.exited";

    // Cross-plugin relay (`lithe/host/functions/*`, protocol version 4). Each
    // refusal has its own code and number, so a caller can branch on either.

    /// The caller's manifest does not declare a call to this function.
    pub const NOT_DECLARED: &str = "plugin.function.notDeclared";
    /// The plugin that should provide the function does not export it, or
    /// has not registered it with its running backend.
    pub const NOT_EXPORTED: &str = "plugin.function.notExported";
    /// The providing plugin is not installed or not enabled, or was disabled
    /// or removed while the call was running.
    pub const PROVIDER_DISABLED: &str = "plugin.function.providerDisabled";
    /// The caller declared another contract version than the provider exports.
    pub const VERSION_MISMATCH: &str = "plugin.function.versionMismatch";
    /// The provider is already on the call chain, so the call would come
    /// back to a plugin that is waiting for it (including a plugin calling
    /// itself).
    pub const CALL_CYCLE: &str = "plugin.function.callCycle";
    /// The call chain is longer than the depth limit.
    pub const DEPTH_EXCEEDED: &str = "plugin.function.depthExceeded";
    /// The calling plugin already has the most relayed calls it may have
    /// running at once.
    pub const TOO_MANY_CALLS: &str = "plugin.function.tooManyCalls";
    /// The relayed params or result exceed the relay's byte limit.
    pub const PAYLOAD_TOO_LARGE: &str = "plugin.function.payloadTooLarge";
    /// The provider's backend could not serve the call: it did not start in
    /// time, exited, or withdrew the function while the call ran.
    pub const PROVIDER_UNAVAILABLE: &str = "plugin.function.providerUnavailable";
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
/// Address of one plugin function: the owning plugin plus its function ID.
/// The host routes by plugin identity first, so a reference can never reach
/// a session of another plugin.
pub struct FunctionReference {
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    #[serde(rename = "functionID")]
    pub function_id: String,
}

/// What a session knows when an invocation is planned.
pub(crate) struct FunctionSession<'a> {
    /// Plugin that started the session; `None` for host-owned servers.
    pub plugin_id: Option<&'a str>,
    /// Whether the backend negotiated a supported protocol version.
    pub negotiated: bool,
    /// Currently registered function IDs.
    pub functions: &'a BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Terminal failure of one invocation, before it becomes a runtime error.
pub(crate) struct FunctionFailure {
    pub code: &'static str,
    pub message: String,
    /// Plugin-defined code from `error.data.code`, for the plugin's own UI.
    /// Lithe never interprets it.
    pub plugin_error_code: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// One accepted progress report.
pub(crate) struct FunctionProgress {
    pub operation_id: String,
    pub message: Option<String>,
    /// Whole percent in `0..=100`.
    pub percentage: Option<u64>,
}

/// The client half of the negotiation, placed under `capabilities.experimental`.
pub(crate) fn client_experimental_capabilities() -> (&'static str, Value) {
    (EXPERIMENTAL_KEY, json!({ "versions": SUPPORTED_VERSIONS }))
}

/// The version and functions of a backend that answered a version this
/// client offered, or `None` when the protocol was not negotiated. A
/// malformed function list rejects the whole answer, so a session never
/// starts with half a registry.
pub(crate) fn negotiate(capabilities: &Value) -> Option<(u64, BTreeSet<String>)> {
    let answer = capabilities
        .get("experimental")
        .and_then(|experimental| experimental.get(EXPERIMENTAL_KEY))?;
    let version = answer.get("version").and_then(Value::as_u64)?;
    if !SUPPORTED_VERSIONS.contains(&version) {
        return None;
    }
    let functions = match answer.get("functions") {
        None => BTreeSet::new(),
        Some(descriptors) => descriptor_ids(descriptors, &BTreeSet::new()).ok()?,
    };
    Some((version, functions))
}

/// The registry after a `lithe/function/register` request. The request is
/// all or nothing: one malformed, duplicate, or already registered function,
/// or exceeding the session limit, refuses every function in it.
pub(crate) fn apply_registration(
    current: &BTreeSet<String>,
    params: Option<&Value>,
) -> Result<BTreeSet<String>, &'static str> {
    let descriptors = params
        .and_then(|params| params.get("functions"))
        .filter(|functions| functions.as_array().is_some_and(|items| !items.is_empty()))
        .ok_or("`functions` must be a nonempty array.")?;
    let added = descriptor_ids(descriptors, current)?;
    let mut registry = current.clone();
    registry.extend(added);
    Ok(registry)
}

/// The registry and the withdrawn IDs after a `lithe/function/unregister`
/// request, all or nothing like registration.
pub(crate) fn apply_unregistration(
    current: &BTreeSet<String>,
    params: Option<&Value>,
) -> Result<(BTreeSet<String>, Vec<String>), &'static str> {
    let ids = params
        .and_then(|params| params.get("ids"))
        .and_then(Value::as_array)
        .filter(|ids| !ids.is_empty())
        .ok_or("`ids` must be a nonempty array.")?;
    let mut removed = BTreeSet::new();
    for id in ids {
        let id = id.as_str().ok_or("Every ID must be a string.")?;
        if !current.contains(id) {
            return Err("Only registered functions can be unregistered.");
        }
        if !removed.insert(id.to_string()) {
            return Err("An ID is listed twice.");
        }
    }
    let registry = current.difference(&removed).cloned().collect();
    Ok((registry, removed.into_iter().collect()))
}

/// Params of the `lithe/function/invoke` request for `reference`, or the
/// refusal with its stable code in `details`. Checks run in a fixed order so
/// every host reports the same code for the same request.
pub(crate) fn plan_invocation(
    session: &FunctionSession<'_>,
    reference: &FunctionReference,
    operation_id: &str,
    params: &Value,
) -> Result<Value, CoreError> {
    if !is_plugin_id(&reference.plugin_id) || !is_function_id(&reference.function_id) {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "The function reference is malformed.",
            codes::INVALID_REFERENCE,
        ));
    }
    if !params.is_object() {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "Function params must be a JSON object.",
            codes::INVALID_PARAMS,
        ));
    }
    let Some(owner) = session.plugin_id else {
        return Err(refusal(
            ErrorCode::NotSupported,
            "This session does not belong to a plugin.",
            codes::UNAVAILABLE,
        ));
    };
    if owner != reference.plugin_id {
        return Err(refusal(
            ErrorCode::PermissionDenied,
            "The function belongs to another plugin.",
            codes::WRONG_PLUGIN,
        ));
    }
    if !session.negotiated {
        return Err(refusal(
            ErrorCode::NotSupported,
            "The plugin process did not agree on a plugin-function protocol version.",
            codes::UNAVAILABLE,
        ));
    }
    if !session.functions.contains(&reference.function_id) {
        return Err(refusal(
            ErrorCode::NotSupported,
            "The plugin has not registered this function.",
            codes::UNKNOWN,
        ));
    }
    Ok(json!({
        "functionID": reference.function_id,
        "operationID": operation_id,
        "params": params
    }))
}

/// Normalizes the backend's JSON-RPC response to an invocation. A success is
/// wrapped as `{ "value": result }` like build-provider replies, so `null` is
/// a valid result distinct from a missing one.
pub(crate) fn invocation_outcome(response: &Value) -> Result<Value, FunctionFailure> {
    if let Some(error) = response.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .map(bounded_message)
            .filter(|message| !message.is_empty())
            .unwrap_or_else(|| "The plugin function failed.".to_string());
        let plugin_error_code = error
            .get("data")
            .and_then(|data| data.get("code"))
            .and_then(Value::as_str)
            .filter(|code| is_plugin_error_code(code))
            .map(ToString::to_string);
        return Err(FunctionFailure {
            code: codes::FAILED,
            message,
            plugin_error_code,
        });
    }
    let Some(result) = response.get("result") else {
        return Err(invalid_result("The plugin function returned no result."));
    };
    // Serialized length is what crosses the C ABI and the host bridge.
    if result.to_string().len() > MAX_RESULT_BYTES {
        return Err(invalid_result(
            "The plugin function returned more data than a function result may hold.",
        ));
    }
    Ok(json!({ "value": result }))
}

/// A progress report that is well formed, or `None` to ignore it. Whether the
/// operation is still running is the engine's check, not this function's.
pub(crate) fn parse_progress(params: Option<&Value>) -> Option<FunctionProgress> {
    let params = params?.as_object()?;
    let operation_id = params.get("operationID")?.as_str()?.to_string();
    let message = match params.get("message") {
        None => None,
        Some(message) => Some(bounded_message(message.as_str()?)),
    };
    let percentage = match params.get("percentage") {
        None => None,
        Some(percentage) => Some(percentage.as_u64().filter(|value| *value <= 100)?),
    };
    Some(FunctionProgress {
        operation_id,
        message,
        percentage,
    })
}

/// The stable code for a backend request the host refuses on principle, or
/// `None` for any other method. Domain dispatch can route back into the
/// requesting backend, whose handler would then wait on itself; host
/// capabilities are offered per protocol version, and version 1 offers none.
pub(crate) fn refused_backend_request(method: &str) -> Option<&'static str> {
    if method == INVOKE_METHOD
        || method.starts_with("lithe/build/")
        || method.starts_with("lithe/keymap/")
    {
        Some(codes::RECURSIVE_CALL)
    } else if method.starts_with("lithe/host/") {
        Some(codes::HOST_UNAVAILABLE)
    } else {
        None
    }
}

/// Why a backend's `lithe/host/*` request is not forwarded to the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostRequestRefusal {
    /// JSON-RPC error code of the answer.
    pub rpc_code: i64,
    /// Stable contract code, sent as `error.data.code`.
    pub code: &'static str,
    pub message: &'static str,
    /// Sent as `error.data.details`, such as the `option` a host does not
    /// support.
    pub details: Option<Value>,
}

/// Where an accepted `lithe/host/*` request goes.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum HostRoute {
    /// To the host, as a `hostRequest` event of this service.
    Forward(&'static str),
    /// Answered by Core with this result; the host never sees the request.
    Answer(Value),
    /// Another plugin's function: Core's relay checks, dispatches, and
    /// answers it. The host sees only the start request for a provider whose
    /// backend is not running.
    Relay,
}

/// How Core checks the params of one host method before the host sees them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HostParams {
    /// Absent, `null`, or `{}`.
    Empty,
    /// `{ key }`, or `{ key, secret }` when `with_secret`.
    Credential { with_secret: bool },
    /// `{ subscriptionID }`.
    Subscription,
    /// Exactly `{ context }`, a well-formed context reference.
    Context,
    /// Snapshot source listing or one bounded chunk from a selected source.
    KeymapSnapshot { chunk: bool },
    /// `{ context, serverID, method, params?, timeoutMilliseconds? }`: one
    /// request to the plugin's own language server (plan API-25).
    LanguageServerRequest,
    /// `{ context, serverID, method, params? }`: one notification to it.
    LanguageServerNotify,
    /// `{ context, serverID, state, message?, percentage? }`: the plugin's
    /// preparation status of the server.
    LanguageServerStatus,
    /// `{ context, scheme, function }`: the function that supplies the text
    /// of a URI scheme (plan API-12).
    ContentProvider,
    /// Exactly `{ functionID }`, a well-formed function ID.
    FunctionProviders,
    /// `{ pluginID, functionID, context, params?, timeoutMilliseconds? }`.
    FunctionInvoke,
    /// Any object whose `context`, when present, is a well-formed
    /// reference. The service checks the rest and answers
    /// `plugin.host.invalidParams` or, for a field it does not know,
    /// `plugin.host.unsupportedOption` itself; for methods whose params
    /// Core cannot type without owning their domain.
    // No row of version 3 uses it yet; the file, editor, and window services
    // that follow add their rows with it.
    #[allow(dead_code)]
    Object,
}

/// One row of the host-method table.
pub(crate) struct HostMethod {
    pub method: &'static str,
    /// Service whose grant admits the method.
    pub service: &'static str,
    /// First protocol version that defines the method.
    pub since: u64,
    pub params: HostParams,
    /// A separate grant per method for new services; legacy services use their aggregate grant.
    pub permission: Option<&'static str>,
}

/// Every backend-to-host method Core admits. A method missing here is
/// `plugin.host.unavailable` whatever the host could do, so a new host
/// service adds its rows here, its grant to `GRANTABLE_HOST_SERVICES` and
/// the manifest permission, and its handler to the host's dispatcher.
pub(crate) const HOST_METHODS: &[HostMethod] = &[
    HostMethod {
        method: FUNCTIONS_PROVIDERS,
        service: HOST_SERVICE_FUNCTIONS,
        permission: None,
        since: RELAY_VERSION,
        params: HostParams::FunctionProviders,
    },
    HostMethod {
        method: FUNCTIONS_INVOKE,
        service: HOST_SERVICE_FUNCTIONS,
        permission: None,
        since: RELAY_VERSION,
        params: HostParams::FunctionInvoke,
    },
    HostMethod {
        method: "lithe/host/keymapImport/listInputs",
        service: "keymapImport",
        permission: Some("keymaps.readSelectedSources"),
        since: CONTEXT_VERSION,
        params: HostParams::KeymapSnapshot { chunk: false },
    },
    HostMethod {
        method: "lithe/host/keymapImport/readChunk",
        service: "keymapImport",
        permission: Some("keymaps.readSelectedSources"),
        since: CONTEXT_VERSION,
        params: HostParams::KeymapSnapshot { chunk: true },
    },
    HostMethod {
        method: "lithe/host/terminal/reopen",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/terminal/dispose",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/terminal/create",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/terminal/show",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/terminal/close",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/terminal/onExit",
        service: "terminal",
        permission: Some("terminal.create"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: CREDENTIALS_GET,
        service: HOST_SERVICE_CREDENTIALS,
        permission: None,
        since: 2,
        params: HostParams::Credential { with_secret: false },
    },
    HostMethod {
        method: CREDENTIALS_SET,
        service: HOST_SERVICE_CREDENTIALS,
        permission: None,
        since: 2,
        params: HostParams::Credential { with_secret: true },
    },
    HostMethod {
        method: CREDENTIALS_DELETE,
        service: HOST_SERVICE_CREDENTIALS,
        permission: None,
        since: 2,
        params: HostParams::Credential { with_secret: false },
    },
    HostMethod {
        method: GET_CAPABILITIES,
        service: HOST_SERVICE_HOST,
        permission: None,
        since: CONTEXT_VERSION,
        params: HostParams::Empty,
    },
    HostMethod {
        method: SUBSCRIPTIONS_DISPOSE,
        service: HOST_SERVICE_SUBSCRIPTIONS,
        permission: None,
        since: CONTEXT_VERSION,
        params: HostParams::Subscription,
    },
    HostMethod {
        method: WORKSPACE_LIST_CONTEXTS,
        service: HOST_SERVICE_WORKSPACE,
        permission: None,
        since: CONTEXT_VERSION,
        params: HostParams::Empty,
    },
    HostMethod {
        method: WORKSPACE_GET_CONTEXT,
        service: HOST_SERVICE_WORKSPACE,
        permission: None,
        since: CONTEXT_VERSION,
        params: HostParams::Context,
    },
    HostMethod {
        method: WORKSPACE_GET_FOLDERS,
        service: HOST_SERVICE_WORKSPACE,
        permission: None,
        since: CONTEXT_VERSION,
        params: HostParams::Context,
    },
    HostMethod {
        method: "lithe/host/workspace/readDirectory",
        service: "workspace",
        permission: Some("workspace.files.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/workspace/stat",
        service: "workspace",
        permission: Some("workspace.files.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/workspace/readFile",
        service: "workspace",
        permission: Some("workspace.files.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/workspace/watch",
        service: "workspace",
        permission: Some("workspace.files.watch"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/workspace/findFiles",
        service: "workspace",
        permission: Some("workspace.search"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/workspace/findText",
        service: "workspace",
        permission: Some("workspace.search"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/documents/list",
        service: "documents",
        permission: Some("documents.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/documents/getSnapshot",
        service: "documents",
        permission: Some("documents.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/registerActions",
        service: "editor",
        permission: Some("editor.actions"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/registerProviders",
        service: "editor",
        permission: Some("editor.providers"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/getActive",
        service: "editor",
        permission: Some("documents.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/getSelections",
        service: "editor",
        permission: Some("documents.read"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/applyEdits",
        service: "editor",
        permission: Some("editor.edit"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/replaceSelections",
        service: "editor",
        permission: Some("editor.edit"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/insertText",
        service: "editor",
        permission: Some("editor.edit"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/open",
        service: "editor",
        permission: Some("editor.open"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/editor/reveal",
        service: "editor",
        permission: Some("editor.open"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/preview/openHTML",
        service: "preview",
        permission: Some("preview.open"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/browser/openExternal",
        service: "browser",
        permission: Some("browser.open"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/window/showInformation",
        service: "window",
        permission: Some("window.messages"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/window/showWarning",
        service: "window",
        permission: Some("window.messages"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    HostMethod {
        method: "lithe/host/window/showError",
        service: "window",
        permission: Some("window.messages"),
        since: CONTEXT_VERSION,
        params: HostParams::Object,
    },
    // Plan API-25: the plugin's own language servers. The host resolves
    // `{ context, serverID }` to the session and Core's
    // `lsp.pluginServerRequest` enforces the declared session policy.
    HostMethod {
        method: LANGUAGE_SERVER_REQUEST,
        service: HOST_SERVICE_LANGUAGE_SERVER,
        permission: Some(PERMISSION_LANGUAGE_SERVER_REQUEST),
        since: CONTEXT_VERSION,
        params: HostParams::LanguageServerRequest,
    },
    HostMethod {
        method: LANGUAGE_SERVER_NOTIFY,
        service: HOST_SERVICE_LANGUAGE_SERVER,
        permission: Some(PERMISSION_LANGUAGE_SERVER_REQUEST),
        since: CONTEXT_VERSION,
        params: HostParams::LanguageServerNotify,
    },
    HostMethod {
        method: LANGUAGE_SERVER_SET_STATUS,
        service: HOST_SERVICE_LANGUAGE_SERVER,
        permission: Some(PERMISSION_LANGUAGE_SERVER_REQUEST),
        since: CONTEXT_VERSION,
        params: HostParams::LanguageServerStatus,
    },
    // Plan API-12: read-only text of a URI scheme the backend serves.
    HostMethod {
        method: DOCUMENTS_REGISTER_CONTENT_PROVIDER,
        service: "documents",
        permission: Some(PERMISSION_DOCUMENTS_CONTENT_PROVIDER),
        since: CONTEXT_VERSION,
        params: HostParams::ContentProvider,
    },
];

/// Host service of the plugin's own language servers (plan API-25).
pub(crate) const HOST_SERVICE_LANGUAGE_SERVER: &str = "languageServer";
/// Forwards one declared request to the plugin's language server.
pub(crate) const LANGUAGE_SERVER_REQUEST: &str = "lithe/host/languageServer/request";
/// Forwards one notification to the plugin's language server.
pub(crate) const LANGUAGE_SERVER_NOTIFY: &str = "lithe/host/languageServer/notify";
/// Reports the plugin's preparation state of a language server to the user.
pub(crate) const LANGUAGE_SERVER_SET_STATUS: &str = "lithe/host/languageServer/setStatus";
/// Registers a backend function as the content provider of a URI scheme.
pub(crate) const DOCUMENTS_REGISTER_CONTENT_PROVIDER: &str =
    "lithe/host/documents/registerContentProvider";
/// Lifecycle of a language server the plugin declares.
const LANGUAGE_SERVER_DID_CHANGE_STATE: &str = "lithe/host/languageServer/didChangeState";
/// A server notification the language server's `forwardNotifications` lists.
const LANGUAGE_SERVER_DID_RECEIVE_NOTIFICATION: &str =
    "lithe/host/languageServer/didReceiveNotification";

/// Services every plugin-owned session of their version has without a
/// permission: they reveal nothing beyond the session's own grants.
fn is_implicit_service(service: &str) -> bool {
    service == HOST_SERVICE_HOST
        || service == HOST_SERVICE_SUBSCRIPTIONS
        || service == HOST_SERVICE_COMMANDS
}

/// Where a backend request for a host service goes, or why it is refused.
/// `version` is the negotiated protocol version (0 when not negotiated) and
/// `granted` the services the plugin's permissions grant the session. The
/// params are checked here, so the host only ever sees a well-formed
/// request. From version 3 a field the method does not define is
/// `plugin.host.unsupportedOption` naming it, so a later host can add it as
/// an option without a new version and a backend can tell an option this
/// host lacks from a malformed request.
pub(crate) fn host_request(
    method: &str,
    params: Option<&Value>,
    version: u64,
    granted: &BTreeSet<String>,
) -> Result<HostRoute, HostRequestRefusal> {
    let Some(entry) = HOST_METHODS
        .iter()
        .find(|entry| entry.method == method && version >= entry.since.max(HOST_SERVICES_VERSION))
    else {
        return Err(HostRequestRefusal {
            rpc_code: -32601,
            code: codes::HOST_UNAVAILABLE,
            message: "The host offers no such service to this plugin process.",
            details: None,
        });
    };
    if !is_implicit_service(entry.service)
        && !granted.contains(if entry.permission.is_some() {
            entry.method
        } else {
            entry.service
        })
    {
        return Err(HostRequestRefusal {
            // Version 2 answered a missing grant like a missing method.
            rpc_code: if version >= CONTEXT_VERSION {
                host_rpc_code(codes::HOST_PERMISSION_DENIED)
            } else {
                -32601
            },
            code: codes::HOST_PERMISSION_DENIED,
            message: "The plugin does not declare the permission for this host service.",
            details: None,
        });
    }
    if version >= CONTEXT_VERSION
        && params.is_some_and(|value| value.to_string().len() > MAX_RESULT_BYTES)
    {
        return Err(HostRequestRefusal {
            rpc_code: host_rpc_code(codes::HOST_LIMIT_EXCEEDED),
            code: codes::HOST_LIMIT_EXCEEDED,
            message: "Host request exceeds the byte limit.",
            details: None,
        });
    }
    check_host_params(entry.params, params, version)?;
    if entry.method == GET_CAPABILITIES {
        return Ok(HostRoute::Answer(capabilities_answer(version, granted)));
    }
    if entry.service == HOST_SERVICE_FUNCTIONS {
        return Ok(HostRoute::Relay);
    }
    Ok(HostRoute::Forward(entry.service))
}

/// The params the host receives for an accepted request: the backend's own,
/// except that a status message is cut to the bound a progress message has,
/// so a hostile backend cannot inflate every event that carries it.
pub(crate) fn forwarded_host_params(method: &str, params: Option<&Value>) -> Value {
    let mut forwarded = params.cloned().unwrap_or(Value::Null);
    if method == LANGUAGE_SERVER_SET_STATUS {
        if let Some(message) = forwarded.get_mut("message") {
            if let Some(text) = message.as_str() {
                *message = Value::String(bounded_message(text));
            }
        }
    }
    forwarded
}

/// The answer to `lithe/host/getCapabilities`: the negotiated version, the
/// services and methods this session may call, where the backend runs, and
/// the bounds Core enforces. It lists only what the session is granted, so
/// it reveals nothing about other plugins. `granted` is what the host
/// passed to `lsp.startServer.hostServices`; a host passes only services it
/// serves, so a listed method never answers `plugin.host.unavailable` for
/// want of a handler.
pub(crate) fn capabilities_answer(version: u64, granted: &BTreeSet<String>) -> Value {
    let admitted = |service: &str| is_implicit_service(service) || granted.contains(service);
    let mut services = serde_json::Map::new();
    let mut add = |service: &str, kind: &str, method: &str| {
        let entry = services
            .entry(service.to_string())
            .or_insert_with(|| json!({ "methods": [], "notifications": [] }));
        if let Some(list) = entry[kind].as_array_mut() {
            list.push(json!(method));
        }
    };
    for entry in HOST_METHODS.iter().filter(|entry| {
        version >= entry.since
            && if entry.permission.is_some() {
                granted.contains(entry.method)
            } else {
                admitted(entry.service)
            }
    }) {
        add(entry.service, "methods", entry.method);
    }
    for entry in HOST_NOTIFICATIONS.iter().filter(|entry| {
        version >= entry.since
            && (is_implicit_service(entry.service) || holds_service(entry.service, granted))
    }) {
        add(entry.service, "notifications", entry.method);
    }
    json!({
        "protocolVersion": version,
        // The host starts every plugin backend on the machine that runs
        // Lithe, also for remote workspaces.
        "backendAuthority": "local",
        "services": services,
        "limits": {
            "pendingHostRequests": MAX_PENDING_HOST_REQUESTS,
            "functionResultBytes": MAX_RESULT_BYTES,
            "hostRequestBytes": MAX_RESULT_BYTES,
            "hostResultBytes": MAX_RESULT_BYTES,
            "errorMessageBytes": MAX_MESSAGE_BYTES,
            "errorDetailsBytes": MAX_HOST_DETAILS_BYTES,
            "notificationBytes": MAX_HOST_NOTIFICATION_BYTES,
        },
    })
}

/// How Core checks the params of one host-to-backend notification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotificationParams {
    /// Exactly `{ revision }`, a positive integer.
    Revision,
    /// Exactly `{ subscriptionID, sequence, event }`: the subscription the
    /// backend holds, a positive sequence that grows per subscription, and
    /// the service's event object.
    SubscriptionEvent,
    /// `{ commandID, context? }`: one of the plugin's own commands and the
    /// workspace context of the window it ran in.
    Command,
    /// `{ context, serverID, state, generation }`: a lifecycle change of one
    /// of the plugin's language servers.
    LanguageServerState,
    /// `{ context, serverID, generation, method, params? | truncated }`: a
    /// forwarded server notification, without params when too large.
    LanguageServerNotification,
}

/// One row of the host-notification table.
pub(crate) struct HostNotification {
    pub method: &'static str,
    /// Service whose grant admits sending it; implicit services need none.
    pub service: &'static str,
    pub since: u64,
    pub params: NotificationParams,
}

const WORKSPACE_DID_CHANGE_CONTEXTS: &str = "lithe/host/workspace/didChangeContexts";
const SUBSCRIPTIONS_NOTIFY: &str = "lithe/host/subscriptions/notify";
const COMMANDS_DID_RUN: &str = "lithe/host/commands/didRun";
/// The plugin's own UI commands reaching its backend. Every plugin-owned
/// session of version 3 has it; a command names only the plugin's own IDs.
const HOST_SERVICE_COMMANDS: &str = "commands";

/// Every host-to-backend notification the host may send through
/// `lsp.hostNotify`. A notification missing here never reaches a backend,
/// so the host cannot use the channel to call into the backend's own
/// protocol (functions, build or VCS methods).
pub(crate) const HOST_NOTIFICATIONS: &[HostNotification] = &[
    HostNotification {
        method: WORKSPACE_DID_CHANGE_CONTEXTS,
        service: HOST_SERVICE_WORKSPACE,
        since: CONTEXT_VERSION,
        params: NotificationParams::Revision,
    },
    HostNotification {
        method: SUBSCRIPTIONS_NOTIFY,
        service: HOST_SERVICE_SUBSCRIPTIONS,
        since: CONTEXT_VERSION,
        params: NotificationParams::SubscriptionEvent,
    },
    HostNotification {
        method: COMMANDS_DID_RUN,
        service: HOST_SERVICE_COMMANDS,
        since: CONTEXT_VERSION,
        params: NotificationParams::Command,
    },
    HostNotification {
        method: LANGUAGE_SERVER_DID_CHANGE_STATE,
        service: HOST_SERVICE_LANGUAGE_SERVER,
        since: CONTEXT_VERSION,
        params: NotificationParams::LanguageServerState,
    },
    HostNotification {
        method: LANGUAGE_SERVER_DID_RECEIVE_NOTIFICATION,
        service: HOST_SERVICE_LANGUAGE_SERVER,
        since: CONTEXT_VERSION,
        params: NotificationParams::LanguageServerNotification,
    },
];

/// Whether the session holds a service: its aggregate grant, or, for a
/// service granted per method, any of its methods.
fn holds_service(service: &str, granted: &BTreeSet<String>) -> bool {
    granted.contains(service)
        || HOST_METHODS.iter().any(|entry| {
            entry.service == service && entry.permission.is_some() && granted.contains(entry.method)
        })
}

/// A language server state a `didChangeState` notification may carry.
fn is_language_server_state(value: &str) -> bool {
    matches!(value, "starting" | "running" | "stopped" | "crashed")
}

/// Whether a host notification reaches this session. `Ok(false)` means the
/// backend negotiated a version without it, so the host may skip it; a
/// method outside the table, one whose service the session was not
/// granted, or malformed params are the host's mistake and refused.
pub(crate) fn host_notification(
    method: &str,
    params: &Value,
    version: u64,
    granted: &BTreeSet<String>,
) -> Result<bool, CoreError> {
    let invalid = |message: &str| {
        refusal(
            ErrorCode::InvalidRequest,
            message,
            codes::HOST_INVALID_PARAMS,
        )
    };
    let Some(entry) = HOST_NOTIFICATIONS
        .iter()
        .find(|entry| entry.method == method)
    else {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "The host may not send this notification to a plugin process.",
            codes::HOST_UNAVAILABLE,
        ));
    };
    if !is_implicit_service(entry.service) && !holds_service(entry.service, granted) {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "The session was not granted the service of this notification.",
            codes::HOST_PERMISSION_DENIED,
        ));
    }
    let Some(object) = params.as_object() else {
        return Err(invalid("Notification params must be an object."));
    };
    if serde_json::to_vec(params).map_or(true, |bytes| bytes.len() > MAX_HOST_NOTIFICATION_BYTES) {
        return Err(invalid(
            "Notification params exceed the notification bound.",
        ));
    }
    let positive = |key: &str| {
        object
            .get(key)
            .and_then(Value::as_u64)
            .is_some_and(|value| value >= 1)
    };
    let only = |keys: &[&str]| object.keys().all(|key| keys.contains(&key.as_str()));
    let well_formed = match entry.params {
        NotificationParams::Revision => only(&["revision"]) && positive("revision"),
        NotificationParams::SubscriptionEvent => {
            only(&["subscriptionID", "sequence", "event"])
                && object
                    .get("subscriptionID")
                    .and_then(Value::as_str)
                    .is_some_and(is_credential_key)
                && positive("sequence")
                && object.get("event").is_some_and(Value::is_object)
        }
        NotificationParams::Command => {
            only(&["commandID", "context"])
                && object
                    .get("commandID")
                    .and_then(Value::as_str)
                    .is_some_and(is_command_id)
                && object.get("context").map_or(true, is_context_reference)
        }
        NotificationParams::LanguageServerState => {
            only(&["context", "serverID", "state", "generation"])
                && object.get("context").is_some_and(is_context_reference)
                && object
                    .get("serverID")
                    .and_then(Value::as_str)
                    .is_some_and(is_protocol_name)
                && object
                    .get("state")
                    .and_then(Value::as_str)
                    .is_some_and(is_language_server_state)
                && positive("generation")
        }
        NotificationParams::LanguageServerNotification => {
            let truncated = object.get("truncated");
            only(&[
                "context",
                "serverID",
                "generation",
                "method",
                "params",
                "truncated",
            ]) && object.get("context").is_some_and(is_context_reference)
                && object
                    .get("serverID")
                    .and_then(Value::as_str)
                    .is_some_and(is_protocol_name)
                && object
                    .get("method")
                    .and_then(Value::as_str)
                    .is_some_and(is_protocol_name)
                && positive("generation")
                // A truncated notification drops its params entirely.
                && match truncated {
                    None => true,
                    Some(Value::Bool(true)) => !object.contains_key("params"),
                    Some(_) => false,
                }
        }
    };
    if !well_formed {
        return Err(invalid(
            "Notification params do not match the notification.",
        ));
    }
    Ok(version >= entry.since)
}

/// A UI command ID as the manifest schema spells it: `[a-z0-9.-]+`.
fn is_command_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_FUNCTION_ID_BYTES
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '.' | '-')
        })
}

fn check_host_params(
    rule: HostParams,
    params: Option<&Value>,
    version: u64,
) -> Result<(), HostRequestRefusal> {
    let invalid = |message| HostRequestRefusal {
        rpc_code: -32602,
        code: codes::HOST_INVALID_PARAMS,
        message,
        details: None,
    };
    let empty = serde_json::Map::new();
    let params = match params {
        None | Some(Value::Null) if rule == HostParams::Empty => &empty,
        Some(Value::Object(params)) => params,
        _ => return Err(invalid("Params must be an object.")),
    };
    let allowed: &[&str] = match rule {
        HostParams::Empty => &[],
        HostParams::Credential { with_secret: true } => &["key", "secret"],
        HostParams::Credential { with_secret: false } => &["key"],
        HostParams::Subscription => &["subscriptionID"],
        HostParams::Context => &["context"],
        HostParams::FunctionProviders => &["functionID"],
        HostParams::FunctionInvoke => &[
            "pluginID",
            "functionID",
            "context",
            "params",
            "timeoutMilliseconds",
            "parentOperationID",
        ],
        HostParams::KeymapSnapshot { chunk: false } => &["snapshotID", "providerID"],
        HostParams::KeymapSnapshot { chunk: true } => &[
            "snapshotID",
            "providerID",
            "fileID",
            "offset",
            "maximumBytes",
        ],
        HostParams::LanguageServerRequest => &[
            "context",
            "serverID",
            "method",
            "params",
            "timeoutMilliseconds",
        ],
        HostParams::LanguageServerNotify => &["context", "serverID", "method", "params"],
        HostParams::LanguageServerStatus => {
            &["context", "serverID", "state", "message", "percentage"]
        }
        HostParams::ContentProvider => &["context", "scheme", "function"],
        HostParams::Object => {
            return match params.get("context") {
                Some(context) if !is_context_reference(context) => {
                    Err(invalid(CONTEXT_REFERENCE_MESSAGE))
                }
                _ => Ok(()),
            };
        }
    };
    if let Some(option) = params.keys().find(|key| !allowed.contains(&key.as_str())) {
        // Version 2 answered every unknown field as malformed params.
        if version < CONTEXT_VERSION {
            return Err(invalid("Params name a field this service does not define."));
        }
        return Err(HostRequestRefusal {
            rpc_code: host_rpc_code(codes::HOST_UNSUPPORTED_OPTION),
            code: codes::HOST_UNSUPPORTED_OPTION,
            message: "Params name an option this host does not support.",
            details: Some(json!({ "option": option })),
        });
    }
    match rule {
        HostParams::Credential { with_secret } => {
            if !params
                .get("key")
                .and_then(Value::as_str)
                .is_some_and(is_credential_key)
            {
                return Err(invalid(
                    "A credential key is 1-128 ASCII letters, digits, '.', '_', ':' or '-'.",
                ));
            }
            if with_secret
                && !params
                    .get("secret")
                    .and_then(Value::as_str)
                    .is_some_and(|secret| secret.len() <= MAX_CREDENTIAL_SECRET_BYTES)
            {
                return Err(invalid("A secret is a string of at most 16 KiB."));
            }
        }
        HostParams::Subscription => {
            if !params
                .get("subscriptionID")
                .and_then(Value::as_str)
                .is_some_and(is_credential_key)
            {
                return Err(invalid(
                    "A subscription ID is 1-128 ASCII letters, digits, '.', '_', ':' or '-'.",
                ));
            }
        }
        HostParams::Context => {
            if !params.get("context").is_some_and(is_context_reference) {
                return Err(invalid(CONTEXT_REFERENCE_MESSAGE));
            }
        }
        HostParams::FunctionProviders => {
            if !params
                .get("functionID")
                .and_then(Value::as_str)
                .is_some_and(is_function_id)
            {
                return Err(invalid(FUNCTION_ID_MESSAGE));
            }
        }
        HostParams::FunctionInvoke => check_function_invoke_params(params)?,
        HostParams::KeymapSnapshot { chunk } => {
            let opaque_id = |key: &str| {
                params.get(key).and_then(Value::as_str).is_some_and(|id| {
                    !id.is_empty()
                        && id.len() <= 128
                        && id
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
                })
            };
            let provider = params
                .get("providerID")
                .and_then(Value::as_str)
                .is_some_and(crate::plugins::keymap_import::valid_provider_id);
            let valid_chunk = !chunk
                || (opaque_id("fileID")
                    && params
                        .get("offset")
                        .and_then(Value::as_u64)
                        .is_some_and(|offset| {
                            offset <= crate::plugins::keymap_import::MAX_INPUT_FILE_BYTES as u64
                        })
                    && params
                        .get("maximumBytes")
                        .and_then(Value::as_u64)
                        .is_some_and(|size| {
                            size > 0
                                && size
                                    <= crate::plugins::keymap_import::MAX_INPUT_CHUNK_BYTES as u64
                        }));
            if !opaque_id("snapshotID") || !provider || !valid_chunk {
                return Err(invalid(
                    "Snapshot source parameters are malformed or exceed their bounds.",
                ));
            }
        }
        HostParams::LanguageServerRequest
        | HostParams::LanguageServerNotify
        | HostParams::LanguageServerStatus => {
            check_language_server_params(rule, params, &invalid)?;
        }
        HostParams::ContentProvider => {
            if !params.get("context").is_some_and(is_context_reference) {
                return Err(invalid(CONTEXT_REFERENCE_MESSAGE));
            }
            let scheme = params.get("scheme").and_then(Value::as_str);
            if !scheme.is_some_and(is_content_scheme) {
                return Err(invalid(
                    "A content scheme is 1-64 lowercase ASCII letters, digits, '+', '-' or '.', starts with a letter, and is not a scheme the host owns.",
                ));
            }
            if !params
                .get("function")
                .and_then(Value::as_str)
                .is_some_and(is_function_id)
            {
                return Err(invalid(
                    "The content function must be a plugin function ID.",
                ));
            }
        }
        HostParams::Empty | HostParams::Object => {}
    }
    Ok(())
}

/// Checks the params the `languageServer` host methods share: the context,
/// the server, the method, and each method's own fields. Whether the server
/// belongs to the plugin and the method is declared is the engine's answer,
/// since only it holds the session policy.
fn check_language_server_params(
    rule: HostParams,
    params: &serde_json::Map<String, Value>,
    invalid: &dyn Fn(&'static str) -> HostRequestRefusal,
) -> Result<(), HostRequestRefusal> {
    if !params.get("context").is_some_and(is_context_reference) {
        return Err(invalid(CONTEXT_REFERENCE_MESSAGE));
    }
    if !params
        .get("serverID")
        .and_then(Value::as_str)
        .is_some_and(is_protocol_name)
    {
        return Err(invalid(
            "serverID must name one of the plugin's language servers.",
        ));
    }
    if rule == HostParams::LanguageServerStatus {
        if !params
            .get("state")
            .and_then(Value::as_str)
            .is_some_and(is_status_state)
        {
            return Err(invalid(
                "state is one of preparing, ready, degraded, or failed.",
            ));
        }
        if params
            .get("message")
            .is_some_and(|message| !message.is_string())
        {
            return Err(invalid("message must be a string."));
        }
        if params
            .get("percentage")
            .is_some_and(|value| !value.as_u64().is_some_and(|percentage| percentage <= 100))
        {
            return Err(invalid("percentage is a whole number from 0 to 100."));
        }
        return Ok(());
    }
    if !params
        .get("method")
        .and_then(Value::as_str)
        .is_some_and(is_protocol_name)
    {
        return Err(invalid("method must be a non-empty LSP method name."));
    }
    if rule == HostParams::LanguageServerRequest
        && params.get("timeoutMilliseconds").is_some_and(|value| {
            !value.as_u64().is_some_and(|milliseconds| {
                (1..=language_server_sessions::MAX_REQUEST_TIMEOUT_MILLISECONDS)
                    .contains(&milliseconds)
            })
        })
    {
        return Err(invalid(
            "timeoutMilliseconds is a whole number from 1 to 300000.",
        ));
    }
    Ok(())
}

const FUNCTION_ID_MESSAGE: &str =
    "A function ID is dot-separated lowerCamelCase segments of at most 128 bytes.";

/// The shape of a `lithe/host/functions/invoke` request. Whether the caller
/// declared the call and the provider exports it is the relay's check, which
/// needs the plugin snapshot.
fn check_function_invoke_params(
    params: &serde_json::Map<String, Value>,
) -> Result<(), HostRequestRefusal> {
    let invalid = |message| HostRequestRefusal {
        rpc_code: -32602,
        code: codes::HOST_INVALID_PARAMS,
        message,
        details: None,
    };
    if !params
        .get("pluginID")
        .and_then(Value::as_str)
        .is_some_and(is_plugin_id)
    {
        return Err(invalid(
            "A plugin ID is lowercase letters, digits, '.' and '-'.",
        ));
    }
    if !params
        .get("functionID")
        .and_then(Value::as_str)
        .is_some_and(is_function_id)
    {
        return Err(invalid(FUNCTION_ID_MESSAGE));
    }
    if !params.get("context").is_some_and(is_context_reference) {
        return Err(invalid(CONTEXT_REFERENCE_MESSAGE));
    }
    if params.get("params").is_some_and(|value| !value.is_object()) {
        return Err(invalid("Function params must be a JSON object."));
    }
    if params
        .get("timeoutMilliseconds")
        .is_some_and(|value| !value.as_u64().is_some_and(|milliseconds| milliseconds >= 1))
    {
        return Err(invalid("A timeout is a positive number of milliseconds."));
    }
    // Only the shape is checked here. Whether the ID names a call this backend
    // is serving needs the session's pending requests, so the relay decides.
    if params.get("parentOperationID").is_some_and(|value| {
        !value
            .as_str()
            .is_some_and(|id| (1..=128).contains(&id.len()))
    }) {
        return Err(invalid(
            "A parent operation ID is the operationID of a call this backend is serving, 1-128 bytes.",
        ));
    }
    Ok(())
}

/// A preparation state a plugin may report for its language server.
fn is_status_state(value: &str) -> bool {
    matches!(value, "preparing" | "ready" | "degraded" | "failed")
}

/// Schemes the host or the platform resolves itself. A plugin that served
/// one would replace what the user expects the URI to open.
const RESERVED_CONTENT_SCHEMES: &[&str] = &[
    "about",
    "blob",
    "data",
    "file",
    "ftp",
    "http",
    "https",
    "javascript",
    "lithe",
    "mailto",
    "untitled",
    "ws",
    "wss",
];

/// A URI scheme a plugin may serve (RFC 3986, lowercase, bounded).
fn is_content_scheme(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_lowercase())
        && value.len() <= 64
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '+' | '-' | '.')
        })
        && !RESERVED_CONTENT_SCHEMES.contains(&value)
}

const CONTEXT_REFERENCE_MESSAGE: &str =
    "A context is { contextID, generation }: an ID of 1-128 ASCII letters, digits, '.', '_', ':' or '-', and a positive generation.";

/// `{ contextID, generation }` naming one generation of one workspace
/// context. Only the shape is checked here; whether it is still current is
/// the host's answer (`plugin.host.contextExpired`).
pub(crate) fn is_context_reference(value: &Value) -> bool {
    let Some(reference) = value.as_object() else {
        return false;
    };
    reference.len() == 2
        && reference
            .get("contextID")
            .and_then(Value::as_str)
            .is_some_and(is_credential_key)
        && reference
            .get("generation")
            .and_then(Value::as_u64)
            .is_some_and(|generation| generation >= 1)
}

/// Adds the workspace context the host named to the params of one
/// `lithe/function/invoke`. A malformed reference is refused. A backend
/// that negotiated a version without contexts receives the call unchanged,
/// so a page works with an older backend exactly as before.
pub(crate) fn attach_context(
    invoke_params: &mut Value,
    version: u64,
    context: Option<&Value>,
) -> Result<(), CoreError> {
    let Some(context) = context else {
        return Ok(());
    };
    if !is_context_reference(context) {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "The workspace context reference is malformed.",
            codes::INVALID_PARAMS,
        ));
    }
    if version >= CONTEXT_VERSION {
        if let Some(params) = invoke_params.as_object_mut() {
            params.insert("context".to_string(), context.clone());
        }
    }
    Ok(())
}

/// Writes the calling plugin into the params of a relayed
/// `lithe/function/invoke` as `caller: { "pluginID": ... }`, a sibling of
/// `functionID`, `operationID`, `params` and `context`. Only Core writes it,
/// from the identity of the session that made the request, so a callee can
/// key state by caller without trusting anything in the params. A callee that
/// negotiated a version before the relay never receives it, and a call the
/// host itself starts (`caller` is `None`) never carries one: its absence
/// means the host.
pub(crate) fn attach_caller(invoke_params: &mut Value, version: u64, caller: Option<&str>) {
    let Some(caller) = caller else {
        return;
    };
    if version < RELAY_VERSION {
        return;
    }
    if let Some(params) = invoke_params.as_object_mut() {
        params.insert("caller".to_string(), json!({ "pluginID": caller }));
    }
}

/// The JSON-RPC error code of a host-service code from version 3 on. Each
/// code has its own number, so a backend can branch on the number alone:
/// codes with a standard meaning keep the JSON-RPC or LSP number, and the
/// rest take numbers from the server-defined range, after -32000, which
/// backends use for their own failures. Versions 1 and 2 keep their
/// earlier numbers, see `host_request`.
pub(crate) fn host_rpc_code(code: &str) -> i64 {
    match code {
        codes::HOST_UNAVAILABLE => -32601,
        codes::HOST_INVALID_PARAMS => -32602,
        codes::HOST_CANCELLED => -32800,
        codes::HOST_PERMISSION_DENIED => -32010,
        codes::HOST_CONTEXT_EXPIRED => -32011,
        codes::HOST_AUTHORITY_UNSUPPORTED => -32012,
        codes::HOST_VERSION_CONFLICT => -32013,
        codes::HOST_LIMIT_EXCEEDED => -32014,
        codes::HOST_TIMEOUT => -32015,
        codes::HOST_NOT_FOUND => -32016,
        codes::HOST_READ_ONLY => -32017,
        codes::HOST_UNSUPPORTED_OPTION => -32018,
        codes::HOST_PRECONDITION_FAILED => -32019,
        codes::HOST_BUSY => -32020,
        codes::HOST_RATE_LIMITED => -32021,
        codes::HOST_LANGUAGE_SERVER_UNAVAILABLE => -32022,
        codes::HOST_LANGUAGE_SERVER_ERROR => -32023,
        codes::HOST_METHOD_NOT_DECLARED => -32024,
        codes::HOST_FOREIGN_CONTRIBUTION => -32026,
        codes::NOT_DECLARED => -32027,
        codes::NOT_EXPORTED => -32028,
        codes::PROVIDER_DISABLED => -32029,
        codes::VERSION_MISMATCH => -32030,
        codes::CALL_CYCLE => -32065,
        codes::DEPTH_EXCEEDED => -32066,
        codes::TOO_MANY_CALLS => -32067,
        codes::PAYLOAD_TOO_LARGE => -32068,
        codes::PROVIDER_UNAVAILABLE => -32069,
        // A relayed call's own failure is not a host failure: the caller
        // must tell the provider's error from Core's by the number alone.
        codes::FAILED => -32070,
        codes::INVALID_RESULT => -32071,
        _ => -32603,
    }
}

/// The `details` of a host failure a version 3 backend receives in
/// `error.data.details`: an object of at most `MAX_HOST_DETAILS_BYTES`
/// serialized, such as the current version of a `versionConflict` or the
/// index of the edit a range error names. Anything else is dropped, so a
/// host cannot inflate the reply or send a value a backend must not parse.
pub(crate) fn bounded_host_details(details: Option<&Value>) -> Option<Value> {
    let details = details?;
    if !details.is_object() {
        return None;
    }
    let size = serde_json::to_vec(details).map(|bytes| bytes.len()).ok()?;
    (size <= MAX_HOST_DETAILS_BYTES).then(|| details.clone())
}

/// The code and JSON-RPC error code a version 3 backend receives when the
/// host failed a forwarded request. Only the codes a host may report pass
/// through; anything else, including none, is `plugin.host.failed`, so a
/// host cannot impersonate Core's own refusals of other kinds.
pub(crate) fn host_failure(code: Option<&str>) -> (&'static str, i64) {
    let code = match code {
        Some(codes::HOST_UNAVAILABLE) => codes::HOST_UNAVAILABLE,
        Some(codes::HOST_PERMISSION_DENIED) => codes::HOST_PERMISSION_DENIED,
        Some(codes::HOST_INVALID_PARAMS) => codes::HOST_INVALID_PARAMS,
        Some(codes::HOST_CONTEXT_EXPIRED) => codes::HOST_CONTEXT_EXPIRED,
        Some(codes::HOST_AUTHORITY_UNSUPPORTED) => codes::HOST_AUTHORITY_UNSUPPORTED,
        Some(codes::HOST_VERSION_CONFLICT) => codes::HOST_VERSION_CONFLICT,
        Some(codes::HOST_LIMIT_EXCEEDED) => codes::HOST_LIMIT_EXCEEDED,
        Some(codes::HOST_CANCELLED) => codes::HOST_CANCELLED,
        Some(codes::HOST_TIMEOUT) => codes::HOST_TIMEOUT,
        Some(codes::HOST_NOT_FOUND) => codes::HOST_NOT_FOUND,
        Some(codes::HOST_READ_ONLY) => codes::HOST_READ_ONLY,
        Some(codes::HOST_UNSUPPORTED_OPTION) => codes::HOST_UNSUPPORTED_OPTION,
        Some(codes::HOST_PRECONDITION_FAILED) => codes::HOST_PRECONDITION_FAILED,
        Some(codes::HOST_BUSY) => codes::HOST_BUSY,
        Some(codes::HOST_RATE_LIMITED) => codes::HOST_RATE_LIMITED,
        Some(codes::HOST_LANGUAGE_SERVER_UNAVAILABLE) => codes::HOST_LANGUAGE_SERVER_UNAVAILABLE,
        Some(codes::HOST_LANGUAGE_SERVER_ERROR) => codes::HOST_LANGUAGE_SERVER_ERROR,
        Some(codes::HOST_METHOD_NOT_DECLARED) => codes::HOST_METHOD_NOT_DECLARED,
        Some(codes::HOST_FOREIGN_CONTRIBUTION) => codes::HOST_FOREIGN_CONTRIBUTION,
        // A backend exit is reported to pages, never to the backend itself.
        _ => codes::HOST_FAILED,
    };
    (code, host_rpc_code(code))
}

/// Key of a stored secret, also the alphabet of subscription and context
/// IDs. It excludes path separators so a host may use the value in a store
/// item or file name without escaping.
fn is_credential_key(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_CREDENTIAL_KEY_BYTES
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | ':' | '-')
        })
}

/// Truncates a host's failure message like a backend's.
pub(crate) fn bounded_host_message(value: &str) -> String {
    bounded_message(value)
}

/// IDs of a descriptor array, refusing malformed descriptors, duplicates,
/// IDs already in `existing`, and a registry beyond the session limit.
fn descriptor_ids(
    descriptors: &Value,
    existing: &BTreeSet<String>,
) -> Result<BTreeSet<String>, &'static str> {
    let descriptors = descriptors
        .as_array()
        .ok_or("`functions` must be an array.")?;
    let mut ids = BTreeSet::new();
    for descriptor in descriptors {
        // Unknown descriptor fields are ignored within a version, as for
        // every negotiated object, so a backend can add optional metadata.
        let id = descriptor
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| is_function_id(id))
            .ok_or("Every function needs a valid `id`.")?;
        if existing.contains(id) || !ids.insert(id.to_string()) {
            return Err("A function ID is registered twice.");
        }
    }
    if existing.len() + ids.len() > MAX_FUNCTIONS {
        return Err("Too many functions are registered.");
    }
    Ok(ids)
}

/// Dot-separated lowerCamelCase segments, for example `snapshot.refresh`.
pub(crate) fn is_function_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_FUNCTION_ID_BYTES
        && value.split('.').all(|segment| {
            let mut characters = segment.chars();
            characters
                .next()
                .is_some_and(|first| first.is_ascii_lowercase())
                && characters.all(|character| character.is_ascii_alphanumeric())
        })
}

/// The manifest's plugin ID alphabet: lowercase letters, digits, `.` and `-`.
pub(crate) fn is_plugin_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_PLUGIN_ID_BYTES
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '.'
                || character == '-'
        })
}

fn is_plugin_error_code(value: &str) -> bool {
    let mut characters = value.chars();
    value.len() <= MAX_PLUGIN_ERROR_CODE_BYTES
        && characters
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
        && characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

/// Truncates at a character boundary so a hostile message cannot inflate
/// every event that carries it.
fn bounded_message(value: &str) -> String {
    if value.len() <= MAX_MESSAGE_BYTES {
        return value.to_string();
    }
    let mut end = MAX_MESSAGE_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn invalid_result(message: &str) -> FunctionFailure {
    FunctionFailure {
        code: codes::INVALID_RESULT,
        message: message.to_string(),
        plugin_error_code: None,
    }
}

fn refusal(category: ErrorCode, message: &str, code: &str) -> CoreError {
    CoreError::new(category, message).with_details(code)
}

#[cfg(test)]
mod tests {
    //! Golden cases from `shared/contracts/plugins/v1/fixtures/backend/function-protocol.json`.
    //! Timing behavior (cancellation, deadlines, late replies, revocation of a
    //! running call) is covered against a scripted backend in the engine tests.

    use super::*;

    const FIXTURE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/backend/function-protocol.json"
    ));

    fn fixture() -> Value {
        serde_json::from_str(FIXTURE).expect("the function-protocol fixture is JSON")
    }

    fn cases(section: &str) -> Vec<Value> {
        fixture()[section]
            .as_array()
            .unwrap_or_else(|| panic!("fixture section {section} is missing"))
            .clone()
    }

    fn id_set(value: &Value) -> BTreeSet<String> {
        value
            .as_array()
            .expect("an ID list")
            .iter()
            .map(|id| id.as_str().expect("a string ID").to_string())
            .collect()
    }

    fn name(case: &Value) -> &str {
        case["name"].as_str().expect("every case is named")
    }

    #[test]
    fn the_offer_matches_the_fixture() {
        let fixture = fixture();
        let (key, offer) = client_experimental_capabilities();
        assert_eq!(fixture["protocol"], key);
        assert_eq!(fixture["offer"], offer);
    }

    #[test]
    fn negotiation_follows_the_fixture() {
        for case in cases("negotiation") {
            let negotiated = negotiate(&case["capabilities"]);
            let expected = &case["expected"];
            match expected["functions"].as_array() {
                Some(_) => assert_eq!(
                    negotiated,
                    Some((
                        expected["version"].as_u64().unwrap_or(1),
                        id_set(&expected["functions"])
                    )),
                    "{}",
                    name(&case)
                ),
                None => assert_eq!(negotiated, None, "{}", name(&case)),
            }
        }
    }

    #[test]
    fn registration_follows_the_fixture() {
        for case in cases("registration") {
            let current = id_set(&case["registered"]);
            let params = case.get("params");
            let expected = &case["expected"];
            let outcome = match case["method"].as_str() {
                Some(REGISTER_METHOD) => {
                    apply_registration(&current, params).map(|registry| (registry, Vec::new()))
                }
                Some(UNREGISTER_METHOD) => apply_unregistration(&current, params),
                other => panic!("{}: unknown method {other:?}", name(&case)),
            };
            if expected["status"] == "accepted" {
                let (registry, removed) =
                    outcome.unwrap_or_else(|reason| panic!("{}: {reason}", name(&case)));
                assert_eq!(registry, id_set(&expected["functions"]), "{}", name(&case));
                let expected_removed: Vec<String> =
                    id_set(&expected["removed"]).into_iter().collect();
                assert_eq!(removed, expected_removed, "{}", name(&case));
            } else {
                assert_eq!(expected["code"], codes::INVALID_REGISTRATION);
                assert!(outcome.is_err(), "{} should be refused", name(&case));
            }
        }
    }

    #[test]
    fn invocation_planning_follows_the_fixture() {
        for case in cases("invocations") {
            let session = &case["session"];
            let functions = id_set(&session["functions"]);
            let reference: FunctionReference =
                serde_json::from_value(case["request"]["function"].clone())
                    .unwrap_or_else(|error| panic!("{}: {error}", name(&case)));
            let planned = plan_invocation(
                &FunctionSession {
                    plugin_id: session["pluginID"].as_str(),
                    negotiated: session["negotiated"].as_bool().unwrap_or(false),
                    functions: &functions,
                },
                &reference,
                "operation-1",
                &case["request"]["params"],
            );
            let expected = &case["expected"];
            if expected["status"] == "sent" {
                let params = planned.unwrap_or_else(|error| panic!("{}: {error:?}", name(&case)));
                assert_eq!(expected["method"], INVOKE_METHOD, "{}", name(&case));
                assert_eq!(params, expected["params"], "{}", name(&case));
            } else {
                let error = planned.expect_err(name(&case));
                assert_eq!(
                    error.details.as_deref(),
                    expected["code"].as_str(),
                    "{}",
                    name(&case)
                );
            }
        }
    }

    #[test]
    fn outcomes_follow_the_fixture() {
        for case in cases("outcomes") {
            let expected = &case["expected"];
            match invocation_outcome(&case["response"]) {
                Ok(result) => assert_eq!(result, expected["result"], "{}", name(&case)),
                Err(failure) => {
                    let error = &expected["error"];
                    assert_eq!(failure.code, error["code"], "{}", name(&case));
                    assert_eq!(failure.message, error["message"], "{}", name(&case));
                    assert_eq!(
                        failure.plugin_error_code.as_deref(),
                        error["pluginErrorCode"].as_str(),
                        "{}",
                        name(&case)
                    );
                }
            }
        }
    }

    #[test]
    fn progress_follows_the_fixture() {
        for case in cases("progress") {
            let parsed = parse_progress(case.get("params"));
            let expected = &case["expected"];
            if expected.is_null() {
                assert_eq!(parsed, None, "{}", name(&case));
            } else {
                assert_eq!(
                    parsed,
                    Some(FunctionProgress {
                        operation_id: expected["operationID"].as_str().unwrap().to_string(),
                        message: expected["message"].as_str().map(ToString::to_string),
                        percentage: expected["percentage"].as_u64(),
                    }),
                    "{}",
                    name(&case)
                );
            }
        }
    }

    #[test]
    fn backend_requests_follow_the_fixture() {
        for case in cases("backendRequests") {
            assert_eq!(
                refused_backend_request(case["method"].as_str().unwrap()),
                case["expected"]["code"].as_str(),
                "{}",
                name(&case)
            );
        }
    }

    #[test]
    fn host_requests_follow_the_fixture() {
        for case in cases("hostRequests") {
            let granted: BTreeSet<String> = id_set(&case["hostServices"]);
            let outcome = host_request(
                case["method"].as_str().unwrap(),
                case.get("params"),
                case["version"].as_u64().unwrap(),
                &granted,
            );
            let expected = &case["expected"];
            if expected["relay"].as_bool() == Some(true) {
                assert_eq!(outcome, Ok(HostRoute::Relay), "{}", name(&case));
                continue;
            }
            if let Some(service) = expected["forward"].as_str() {
                assert_eq!(
                    outcome,
                    Ok(HostRoute::Forward(
                        HOST_METHODS
                            .iter()
                            .map(|entry| entry.service)
                            .find(|known| *known == service)
                            .expect("a known service")
                    )),
                    "{}",
                    name(&case)
                );
                continue;
            }
            match expected.get("answer") {
                Some(answer) => {
                    assert_eq!(
                        outcome,
                        Ok(HostRoute::Answer(answer.clone())),
                        "{}",
                        name(&case)
                    )
                }
                None => {
                    let refusal = outcome.expect_err(name(&case));
                    assert_eq!(refusal.code, expected["code"], "{}", name(&case));
                    assert_eq!(refusal.rpc_code, expected["rpcCode"], "{}", name(&case));
                    assert_eq!(
                        refusal.details.as_ref(),
                        expected.get("details"),
                        "{}",
                        name(&case)
                    );
                }
            }
        }
    }

    #[test]
    fn invocation_contexts_follow_the_fixture() {
        for case in cases("invocationContexts") {
            let mut params = case["params"].clone();
            let outcome = attach_context(
                &mut params,
                case["version"].as_u64().unwrap(),
                case.get("context"),
            );
            let expected = &case["expected"];
            match expected["code"].as_str() {
                Some(code) => assert_eq!(
                    outcome.expect_err(name(&case)).details.as_deref(),
                    Some(code),
                    "{}",
                    name(&case)
                ),
                None => {
                    outcome.unwrap_or_else(|error| panic!("{}: {error:?}", name(&case)));
                    assert_eq!(params, expected["params"], "{}", name(&case));
                }
            }
        }
    }

    #[test]
    fn invocation_callers_follow_the_fixture() {
        for case in cases("invocationCallers") {
            let mut params = case["params"].clone();
            attach_caller(
                &mut params,
                case["version"].as_u64().unwrap(),
                case["caller"].as_str(),
            );
            assert_eq!(params, case["expected"]["params"], "{}", name(&case));
        }
    }

    #[test]
    fn relay_errors_follow_the_fixture() {
        for case in cases("relayErrors") {
            let code = case["code"].as_str().unwrap();
            assert_eq!(host_rpc_code(code), case["rpcCode"], "{}", name(&case));
        }
    }

    /// Every failure a relayed call can end with has its own number, so a
    /// caller can branch on either the string or the number.
    #[test]
    fn relay_refusals_have_distinct_numbers() {
        let relay_codes = [
            codes::FAILED,
            codes::INVALID_RESULT,
            codes::NOT_DECLARED,
            codes::NOT_EXPORTED,
            codes::PROVIDER_DISABLED,
            codes::VERSION_MISMATCH,
            codes::CALL_CYCLE,
            codes::DEPTH_EXCEEDED,
            codes::TOO_MANY_CALLS,
            codes::PAYLOAD_TOO_LARGE,
            codes::PROVIDER_UNAVAILABLE,
        ];
        let numbers: BTreeSet<i64> = relay_codes.iter().map(|code| host_rpc_code(code)).collect();
        assert_eq!(numbers.len(), relay_codes.len());
        assert!(!numbers.contains(&-32603));
    }

    /// The relay's discovery and invocation requests are not the old
    /// recursive call: the backend still cannot send `lithe/function/invoke`.
    #[test]
    fn relay_methods_do_not_weaken_the_recursive_call_refusal() {
        assert_eq!(
            refused_backend_request(INVOKE_METHOD),
            Some(codes::RECURSIVE_CALL)
        );
        assert_eq!(
            refused_backend_request("lithe/build/model"),
            Some(codes::RECURSIVE_CALL)
        );
    }

    #[test]
    fn host_failures_follow_the_fixture() {
        for case in cases("hostFailures") {
            let (code, rpc_code) = host_failure(case["code"].as_str());
            assert_eq!(code, case["expected"]["code"], "{}", name(&case));
            assert_eq!(rpc_code, case["expected"]["rpcCode"], "{}", name(&case));
        }
    }

    #[test]
    fn host_notifications_follow_the_fixture() {
        for case in cases("hostNotifications") {
            let granted: BTreeSet<String> = case["hostServices"]
                .as_array()
                .unwrap()
                .iter()
                .map(|service| service.as_str().unwrap().to_string())
                .collect();
            let outcome = host_notification(
                case["method"].as_str().unwrap(),
                &case["params"],
                case["version"].as_u64().unwrap(),
                &granted,
            );
            let expected = &case["expected"];
            match expected["code"].as_str() {
                Some(code) => assert_eq!(
                    outcome.expect_err(name(&case)).details.as_deref(),
                    Some(code),
                    "{}",
                    name(&case)
                ),
                None => assert_eq!(
                    outcome.unwrap_or_else(|error| panic!("{}: {error:?}", name(&case))),
                    expected["delivered"].as_bool().unwrap(),
                    "{}",
                    name(&case)
                ),
            }
        }
    }

    /// Details pass only as a bounded object, so a host cannot hand a
    /// backend an unbounded or untyped payload through a failure.
    #[test]
    fn host_failure_details_are_a_bounded_object() {
        let details = json!({ "currentVersion": 7 });
        assert_eq!(bounded_host_details(Some(&details)), Some(details));
        assert_eq!(bounded_host_details(Some(&json!("text"))), None);
        let oversized = json!({ "text": "x".repeat(MAX_HOST_DETAILS_BYTES) });
        assert_eq!(bounded_host_details(Some(&oversized)), None);
        assert_eq!(bounded_host_details(None), None);
    }

    /// An oversized notification is refused before it reaches a backend.
    #[test]
    fn host_notifications_are_bounded() {
        let params = json!({
            "subscriptionID": "s1",
            "sequence": 1,
            "event": { "text": "x".repeat(MAX_HOST_NOTIFICATION_BYTES) }
        });
        let refusal = host_notification(SUBSCRIPTIONS_NOTIFY, &params, 3, &BTreeSet::new())
            .expect_err("the notification is too large");
        assert_eq!(refusal.details.as_deref(), Some(codes::HOST_INVALID_PARAMS));
    }

    /// Capability discovery lists only what the session may call.
    #[test]
    fn capabilities_list_only_granted_services() {
        let granted = BTreeSet::from([HOST_SERVICE_WORKSPACE.to_string()]);
        let answer = capabilities_answer(3, &granted);
        let services = answer["services"].as_object().expect("services");
        assert!(services.contains_key(HOST_SERVICE_WORKSPACE));
        assert!(services.contains_key(HOST_SERVICE_HOST));
        assert!(services.contains_key(HOST_SERVICE_SUBSCRIPTIONS));
        assert!(!services.contains_key(HOST_SERVICE_CREDENTIALS));
    }

    /// Every grantable service has at least one method, so a grant never
    /// admits nothing.
    #[test]
    fn grantable_services_have_methods() {
        for service in GRANTABLE_HOST_SERVICES {
            assert!(
                HOST_METHODS.iter().any(|entry| entry.service == *service),
                "{service}"
            );
        }
    }

    /// The secret bound is inclusive and measured in UTF-8 bytes.
    #[test]
    fn credential_secrets_are_bounded() {
        let granted = BTreeSet::from([HOST_SERVICE_CREDENTIALS.to_string()]);
        let set = |secret: String| {
            host_request(
                CREDENTIALS_SET,
                Some(&json!({ "key": "k", "secret": secret })),
                2,
                &granted,
            )
        };
        assert!(set("x".repeat(MAX_CREDENTIAL_SECRET_BYTES)).is_ok());
        assert_eq!(
            set("x".repeat(MAX_CREDENTIAL_SECRET_BYTES + 1))
                .unwrap_err()
                .code,
            codes::HOST_INVALID_PARAMS
        );
    }

    /// Snapshot reads are separately granted and may name only bounded opaque references.
    #[test]
    fn keymap_snapshot_host_requests_require_grants_and_bounded_references() {
        let method = "lithe/host/keymapImport/readChunk";
        let granted = BTreeSet::from([method.to_string()]);
        let valid = json!({ "snapshotID": "abc-123", "providerID": "editor", "fileID": "file-1", "offset": 0, "maximumBytes": 131072 });
        assert!(matches!(
            host_request(method, Some(&valid), 3, &granted),
            Ok(HostRoute::Forward("keymapImport"))
        ));
        assert!(host_request(method, Some(&valid), 2, &granted).is_err());
        assert!(host_request(method, Some(&valid), 3, &BTreeSet::new()).is_err());
        for invalid in [
            json!({ "snapshotID": "../private", "providerID": "editor", "fileID": "file-1", "offset": 0, "maximumBytes": 1 }),
            json!({ "snapshotID": "abc", "providerID": "editor", "fileID": "file-1", "offset": 0, "maximumBytes": 131073 }),
            json!({ "snapshotID": "abc", "providerID": "editor", "fileID": "file-1", "offset": -1, "maximumBytes": 1 }),
            json!({ "snapshotID": "abc", "providerID": "editor", "fileID": "file-1", "offset": 0, "maximumBytes": 1, "path": "/private" }),
        ] {
            assert!(host_request(method, Some(&invalid), 3, &granted).is_err());
        }
        let list = "lithe/host/keymapImport/listInputs";
        let list_grant = BTreeSet::from([list.to_string()]);
        assert!(host_request(
            list,
            Some(&json!({ "snapshotID": "abc", "providerID": "editor" })),
            3,
            &list_grant
        )
        .is_ok());
        assert!(host_request(
            list,
            Some(&json!({ "snapshotID": "abc", "providerID": "editor", "path": "secret" })),
            3,
            &list_grant
        )
        .is_err());
    }

    /// A message over the bound is cut at a character boundary, never inside
    /// a multi-byte character.
    #[test]
    fn long_failure_messages_are_truncated_on_character_boundaries() {
        let message = format!("{}é", "a".repeat(MAX_MESSAGE_BYTES - 1));
        let failure = invocation_outcome(&json!({ "error": { "code": 1, "message": message } }))
            .expect_err("an error response fails");
        assert_eq!(failure.message, "a".repeat(MAX_MESSAGE_BYTES - 1));
    }

    #[test]
    fn oversized_results_are_invalid() {
        let result = "x".repeat(MAX_RESULT_BYTES);
        let failure = invocation_outcome(&json!({ "result": result }))
            .expect_err("a result over the bound is refused");
        assert_eq!(failure.code, codes::INVALID_RESULT);
    }

    /// A status message is cut at the progress bound before it reaches the
    /// host, at a character boundary; other methods pass untouched.
    #[test]
    fn forwarded_status_messages_are_bounded() {
        let message = format!("{}é", "a".repeat(MAX_MESSAGE_BYTES - 1));
        let params = json!({ "serverID": "metals", "state": "preparing", "message": message });
        let forwarded = forwarded_host_params(LANGUAGE_SERVER_SET_STATUS, Some(&params));
        assert_eq!(forwarded["message"], "a".repeat(MAX_MESSAGE_BYTES - 1));
        assert_eq!(forwarded["state"], "preparing");
        let request = json!({ "method": "x", "message": "m".repeat(MAX_MESSAGE_BYTES + 1) });
        assert_eq!(
            forwarded_host_params(LANGUAGE_SERVER_REQUEST, Some(&request)),
            request
        );
        assert_eq!(
            forwarded_host_params(LANGUAGE_SERVER_REQUEST, None),
            Value::Null
        );
    }

    /// A content scheme is a lowercase RFC 3986 scheme the host does not own.
    #[test]
    fn content_schemes_exclude_host_owned_ones() {
        for accepted in ["metals-library", "rust-std", "a", "x1+y.z"] {
            assert!(is_content_scheme(accepted), "{accepted}");
        }
        for refused in [
            "", "File", "1abc", "-abc", "a b", "a_b", "file", "https", "data", "lithe", "untitled",
        ] {
            assert!(!is_content_scheme(refused), "{refused}");
        }
        assert!(is_content_scheme(&"a".repeat(64)));
        assert!(!is_content_scheme(&"a".repeat(65)));
    }

    /// Only a session granted the language server methods lists them, and a
    /// session without the grant still lists nothing of the service.
    #[test]
    fn capabilities_list_language_server_methods_only_when_granted() {
        let services = |granted: &[&str]| {
            let granted = granted.iter().map(|method| method.to_string()).collect();
            capabilities_answer(3, &granted)["services"].clone()
        };
        assert!(services(&[]).get(HOST_SERVICE_LANGUAGE_SERVER).is_none());
        let granted = services(&[LANGUAGE_SERVER_REQUEST, LANGUAGE_SERVER_SET_STATUS]);
        let entry = &granted[HOST_SERVICE_LANGUAGE_SERVER];
        assert_eq!(
            entry["methods"],
            json!([LANGUAGE_SERVER_REQUEST, LANGUAGE_SERVER_SET_STATUS])
        );
        assert_eq!(
            entry["notifications"],
            json!([
                LANGUAGE_SERVER_DID_CHANGE_STATE,
                LANGUAGE_SERVER_DID_RECEIVE_NOTIFICATION
            ])
        );
    }

    #[test]
    fn the_registry_is_bounded() {
        let current: BTreeSet<String> = (0..MAX_FUNCTIONS)
            .map(|index| format!("f{index}"))
            .collect();
        let error =
            apply_registration(&current, Some(&json!({ "functions": [{ "id": "extra" }] })))
                .expect_err("the session limit holds");
        assert!(error.contains("Too many"));
    }
}
