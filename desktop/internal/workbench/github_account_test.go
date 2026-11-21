package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A packaged build is launched without LITHE_GITHUB_CLIENT_ID, so sign-in must not depend on it:
// the Viva client used to read the OAuth client only from that variable and showed every user
// "GitHub sign-in is not configured for this build" on the Git settings page.
func TestGitHubSignInIsAvailableWithoutClientIDVariable(t *testing.T) {
	t.Setenv("LITHE_GITHUB_CLIENT_ID", "")
	if got := githubClientID(); got == "" {
		t.Fatal("githubClientID() is empty without LITHE_GITHUB_CLIENT_ID; the product's OAuth client must be built in")
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if snapshot := h.app.githubAccountSnapshot(); !snapshot.available {
		t.Fatalf("the Git settings page reports GitHub sign-in unavailable with a kernel that plans GitHub requests: %+v", snapshot)
	}
}

// LITHE_GITHUB_CLIENT_ID still replaces the built-in client, for a fork's or a development OAuth app.
func TestGitHubClientIDVariableReplacesBuiltInClient(t *testing.T) {
	t.Setenv("LITHE_GITHUB_CLIENT_ID", "  dev-client  ")
	if got := githubClientID(); got != "dev-client" {
		t.Fatalf("githubClientID() = %q, want the trimmed variable %q", got, "dev-client")
	}
}
