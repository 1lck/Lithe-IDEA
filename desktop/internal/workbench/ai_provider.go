package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
)

// The provider discovery of commit message generation and inline edits: the endpoint, model and
// key the user's own Codex or Claude configuration names. Core finds the native files and parses
// them; this file only reads the files Core names and resolves the credential locator against
// the same text and environment. A key stays in memory and is never logged or persisted.

// AIKernel is what provider discovery asks the kernel. *core.Client satisfies it through
// CoreAIKernel; a window built without one offers no AI generation.
type AIKernel interface {
	AIConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]core.AIConfigurationFile, error)
	ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error)
}

// CoreAIKernel adapts the typed Core client to AIKernel.
type CoreAIKernel struct{ Client *core.Client }

func (k CoreAIKernel) AIConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]core.AIConfigurationFile, error) {
	return k.Client.AIConfigurationSources(ctx, source, home, environment)
}

func (k CoreAIKernel) ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error) {
	return k.Client.ParseAIConfiguration(ctx, request)
}

// aiConfigFileLimit matches Core's accepted configuration text size.
const aiConfigFileLimit = 1 << 20

// Stable reasons a discovered provider cannot be used. Generation only needs to know that a
// provider has one; the names keep the reasons apart when a test or a log needs them.
const (
	aiIssueConfigRead            = "configRead"
	aiIssueInvalidConfig         = "invalidConfig"
	aiIssueUnsupportedAuth       = "unsupportedAuth"
	aiIssueCredential            = "credential"
	aiIssueCredentialUnsupported = "credentialUnsupported"
)

var (
	errAICredentialUnreadable  = errors.New("AI credential unreadable")
	errAICredentialUnsupported = errors.New("AI credential unsupported")
)

// aiProvider is one provider discovered from the user's local Codex or Claude configuration.
// APIKey is memory-only and must never be logged or persisted.
type aiProvider struct {
	Source   string
	Name     string
	Endpoint string
	Model    string
	Protocol string
	// Authentication is bearer or apiKey, as Core parsed it.
	Authentication string
	APIKey         string
	Issue          string
	MissingKey     bool
}

// aiKernelReady reports whether the window can discover providers at all.
func (a *App) aiKernelReady() bool { return a.aiKernel != nil }

// discoverAIProviders reads the local Codex and Claude configuration through Core and resolves
// each credential locator. A source that cannot be read or parsed contributes no provider; no
// error carries a secret.
func (a *App) discoverAIProviders(ctx context.Context) map[string][]aiProvider {
	providers := map[string][]aiProvider{}
	if a.aiKernel == nil {
		return providers
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return providers
	}
	environment := aiEnvironment()
	for _, source := range aiProviderSources() {
		if provider, ok := a.discoverAIProvider(ctx, source, home, environment); ok {
			providers[source] = append(providers[source], provider)
		}
	}
	return providers
}

// discoverAIProvider reads one source. It reports false when the source names no provider; a
// provider that cannot be used is returned with its Issue or MissingKey set.
func (a *App) discoverAIProvider(ctx context.Context, source, home string, environment map[string]string) (aiProvider, bool) {
	files, err := a.aiKernel.AIConfigurationSources(ctx, source, home, environment)
	if err != nil {
		return aiProvider{}, false
	}
	texts := map[string]string{}
	for _, file := range files {
		value, present, err := readAIConfigurationFile(file.Path)
		if err != nil {
			return aiProvider{Source: source, Issue: aiIssueConfigRead}, true
		}
		if present {
			texts[file.File] = value
		}
	}
	parsed, err := a.aiKernel.ParseAIConfiguration(ctx, core.AIConfigurationParseRequest{
		Source:      source,
		Files:       texts,
		Environment: environment,
	})
	if err != nil || parsed == nil {
		return aiProvider{}, false
	}
	if parsed.Provider == nil {
		if parsed.Issue != nil {
			return aiProvider{Source: source, Issue: aiIssueInvalidConfig}, true
		}
		return aiProvider{}, false
	}
	provider := aiProvider{
		Source:         source,
		Name:           parsed.Provider.Name,
		Endpoint:       parsed.Provider.Endpoint,
		Model:          parsed.Provider.Model,
		Protocol:       parsed.Provider.APIProtocol,
		Authentication: parsed.Provider.Authentication,
	}
	if provider.Name == "" {
		provider.Name = parsed.Provider.Endpoint
	}
	if provider.Model == "" {
		provider.Model = parsed.Model
	}
	switch {
	case parsed.UnsupportedAuthentication:
		provider.Issue = aiIssueUnsupportedAuth
	case parsed.HasCredential && parsed.Credential != nil:
		key, err := resolveAICredential(texts, environment, parsed.Credential)
		switch {
		case errors.Is(err, errAICredentialUnsupported):
			provider.Issue = aiIssueCredentialUnsupported
		case err != nil:
			provider.Issue = aiIssueCredential
		case strings.TrimSpace(key) == "":
			provider.MissingKey = true
		default:
			provider.APIKey = key
		}
	default:
		// A generation request needs a key even when the provider metadata says it does not.
		provider.MissingKey = true
	}
	return provider, true
}

// aiProviderSources are the AI CLI configuration sources Core exposes, in the order
// generation tries them.
func aiProviderSources() []string { return []string{"codex", "claude"} }

// aiEnvironment is the process environment Core's configuration discovery and credential
// locators resolve against. The snapshot is not logged and never leaves the process.
func aiEnvironment() map[string]string {
	environment := map[string]string{}
	for _, entry := range loginenv.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && name != "" {
			environment[name] = value
		}
	}
	return environment
}

func readAIConfigurationFile(path string) (string, bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, aiConfigFileLimit+1))
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	if len(data) > aiConfigFileLimit {
		return "", false, fmt.Errorf("%s is larger than %d bytes", filepath.Base(path), aiConfigFileLimit)
	}
	return string(data), true, nil
}

func resolveAICredential(texts, environment map[string]string, locator *core.AIConfigurationCredential) (string, error) {
	switch locator.Kind {
	case "environment":
		return environment[locator.Name], nil
	case "file":
		if locator.File == "config" {
			// The Codex TOML locator is the only path that needs a TOML parser.
			// It is reported instead of adding a second configuration parser.
			return "", errAICredentialUnsupported
		}
		value, err := resolveJSONPath(texts[locator.File], locator.Path)
		if err != nil {
			return "", errAICredentialUnreadable
		}
		return value, nil
	}
	return "", errAICredentialUnsupported
}

func resolveJSONPath(text string, path []string) (string, error) {
	var document any
	if err := json.Unmarshal([]byte(text), &document); err != nil {
		return "", err
	}
	current := document
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return "", errors.New("not an object")
		}
		current, ok = object[key]
		if !ok {
			return "", errors.New("missing key")
		}
	}
	value, ok := current.(string)
	if !ok {
		return "", errors.New("not a string")
	}
	return value, nil
}
