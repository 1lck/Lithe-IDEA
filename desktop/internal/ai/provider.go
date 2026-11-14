package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
)

// Provider discovery: the endpoint, model and key the user's own Codex or Claude configuration
// names. Core finds the native files and parses them; this file only reads the files Core
// names and resolves the credential locator against the same text and environment.

// configFileLimit matches Core's accepted configuration text size.
const configFileLimit = 1 << 20

// Stable reasons a discovered provider cannot be used. Generation only needs to know that a
// provider has one; the names keep the reasons apart when a test or a log needs them.
const (
	issueConfigRead            = "configRead"
	issueInvalidConfig         = "invalidConfig"
	issueUnsupportedAuth       = "unsupportedAuth"
	issueCredential            = "credential"
	issueCredentialUnsupported = "credentialUnsupported"
)

var (
	errCredentialUnreadable  = errors.New("AI credential unreadable")
	errCredentialUnsupported = errors.New("AI credential unsupported")
)

// ErrNoProvider reports that no configured provider can be used.
var ErrNoProvider = errors.New("no AI provider")

// Provider is one provider discovered from the user's local Codex or Claude configuration.
// APIKey is memory-only and must never be logged or persisted.
type Provider struct {
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

// Usable reports that the provider has no issue and holds a credential.
func (p Provider) Usable() bool {
	return p.Issue == "" && !p.MissingKey && p.APIKey != "" && p.Endpoint != ""
}

// plan is the credential-free description Core plans a commit or pull request request for.
func (p Provider) plan() PlanProvider {
	return PlanProvider{
		ID: p.Source, Name: p.Name, Endpoint: p.Endpoint, Model: p.Model,
		APIProtocol: p.Protocol, Authentication: p.Authentication, Source: p.Source, RequiresAPIKey: true,
	}
}

// Sources are the AI CLI configuration sources Core exposes, in the order generation tries
// them.
func Sources() []string { return []string{"codex", "claude"} }

// Discover reads the local Codex and Claude configuration through Core and resolves each
// credential locator. A source that cannot be read or parsed contributes no provider; no error
// carries a secret.
func Discover(ctx context.Context, k Kernel) map[string][]Provider {
	providers := map[string][]Provider{}
	home, err := os.UserHomeDir()
	if err != nil {
		return providers
	}
	environment := Environment()
	for _, source := range Sources() {
		if provider, ok := discover(ctx, k, source, home, environment); ok {
			providers[source] = append(providers[source], provider)
		}
	}
	return providers
}

// discover reads one source. It reports false when the source names no provider; a provider
// that cannot be used is returned with its Issue or MissingKey set.
func discover(ctx context.Context, k Kernel, source, home string, environment map[string]string) (Provider, bool) {
	files, err := k.ConfigurationSources(ctx, source, home, environment)
	if err != nil {
		return Provider{}, false
	}
	texts := map[string]string{}
	for _, file := range files {
		value, present, err := readConfigurationFile(file.Path)
		if err != nil {
			return Provider{Source: source, Issue: issueConfigRead}, true
		}
		if present {
			texts[file.File] = value
		}
	}
	parsed, err := k.ParseConfiguration(ctx, ConfigurationParseRequest{
		Source:      source,
		Files:       texts,
		Environment: environment,
	})
	if err != nil || parsed == nil {
		return Provider{}, false
	}
	if parsed.Provider == nil {
		if parsed.Issue != nil {
			return Provider{Source: source, Issue: issueInvalidConfig}, true
		}
		return Provider{}, false
	}
	provider := Provider{
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
		provider.Issue = issueUnsupportedAuth
	case parsed.HasCredential && parsed.Credential != nil:
		key, err := resolveCredential(texts, environment, parsed.Credential)
		switch {
		case errors.Is(err, errCredentialUnsupported):
			provider.Issue = issueCredentialUnsupported
		case err != nil:
			provider.Issue = issueCredential
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

// Pick is the first usable provider of the given sources, in their order.
func Pick(providers map[string][]Provider, sources []string) (Provider, bool) {
	for _, source := range sources {
		for _, provider := range providers[source] {
			if provider.Usable() {
				return provider, true
			}
		}
	}
	return Provider{}, false
}

// Choose discovers the providers and picks the first usable one of sources, or reports
// ErrNoProvider.
func Choose(ctx context.Context, k Kernel, sources []string) (Provider, error) {
	provider, ok := Pick(Discover(ctx, k), sources)
	if !ok {
		return Provider{}, ErrNoProvider
	}
	return provider, nil
}

// ConfigurationPath is the first native file of a source that exists, or the first file Core
// names when none does. Empty means Core named no file.
func ConfigurationPath(ctx context.Context, k Kernel, source string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	files, err := k.ConfigurationSources(ctx, source, home, Environment())
	if err != nil || len(files) == 0 {
		return ""
	}
	for _, file := range files {
		if _, err := os.Stat(file.Path); err == nil {
			return file.Path
		}
	}
	return files[0].Path
}

// Environment is the process environment Core's configuration discovery and credential
// locators resolve against. The snapshot is not logged and never leaves the process.
func Environment() map[string]string {
	environment := map[string]string{}
	for _, entry := range loginenv.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && name != "" {
			environment[name] = value
		}
	}
	return environment
}

func readConfigurationFile(path string) (string, bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, configFileLimit+1))
	if err != nil {
		return "", false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	if len(data) > configFileLimit {
		return "", false, fmt.Errorf("%s is larger than %d bytes", filepath.Base(path), configFileLimit)
	}
	return string(data), true, nil
}

func resolveCredential(texts, environment map[string]string, locator *ConfigurationCredential) (string, error) {
	switch locator.Kind {
	case "environment":
		return environment[locator.Name], nil
	case "file":
		if locator.File == "config" {
			// The Codex TOML locator is the only path that needs a TOML parser.
			// It is reported instead of adding a second configuration parser.
			return "", errCredentialUnsupported
		}
		value, err := resolveJSONPath(texts[locator.File], locator.Path)
		if err != nil {
			return "", errCredentialUnreadable
		}
		return value, nil
	}
	return "", errCredentialUnsupported
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
