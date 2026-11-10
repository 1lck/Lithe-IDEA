package core

import (
	"context"
	"encoding/json"
	"runtime"
)

// PluginBackendStart is the host-resolved process and workspace. The host must
// only supply programs and grants from an approved, verified plugin package.
type PluginBackendStart struct {
	ProviderID             string            `json:"providerId"`
	PluginID               string            `json:"pluginId"`
	Role                   string            `json:"role,omitempty"`
	ExecutablePath         string            `json:"executablePath"`
	Arguments              []string          `json:"arguments,omitempty"`
	Environment            map[string]string `json:"environment,omitempty"`
	RootURI                any               `json:"rootUri"`
	WorkingDirectory       string            `json:"workingDirectory"`
	HostServices           []string          `json:"hostServices,omitempty"`
	InitializationOptions  json.RawMessage   `json:"initializationOptions,omitempty"`
	WorkspaceConfiguration json.RawMessage   `json:"workspaceConfiguration,omitempty"`
	// SessionPolicy is the launch plan's sessionPolicy, sent unchanged so Core's
	// engine enforces what a plugin backend may ask of its own language server.
	SessionPolicy                 json.RawMessage `json:"sessionPolicy,omitempty"`
	InitializeTimeoutMilliseconds int             `json:"initializeTimeoutMilliseconds,omitempty"`
	RequestTimeoutMilliseconds    int             `json:"requestTimeoutMilliseconds,omitempty"`
	ShutdownTimeoutMilliseconds   int             `json:"shutdownTimeoutMilliseconds,omitempty"`
}

// NativeDocumentPath asks Core to convert a native absolute path to a URI.
type NativeDocumentPath struct {
	Path     string `json:"path"`
	Platform string `json:"platform"`
}

type PluginBackendStarted struct {
	Channel   string `json:"channel"`
	SessionID string `json:"sessionId"`
	State     string `json:"state"`
	ProcessID *int   `json:"processId"`
}

// PluginBackendPlan is Core's launch selection and package requirements. The
// host must verify package paths and trust, resolve tools, and create the
// requested writable directories before starting a process.
type PluginBackendPlan struct {
	// Owner identifies the validated package that produced this launch plan.
	Owner  *PluginSettingsOwner `json:"owner,omitempty"`
	Launch struct {
		Kind             string   `json:"kind"`
		Path             string   `json:"path"`
		Commands         []string `json:"commands"`
		Tool             string   `json:"tool"`
		Entry            string   `json:"entry"`
		PackagedRuntime  string   `json:"packagedRuntime"`
		MinimumVersion   string   `json:"minimumVersion"`
		RuntimeArguments []string `json:"runtimeArguments"`
		VersionArguments []string `json:"versionArguments"`
		// Function and TimeoutMilliseconds describe a backend-resolved launch
		// (kind "backend"): the first step calls this plugin function.
		Function            string `json:"function"`
		TimeoutMilliseconds int    `json:"timeoutMilliseconds"`
	} `json:"launch"`
	// ResolveParams is the params of a backend-resolved launch function.
	ResolveParams json.RawMessage `json:"resolveParams"`
	// SessionPolicy is the language-server session policy of a languageServers 3 server.
	SessionPolicy json.RawMessage `json:"sessionPolicy"`
	// Environment and WritablePaths come from a decoded backend launch answer.
	Environment            map[string]string `json:"environment"`
	WritablePaths          []string          `json:"writablePaths"`
	Arguments              []string          `json:"arguments"`
	ValidationArguments    []string          `json:"validationArguments"`
	RequiredDirectories    []string          `json:"requiredDirectories"`
	RequiredPackagePaths   []string          `json:"requiredPackagePaths"`
	RuntimeRequirements    json.RawMessage   `json:"runtimeRequirements"`
	InitializationOptions  json.RawMessage   `json:"initializationOptions"`
	WorkspaceConfiguration json.RawMessage   `json:"workspaceConfiguration"`
	Settings               json.RawMessage   `json:"settings"`
	Backend                struct {
		HostServices []string `json:"hostServices"`
		Version      int      `json:"version"`
	} `json:"backend"`
	// BuildProvider is present when the plan was selected by buildSystemID.
	// LanguageServer names a session this host already keeps for that language
	// instead of a second process; the host must send build requests to it.
	BuildProvider *PluginBuildProviderPlan `json:"buildProvider"`
}

