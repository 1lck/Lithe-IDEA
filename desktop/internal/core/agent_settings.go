package core

import "context"

// Typed wrappers for the Agent management commands the AI settings pages use:
// global instructions, shared instructions, Hooks and Skills, plus Markdown
// rendering for replies. The rules (revision guards, native paths, validation)
// live in Core; Go only carries the shapes of shared/contracts/rust-core-api.md.

// AgentInstructionFile is one effective native instruction file snapshot.
type AgentInstructionFile struct {
	AgentID  string `json:"agentId"`
	Path     string `json:"path"`
	Content  string `json:"content"`
	Exists   bool   `json:"exists"`
	Revision string `json:"revision"`
}

// ReadAgentInstructions reads one Agent's global instructions without creating files.
func (c *Client) ReadAgentInstructions(ctx context.Context, agentID string) (AgentInstructionFile, error) {
	var result AgentInstructionFile
	err := c.Execute(ctx, "agent.instructions.read", struct {
		AgentID string `json:"agentId"`
	}{agentID}, &result)
	return result, err
}

// SaveAgentInstructions replaces the instructions only while the path and revision
// the editor read are still current; a changed file is rejected with file_changed.
func (c *Client) SaveAgentInstructions(ctx context.Context, agentID, content, expectedPath, expectedRevision string) (AgentInstructionFile, error) {
	var result AgentInstructionFile
	err := c.Execute(ctx, "agent.instructions.save", struct {
		AgentID          string `json:"agentId"`
		Content          string `json:"content"`
		ExpectedPath     string `json:"expectedPath"`
		ExpectedRevision string `json:"expectedRevision"`
	}{agentID, content, expectedPath, expectedRevision}, &result)
	return result, err
}

// AgentFileGuard names a native file and the revision a write must still find.
type AgentFileGuard struct {
	AgentID  string `json:"agentId"`
	Path     string `json:"path"`
	Revision string `json:"revision"`
}

// AgentSharedTarget is one Agent's state of the shared instruction block.
type AgentSharedTarget struct {
	AgentID      string                `json:"agentId"`
	File         *AgentInstructionFile `json:"file"`
	Enabled      *bool                 `json:"enabled"`
	NeedsSync    bool                  `json:"needsSync"`
	OwnLineCount int                   `json:"ownLineCount"`
	Issue        *string               `json:"issue"`
}

// AgentSharedInstructions is the shared source and each Agent's synchronized state.
type AgentSharedInstructions struct {
	File   AgentInstructionFile `json:"file"`
	Agents []AgentSharedTarget  `json:"agents"`
}

func (c *Client) sharedInstructions(ctx context.Context, payload any) (AgentSharedInstructions, error) {
	var result AgentSharedInstructions
	err := c.Execute(ctx, "agent.instructions.shared", payload, &result)
	return result, err
}

// ReadAgentSharedInstructions reads the shared source and native targets.
func (c *Client) ReadAgentSharedInstructions(ctx context.Context, dataDirectory string) (AgentSharedInstructions, error) {
	return c.sharedInstructions(ctx, struct {
		DataDirectory string `json:"dataDirectory"`
		Action        string `json:"action"`
	}{dataDirectory, "read"})
}

// SaveAgentSharedInstructions saves the shared source and updates enabled targets.
func (c *Client) SaveAgentSharedInstructions(ctx context.Context, dataDirectory, content, expectedRevision string, files []AgentFileGuard) (AgentSharedInstructions, error) {
	return c.sharedInstructions(ctx, struct {
		DataDirectory    string           `json:"dataDirectory"`
		Action           string           `json:"action"`
		Content          string           `json:"content"`
		ExpectedRevision string           `json:"expectedRevision"`
		Files            []AgentFileGuard `json:"files"`
	}{dataDirectory, "save", content, expectedRevision, files})
}

// SetAgentSharedInstructionsEnabled inserts or removes only the Lithe block in one
// Agent's effective native file.
func (c *Client) SetAgentSharedInstructionsEnabled(ctx context.Context, dataDirectory, agentID string, enabled bool, expectedRevision string, file AgentFileGuard) (AgentSharedInstructions, error) {
	return c.sharedInstructions(ctx, struct {
		DataDirectory    string         `json:"dataDirectory"`
		Action           string         `json:"action"`
		AgentID          string         `json:"agentId"`
		Enabled          bool           `json:"enabled"`
		ExpectedRevision string         `json:"expectedRevision"`
		File             AgentFileGuard `json:"file"`
	}{dataDirectory, "setEnabled", agentID, enabled, expectedRevision, file})
}

