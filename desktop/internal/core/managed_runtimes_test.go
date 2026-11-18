package core

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestManagedRuntimesBridgeUsesSharedContract(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/managed-runtimes.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest          json.RawMessage `json:"manifest"`
		Resolution        json.RawMessage `json:"resolution"`
		WindowsResolution json.RawMessage `json:"windowsResolution"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := NewClient()
	for _, os := range []string{"linux", "windows"} {
		t.Run(os, func(t *testing.T) {
			platform := ManagedRuntimePlatform{OS: os, Arch: "x86_64"}
			plan, err := client.PlanManagedRuntimes(ctx, fixture.Manifest, platform)
			if err != nil || plan.Resolve == nil || len(plan.Dependencies) != 2 {
				t.Fatalf("plan=%+v error=%v", plan, err)
			}
			for _, dependency := range plan.Dependencies {
				if dependency.OS != os || len(dependency.CacheKey) != 64 || dependency.SHA256 == "" {
					t.Fatalf("incomplete native download plan: %+v", dependency)
				}
			}
			answer := fixture.Resolution
			if os == "windows" {
				answer = fixture.WindowsResolution
			}
			resolution, err := client.DecodeManagedRuntimeResolution(ctx, fixture.Manifest, platform, answer)
			if err != nil || len(resolution.Runtimes) != 1 || len(resolution.Missing) != 1 || resolution.Missing[0] != "server" {
				t.Fatalf("resolution=%+v error=%v", resolution, err)
			}
			if _, err := client.DecodeManagedRuntimeResolution(ctx, fixture.Manifest, platform, json.RawMessage(`{"runtimes":[],"missing":[]}`)); err == nil {
				t.Fatal("an incomplete answer crossed the native boundary")
			}
		})
	}
}
