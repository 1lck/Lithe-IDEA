package ai

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// testDeadline bounds every wait in these tests, so a stuck kernel call fails the test with a
// diagnostic instead of waiting for the test binary's global timeout.
const testDeadline = 30 * time.Second

// testContext returns a context that ends after testDeadline and is released with the test.
func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), testDeadline)
	t.Cleanup(cancel)
	return ctx
}

// testClient is an AI client over the linked Core.
func testClient() *Client { return NewClient(core.NewClient()) }

// requireCode fails the test unless err is a Core error with the code want.
func requireCode(t *testing.T, err error, want core.ErrorCode) {
	t.Helper()
	var coreErr *core.Error
	if !errors.As(err, &coreErr) {
		t.Fatalf("error = %v (%T), want *core.Error with code %q", err, err, want)
	}
	if coreErr.Code != want {
		t.Fatalf("error code = %q, want %q (error: %v)", coreErr.Code, want, coreErr)
	}
}

// readCoreFixtureJSON decodes a fixture under rust/fixtures of the linked Core checkout.
func readCoreFixtureJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture(path))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, value); err != nil {
		t.Fatal(err)
	}
}
