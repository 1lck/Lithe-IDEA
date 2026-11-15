package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestToolchainPinSourcesMatchSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("toolchain-pin-storage.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name, Command string
			Input         json.RawMessage
			Expected      any
			Error         string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var result map[string]any
			if err := NewClient().Execute(ctx, c.Command, c.Input, &result); err != nil {
				t.Fatal(err)
			}
			if c.Error != "" {
				failure, ok := result["error"].(map[string]any)
				if result["status"] != "rejected" || !ok || failure["code"] != c.Error {
					t.Fatalf("outcome = %#v", result)
				}
			} else if !reflect.DeepEqual(result, c.Expected) {
				t.Fatalf("outcome = %#v, want %#v", result, c.Expected)
			}
		})
	}
}
