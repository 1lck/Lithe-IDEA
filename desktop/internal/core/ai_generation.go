package core

import (
	"context"
	"encoding/json"
)

// AICommitProvider is the credential-free provider description of the commit
// planner. Credentials never cross the Core boundary.
type AICommitProvider struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	Endpoint            string `json:"endpoint"`
	Model               string `json:"model"`
	APIProtocol         string `json:"apiProtocol"`
	Authentication      string `json:"authentication"`
	Source              string `json:"source"`
	RequiresAPIKey      bool   `json:"requiresApiKey"`
	AllowsInsecureHTTP  bool   `json:"allowsInsecureHttp"`
	ChatTokenLimitField string `json:"chatTokenLimitField,omitempty"`
}

// AICommitOptions are the user choices of one commit message generation.
type AICommitOptions struct {
	Language              string `json:"language"`
	Format                string `json:"format"`
	CustomInstructions    string `json:"customInstructions"`
	IncludeBody           bool   `json:"includeBody"`
	SubjectMaximumLength  int    `json:"subjectMaximumLength"`
	MaximumDiffCharacters int    `json:"maximumDiffCharacters"`
	ReasoningEffort       string `json:"reasoningEffort"`
}

// AICommitFile is one file of commit evidence. OriginalCharacters is the
// untruncated diff length reported by git.commitMessageContext. The JSON
// command expects it on every file, with Diff already cut to the budget.
type AICommitFile struct {
	Path               string `json:"path"`
	ChangeKind         string `json:"changeKind"`
	Diff               string `json:"diff"`
	OriginalCharacters *int   `json:"originalCharacters,omitempty"`
}

// AIHTTPRequest is a credential-free provider request. The host attaches the
// authentication headers and performs the HTTP call.
type AIHTTPRequest struct {
	URL  string          `json:"url"`
	Body json.RawMessage `json:"body"`
}

// AIPlanCommit builds the provider request for a commit message.
func (c *Client) AIPlanCommit(ctx context.Context, provider AICommitProvider, options AICommitOptions, files []AICommitFile) (AIHTTPRequest, error) {
	var result AIHTTPRequest
	err := c.Execute(ctx, "ai.planCommit", struct {
		Provider AICommitProvider `json:"provider"`
		Options  AICommitOptions  `json:"options"`
		Files    []AICommitFile   `json:"files"`
	}{provider, options, files}, &result)
	return result, err
}

// AIDecodeCommitMessage extracts the message from a provider response body. The
// host rejects responses over 2 MiB before calling it.
func (c *Client) AIDecodeCommitMessage(ctx context.Context, protocol string, response json.RawMessage, includeBody bool) (string, error) {
	var result struct {
		Message string `json:"message"`
	}
	err := c.Execute(ctx, "ai.decodeCommitMessage", struct {
		Protocol    string          `json:"protocol"`
		Response    json.RawMessage `json:"response"`
		IncludeBody bool            `json:"includeBody"`
	}{protocol, response, includeBody}, &result)
	return result.Message, err
}

// AICommitBudgetFile is the budgeted prefix length of one file.
type AICommitBudgetFile struct {
	Characters int  `json:"characters"`
	Truncated  bool `json:"truncated"`
}

// AICommitInputBudget distributes the diff budget across files given their
// Unicode scalar lengths.
func (c *Client) AICommitInputBudget(ctx context.Context, maximumDiffCharacters int, fileLengths []int) ([]AICommitBudgetFile, error) {
	var result struct {
		Files []AICommitBudgetFile `json:"files"`
	}
	err := c.Execute(ctx, "ai.commitInputBudget", struct {
		MaximumDiffCharacters int   `json:"maximumDiffCharacters"`
		FileLengths           []int `json:"fileLengths"`
	}{maximumDiffCharacters, nonNil(fileLengths)}, &result)
	return result.Files, err
}

// AIInlineEditProvider is the provider facts of an inline edit request.
type AIInlineEditProvider struct {
	WireProtocol          string `json:"wireProtocol"`
	Endpoint              string `json:"endpoint"`
	RequiresAPIKey        bool   `json:"requiresApiKey"`
	AllowsInsecureHTTP    bool   `json:"allowsInsecureHttp"`
	AcceptsUnlistedModels bool   `json:"acceptsUnlistedModels"`
	ChatTokenLimitField   string `json:"chatTokenLimitField,omitempty"`
	SupportsTemperature   bool   `json:"supportsTemperature"`
}

// AIInlineEditModel selects the model; Listing is catalog, discovered or
// unlisted. MaxTokens may be nil.
type AIInlineEditModel struct {
	ID        string `json:"id"`
	Listing   string `json:"listing"`
	MaxTokens *int   `json:"maxTokens"`
}

// AIInlineEdit is the editor text window of one inline edit.
type AIInlineEdit struct {
	BeforeSelection string `json:"beforeSelection"`
	SelectedText    string `json:"selectedText"`
	AfterSelection  string `json:"afterSelection"`
	Instruction     string `json:"instruction"`
	FilePath        string `json:"filePath"`
	LanguageID      string `json:"languageId"`
}

