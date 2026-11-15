package ai

import (
	"context"
	"encoding/json"
	"errors"
	"unicode/utf8"
)

// The editor's inline edit: Core plans the request (ai.inlineEdit.plan) and decodes the answer
// (ai.inlineEdit.decode). The editor applies an accepted edit itself, as one undoable step,
// and only when the selection did not change meanwhile.

// InlineEditWindow is how many bytes of context are read on each side of the selection. Core
// keeps 12,000 Unicode scalars of them; a scalar is at most 4 bytes.
const InlineEditWindow = 48_000

// InlineEditProvider is the provider facts of an inline edit request.
type InlineEditProvider struct {
	WireProtocol          string `json:"wireProtocol"`
	Endpoint              string `json:"endpoint"`
	RequiresAPIKey        bool   `json:"requiresApiKey"`
	AllowsInsecureHTTP    bool   `json:"allowsInsecureHttp"`
	AcceptsUnlistedModels bool   `json:"acceptsUnlistedModels"`
	ChatTokenLimitField   string `json:"chatTokenLimitField,omitempty"`
	SupportsTemperature   bool   `json:"supportsTemperature"`
}

// InlineEditModel selects the model; Listing is catalog, discovered or unlisted. MaxTokens may
// be nil.
type InlineEditModel struct {
	ID        string `json:"id"`
	Listing   string `json:"listing"`
	MaxTokens *int   `json:"maxTokens"`
}

// InlineEdit is the editor text window of one inline edit.
type InlineEdit struct {
	BeforeSelection string `json:"beforeSelection"`
	SelectedText    string `json:"selectedText"`
	AfterSelection  string `json:"afterSelection"`
	Instruction     string `json:"instruction"`
	FilePath        string `json:"filePath"`
	LanguageID      string `json:"languageId"`
}

// CredentialSlot tells the host where to attach its credential. Scheme is bearer or raw.
type CredentialSlot struct {
	Required bool   `json:"required"`
	Header   string `json:"header"`
	Scheme   string `json:"scheme"`
}

// InlineEditPlan is the credential-free request of an inline edit.
type InlineEditPlan struct {
	URL        string            `json:"url"`
	Body       json.RawMessage   `json:"body"`
	Headers    map[string]string `json:"headers"`
	Credential CredentialSlot    `json:"credential"`
}

// PlanInlineEdit builds the provider request for one inline edit (ai.inlineEdit.plan).
func (c *Client) PlanInlineEdit(ctx context.Context, provider InlineEditProvider, model InlineEditModel, edit InlineEdit) (InlineEditPlan, error) {
	var result InlineEditPlan
	err := c.core.Execute(ctx, "ai.inlineEdit.plan", struct {
		Provider InlineEditProvider `json:"provider"`
		Model    InlineEditModel    `json:"model"`
		Edit     InlineEdit         `json:"edit"`
	}{provider, model, edit}, &result)
	return result, err
}

// DecodeInlineEdit extracts the replacement text from a provider answer (ai.inlineEdit.decode).
// An empty replacement is a valid result the caller must report.
func (c *Client) DecodeInlineEdit(ctx context.Context, wireProtocol string, response json.RawMessage) (string, error) {
	var result struct {
		EditedText string `json:"editedText"`
	}
	err := c.core.Execute(ctx, "ai.inlineEdit.decode", struct {
		WireProtocol string          `json:"wireProtocol"`
		Response     json.RawMessage `json:"response"`
	}{wireProtocol, response}, &result)
	return result.EditedText, err
}

// InlineContext is the text around the selection from start to end, at most InlineEditWindow
// bytes on each side and cut at character boundaries.
func InlineContext(text []byte, start, end int) (before, after string) {
	from := max(0, start-InlineEditWindow)
	for from < start && !utf8.RuneStart(text[from]) {
		from++
	}
	to := min(len(text), end+InlineEditWindow)
	for to > end && to < len(text) && !utf8.RuneStart(text[to]) {
		to--
	}
	return string(text[from:start]), string(text[end:to])
}

// EditInline plans, sends and decodes one inline edit with the first usable provider of sources
// and returns the replacement of the selected text.
func EditInline(ctx context.Context, k Kernel, edit InlineEdit, sources []string) (string, error) {
	provider, err := Choose(ctx, k, sources)
	if err != nil {
		return "", err
	}
	model := InlineEditModel{ID: provider.Model, Listing: "unlisted"}
	plan, err := k.PlanInlineEdit(ctx, InlineEditProvider{
		WireProtocol: provider.Protocol, Endpoint: provider.Endpoint, RequiresAPIKey: true,
		AcceptsUnlistedModels: true, ChatTokenLimitField: "max_completion_tokens",
	}, model, edit)
	if err != nil {
		return "", err
	}
	out := map[string]string{"Content-Type": "application/json"}
	for name, value := range plan.Headers {
		out[name] = value
	}
	if plan.Credential.Required {
		value := provider.APIKey
		if plan.Credential.Scheme == "bearer" {
			value = "Bearer " + value
		}
		out[plan.Credential.Header] = value
	}
	answer, err := post(ctx, plan.URL, out, plan.Body)
	if err != nil {
		return "", err
	}
	if !json.Valid(answer) {
		return "", errors.New("AI_INLINE_EDIT_INVALID_RESPONSE")
	}
	return k.DecodeInlineEdit(ctx, provider.Protocol, answer)
}
