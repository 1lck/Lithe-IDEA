package ai

import (
	"maps"
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

func TestProviderDiscoveryUsesRealCoreParser(t *testing.T) {
	const codexConfig = "model = 'fixture-model'\nmodel_provider = 'gateway'\n[model_providers.gateway]\nbase_url = 'https://example.test/v1'\nrequires_openai_auth = true\n"
	const codexAuth = `{"OPENAI_API_KEY":"fixture-file-secret"}`
	const claudeSettings = `{"model":"fixture-claude-model","env":{"ANTHROPIC_BASE_URL":"https://claude.example.test/v1","ANTHROPIC_API_KEY":"fixture-claude-file-secret"}}`
	codex := Provider{
		Source: "codex", Name: "Codex · gateway", Endpoint: "https://example.test/v1", Model: "fixture-model",
		Protocol: "responses", Authentication: "bearer", APIKey: "fixture-file-secret",
	}
	claudeEnvironment := Provider{
		Source: "claude", Name: "Claude", Endpoint: "https://claude.example.test/v1", Model: "fixture-claude-model",
		Protocol: "anthropicMessages", Authentication: "apiKey", APIKey: "fixture-environment-secret",
	}
	claudeFile := claudeEnvironment
	claudeFile.APIKey = "fixture-claude-file-secret"
	environment := map[string]string{
		"ANTHROPIC_BASE_URL": "https://claude.example.test/v1",
		"ANTHROPIC_MODEL":    "fixture-claude-model",
		"ANTHROPIC_API_KEY":  "fixture-environment-secret",
	}
	for _, test := range []struct {
		name        string
		files       map[string]string
		environment map[string]string
		want        map[string]Provider
		wantPick    string
		codexPath   string
	}{
		{name: "no configuration"},
		{
			name:      "Codex files only",
			files:     map[string]string{".codex/config.toml": codexConfig, ".codex/auth.json": codexAuth},
			want:      map[string]Provider{"codex": codex},
			wantPick:  "codex",
			codexPath: ".codex/config.toml",
		},
		{
			name:     "Claude files only",
			files:    map[string]string{".claude/settings.json": claudeSettings},
			want:     map[string]Provider{"claude": claudeFile},
			wantPick: "claude",
		},
		{
			name:        "Claude environment without files",
			environment: environment,
			want:        map[string]Provider{"claude": claudeEnvironment},
			wantPick:    "claude",
		},
		{
			name:        "both sources",
			files:       map[string]string{".codex/config.toml": codexConfig, ".codex/auth.json": codexAuth},
			environment: environment,
			want:        map[string]Provider{"codex": codex, "claude": claudeEnvironment},
			wantPick:    "codex",
		},
		{
			name: "environment selects configuration directories",
			files: map[string]string{
				"codex-home/config.toml":    codexConfig,
				"codex-home/auth.json":      codexAuth,
				"claude-home/settings.json": claudeSettings,
			},
			environment: map[string]string{"CODEX_HOME": "codex-home", "CLAUDE_CONFIG_DIR": "claude-home"},
			want:        map[string]Provider{"codex": codex, "claude": claudeFile},
			wantPick:    "codex",
			codexPath:   "codex-home/config.toml",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			home := t.TempDir()
			for name, contents := range test.files {
				path := filepath.Join(home, name)
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			environment := maps.Clone(test.environment)
			for _, key := range []string{"CODEX_HOME", "CLAUDE_CONFIG_DIR"} {
				if relative := environment[key]; relative != "" {
					environment[key] = filepath.Join(home, relative)
				}
			}
			// Both native path discovery and parsing use the real Core. Neither the home
			// nor the environment comes from the developer's account, even when nil.
			kernel := testClient()
			providers := discoverProviders(testContext(t), kernel, home, environment)
			if len(providers) != len(test.want) {
				t.Fatalf("provider sources = %d, want %d", len(providers), len(test.want))
			}
			for _, source := range Sources() {
				want, configured := test.want[source]
				if !configured {
					if len(providers[source]) != 0 {
						t.Fatalf("unexpected provider for %s", source)
					}
					continue
				}
				if len(providers[source]) != 1 {
					t.Fatalf("providers for %s = %d, want 1", source, len(providers[source]))
				}
				provider := providers[source][0]
				keyMatches := provider.APIKey == want.APIKey
				provider.APIKey, want.APIKey = "", ""
				if provider != want || !keyMatches {
					t.Fatalf("%s provider: metadataMatch=%v credentialMatch=%v", source, provider == want, keyMatches)
				}
			}
			if provider, ok := Pick(providers, Sources()); ok != (test.wantPick != "") || provider.Source != test.wantPick {
				t.Fatal("provider selection does not match the fixture")
			}
			if test.codexPath != "" {
				if got := configurationPath(testContext(t), kernel, "codex", home, environment); got != filepath.Join(home, test.codexPath) {
					t.Fatal("configuration path does not match the fixture")
				}
			}
		})
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
