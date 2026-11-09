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
)

// agentConfigFileLimit matches Core's accepted configuration text size.
const agentConfigFileLimit = 1 << 20

// Stable reasons a discovered provider cannot be used. They are translated in
// agent_view.go; upstream Core messages pass through unchanged.
const (
	agentIssueHome                  = "home"
	agentIssueConfigRead            = "configRead"
	agentIssueInvalidConfig         = "invalidConfig"
	agentIssueUnsupportedAuth       = "unsupportedAuth"
	agentIssueCredential            = "credential"
	agentIssueCredentialUnsupported = "credentialUnsupported"
)

var (
	errAgentCredentialUnreadable  = errors.New("agent credential unreadable")
	errAgentCredentialUnsupported = errors.New("agent credential unsupported")
)

// agentProvider is one provider discovered from the user's local Codex or
// Claude configuration. APIKey is memory-only and must never be logged or
// persisted.
type agentProvider struct {
	Source     string
	Name       string
	Endpoint   string
	Model      string
	Protocol   string
	APIKey     string
	Issue      string
	MissingKey bool
}

// discoverAgentProviders reads the local Codex and Claude configuration through
// Core and resolves the credential locator against the same text and
// environment. It returns no secret in an error.
func (a *App) discoverAgentProviders(ctx context.Context) (map[string][]agentProvider, map[string]string) {
	providers := map[string][]agentProvider{}
	issues := map[string]string{}
	home, err := os.UserHomeDir()
	if err != nil {
		return providers, map[string]string{"codex": agentIssueHome, "claude": agentIssueHome}
	}
	environment := agentEnvironment()
	for _, source := range agentProviderSources() {
		files, err := a.agentKernel.AIConfigurationSources(ctx, source, home, environment)
		if err != nil {
			issues[source] = a.agentDiscoveryIssue(err)
			continue
		}
		texts := map[string]string{}
		readFailed := false
		for _, file := range files {
			value, present, err := readAgentConfigurationFile(file.Path)
			if err != nil {
				issues[source] = agentIssueConfigRead
				readFailed = true
				break
			}
			if present {
				texts[file.File] = value
			}
		}
		if readFailed {
			continue
		}
		parsed, err := a.agentKernel.ParseAIConfiguration(ctx, core.AIConfigurationParseRequest{
			Source:      source,
			Files:       texts,
			Environment: environment,
		})
		if err != nil {
			issues[source] = a.agentDiscoveryIssue(err)
			continue
		}
		if parsed == nil || parsed.Provider == nil {
			if parsed != nil && parsed.Issue != nil {
				issues[source] = agentIssueInvalidConfig
			}
			continue
		}
		provider := agentProvider{
			Source:   source,
			Name:     parsed.Provider.Name,
			Endpoint: parsed.Provider.Endpoint,
			Model:    parsed.Provider.Model,
			Protocol: parsed.Provider.APIProtocol,
		}
		if provider.Name == "" {
			provider.Name = parsed.Provider.Endpoint
		}
		if provider.Model == "" {
			provider.Model = parsed.Model
		}
		if parsed.UnsupportedAuthentication {
			provider.Issue = agentIssueUnsupportedAuth
		} else if parsed.HasCredential && parsed.Credential != nil {
			key, err := resolveAgentCredential(texts, environment, parsed.Credential)
			if errors.Is(err, errAgentCredentialUnsupported) {
				provider.Issue = agentIssueCredentialUnsupported
			} else if err != nil {
				provider.Issue = agentIssueCredential
			} else if strings.TrimSpace(key) == "" {
				provider.MissingKey = true
			} else {
				provider.APIKey = key
			}
		} else {
			// Core's ApiKey launch requires a non-empty key even when the
			// provider metadata says it does not need one. Mark the provider so
			// the panel explains the disabled Start button instead of leaving it
			// permanently disabled without a reason.
			provider.MissingKey = true
		}
		providers[source] = append(providers[source], provider)
	}
	return providers, issues
}

// agentProviderSources are the AI CLI configuration sources Core exposes.
// The selected agent is matched to a provider by the protocol Core reports for
// both, not by a tool name.
func agentProviderSources() []string { return []string{"codex", "claude"} }

// agentEnvironment is the process environment Core's configuration discovery
// and credential locators resolve against. The snapshot is not logged and
// never leaves the process.
func agentEnvironment() map[string]string {
	environment := map[string]string{}
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && name != "" {
			environment[name] = value
		}
	}
	return environment
}

func readAgentConfigurationFile(path string) (string, bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, agentConfigFileLimit+1))
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	if len(data) > agentConfigFileLimit {
		return "", false, fmt.Errorf("%s is larger than %d bytes", filepath.Base(path), agentConfigFileLimit)
	}
	return string(data), true, nil
}

func resolveAgentCredential(texts, environment map[string]string, locator *core.AIConfigurationCredential) (string, error) {
	switch locator.Kind {
	case "environment":
		return environment[locator.Name], nil
	case "file":
		if locator.File == "config" {
			// The Codex TOML locator is the only path that needs a TOML parser.
			// It is reported instead of adding a second configuration parser.
			return "", errAgentCredentialUnsupported
		}
		value, err := resolveJSONPath(texts[locator.File], locator.Path)
		if err != nil {
			return "", errAgentCredentialUnreadable
		}
		return value, nil
	}
	return "", errAgentCredentialUnsupported
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
