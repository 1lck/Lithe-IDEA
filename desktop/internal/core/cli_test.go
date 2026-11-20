package core

import (
	"context"
	"encoding/json"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestCLISharedFixture(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile(contractfixture.CoreFixture("application/cli-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Launch []struct {
			Args   []string
			Action string
			Detach bool
		}
		Targets []struct {
			Kind, Mode string
			Plugins    bool
			Commands   []string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range fixture.Launch {
		plan, err := client.PlanCLILaunch(ctx, test.Args)
		if err != nil || plan.Action != test.Action || plan.Detach != test.Detach {
			t.Fatalf("launch %+v: %+v %v", test, plan, err)
		}
	}
	for _, test := range fixture.Targets {
		target, err := client.CLIOpenTarget(ctx, test.Kind)
		if err != nil || target.Mode != test.Mode || target.Plugins != test.Plugins {
			t.Fatalf("target %+v: %+v %v", test, target, err)
		}
		for _, command := range test.Commands {
			if !slices.Contains(target.Commands, command) {
				t.Fatalf("target %s does not permit %s", test.Kind, command)
			}
		}
	}
}