// AgentHook is one Hook of the platform-owned library.
type AgentHook struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Description      string   `json:"description"`
	Event            string   `json:"event"`
	Matcher          string   `json:"matcher"`
	Command          string   `json:"command"`
	TimeoutSeconds   *int     `json:"timeoutSeconds"`
	Agents           []string `json:"agents"`
	Enabled          bool     `json:"enabled"`
	PendingRemoval   bool     `json:"pendingRemoval"`
	ConfiguredAgents []string `json:"configuredAgents,omitempty"`
	NeedsSync        bool     `json:"needsSync,omitempty"`
}

// AgentHookTarget is one Agent's native Hook configuration state.
type AgentHookTarget struct {
	AgentID  string          `json:"agentId"`
	File     *AgentFileGuard `json:"file"`
	Issue    *string         `json:"issue"`
	Disabled bool            `json:"disabled"`
}

// AgentHookLibrary is Core's Hook library with the actual native state.
type AgentHookLibrary struct {
	Revision string            `json:"revision"`
	Hooks    []AgentHook       `json:"hooks"`
	Targets  []AgentHookTarget `json:"targets"`
}

type agentHooksRequest struct {
	DataDirectory    string           `json:"dataDirectory"`
	Action           string           `json:"action"`
	ExpectedRevision string           `json:"expectedRevision,omitempty"`
	Files            []AgentFileGuard `json:"files,omitempty"`
	Hook             *AgentHook       `json:"hook,omitempty"`
	ID               string           `json:"id,omitempty"`
}

func (c *Client) hooks(ctx context.Context, request agentHooksRequest) (AgentHookLibrary, error) {
	var result AgentHookLibrary
	err := c.Execute(ctx, "agent.hooks", request, &result)
	return result, err
}

// ReadAgentHooks reads the library and native state; it executes nothing.
func (c *Client) ReadAgentHooks(ctx context.Context, dataDirectory string) (AgentHookLibrary, error) {
	return c.hooks(ctx, agentHooksRequest{DataDirectory: dataDirectory, Action: "read"})
}

// SaveAgentHook adds or replaces one Hook under the revision and native guards read.
func (c *Client) SaveAgentHook(ctx context.Context, dataDirectory, expectedRevision string, files []AgentFileGuard, hook AgentHook) (AgentHookLibrary, error) {
	return c.hooks(ctx, agentHooksRequest{DataDirectory: dataDirectory, Action: "save", ExpectedRevision: expectedRevision, Files: files, Hook: &hook})
}

// RemoveAgentHook removes one Hook from the library and the native files.
func (c *Client) RemoveAgentHook(ctx context.Context, dataDirectory, expectedRevision string, files []AgentFileGuard, id string) (AgentHookLibrary, error) {
	return c.hooks(ctx, agentHooksRequest{DataDirectory: dataDirectory, Action: "remove", ExpectedRevision: expectedRevision, Files: files, ID: id})
}

// SyncAgentHooks retries the existing desired state.
func (c *Client) SyncAgentHooks(ctx context.Context, dataDirectory, expectedRevision string, files []AgentFileGuard) (AgentHookLibrary, error) {
	return c.hooks(ctx, agentHooksRequest{DataDirectory: dataDirectory, Action: "sync", ExpectedRevision: expectedRevision, Files: files})
}

// AgentHookDraft is an unsaved editor draft; TimeoutText is the raw field.
type AgentHookDraft struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Event       string   `json:"event"`
	Matcher     string   `json:"matcher"`
	Command     string   `json:"command"`
	TimeoutText string   `json:"timeoutText"`
	Agents      []string `json:"agents"`
}

// AgentHookRef names an existing library row for the unique-name rule.
type AgentHookRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// AgentHookIssue is one field problem; the client localizes agent.hooks.draft.<field>.<code>.
type AgentHookIssue struct {
	Field string `json:"field"`
	Code  string `json:"code"`
}

