package ai

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestConfigurationSourcesUsesCorePaths(t *testing.T) {
	home := t.TempDir()
	files, err := testClient().ConfigurationSources(testContext(t), "codex", home, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0].File != "config" || files[1].File != "auth" {
		t.Fatalf("codex files = %#v", files)
	}
	if files[0].Path != filepath.Join(home, ".codex", "config.toml") || files[1].Path != filepath.Join(home, ".codex", "auth.json") {
		t.Fatalf("codex paths = %#v", files)
	}

	override := t.TempDir()
	files, err = testClient().ConfigurationSources(testContext(t), "codex", home, map[string]string{"CODEX_HOME": override})
	if err != nil {
		t.Fatal(err)
	}
	if files[0].Path != filepath.Join(override, "config.toml") {
		t.Fatalf("CODEX_HOME path = %q", files[0].Path)
	}

	files, err = testClient().ConfigurationSources(testContext(t), "claude", home, map[string]string{"CLAUDE_CONFIG_DIR": override})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 3 || files[0].Path != filepath.Join(override, "settings.json") ||
		files[1].Path != filepath.Join(override, ".credentials.json") ||
		files[2].Path != filepath.Join(home, ".claude.json") {
		t.Fatalf("claude files = %#v", files)
	}
}

func TestConfigurationParseReturnsMetadataAndLocatorOnly(t *testing.T) {
	const secret = "fixture-secret-key"
	client := testClient()
	configuration, err := client.ParseConfiguration(testContext(t), ConfigurationParseRequest{
		Source: "codex",
		Files: map[string]string{
			"config": "model = 'fixture-model'\nmodel_provider = 'gateway'\n[model_providers.gateway]\nbase_url = 'https://example.test/v1'\nrequires_openai_auth = true\n",
			"auth":   `{"OPENAI_API_KEY":"` + secret + `"}`,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if configuration == nil || configuration.Provider == nil {
		t.Fatalf("configuration = %#v", configuration)
	}
	if configuration.Model != "fixture-model" || configuration.Provider.Endpoint != "https://example.test/v1" ||
		configuration.Provider.APIProtocol != "responses" || !configuration.HasCredential {
		t.Fatalf("configuration = %#v", configuration)
	}
	if configuration.Credential == nil || configuration.Credential.Kind != "file" || configuration.Credential.File != "auth" ||
		strings.Join(configuration.Credential.Path, ".") != "OPENAI_API_KEY" {
		t.Fatalf("credential locator = %#v", configuration.Credential)
	}
	encoded, err := json.Marshal(configuration)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatal("parse result contains the credential value")
	}

	configuration, err = client.ParseConfiguration(testContext(t), ConfigurationParseRequest{
		Source: "claude",
		Files: map[string]string{
			"settings": `{"env":{"ANTHROPIC_BASE_URL":"https://example.test/v1","ANTHROPIC_API_KEY":"` + secret + `"}}`,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if configuration == nil || configuration.Provider == nil || configuration.Provider.APIProtocol != "anthropicMessages" {
		t.Fatalf("claude configuration = %#v", configuration)
	}
	if configuration.Credential == nil || configuration.Credential.File != "settings" {
		t.Fatalf("claude credential locator = %#v", configuration.Credential)
	}
}

func TestConfigurationParseReportsNothingConfigured(t *testing.T) {
	configuration, err := testClient().ParseConfiguration(testContext(t), ConfigurationParseRequest{
		Source: "codex",
		Files:  map[string]string{"config": " \n"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if configuration != nil {
		t.Fatalf("configuration = %#v, want nil", configuration)
	}
}

func TestConfigurationRejectsUnknownSource(t *testing.T) {
	_, err := testClient().ParseConfiguration(testContext(t), ConfigurationParseRequest{Source: "unknown"})
	requireCode(t, err, core.CodeInvalidRequest)
}

func TestConfigurationParseMatchesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("ai/cli-configuration-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		SecretMarker string `json:"secretMarker"`
		StrictCases  []struct {
			ID          string            `json:"id"`
			Source      string            `json:"source"`
			Files       map[string]string `json:"files"`
			Environment map[string]string `json:"environment"`
			Expected    json.RawMessage   `json:"expected"`
		} `json:"strictCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, test := range fixture.StrictCases {
		if test.Expected == nil {
			continue
		}
		configuration, err := testClient().ParseConfiguration(testContext(t), ConfigurationParseRequest{
			Source:      test.Source,
			Files:       test.Files,
			Environment: test.Environment,
		})
		if err != nil {
			t.Fatalf("%s: %v", test.ID, err)
		}
		var expected map[string]any
		if err := json.Unmarshal(test.Expected, &expected); err != nil {
			t.Fatalf("%s: expected: %v", test.ID, err)
		}
		if expected == nil {
			if configuration != nil {
				t.Fatalf("%s: configuration = %#v, want nil", test.ID, configuration)
			}
			continue
		}
		if configuration == nil {
			t.Fatalf("%s: configuration is nil", test.ID)
		}
		if _, present := expected["model"]; present {
			if got, want := configuration.Model, stringField(expected, "model"); got != want {
				t.Fatalf("%s: model = %q, want %q", test.ID, got, want)
			}
		}
		expectedProvider, providerPresent := expected["provider"]
		if providerPresent && expectedProvider == nil {
			if configuration.Provider != nil {
				t.Fatalf("%s: provider = %#v, want nil", test.ID, configuration.Provider)
			}
		} else if providerPresent {
			provider, _ := expectedProvider.(map[string]any)
			if configuration.Provider == nil {
				t.Fatalf("%s: provider is nil", test.ID)
			}
			if _, present := provider["endpoint"]; present {
				if got, want := configuration.Provider.Endpoint, stringField(provider, "endpoint"); got != want {
					t.Fatalf("%s: endpoint = %q, want %q", test.ID, got, want)
				}
			}
			if _, present := provider["apiProtocol"]; present {
				if got, want := configuration.Provider.APIProtocol, stringField(provider, "apiProtocol"); got != want {
					t.Fatalf("%s: apiProtocol = %q, want %q", test.ID, got, want)
				}
			}
		}
		if expectedHasCredential, present := expected["hasCredential"]; present {
			if got, want := configuration.HasCredential, expectedHasCredential == true; got != want {
				t.Fatalf("%s: hasCredential = %v, want %v", test.ID, got, want)
			}
		}
		expectedCredential, credentialPresent := expected["credential"]
		if credentialPresent && expectedCredential == nil {
			if configuration.Credential != nil {
				t.Fatalf("%s: credential = %#v, want nil", test.ID, configuration.Credential)
			}
		} else if credentialPresent {
			credential, _ := expectedCredential.(map[string]any)
			if configuration.Credential == nil || configuration.Credential.Kind != stringField(credential, "kind") {
				t.Fatalf("%s: credential = %#v, want kind %q", test.ID, configuration.Credential, stringField(credential, "kind"))
			}
		}
		encoded, err := json.Marshal(configuration)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(encoded), fixture.SecretMarker) {
			t.Fatalf("%s leaked the fixture secret", test.ID)
		}
	}
}

func stringField(value map[string]any, key string) string {
	text, _ := value[key].(string)
	return text
}
