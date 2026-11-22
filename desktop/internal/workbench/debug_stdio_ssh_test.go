//go:build lithe_remote_e2e && (darwin || windows)

package workbench

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

func TestRemoteStdioDebugAdapterMapsWorkspaceBreakpointsOverSSH(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux OpenSSH target")
	}
	client := core.NewClient()
	connection, connected := connectVariantSSH(t, client, host)
	arch := linuxSSHFixtureArch(t, connected)
	platform := connected.Host.PluginPlatform()
	fixture := buildLinuxSSHFixtureFor(t, "stdio-adapter", "./testdata/remote_debug_adapter", arch)
	manifest := strings.Replace(debugFixtureManifest, `{"kind": "packaged", "path": "adapter"}`, `{"kind": "systemCommand", "commands": ["sh"]}`, 1)
	manifest = strings.Replace(manifest, `["-test.run=^TestDebugAdapterRunner$"]`, `["-c", "exec ./stdio-adapter"]`, 1)
	const pluginID = "dev.lithe.test.debug-adapter"
	options := debugPluginOptions(t, pluginID, manifest, false, client, "dark")
	options.Kernel = &testKernel{Client: client}
	h := newHarnessWithOptions(t, options)

	const directoryID = "debug-stdio"
	sessionID := connected.Session.ID
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var directory struct{ Path string }
	if err := client.RemoteHostRequest(ctx, sessionID, "fs.createRunDirectory", map[string]string{"directoryId": directoryID}, &directory); err != nil {
		t.Fatalf("create remote fixture directory: %v", err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := client.RemoteHostRequest(cleanup, sessionID, "fs.releaseRunDirectory", map[string]string{"directoryId": directoryID}, nil); err != nil && !remoteConnectionClosed(err) {
			t.Errorf("release remote fixture directory: %v", err)
		}
	})
	for _, name := range []string{"source.txt", "other.txt"} {
		if _, saved, err := client.RemoteWriteFile(ctx, sessionID, path.Join(directory.Path, name), []byte("one\ntwo\nthree\n"), nil); err != nil || !saved {
			t.Fatalf("write remote %s: saved=%v, err=%v", name, saved, err)
		}
	}
	anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
	if err := remoteplaceholder.Ensure(anchor); err != nil {
		t.Fatal(err)
	}
	const connectionID = "debug-stdio-ssh"
	root := remoteplaceholder.Root(anchor, connectionID, directory.Path)
	h.app.openRemoteProject(remoteTarget{
		connectionID: connectionID, name: "Stdio adapter SSH test", host: connection,
		session: *connected.Session, platform: platform, remoteRoot: directory.Path, root: root, trusted: true,
	})
	p := h.app.project
	if p == nil || p.remote == nil {
		t.Fatal("the SSH project did not open")
	}
	attachment := p.remote.binding.CaptureConnection()
	if attachment == nil {
		t.Fatal("the SSH project has no active connection")
	}
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if err := client.UploadRemotePluginFile(attachment.Context(ctx), fixture, path.Join(directory.Path, "stdio-adapter"), fmt.Sprintf("%x", sha256.Sum256(data)), 0o500); err != nil {
		t.Fatalf("upload remote adapter: %v", err)
	}
	source, other := filepath.Join(root, "source.txt"), filepath.Join(root, "other.txt")
	openSource(t, h, p, source)
	h.app.chooseTitleConfiguration(p, "")
	h.app.toggleBreakpointAt(p, source, 3)
	h.click(center(h.button(itemTitleDebug)))
	awaitStateWithin(t, h, 20*time.Second, "a stopped event and stack trace over stdio", func() bool {
		if notice := lastNotice(h); notice == i18n.Shared(h.app.language(), "desktop.remote.workspace.localOnly") {
			t.Fatalf("toolbar Debug rejected the remote workspace: %s", notice)
		}
		if p.debug.failure != "" {
			t.Fatalf("remote stdio adapter failed: %s\noutput: %q", p.debug.failure, p.debug.output)
		}
		return p.debug.state == "paused" && len(p.debug.frames) > 0
	})
	if frame := p.debug.frames[0]; frame.Name != "fixture-linux" || frame.SourcePath != source || frame.Line != 3 {
		t.Fatalf("stack frame = %+v, want the remote adapter's mapped source and line", frame)
	}
	h.app.openFileAt(p, other, 1)
	awaitStateWithin(t, h, 10*time.Second, "the remote editor and thread picker", func() bool {
		doc := p.selectedDocument(p.docs.group)
		return doc != nil && doc.path == other && len(p.debug.threads) > 0
	})
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	point := center(h.pageHit("fixture-linux").Bounds)
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 10*time.Second, "the selected remote stack frame to open the source", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("remote stdio adapter failed while opening the stack frame: %s", p.debug.failure)
		}
		doc := p.selectedDocument(p.docs.group)
		return doc != nil && doc.path == source
	})
	if line, column := p.selectedDocument(p.docs.group).view.Caret(); line != 2 || column != 0 {
		t.Fatalf("source opened at line %d, column %d; want line 3, column 1", line+1, column+1)
	}
	session := p.debug.activeSession()
	h.app.stopDebugByUser(p)
	awaitValueWithin(t, h, 10*time.Second, session.cleanupDone, "the stdio adapter process to exit")
	if session.cleanupErr != nil || p.debug.activeSession() != nil {
		t.Fatalf("the stdio adapter did not stop cleanly: %v", session.cleanupErr)
	}
	check, cancelCheck := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelCheck()
	if forwards, err := client.RemoteForwards(check, sessionID); err != nil || len(forwards) != 0 {
		t.Fatalf("stdio adapter used a port forward: forwards=%+v, err=%v", forwards, err)
	}
}
