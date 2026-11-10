package core

import (
	"context"
	"encoding/json"
)

// McpEntry is one environment variable or HTTP header of an MCP server.
type McpEntry struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// McpServer is Core's normalized MCP server definition. DefinitionHash is the
// library grouping identity and SourceHash covers the complete source entry,
// including fields Core does not model. Both are produced by Core and are never
// computed by the platform.
type McpServer struct {
	Name           string     `json:"name"`
	Transport      string     `json:"transport"`
	Command        string     `json:"command,omitempty"`
	URL            string     `json:"url,omitempty"`
	Args           []string   `json:"args"`
	Env            []McpEntry `json:"env"`
	Headers        []McpEntry `json:"headers"`
	DefinitionHash string     `json:"definitionHash,omitempty"`
	SourceHash     string     `json:"sourceHash,omitempty"`
}

// McpToolFilters are the native Codex tool lists retained across a removal.
type McpToolFilters struct {
	EnabledTools  []string `json:"enabledTools,omitempty"`
	DisabledTools []string `json:"disabledTools,omitempty"`
}

// McpLedgerEntry records an entry Lithe wrote. It never contains env or header
// values. ToolFilters is keyed by native path.
type McpLedgerEntry struct {
	Name           string                    `json:"name"`
	DefinitionHash string                    `json:"definitionHash"`
	SourceHash     string                    `json:"sourceHash,omitempty"`
	ToolFilters    map[string]McpToolFilters `json:"toolFilters,omitempty"`
}

// McpLibraryFile is one native configuration file offered to the library
// commands. ID is the host's opaque ledger key. Content is nil when the file
// does not exist.
type McpLibraryFile struct {
	ID          string           `json:"id"`
	Source      string           `json:"source"`
	Scope       string           `json:"scope"`
	ProjectPath string           `json:"projectPath,omitempty"`
	Path        string           `json:"path"`
	Content     *string          `json:"content"`
	Owned       []McpLedgerEntry `json:"owned"`
}

// McpLibrarySource is where a library row's definition was found.
type McpLibrarySource struct {
	File           string `json:"file"`
	DefinitionHash string `json:"definitionHash"`
	SourceHash     string `json:"sourceHash"`
	OwnedByLithe   bool   `json:"ownedByLithe"`
}

// McpLibraryRow is one merged server of the library.
type McpLibraryRow struct {
	ID                    string             `json:"id"`
	Definition            McpServer          `json:"definition"`
	Sources               []McpLibrarySource `json:"sources"`
	HasDefinitionConflict bool               `json:"hasDefinitionConflict"`
	ProjectOnly           bool               `json:"projectOnly"`
}

