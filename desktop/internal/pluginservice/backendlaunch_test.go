package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestLanguageLaunchReceivesSelectedInstallations(t *testing.T) {
	home := "/selected/sdk"
	service := &Service{LanguageTool: func(_ context.Context, root, tool string) (*core.ToolchainSelection, error) {
		if root != "/workspace" {
			t.Fatalf("wrong workspace: %s", root)
		}
		switch tool {
		case "compiler":
			return &core.ToolchainSelection{Executable: home + "/bin/compiler", Home: &home, Version: "8", Environment: map[string]string{"SECRET": "not forwarded"}}, nil
		case "project-script":
			return &core.ToolchainSelection{Executable: "/workspace/wrapper", ProjectCode: true}, nil
		default:
			return nil, nil
		}
	}}
	result, err := service.languageLaunchParams(context.Background(), "/workspace",
		json.RawMessage(`{"requiresTools":["compiler","missing","project-script"]}`), json.RawMessage(`{"serverID":"example","settings":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]json.RawMessage
	if err := json.Unmarshal(result, &value); err != nil {
		t.Fatal(err)
	}
	if string(value["serverID"]) != `"example"` || string(value["tools"]) != `{"compiler":{"executable":"/selected/sdk/bin/compiler","home":"/selected/sdk","version":"8"}}` {
		t.Fatalf("launch facts: %s", result)
	}
}

func TestLanguageLaunchPropagatesToolReadFailure(t *testing.T) {
	want := errors.New("permission denied")
	service := &Service{LanguageTool: func(context.Context, string, string) (*core.ToolchainSelection, error) { return nil, want }}
	_, err := service.languageLaunchParams(context.Background(), "/workspace", json.RawMessage(`{"requiresTools":["compiler"]}`), json.RawMessage(`{}`))
	if !errors.Is(err, want) {
		t.Fatalf("lost read failure: %v", err)
	}
}

func TestLanguageLaunchKeepsParamsWithoutOptionalTools(t *testing.T) {
	service := &Service{LanguageTool: func(context.Context, string, string) (*core.ToolchainSelection, error) { return nil, nil }}
	params := json.RawMessage(`{"settings": {"user": true}}`)
	result, err := service.languageLaunchParams(context.Background(), "/workspace", json.RawMessage(`{"requiresTools":["missing"]}`), params)
	if err != nil || string(result) != string(params) {
		t.Fatalf("changed unconfigured launch: %s %v", result, err)
	}
}