// PluginBuildProviderPlan identifies the build system a provider serves and
// whether the host reuses an existing language-server session.
type PluginBuildProviderPlan struct {
	BuildSystemID       string `json:"buildSystemID"`
	ExecutesProjectCode bool   `json:"executesProjectCode"`
	MayUseNetwork       bool   `json:"mayUseNetwork"`
	LanguageServer      string `json:"languageServer,omitempty"`
}

type PluginBackendDirectories struct {
	PluginDirectory         string                     `json:"pluginDirectory"`
	StateDirectory          string                     `json:"stateDirectory"`
	WorkspaceStateDirectory string                     `json:"workspaceStateDirectory,omitempty"`
	LogDirectory            string                     `json:"logDirectory,omitempty"`
	TemporaryDirectory      string                     `json:"temporaryDirectory,omitempty"`
	Architecture            string                     `json:"architecture"`
	Settings                map[string]json.RawMessage `json:"settings,omitempty"`
	ProjectSettings         map[string]json.RawMessage `json:"projectSettings,omitempty"`
}

// PluginArchitecture is this host's CPU in the plugin contract's names, which
// are what Core accepts when it plans a backend launch.
func PluginArchitecture() string {
	return pluginArchitecture(runtime.GOARCH)
}

// pluginArchitecture maps a Go architecture to the plugin contract's name. The
// contract allows only arm64 and x86_64, and Go calls x86_64 amd64. Marketplace
// platforms such as windows-x64 are a different naming and do not use this.
func pluginArchitecture(goarch string) string {
	if goarch == "amd64" {
		return "x86_64"
	}
	return goarch
}

// PluginEditorLanguage is Core's validated static language declaration. A
// configuration-only contribution has no grammar and does not require a file.
type PluginEditorLanguage struct {
	ID             string          `json:"id"`
	FileExtensions []string        `json:"fileExtensions"`
	FileNames      []string        `json:"fileNames"`
	Grammar        *PluginGrammar  `json:"grammar"`
	Configuration  json.RawMessage `json:"configuration"`
}

// PluginGrammar is a validated TextMate source, retained byte for byte.
type PluginGrammar struct {
	Kind      string `json:"kind"`
	ScopeName string `json:"scopeName"`
	Source    string `json:"source"`
}

// DecodePluginGrammar asks Core to validate static editor resources. The
// caller reads the package file off the UI thread after verifying the package,
// bounded by the contract's grammar size limit; decoding does not authenticate
// the source or register it with an editor.
func (c *Client) DecodePluginGrammar(ctx context.Context, manifest json.RawMessage, languageID, source string) (PluginEditorLanguage, error) {
	const command = "plugins.declarative.decodeGrammar"
	var result struct {
		Status   string                `json:"status"`
		Error    *MarketplaceRejection `json:"error"`
		Language *PluginEditorLanguage `json:"language"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest   json.RawMessage `json:"manifest"`
		LanguageID string          `json:"languageID"`
		Grammar    string          `json:"grammar"`
	}{manifest, languageID, source}, &result); err != nil {
		return PluginEditorLanguage{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginEditorLanguage{}, result.Error
	}
	if result.Status != "ok" || result.Language == nil || result.Language.ID == "" {
		return PluginEditorLanguage{}, newParseError(command, "grammar validation returned an invalid outcome", "")
	}
	return *result.Language, nil
}

// ValidatePluginManifest obtains Core's normalized manifest and rejects any
// capability that the host does not explicitly claim to implement.
func (c *Client) ValidatePluginManifest(ctx context.Context, manifest json.RawMessage, capabilities map[string][]int) (json.RawMessage, error) {
	const command = "plugins.declarative.validate"
	if capabilities == nil {
		capabilities = map[string][]int{}
	}
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plugin json.RawMessage       `json:"plugin"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest     json.RawMessage  `json:"manifest"`
		Capabilities map[string][]int `json:"hostCapabilities"`
	}{manifest, capabilities}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || len(result.Plugin) == 0 || string(result.Plugin) == "null" {
		return nil, newParseError(command, "plugin validation returned an invalid outcome", "")
	}
	return result.Plugin, nil
}

// PlanPluginBackend asks Core to expand a previously validated backend
// declaration. Planning does not verify an archive's provenance or approve its
// programs.
func (c *Client) PlanPluginBackend(ctx context.Context, manifest json.RawMessage, directories PluginBackendDirectories) (PluginBackendPlan, error) {
	return c.planPluginLaunch(ctx, struct {
		Manifest json.RawMessage          `json:"manifest"`
		Backend  bool                     `json:"backend"`
		Request  PluginBackendDirectories `json:"request"`
	}{manifest, true, directories})
}

