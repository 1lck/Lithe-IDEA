package core

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemotePluginUploadRequiresAndDispatchesToCapturedAttachment(t *testing.T) {
	ctx := testContext(t)
	client := NewClient()
	var lost []string
	workspace := NewRemoteWorkspace(t.TempDir(), "/srv/repo", func(id string) { lost = append(lost, id) })
	t.Cleanup(func() { workspace.Detach() })
	workspace.Attach("missing-plugin-upload-session")
	previous := workspace.CaptureConnection()
	workspace.Attach("missing-plugin-upload-session")
	current := workspace.CaptureConnection()
	source := filepath.Join(t.TempDir(), "server")
	writeFile(t, source, "fixture")
	target := "/private/staging/server"
	digest := strings.Repeat("a", 64)

	for _, rejected := range []struct {
		name string
		ctx  context.Context
	}{
		{"local", ctx},
		{"following reconnections", WithRemoteWorkspace(ctx, workspace)},
		{"replaced attachment with the same session ID", previous.Context(ctx)},
	} {
		t.Run(rejected.name, func(t *testing.T) {
			requireCode(t, client.UploadRemotePluginFile(rejected.ctx, "relative", target, digest, 0o500), CodeConnectionClosed)
			if !current.IsCurrent() || len(lost) != 0 {
				t.Fatalf("refused upload affected the current attachment, reported loss %v", lost)
			}
		})
	}

	// Core validates the source path before it looks up the session. Its
	// validation error proves an upload on the captured attachment was sent.
	requireCode(t, client.UploadRemotePluginFile(current.Context(ctx), "relative", target, digest, 0o500), CodeInvalidRequest)
	if !current.IsCurrent() || len(lost) != 0 {
		t.Fatalf("invalid source affected the current attachment, reported loss %v", lost)
	}
	requireCode(t, client.UploadRemotePluginFile(current.Context(ctx), source, target, digest, 0o500), CodeConnectionClosed)
	if current.IsCurrent() || len(lost) != 1 || lost[0] != "missing-plugin-upload-session" {
		t.Fatalf("missing Core session: attachment current = %v, reported loss %v", current.IsCurrent(), lost)
	}
}