// AICredentialSlot tells the host where to attach its credential. Scheme is
// bearer or raw.
type AICredentialSlot struct {
	Required bool   `json:"required"`
	Header   string `json:"header"`
	Scheme   string `json:"scheme"`
}

// AIInlineEditPlan is the credential-free request of an inline edit.
type AIInlineEditPlan struct {
	URL        string            `json:"url"`
	Body       json.RawMessage   `json:"body"`
	Headers    map[string]string `json:"headers"`
	Credential AICredentialSlot  `json:"credential"`
}

// AIInlineEditPlan builds the provider request for one inline edit.
func (c *Client) AIInlineEditPlan(ctx context.Context, provider AIInlineEditProvider, model AIInlineEditModel, edit AIInlineEdit) (AIInlineEditPlan, error) {
	var result AIInlineEditPlan
	err := c.Execute(ctx, "ai.inlineEdit.plan", struct {
		Provider AIInlineEditProvider `json:"provider"`
		Model    AIInlineEditModel    `json:"model"`
		Edit     AIInlineEdit         `json:"edit"`
	}{provider, model, edit}, &result)
	return result, err
}

// AIInlineEditDecode extracts the replacement text from a provider response. An
// empty replacement is a valid result the caller must report.
func (c *Client) AIInlineEditDecode(ctx context.Context, wireProtocol string, response json.RawMessage) (string, error) {
	var result struct {
		EditedText string `json:"editedText"`
	}
	err := c.Execute(ctx, "ai.inlineEdit.decode", struct {
		WireProtocol string          `json:"wireProtocol"`
		Response     json.RawMessage `json:"response"`
	}{wireProtocol, response}, &result)
	return result.EditedText, err
}

// CommitContextFile is a selected file of git.commitMessageContext.
type CommitContextFile struct {
	Path         string `json:"path"`
	OriginalPath string `json:"originalPath,omitempty"`
	ChangeKind   string `json:"changeKind"`
}

// CommitContextRepository is one repository and its selected files.
type CommitContextRepository struct {
	Root  string              `json:"root"`
	Files []CommitContextFile `json:"files"`
}

// CommitContextEvidence is the bounded evidence captured for AI generation.
type CommitContextEvidence struct {
	Files []AICommitFile
	Token string
}

type commitContextRequest struct {
	Action                string                    `json:"action"`
	Mode                  string                    `json:"mode"`
	Repositories          []CommitContextRepository `json:"repositories"`
	MaximumDiffCharacters int                       `json:"maximumDiffCharacters,omitempty"`
	Token                 string                    `json:"token,omitempty"`
}

// CommitMessageContext captures AI commit evidence without modifying the index.
// mode is staged or worktree and must match the commit operation. It runs Git
// and blocks; call it from a background goroutine.
func (c *Client) CommitMessageContext(ctx context.Context, mode string, repositories []CommitContextRepository, maximumDiffCharacters int) (CommitContextEvidence, error) {
	var raw struct {
		Files []struct {
			Path               string `json:"path"`
			ChangeKind         string `json:"changeKind"`
			Diff               string `json:"diff"`
			OriginalCharacters int    `json:"originalCharacters"`
		} `json:"files"`
		Token string `json:"token"`
	}
	err := c.Execute(ctx, "git.commitMessageContext", commitContextRequest{
		Action: "capture", Mode: mode, Repositories: repositories, MaximumDiffCharacters: maximumDiffCharacters,
	}, &raw)
	out := CommitContextEvidence{Token: raw.Token}
	for _, f := range raw.Files {
		n := f.OriginalCharacters
		out.Files = append(out.Files, AICommitFile{Path: f.Path, ChangeKind: f.ChangeKind, Diff: f.Diff, OriginalCharacters: &n})
	}
	return out, err
}

// CommitMessageContextIsCurrent rechecks the captured evidence token against
// the current Git state. Apply generated text only when it returns true.
func (c *Client) CommitMessageContextIsCurrent(ctx context.Context, mode string, repositories []CommitContextRepository, token string) (bool, error) {
	var result struct {
		IsCurrent bool `json:"isCurrent"`
	}
	err := c.Execute(ctx, "git.commitMessageContext", commitContextRequest{
		Action: "check", Mode: mode, Repositories: repositories, Token: token,
	}, &result)
	return result.IsCurrent, err
}

// IDEHostControl sends one ideHost.control action to the local capability
// broker and returns the raw result. Actions are open, close, closeOwner, poll,
// claim, respond, catalog, validate and output; see Lithe-core-rust rust/contracts/ide-api/v1.md.
func (c *Client) IDEHostControl(ctx context.Context, action string, arguments any) (json.RawMessage, error) {
	var result json.RawMessage
	err := c.Execute(ctx, "ideHost.control", struct {
		Action    string `json:"action"`
		Arguments any    `json:"arguments"`
	}{action, arguments}, &result)
	return result, err
}
