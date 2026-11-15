package ai

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestCredentialLocatorResolution(t *testing.T) {
	texts := map[string]string{
		"auth":   `{"OPENAI_API_KEY":"fixture-secret","nested":{"key":"nested-secret"}}`,
		"config": "model = 'fixture'\n",
	}
	environment := map[string]string{"COMPANY_KEY": "environment-secret"}
	value, err := resolveCredential(texts, environment, &ConfigurationCredential{Kind: "file", File: "auth", Path: []string{"OPENAI_API_KEY"}})
	if err != nil || value != "fixture-secret" {
		t.Fatalf("auth locator = %q, %v", value, err)
	}
	value, err = resolveCredential(texts, environment, &ConfigurationCredential{Kind: "file", File: "auth", Path: []string{"nested", "key"}})
	if err != nil || value != "nested-secret" {
		t.Fatalf("nested locator = %q, %v", value, err)
	}
	value, err = resolveCredential(texts, environment, &ConfigurationCredential{Kind: "environment", Name: "COMPANY_KEY"})
	if err != nil || value != "environment-secret" {
		t.Fatalf("environment locator = %q, %v", value, err)
	}
	if _, err := resolveCredential(texts, environment, &ConfigurationCredential{Kind: "file", File: "config", Path: []string{"experimental_bearer_token"}}); err == nil {
		t.Fatal("a TOML file locator must be reported as unsupported")
	}
	if _, err := resolveCredential(texts, environment, &ConfigurationCredential{Kind: "file", File: "auth", Path: []string{"missing"}}); err == nil {
		t.Fatal("a missing JSON path must fail")
	}
}

// fileKernel uses the real Core parser with files the test writes.
type fileKernel struct {
	*Client
	files []ConfigurationFile
}

func (k fileKernel) ConfigurationSources(_ context.Context, source, _ string, _ map[string]string) ([]ConfigurationFile, error) {
	if source != "codex" {
		return nil, nil
	}
	return k.files, nil
}

func TestProviderDiscoveryUsesRealCoreParser(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config.toml")
	authPath := filepath.Join(directory, "auth.json")
	if err := os.WriteFile(configPath, []byte("model = 'fixture-model'\nmodel_provider = 'gateway'\n[model_providers.gateway]\nbase_url = 'https://example.test/v1'\nrequires_openai_auth = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(authPath, []byte(`{"OPENAI_API_KEY":"fixture-file-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := fileKernel{Client: testClient(), files: []ConfigurationFile{
		{File: "config", Path: configPath},
		{File: "auth", Path: authPath},
	}}
	providers := Discover(testContext(t), kernel)
	if len(providers["codex"]) != 1 || len(providers["claude"]) != 0 {
		t.Fatalf("providers = %d codex, %d claude; want one Codex provider", len(providers["codex"]), len(providers["claude"]))
	}
	provider := providers["codex"][0]
	if provider.Issue != "" || provider.Endpoint != "https://example.test/v1" || provider.Model != "fixture-model" ||
		provider.Protocol != "responses" || provider.APIKey != "fixture-file-secret" {
		t.Fatalf("provider issue=%q endpoint=%q model=%q protocol=%q keyPresent=%v", provider.Issue, provider.Endpoint, provider.Model, provider.Protocol, provider.APIKey != "")
	}
	if _, ok := Pick(providers, Sources()); !ok {
		t.Fatal("the discovered provider is not usable for generation")
	}
	if got := ConfigurationPath(testContext(t), kernel, "codex"); got != configPath {
		t.Fatalf("configuration path = %q, want %q", got, configPath)
	}
}

func TestPickNeedsACredential(t *testing.T) {
	providers := map[string][]Provider{
		"codex":  {{Endpoint: "https://a", MissingKey: true}},
		"claude": {{Endpoint: "https://b", APIKey: "k", Issue: ""}},
	}
	got, ok := Pick(providers, Sources())
	if !ok || got.Endpoint != "https://b" {
		t.Fatalf("picked %#v %v", got, ok)
	}
	if _, ok := Pick(map[string][]Provider{"codex": {{Endpoint: "https://a", APIKey: "k", Issue: issueCredential}}}, Sources()); ok {
		t.Fatal("a provider with an issue was picked")
	}
	if _, ok := Pick(providers, []string{"codex"}); ok {
		t.Fatal("a source outside the choice was picked")
	}
	both := map[string][]Provider{
		"codex":  {{Endpoint: "https://a", APIKey: "k"}},
		"claude": {{Endpoint: "https://b", APIKey: "k"}},
	}
	if got, ok := Pick(both, []string{"claude"}); !ok || got.Endpoint != "https://b" {
		t.Fatalf("claude only picked %#v %v", got, ok)
	}
	if _, ok := Pick(map[string][]Provider{"claude": {{Endpoint: "https://b"}}}, []string{"claude"}); ok {
		t.Fatal("a provider without a key was picked")
	}
}