// PlanPluginLanguageServer asks Core to expand the language server declaration
// for languageID. It is the same planner as a backend plan but selects the
// language server entry instead of the plugin backend.
func (c *Client) PlanPluginLanguageServer(ctx context.Context, manifest json.RawMessage, languageID string, directories PluginBackendDirectories) (PluginBackendPlan, error) {
	return c.planPluginLaunch(ctx, struct {
		Manifest   json.RawMessage          `json:"manifest"`
		LanguageID string                   `json:"languageID"`
		Request    PluginBackendDirectories `json:"request"`
	}{manifest, languageID, directories})
}

// DecodePluginLanguageServerLaunch checks the answer of a backend-resolved launch
// function (serverProcess 3) and returns the plan the host starts.
func (c *Client) DecodePluginLanguageServerLaunch(ctx context.Context, manifest json.RawMessage, languageID string, directories PluginBackendDirectories, answer json.RawMessage) (PluginBackendPlan, error) {
	const command = "plugins.languageServers.decodeLaunch"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *PluginBackendPlan    `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest   json.RawMessage          `json:"manifest"`
		LanguageID string                   `json:"languageID"`
		Request    PluginBackendDirectories `json:"request"`
		Result     json.RawMessage          `json:"result"`
	}{manifest, languageID, directories, answer}, &result); err != nil {
		return PluginBackendPlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginBackendPlan{}, result.Error
	}
	if result.Status != "ok" || result.Plan == nil {
		return PluginBackendPlan{}, newParseError(command, "launch decoding returned an invalid outcome", "")
	}
	return *result.Plan, nil
}

// PlanPluginBuildProvider asks Core to expand one build system's provider
// launch. The returned plan names buildProvider.buildSystemID and, for a shared
// provider, the language whose existing session answers build requests.
func (c *Client) PlanPluginBuildProvider(ctx context.Context, manifest json.RawMessage, buildSystemID string, directories PluginBackendDirectories) (PluginBackendPlan, error) {
	if buildSystemID == "" {
		return PluginBackendPlan{}, newParseError("plugins.declarative.languageServerLaunchPlan", "no build system was selected", "")
	}
	return c.planPluginLaunch(ctx, struct {
		Manifest      json.RawMessage          `json:"manifest"`
		BuildSystemID string                   `json:"buildSystemID"`
		Request       PluginBackendDirectories `json:"request"`
	}{manifest, buildSystemID, directories})
}

func (c *Client) planPluginLaunch(ctx context.Context, body any) (PluginBackendPlan, error) {
	const command = "plugins.declarative.languageServerLaunchPlan"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *PluginBackendPlan    `json:"plan"`
	}
	if err := c.Execute(ctx, command, body, &result); err != nil {
		return PluginBackendPlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginBackendPlan{}, result.Error
	}
	if result.Status != "ok" || result.Plan == nil {
		return PluginBackendPlan{}, newParseError(command, "plugin launch returned an invalid outcome", "")
	}
	return *result.Plan, nil
}

// BackendEvent preserves Core's ordered, typed facts without interpreting
// plugin-owned result JSON in the platform layer.
// CompletionOptions is the completion trigger and commit characters a language server
// session declares, as Core reports them on a featuresChanged event.
type CompletionOptions struct {
	TriggerCharacters   []string `json:"triggerCharacters"`
	AllCommitCharacters []string `json:"allCommitCharacters"`
}

type BackendEvent struct {
	Type         string          `json:"type"`
	Channel      string          `json:"channel"`
	Sequence     uint64          `json:"sequence"`
	SessionID    string          `json:"sessionId"`
	ProviderID   string          `json:"providerId"`
	PluginID     string          `json:"pluginId"`
	Role         string          `json:"role"`
	State        string          `json:"state"`
	OperationID  string          `json:"operationId"`
	Method       string          `json:"method"`
	URI          string          `json:"uri"`
	Version      *int64          `json:"version"`
	Diagnostics  json.RawMessage `json:"diagnostics"`
	Result       json.RawMessage `json:"result"`
	Error        json.RawMessage `json:"error"`
	Event        string          `json:"event"`
	Fields       json.RawMessage `json:"fields"`
	Level        string          `json:"catalogLevel"`
	Message      string          `json:"message"`
	Detail       string          `json:"detail"`
	LegacyLevel  string          `json:"level"`
	Capabilities []string        `json:"capabilities"`
	// CompletionOptions is set on featuresChanged while completion is offered.
	CompletionOptions *CompletionOptions `json:"completionOptions"`
	ServerInfo        json.RawMessage    `json:"serverInfo"`
}

type pluginFunctionReference struct {
	PluginID   string `json:"pluginID"`
	FunctionID string `json:"functionID"`
}

// PluginHostFailure is a host service failure sent back through Core. The
// code and details are optional and require the negotiated protocol version.
type PluginHostFailure struct {
	Message string          `json:"message"`
	Code    string          `json:"code,omitempty"`
	Details json.RawMessage `json:"details,omitempty"`
}

// RespondPluginHostRequest answers one Core-forwarded host request. A nil
// result is a successful null response; an error must not include a result.
func (c *Client) RespondPluginHostRequest(ctx context.Context, session, requestID string, result json.RawMessage, failure *PluginHostFailure) error {
	const command = "lsp.hostResponse"
	if failure != nil && len(result) != 0 {
		return newParseError(command, "a host response cannot contain both result and error", "")
	}
	return c.Execute(ctx, command, struct {
		SessionID string             `json:"sessionId"`
		RequestID string             `json:"hostRequestID"`
		Result    json.RawMessage    `json:"result,omitempty"`
		Error     *PluginHostFailure `json:"error,omitempty"`
	}{session, requestID, result, failure}, nil)
}

// StartPluginBackend starts a Core-owned process; initialization completes via
// session events. No host service is granted unless explicitly supplied.
func (c *Client) StartPluginBackend(ctx context.Context, request PluginBackendStart) (PluginBackendStarted, error) {
	if request.Role == "" {
		request.Role = "backend"
	}
	return c.startPluginServer(ctx, request)
}

// StartPluginLanguageServer starts one language server planned from a plugin's
// languageServers declaration. The role is what makes Core route its process as
// a language server rather than a plugin backend.
func (c *Client) StartPluginLanguageServer(ctx context.Context, request PluginBackendStart) (PluginBackendStarted, error) {
	request.Role = "language_server"
	return c.startPluginServer(ctx, request)
}

func (c *Client) startPluginServer(ctx context.Context, request PluginBackendStart) (PluginBackendStarted, error) {
	var response PluginBackendStarted
	err := c.Execute(ctx, "lsp.startServer", request, &response)
	return response, err
}

// WaitBackendEvents blocks until events are available or Core's timeout elapses.
func (c *Client) WaitBackendEvents(ctx context.Context, session string, timeoutMilliseconds int) ([]BackendEvent, error) {
	var response struct {
		Events []BackendEvent `json:"events"`
	}
	err := c.Execute(ctx, "lsp.waitEvents", struct {
		SessionID string `json:"sessionId"`
		Timeout   int    `json:"timeoutMilliseconds"`
	}{session, timeoutMilliseconds}, &response)
	return response.Events, err
}

// InvokePluginFunction returns Core's opaque correlation ID; completion and
// progress arrive in the session's ordered event stream.
func (c *Client) InvokePluginFunction(ctx context.Context, session, operation, plugin, function string, params json.RawMessage) (string, error) {
	var response struct {
		OperationID string `json:"operationId"`
	}
	err := c.Execute(ctx, "lsp.functionRequest", struct {
		SessionID   string                  `json:"sessionId"`
		OperationID string                  `json:"operationId,omitempty"`
		Function    pluginFunctionReference `json:"function"`
		Params      json.RawMessage         `json:"params,omitempty"`
	}{session, operation, pluginFunctionReference{plugin, function}, params}, &response)
	return response.OperationID, err
}

// CancelPluginOperation asks Core to cancel an outstanding host operation.
func (c *Client) CancelPluginOperation(ctx context.Context, session, operation string) error {
	return c.Execute(ctx, "lsp.cancelOperation", struct {
		SessionID   string `json:"sessionId"`
		OperationID string `json:"operationId"`
	}{session, operation}, nil)
}

// StopPluginBackend requests shutdown; the session remains owned until it is terminal.
func (c *Client) StopPluginBackend(ctx context.Context, session string) error {
	return c.Execute(ctx, "lsp.stopServer", struct {
		SessionID string `json:"sessionId"`
	}{session}, nil)
}

// DestroyPluginBackend disposes a terminal session. It must not race stop.
func (c *Client) DestroyPluginBackend(ctx context.Context, session string) error {
	return c.Execute(ctx, "lsp.destroyServer", struct {
		SessionID string `json:"sessionId"`
	}{session}, nil)
}

// InvokePluginFunctionInContext is InvokePluginFunction for a protocol version 3
// backend: context is the workspace context reference the call runs in and
// timeoutMilliseconds bounds it when positive.
func (c *Client) InvokePluginFunctionInContext(ctx context.Context, session, operation, plugin, function string, params, workspaceContext json.RawMessage, timeoutMilliseconds int) (string, error) {
	var response struct {
		OperationID string `json:"operationId"`
	}
	body := struct {
		SessionID   string                  `json:"sessionId"`
		OperationID string                  `json:"operationId,omitempty"`
		Function    pluginFunctionReference `json:"function"`
		Params      json.RawMessage         `json:"params,omitempty"`
		Timeout     int                     `json:"timeoutMilliseconds,omitempty"`
		Context     json.RawMessage         `json:"context,omitempty"`
	}{session, operation, pluginFunctionReference{plugin, function}, params, timeoutMilliseconds, workspaceContext}
	err := c.Execute(ctx, "lsp.functionRequest", body, &response)
	return response.OperationID, err
}

// SendPluginHostNotification delivers one host notification to a plugin backend.
// delivered is false when the backend negotiated a version without it.
func (c *Client) SendPluginHostNotification(ctx context.Context, session, method string, params json.RawMessage) (bool, error) {
	var response struct {
		Delivered bool `json:"delivered"`
	}
	err := c.Execute(ctx, "lsp.hostNotify", struct {
		SessionID string          `json:"sessionId"`
		Method    string          `json:"method"`
		Params    json.RawMessage `json:"params"`
	}{session, method, params}, &response)
	return response.Delivered, err
}

// PluginServerRequest forwards one request of a plugin backend to the plugin's
// own language server. The answer arrives as a requestCompleted event of the
// language-server session.
func (c *Client) PluginServerRequest(ctx context.Context, session, operation, plugin, server, method string, params json.RawMessage, timeoutMilliseconds int) (string, error) {
	var response struct {
		OperationID string `json:"operationId"`
	}
	err := c.Execute(ctx, "lsp.pluginServerRequest", struct {
		SessionID   string          `json:"sessionId"`
		OperationID string          `json:"operationId,omitempty"`
		PluginID    string          `json:"pluginId"`
		ServerID    string          `json:"serverID"`
		Method      string          `json:"method"`
		Params      json.RawMessage `json:"params,omitempty"`
		Timeout     int             `json:"timeoutMilliseconds,omitempty"`
	}{session, operation, plugin, server, method, params, timeoutMilliseconds}, &response)
	return response.OperationID, err
}

// PluginServerNotify forwards one notification of a plugin backend to the
// plugin's own language server.
func (c *Client) PluginServerNotify(ctx context.Context, session, plugin, server, method string, params json.RawMessage) (bool, error) {
	var response struct {
		Delivered bool `json:"delivered"`
	}
	err := c.Execute(ctx, "lsp.pluginServerNotify", struct {
		SessionID string          `json:"sessionId"`
		PluginID  string          `json:"pluginId"`
		ServerID  string          `json:"serverID"`
		Method    string          `json:"method"`
		Params    json.RawMessage `json:"params,omitempty"`
	}{session, plugin, server, method, params}, &response)
	return response.Delivered, err
}

// RelayContext is one live workspace context the function relay checks calls against.
type RelayContext struct {
	ContextID  string `json:"contextID"`
	Generation uint64 `json:"generation"`
	Authority  string `json:"authority"`
}

// RelayPlugin is one enabled plugin's pluginFunctions declaration.
type RelayPlugin struct {
	PluginID string            `json:"pluginID"`
	Exports  []json.RawMessage `json:"exports"`
	Calls    []json.RawMessage `json:"calls"`
}

// ConfigureFunctionRelay replaces Core's view of the enabled plugins and live
// workspace contexts that cross-plugin calls are checked against.
func (c *Client) ConfigureFunctionRelay(ctx context.Context, plugins []RelayPlugin, contexts []RelayContext) error {
	if plugins == nil {
		plugins = []RelayPlugin{}
	}
	if contexts == nil {
		contexts = []RelayContext{}
	}
	for i := range plugins {
		if plugins[i].Exports == nil {
			plugins[i].Exports = []json.RawMessage{}
		}
		if plugins[i].Calls == nil {
			plugins[i].Calls = []json.RawMessage{}
		}
	}
	return c.Execute(ctx, "lsp.configureFunctionRelay", struct {
		Plugins  []RelayPlugin  `json:"plugins"`
		Contexts []RelayContext `json:"contexts"`
	}{plugins, contexts}, nil)
}
