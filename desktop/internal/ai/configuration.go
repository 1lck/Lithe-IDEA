package ai

import "context"

// ConfigurationFile is one native file Core asks the platform to read for an AI CLI
// configuration source. File is the key the text is passed back under.
type ConfigurationFile struct {
	File string `json:"file"`
	Path string `json:"path"`
}

// ConfigurationProvider is the credential-free provider metadata parsed from a local Codex or
// Claude configuration. APIProtocol is responses, chatCompletions or anthropicMessages;
// Authentication is bearer or apiKey.
type ConfigurationProvider struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Endpoint       string `json:"endpoint"`
	Model          string `json:"model"`
	APIProtocol    string `json:"apiProtocol"`
	Authentication string `json:"authentication"`
	Source         string `json:"source"`
	RequiresAPIKey bool   `json:"requiresApiKey"`
}

// ConfigurationCredential locates the credential in the same files or environment that were
// passed to the parser. The value itself never crosses the Core boundary.
type ConfigurationCredential struct {
	Kind string   `json:"kind"`
	Name string   `json:"name,omitempty"`
	File string   `json:"file,omitempty"`
	Path []string `json:"path,omitempty"`
}

// Configuration is Core's parse result. A nil value from ParseConfiguration means nothing is
// configured. Provider is nil when the configuration parsed but is not a usable provider; Issue
// then names the stable reason code.
type Configuration struct {
	Model                     string                   `json:"model"`
	Provider                  *ConfigurationProvider   `json:"provider"`
	Issue                     *string                  `json:"issue"`
	ReasoningEffort           *string                  `json:"reasoningEffort"`
	HasCredential             bool                     `json:"hasCredential"`
	Credential                *ConfigurationCredential `json:"credential"`
	UnsupportedAuthentication bool                     `json:"unsupportedAuthentication"`
}

// ConfigurationParseRequest is the payload of ai.configuration.parse. Files is keyed like
// ConfigurationFile.File: config, auth, settings, credentials and root. Environment is the
// process snapshot the credential locator is resolved against; it is not returned or logged.
type ConfigurationParseRequest struct {
	Source          string            `json:"source"`
	Files           map[string]string `json:"files,omitempty"`
	Environment     map[string]string `json:"environment,omitempty"`
	AllowIncomplete bool              `json:"allowIncomplete,omitempty"`
}

// ConfigurationSources names the native files of one AI CLI source (ai.configuration.sources).
// Core decides the paths; the platform only reads them.
func (c *Client) ConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]ConfigurationFile, error) {
	var result struct {
		Files []ConfigurationFile `json:"files"`
	}
	err := c.core.Execute(ctx, "ai.configuration.sources", struct {
		Source      string            `json:"source"`
		Home        string            `json:"home"`
		Environment map[string]string `json:"environment,omitempty"`
	}{Source: source, Home: home, Environment: environment}, &result)
	return result.Files, err
}

// ParseConfiguration applies Core's shared rules to the text of the files ConfigurationSources
// named (ai.configuration.parse). The result carries metadata and a credential locator only;
// the platform resolves the locator.
func (c *Client) ParseConfiguration(ctx context.Context, request ConfigurationParseRequest) (*Configuration, error) {
	var result *Configuration
	if err := c.core.Execute(ctx, "ai.configuration.parse", request, &result); err != nil {
		return nil, err
	}
	return result, nil
}