// McpLibraryFailure names a file that failed to parse; it never echoes content.
type McpLibraryFailure struct {
	File    string `json:"file"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// McpLibrarySnapshot is the result of mcp.librarySnapshot.
type McpLibrarySnapshot struct {
	Rows     []McpLibraryRow     `json:"rows"`
	Failures []McpLibraryFailure `json:"failures"`
}

// McpLibrarySnapshot merges every parsed server of files. It is a pure text
// operation.
func (c *Client) McpLibrarySnapshot(ctx context.Context, files []McpLibraryFile) (McpLibrarySnapshot, error) {
	files = normalizedLibraryFiles(files)
	var result McpLibrarySnapshot
	err := c.Execute(ctx, "mcp.librarySnapshot", struct {
		Files []McpLibraryFile `json:"files"`
	}{files}, &result)
	result.Rows = nonNil(result.Rows)
	result.Failures = nonNil(result.Failures)
	return result, err
}

// McpDraft is the editor draft validated by mcp.validateDraft.
type McpDraft struct {
	Name          string     `json:"name"`
	Transport     string     `json:"transport"`
	Command       string     `json:"command"`
	URL           string     `json:"url"`
	Arguments     []string   `json:"arguments"`
	Env           []McpEntry `json:"env"`
	Headers       []McpEntry `json:"headers"`
	EnabledAgents []string   `json:"enabledAgents"`
	Setup         string     `json:"setup,omitempty"`
}

// McpDraftIssue is one validation problem; values are never echoed.
type McpDraftIssue struct {
	Field string `json:"field"`
	Code  string `json:"code"`
}

// McpDraftValidation is the result of mcp.validateDraft. Definition is nil
// while issues remain.
type McpDraftValidation struct {
	Issues     []McpDraftIssue `json:"issues"`
	Definition *McpServer      `json:"definition"`
}

// McpValidateDraft validates a draft with Core's shared rules.
func (c *Client) McpValidateDraft(ctx context.Context, draft McpDraft) (McpDraftValidation, error) {
	draft.Arguments = nonNil(draft.Arguments)
	draft.Env = nonNil(draft.Env)
	draft.Headers = nonNil(draft.Headers)
	draft.EnabledAgents = nonNil(draft.EnabledAgents)
	var result McpDraftValidation
	err := c.Execute(ctx, "mcp.validateDraft", struct {
		Draft McpDraft `json:"draft"`
	}{draft}, &result)
	result.Issues = nonNil(result.Issues)
	return result, err
}

// McpOriginalSource is a source of the entry the user opened for editing.
type McpOriginalSource struct {
	File         string `json:"file"`
	SourceHash   string `json:"sourceHash,omitempty"`
	OwnedByLithe bool   `json:"ownedByLithe"`
}

// McpOriginal is the entry captured when the editor opened.
type McpOriginal struct {
	Name    string              `json:"name"`
	Sources []McpOriginalSource `json:"sources"`
}

// McpBatchIntent is the intent of mcp.batchPlan. Kind is save, setAgent or
// delete; only the fields of that kind are sent.
type McpBatchIntent struct {
	Kind       string       `json:"kind"`
	Draft      *McpDraft    `json:"draft,omitempty"`
	Original   *McpOriginal `json:"original,omitempty"`
	Definition *McpServer   `json:"definition,omitempty"`
	Agent      string       `json:"agent,omitempty"`
	Enabled    *bool        `json:"enabled,omitempty"`
	Name       string       `json:"name,omitempty"`
	Files      []string     `json:"files,omitempty"`
}

// McpBatchRename is a server rename in one file.
type McpBatchRename struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// McpBatchChange is the planned outcome for one file.
type McpBatchChange struct {
	File    string           `json:"file"`
	Changed bool             `json:"changed"`
	Content *string          `json:"content"`
	Owned   []McpLedgerEntry `json:"owned"`
	Renames []McpBatchRename `json:"renames"`
}

// McpBatchRejection explains a refused batch. File is empty for draft-level
// checks.
type McpBatchRejection struct {
	Code string  `json:"code"`
	Name string  `json:"name"`
	File *string `json:"file"`
}

// McpBatchPlan is the result of mcp.batchPlan. Status is invalid, rejected or
// ready.
type McpBatchPlan struct {
	Status    string             `json:"status"`
	Issues    []McpDraftIssue    `json:"issues"`
	Rejection *McpBatchRejection `json:"rejection"`
	Changes   []McpBatchChange   `json:"changes"`
}

// McpBatchPlan plans every file's write for one library intent. The host writes
// all changed files as one rollback batch and publishes ledgers only after the
// whole batch succeeds.
func (c *Client) McpBatchPlan(ctx context.Context, files []McpLibraryFile, intent McpBatchIntent) (McpBatchPlan, error) {
	files = normalizedLibraryFiles(files)
	intent.Definition = intent.Definition.normalized()
	if intent.Draft != nil {
		draft := *intent.Draft
		draft.Arguments, draft.Env, draft.Headers, draft.EnabledAgents = nonNil(draft.Arguments), nonNil(draft.Env), nonNil(draft.Headers), nonNil(draft.EnabledAgents)
		intent.Draft = &draft
	}
	var result McpBatchPlan
	err := c.Execute(ctx, "mcp.batchPlan", struct {
		Files  []McpLibraryFile `json:"files"`
		Intent McpBatchIntent   `json:"intent"`
	}{files, intent}, &result)
	result.Issues = nonNil(result.Issues)
	result.Changes = nonNil(result.Changes)
	return result, err
}

// McpParseConfigurationRequest is the payload of mcp.parseConfiguration.
type McpParseConfigurationRequest struct {
	Source      string `json:"source"`
	Scope       string `json:"scope"`
	Content     string `json:"content"`
	ProjectPath string `json:"projectPath,omitempty"`
}

// McpParseConfiguration lists the servers of one configuration text.
func (c *Client) McpParseConfiguration(ctx context.Context, request McpParseConfigurationRequest) ([]McpServer, error) {
	var result struct {
		Servers []McpServer `json:"servers"`
	}
	err := c.Execute(ctx, "mcp.parseConfiguration", request, &result)
	return nonNil(result.Servers), err
}

// McpPlanWriteRequest is the payload of mcp.planWrite. Content is nil when the
// file does not exist. ExpectedHash is the full sourceHash of the original
// entry the user saw.
type McpPlanWriteRequest struct {
	Source       string           `json:"source"`
	Scope        string           `json:"scope"`
	ProjectPath  string           `json:"projectPath,omitempty"`
	Content      *string          `json:"content"`
	Operation    string           `json:"operation"`
	Server       *McpServer       `json:"server,omitempty"`
	Name         string           `json:"name,omitempty"`
	PreviousName string           `json:"previousName,omitempty"`
	ExpectedHash string           `json:"expectedHash,omitempty"`
	Owned        []McpLedgerEntry `json:"owned,omitempty"`
	ToolFilters  *McpToolFilters  `json:"toolFilters,omitempty"`
}

// McpWritePlan is the result of mcp.planWrite. Action is inserted, updated,
// unchanged, removed, absent or conflict; a conflict leaves content unchanged.
type McpWritePlan struct {
	Content        string          `json:"content"`
	Changed        bool            `json:"changed"`
	Action         string          `json:"action"`
	Conflict       string          `json:"conflict"`
	DefinitionHash string          `json:"definitionHash"`
	SourceHash     string          `json:"sourceHash"`
	ToolFilters    *McpToolFilters `json:"toolFilters"`
}

// McpPlanWrite plans one set or remove against one configuration text.
func (c *Client) McpPlanWrite(ctx context.Context, request McpPlanWriteRequest) (McpWritePlan, error) {
	request.Server = request.Server.normalized()
	request.Owned = nonNil(request.Owned)
	var raw struct {
		McpWritePlan
		Conflict json.RawMessage `json:"conflict"`
	}
	err := c.Execute(ctx, "mcp.planWrite", request, &raw)
	plan := raw.McpWritePlan
	if len(raw.Conflict) > 0 && string(raw.Conflict) != "null" {
		var code string
		if json.Unmarshal(raw.Conflict, &code) != nil {
			code = string(raw.Conflict)
		}
		plan.Conflict = code
	}
	return plan, err
}

// McpRegistryEntry is one directory entry. Draft is nil for entries that are
// documentation only.
type McpRegistryEntry struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	Summary   string     `json:"summary"`
	Version   string     `json:"version"`
	Publisher *string    `json:"publisher"`
	Source    string     `json:"source"`
	Website   *string    `json:"website"`
	Draft     *McpServer `json:"draft"`
	Setup     string     `json:"setup,omitempty"`
}

// McpRegistryPage is a normalized registry page.
type McpRegistryPage struct {
	Entries    []McpRegistryEntry `json:"entries"`
	NextCursor *string            `json:"nextCursor"`
}

// McpParseRegistry normalizes an official MCP Registry v0.1 response body
// (at most 1 MiB). It never fetches anything.
func (c *Client) McpParseRegistry(ctx context.Context, content string) (McpRegistryPage, error) {
	var result McpRegistryPage
	err := c.Execute(ctx, "mcp.parseRegistry", struct {
		Content string `json:"content"`
	}{content}, &result)
	result.Entries = nonNil(result.Entries)
	return result, err
}

// McpFeaturedRegistry returns the compile-time featured catalog.
func (c *Client) McpFeaturedRegistry(ctx context.Context) (McpRegistryPage, error) {
	var result McpRegistryPage
	err := c.Execute(ctx, "mcp.featuredRegistry", struct{}{}, &result)
	result.Entries = nonNil(result.Entries)
	return result, err
}

// McpProbeRequest is a user-reviewed connection to detect tools on.
type McpProbeRequest struct {
	Transport string     `json:"transport"`
	Command   string     `json:"command,omitempty"`
	Args      []string   `json:"args"`
	Env       []McpEntry `json:"env"`
	URL       string     `json:"url,omitempty"`
	Headers   []McpEntry `json:"headers"`
}

// McpTool is the metadata of one detected tool.
type McpTool struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// McpProbe lists a server's tools. It may start a local process, so the caller
// must have an explicit user action and confirmation, and must run it off the
// UI thread. Cancel through ctx.
func (c *Client) McpProbe(ctx context.Context, request McpProbeRequest) ([]McpTool, error) {
	request.Args = nonNil(request.Args)
	request.Env = nonNil(request.Env)
	request.Headers = nonNil(request.Headers)
	var result struct {
		Tools []McpTool `json:"tools"`
	}
	err := c.Execute(ctx, "mcp.probe", request, &result)
	return nonNil(result.Tools), err
}

// McpToolPolicyRequest is the payload of mcp.toolPolicy. Omit Tool and Enabled
// to read the current policy.
type McpToolPolicyRequest struct {
	Source  string   `json:"source"`
	Content string   `json:"content"`
	Server  string   `json:"server"`
	Tools   []string `json:"tools"`
	Owned   []string `json:"owned,omitempty"`
	Tool    string   `json:"tool,omitempty"`
	Enabled *bool    `json:"enabled,omitempty"`
}

// McpToolPolicyTool is one tool's state under the native rules.
type McpToolPolicyTool struct {
	Name     string `json:"name"`
	Enabled  bool   `json:"enabled"`
	Editable bool   `json:"editable"`
}

// McpToolPolicy is the result of mcp.toolPolicy.
type McpToolPolicy struct {
	Content         string              `json:"content"`
	Changed         bool                `json:"changed"`
	Owned           []string            `json:"owned"`
	Tools           []McpToolPolicyTool `json:"tools"`
	HasRestrictions bool                `json:"hasRestrictions"`
}

// McpToolPolicy reads or edits one tool's switch in a native settings text.
func (c *Client) McpToolPolicy(ctx context.Context, request McpToolPolicyRequest) (McpToolPolicy, error) {
	request.Tools = nonNil(request.Tools)
	var result McpToolPolicy
	err := c.Execute(ctx, "mcp.toolPolicy", request, &result)
	result.Owned = nonNil(result.Owned)
	result.Tools = nonNil(result.Tools)
	return result, err
}

// McpCommandLine formats a command and arguments as a lossless text line.
func (c *Client) McpCommandLine(ctx context.Context, command string, args []string) (string, error) {
	var result struct {
		Line string `json:"line"`
	}
	err := c.Execute(ctx, "mcp.commandLine", struct {
		Action  string   `json:"action"`
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}{"format", command, nonNil(args)}, &result)
	return result.Line, err
}

// McpParseCommandLine splits a text line into command and arguments without
// evaluating a shell.
func (c *Client) McpParseCommandLine(ctx context.Context, line string) (string, []string, error) {
	var result struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	err := c.Execute(ctx, "mcp.commandLine", struct {
		Action string `json:"action"`
		Line   string `json:"line"`
	}{"parse", line}, &result)
	return result.Command, nonNil(result.Args), err
}

// normalized returns a copy whose list fields are empty arrays rather than
// null, which Core's request decoding rejects.
func (s *McpServer) normalized() *McpServer {
	if s == nil {
		return nil
	}
	copy := *s
	copy.Args, copy.Env, copy.Headers = nonNil(copy.Args), nonNil(copy.Env), nonNil(copy.Headers)
	return &copy
}

func normalizedLibraryFiles(files []McpLibraryFile) []McpLibraryFile {
	out := make([]McpLibraryFile, len(files))
	for i, file := range files {
		file.Owned = nonNil(file.Owned)
		out[i] = file
	}
	return out
}
