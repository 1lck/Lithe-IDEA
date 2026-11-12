package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestAICredentialLocatorResolution(t *testing.T) {
	texts := map[string]string{
		"auth":   `{"OPENAI_API_KEY":"fixture-secret","nested":{"key":"nested-secret"}}`,
		"config": "model = 'fixture'\n",
	}
	environment := map[string]string{"COMPANY_KEY": "environment-secret"}
	value, err := resolveAICredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"OPENAI_API_KEY"}})
	if err != nil || value != "fixture-secret" {
		t.Fatalf("auth locator = %q, %v", value, err)
	}
	value, err = resolveAICredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"nested", "key"}})
	if err != nil || value != "nested-secret" {
		t.Fatalf("nested locator = %q, %v", value, err)
	}
	value, err = resolveAICredential(texts, environment, &core.AIConfigurationCredential{Kind: "environment", Name: "COMPANY_KEY"})
	if err != nil || value != "environment-secret" {
		t.Fatalf("environment locator = %q, %v", value, err)
	}
	if _, err := resolveAICredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "config", Path: []string{"experimental_bearer_token"}}); err == nil {
		t.Fatal("a TOML file locator must be reported as unsupported")
	}
	if _, err := resolveAICredential(texts, environment, &core.AIConfigurationCredential{Kind: "file", File: "auth", Path: []string{"missing"}}); err == nil {
		t.Fatal("a missing JSON path must fail")
	}
}

// fileAIKernel uses the real Core parser with files the test writes.
type fileAIKernel struct {
	client *core.Client
	files  []core.AIConfigurationFile
}

func (k fileAIKernel) AIConfigurationSources(_ context.Context, source, _ string, _ map[string]string) ([]core.AIConfigurationFile, error) {
	if source != "codex" {
		return nil, nil
	}
	return k.files, nil
}

func (k fileAIKernel) ParseAIConfiguration(ctx context.Context, request core.AIConfigurationParseRequest) (*core.AIConfiguration, error) {
	return k.client.ParseAIConfiguration(ctx, request)
}

func TestAIProviderDiscoveryUsesRealCoreParser(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config.toml")
	authPath := filepath.Join(directory, "auth.json")
	if err := os.WriteFile(configPath, []byte("model = 'fixture-model'\nmodel_provider = 'gateway'\n[model_providers.gateway]\nbase_url = 'https://example.test/v1'\nrequires_openai_auth = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(authPath, []byte(`{"OPENAI_API_KEY":"fixture-file-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	app := &App{aiKernel: fileAIKernel{client: core.NewClient(), files: []core.AIConfigurationFile{
		{File: "config", Path: configPath},
		{File: "auth", Path: authPath},
	}}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	providers := app.discoverAIProviders(ctx)
	if len(providers["codex"]) != 1 || len(providers["claude"]) != 0 {
		t.Fatalf("providers = %d codex, %d claude; want one Codex provider", len(providers["codex"]), len(providers["claude"]))
	}
	provider := providers["codex"][0]
	if provider.Issue != "" || provider.Endpoint != "https://example.test/v1" || provider.Model != "fixture-model" ||
		provider.Protocol != "responses" || provider.APIKey != "fixture-file-secret" {
		t.Fatalf("provider issue=%q endpoint=%q model=%q protocol=%q keyPresent=%v", provider.Issue, provider.Endpoint, provider.Model, provider.Protocol, provider.APIKey != "")
	}
	if _, ok := pickAIProvider(providers); !ok {
		t.Fatal("the discovered provider is not usable for generation")
	}
}