// AgentHookValidation is Core's verdict on a draft.
type AgentHookValidation struct {
	Valid          bool             `json:"valid"`
	Issues         []AgentHookIssue `json:"issues"`
	TimeoutSeconds *int             `json:"timeoutSeconds"`
}

// ValidateAgentHookDraft validates a draft with the rules save enforces, without I/O.
func (c *Client) ValidateAgentHookDraft(ctx context.Context, draft AgentHookDraft, existing []AgentHookRef) (AgentHookValidation, error) {
	var result AgentHookValidation
	err := c.Execute(ctx, "agent.hooks.validateDraft", struct {
		Hook          AgentHookDraft `json:"hook"`
		ExistingHooks []AgentHookRef `json:"existingHooks"`
	}{draft, existing}, &result)
	return result, err
}

// AgentSkill is one discovered Skill. Enabled is nil when the state is unknown.
type AgentSkill struct {
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Path        string  `json:"path"`
	Scope       string  `json:"scope"`
	Enabled     *bool   `json:"enabled"`
	PluginID    *string `json:"pluginId"`
}

// AgentSkillListing is the result of list and setEnabled.
type AgentSkillListing struct {
	Skills      []AgentSkill      `json:"skills"`
	Source      string            `json:"source"`
	Issues      []string          `json:"issues"`
	Directories map[string]string `json:"directories"`
}

type agentSkillRequest struct {
	Action       string `json:"action"`
	AgentID      string `json:"agentId"`
	Workspace    string `json:"workspace,omitempty"`
	Source       string `json:"source,omitempty"`
	Enabled      *bool  `json:"enabled,omitempty"`
	Scope        string `json:"scope,omitempty"`
	Name         string `json:"name,omitempty"`
	Description  string `json:"description,omitempty"`
	Instructions string `json:"instructions,omitempty"`
}

// ListAgentSkills discovers one Agent's Skills; it starts no conversation.
func (c *Client) ListAgentSkills(ctx context.Context, agentID, workspace string) (AgentSkillListing, error) {
	var result AgentSkillListing
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "list", AgentID: agentID, Workspace: workspace}, &result)
	return result, err
}

// SetAgentSkillEnabled changes a discovered Skill's native visibility and returns
// the fresh listing. scope is required for Claude.
func (c *Client) SetAgentSkillEnabled(ctx context.Context, agentID, workspace, source, scope string, enabled bool) (AgentSkillListing, error) {
	var result AgentSkillListing
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "setEnabled", AgentID: agentID, Workspace: workspace, Source: source, Scope: scope, Enabled: &enabled}, &result)
	return result, err
}

// ReadAgentSkill reads a SKILL.md as text; Core never interprets it.
func (c *Client) ReadAgentSkill(ctx context.Context, agentID, source string) (string, error) {
	var result struct {
		Content string `json:"content"`
	}
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "read", AgentID: agentID, Source: source}, &result)
	return result.Content, err
}

// AgentSkillDirectories returns the native destination map for one Agent.
func (c *Client) AgentSkillDirectories(ctx context.Context, agentID, workspace string) (map[string]string, error) {
	var result struct {
		Directories map[string]string `json:"directories"`
	}
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "directories", AgentID: agentID, Workspace: workspace}, &result)
	return result.Directories, err
}

// CreateAgentSkill writes a new Skill and returns its path.
func (c *Client) CreateAgentSkill(ctx context.Context, agentID, workspace, scope, name, description, instructions string) (string, error) {
	var result struct {
		Path string `json:"path"`
	}
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "create", AgentID: agentID, Workspace: workspace, Scope: scope, Name: name, Description: description, Instructions: instructions}, &result)
	return result.Path, err
}

// ImportAgentSkill copies a user-selected SKILL.md or package directory and returns its path.
func (c *Client) ImportAgentSkill(ctx context.Context, agentID, workspace, scope, source string) (string, error) {
	var result struct {
		Path string `json:"path"`
	}
	err := c.Execute(ctx, "agent.skills", agentSkillRequest{Action: "import", AgentID: agentID, Workspace: workspace, Scope: scope, Source: source}, &result)
	return result.Path, err
}
