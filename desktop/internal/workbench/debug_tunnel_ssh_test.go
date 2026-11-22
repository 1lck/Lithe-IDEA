//go:build lithe_remote_e2e && (darwin || windows)

package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// The copied adapter must receive the challenge response from the Linux host
// before it reports a successful attach and a stopped thread.
func TestSSHTunnelDebugAdapterRunner(t *testing.T) {
	if len(os.Args) == 0 || os.Args[len(os.Args)-1] != "lithe-ssh-tunnel-adapter" {
		t.Skip("only the SSH attach fixture runs this adapter")
	}
	os.Exit(serveFixtureAdapterWithAttach(os.Stdin, os.Stdout, ".", func(raw json.RawMessage) error {
		var endpoint struct {
			Host string `json:"hostName"`
			Port int    `json:"port"`
		}
		if err := json.Unmarshal(raw, &endpoint); err != nil {
			return err
		}
		if endpoint.Host != "127.0.0.1" || endpoint.Port < 1 {
			return fmt.Errorf("unexpected forwarded endpoint: %s:%d", endpoint.Host, endpoint.Port)
		}
		address := net.JoinHostPort(endpoint.Host, strconv.Itoa(endpoint.Port))
		conn, err := net.DialTimeout("tcp", address, 5*time.Second)
		if err != nil {
			return err
		}
		defer conn.Close()
		if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return err
		}
		if _, err := io.WriteString(conn, "lithe"); err != nil {
			return err
		}
		response := make([]byte, len("linux"))
		if _, err := io.ReadFull(conn, response); err != nil {
			return err
		}
		if string(response) != "linux" {
			return fmt.Errorf("unexpected remote response %q", response)
		}
		return nil
	}))
}

func TestLocalDebugAdapterAttachesThroughSSHWorkspaceTunnel(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux OpenSSH target")
	}
	const pluginID = "dev.lithe.test.debug-attach"
	manifest := strings.Replace(debugAttachManifest, `"process": {"launch":`, `"process": {"placement": "ui", "launch":`, 1)
	manifest = strings.Replace(manifest, `"-test.run=^TestDebugAdapterRunner$"`, `"-test.run=^TestSSHTunnelDebugAdapterRunner$", "--", "lithe-ssh-tunnel-adapter"`, 1)
	client := core.NewClient()
	connection, connected := connectVariantSSH(t, client, host)
	arch := linuxSSHFixtureArch(t, connected)
	fixture := buildLinuxSSHFixtureFor(t, "debuggee", "./testdata/remote_debuggee", arch)
	options := debugPluginOptions(t, pluginID, manifest, true, client, "dark")
	options.Kernel = &testKernel{Client: client}
	h := newHarnessWithOptions(t, options)
	sessionID := connected.Session.ID
	const directoryID = "debug-tunnel"
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	var directory struct {
		Path string `json:"path"`
	}
	err := client.RemoteHostRequest(ctx, sessionID, "fs.createRunDirectory", map[string]string{"directoryId": directoryID}, &directory)
	cancel()
	if err == nil {
		t.Cleanup(func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := client.RemoteHostRequest(ctx, sessionID, "fs.releaseRunDirectory", map[string]string{"directoryId": directoryID}, nil); err != nil {
				t.Errorf("release remote fixture directory: %v", err)
			}
		})
	}
	if err != nil || !path.IsAbs(directory.Path) {
		t.Fatalf("create remote fixture directory: path=%q, err=%v", directory.Path, err)
	}
	anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
	if err := remoteplaceholder.Ensure(anchor); err != nil {
		t.Fatal(err)
	}
	const connectionID = "debug-tunnel-ssh"
	root := remoteplaceholder.Root(anchor, connectionID, directory.Path)
	h.app.openRemoteProject(remoteTarget{
		connectionID: connectionID, name: "Debug tunnel SSH test", host: connection,
		session: *connected.Session, platform: connected.Host.PluginPlatform(), remoteRoot: directory.Path, root: root, trusted: true,
	})
	p := h.app.project
	if p == nil || p.remote == nil {
		t.Fatal("the SSH project did not open")
	}
	attachment := p.remote.binding.CaptureConnection()
	if attachment == nil {
		t.Fatal("the SSH project has no active connection")
	}
	remoteContext := attachment.Context(p.ctx)
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	remoteFixture := path.Join(directory.Path, "debuggee")
	ctx, cancel = context.WithTimeout(remoteContext, 20*time.Second)
	err = client.UploadRemotePluginFile(ctx, fixture, remoteFixture, fmt.Sprintf("%x", sha256.Sum256(data)), 0o500)
	cancel()
	if err != nil {
		t.Fatalf("upload remote debuggee: %v", err)
	}
	remotePort, exit := startSSHTunnelDebuggee(t, client, remoteContext, directory.Path, remoteFixture)
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	awaitStateWithin(t, h, 10*time.Second, "the attach adapter", func() bool { return len(p.debug.adapters) == 1 })
	h.app.debugAttach.host.SetText("127.0.0.1")
	h.app.debugAttach.port.SetText(strconv.Itoa(remotePort))
	h.app.startDebug(p)
	awaitRemotePrompt(t, h, p)
	if len(gate.configurations) != 0 || p.debug.activeSession() != nil {
		t.Fatal("the adapter started before approval")
	}
	ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
	forwards, err := client.RemoteForwards(ctx, sessionID)
	cancel()
	if err != nil || len(forwards) != 0 {
		t.Fatalf("before approval got forwards %+v, err=%v", forwards, err)
	}
	h.clickNamed(h.app.text.Debug.RemoteAttach)
	configuration := awaitValueWithin(t, h, 20*time.Second, gate.configurations, "the forwarded attach")
	ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
	forwards, err = client.RemoteForwards(ctx, sessionID)
	cancel()
	if err != nil || len(forwards) != 1 {
		t.Fatalf("after approval got forwards %+v, err=%v", forwards, err)
	}
	forward := forwards[0]
	if int(forward.TargetPort) != remotePort || configuration.Request != "attach" ||
		configuration.Arguments["hostName"] != forward.LocalHost || !sameDebugPort(configuration.Arguments["port"], int(forward.LocalPort)) {
		t.Fatalf("attach configuration %+v does not use the forward %+v", configuration, forward)
	}
	awaitStateWithin(t, h, 15*time.Second, "the adapter to receive the remote response", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("attach failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused"
	})
	if err := awaitValueWithin(t, h, 5*time.Second, exit, "the remote debuggee to verify its challenge"); err != nil {
		t.Fatalf("debuggee: %v", err)
	}
	session := p.debug.activeSession()
	if session == nil {
		t.Fatal("the paused adapter has no active session")
	}
	h.app.stopDebugByUser(p)
	awaitValueWithin(t, h, 15*time.Second, session.cleanupDone, "the attached session to release its resources")
	if session.cleanupErr != nil || p.debug.activeSession() != nil {
		t.Fatalf("debug session remained active or failed to clean up: %v", session.cleanupErr)
	}
	ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
	forwards, err = client.RemoteForwards(ctx, sessionID)
	cancel()
	if err != nil || len(forwards) != 0 {
		t.Fatalf("after Stop got forwards %+v, err=%v", forwards, err)
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(forward.LocalHost, strconv.Itoa(int(forward.LocalPort))))
	if err != nil {
		t.Fatalf("Stop did not release the local port: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestProviderServiceDebugAttachesOverSSHFromRunConfigurationAndBuild(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux OpenSSH target")
	}
	const adapterID = "dev.lithe.test.registry-attach"
	adapter := strings.Replace(registryAttachManifest(adapterID), `"process": {"launch":`, `"process": {"placement": "ui", "launch":`, 1)
	adapter = strings.Replace(adapter, `"-test.run=^TestDebugAdapterRunner$"`, `"-test.run=^TestSSHTunnelDebugAdapterRunner$", "--", "lithe-ssh-tunnel-adapter"`, 1)
	provider := strings.NewReplacer(
		`"command": "fixture-tool"`, `"command": "sh"`,
		`{"kind": "packaged", "path": "provider"}`, `{"kind": "systemCommand", "commands": ["sh"]}`,
		`"-test.run=^TestProviderTestRunner$"`, `"-c", "exec ./debuggee provider"`,
	).Replace(providerServiceDebugManifest)
	client := core.NewClient()
	connection, connected := connectVariantSSH(t, client, host)
	arch := linuxSSHFixtureArch(t, connected)
	fixture := buildLinuxSSHFixtureFor(t, "debuggee", "./testdata/remote_debuggee", arch)

	sessionID := connected.Session.ID
	const directoryID = "debug-provider"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var directory struct{ Path string }
	if err := client.RemoteHostRequest(ctx, sessionID, "fs.createRunDirectory", map[string]string{"directoryId": directoryID}, &directory); err != nil {
		t.Fatalf("create the provider's remote workspace: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := client.RemoteHostRequest(ctx, sessionID, "fs.releaseRunDirectory", map[string]string{"directoryId": directoryID}, nil); err != nil {
			t.Errorf("release the provider's remote workspace: %v", err)
		}
	})
	anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
	if err := remoteplaceholder.Ensure(anchor); err != nil {
		t.Fatal(err)
	}
	root := remoteplaceholder.Root(anchor, directoryID, directory.Path)
	remoteFixture := path.Join(directory.Path, "debuggee")
	if _, saved, err := client.RemoteWriteFile(ctx, sessionID, path.Join(directory.Path, "fixture.marker"), []byte("fixture\n"), nil); err != nil || !saved {
		t.Fatalf("write the build marker: saved=%v, err=%v", saved, err)
	}
	binding := core.NewRemoteWorkspace(root, directory.Path, nil)
	binding.Attach(sessionID)
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if err := client.UploadRemotePluginFile(binding.CaptureConnection().Context(ctx), fixture, remoteFixture, fmt.Sprintf("%x", sha256.Sum256(data)), 0o500); err != nil {
		t.Fatalf("upload the provider and service executable: %v", err)
	}
	h := connectionDebugHarnessWithProvider(t, provider, map[string]string{adapterID: adapter})
	h.app.openRemoteProject(remoteTarget{
		connectionID: directoryID, name: "Provider debug SSH test", host: connection,
		session: *connected.Session, platform: connected.Host.PluginPlatform(), remoteRoot: directory.Path, root: root, trusted: true,
	})
	p := h.app.project
	if p == nil || p.remote == nil {
		t.Fatal("the provider's remote workspace did not open")
	}
	if p.remote.binding.CaptureConnection() == nil {
		t.Fatal("the provider's remote workspace has no connection")
	}
	h.app.post(func(a *App) { a.loadTitleRunConfigs(p) })
	awaitStateWithin(t, h, 20*time.Second, "the remote provider model and service configuration", func() bool {
		instance := p.selectedBuildInstance()
		return instance != nil && instance.modelLoaded && len(instance.Model.Targets) == 1 &&
			p.runConfigsSettled() && len(p.runConfigs.list) == 1
	})
	configurationID := p.runConfigs.list[0].ID
	targetID := p.selectedBuildInstance().Model.Targets[0].ID
	for _, entry := range []string{"run configuration", "build target"} {
		t.Run(entry, func(t *testing.T) {
			t.Cleanup(func() {
				if !t.Failed() {
					return
				}
				output := ""
				if runs := p.build.runs; len(runs) > 0 {
					output = runs[len(runs)-1].output.all()
				}
				t.Logf("notice %q, build status %q, debug state %q, run console:\n%s", lastNotice(h), p.build.status, p.debug.state, output)
			})
			h.app.post(func(a *App) {
				if entry == "run configuration" {
					a.chooseTitleConfiguration(p, configurationID)
					a.titleDebug(p)
					return
				}
				a.debugBuildTarget(p, targetID, "service")
			})
			awaitStateWithin(t, h, 25*time.Second, "the debugger's first handshake with the provider-owned service", func() bool {
				if p.debug.failure != "" {
					t.Fatalf("provider debug failed: %s", p.debug.failure)
				}
				return p.debug.state == "paused"
			})
			session := p.debug.activeSession()
			if session == nil || session.adapter.PluginID != adapterID || !p.build.active() {
				t.Fatalf("the selected adapter did not own the service: session=%v, active=%v", session != nil, p.build.active())
			}
			process, ok := p.build.latest().process.(*buildprocess.RemoteProcess)
			if !ok || process.ID == 0 {
				t.Fatal("the service run did not track its remote process")
			}
			check, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			forwards, err := client.RemoteForwards(check, sessionID)
			cancel()
			if err != nil || len(forwards) != 1 || forwards[0].TargetPort < 1 {
				t.Fatalf("provider attach must have one loopback tunnel: forwards=%+v, err=%v", forwards, err)
			}
			serviceIsRunning := func() bool {
				check, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				programs, err := client.RemoteRunningPrograms(check, sessionID)
				if err != nil {
					t.Fatal(err)
				}
				return slices.ContainsFunc(programs, func(program core.RemoteProgram) bool {
					return program.Kind == core.RemoteProgramProcess && program.ID == process.ID
				})
			}
			if !serviceIsRunning() {
				t.Fatal("the remote session did not list the provider's running service")
			}
			h.app.stopDebugByUser(p)
			awaitValueWithin(t, h, 15*time.Second, session.cleanupDone, "the debugger and tunnel to stop")
			awaitStateWithin(t, h, 15*time.Second, "the provider-owned service to exit", func() bool { return !p.build.active() })
			if session.cleanupErr != nil {
				t.Fatal(session.cleanupErr)
			}
			check, cancel = context.WithTimeout(context.Background(), 10*time.Second)
			forwards, err = client.RemoteForwards(check, sessionID)
			cancel()
			if err != nil || len(forwards) != 0 {
				t.Fatalf("provider stop left forwards: %+v, err=%v", forwards, err)
			}
			if serviceIsRunning() {
				t.Fatal("the provider's debuggee remained active after Stop")
			}
		})
	}
}

func startSSHTunnelDebuggee(t *testing.T, client *core.Client, lifetime context.Context, root, executable string) (int, <-chan error) {
	t.Helper()
	ready := make(chan string, 1)
	var stdout strings.Builder
	ctx, cancel := context.WithTimeout(lifetime, 10*time.Second)
	defer cancel()
	process, err := buildprocess.StartRemote(ctx, lifetime, client, core.RemoteProcessOpen{
		Argv: []string{executable}, Environment: "login",
		ScopedCwd: &core.RemoteScopedDirectory{Root: root},
	}, func(stream buildprocess.Stream, chunk string) {
		if stream == "stdout" {
			stdout.WriteString(chunk)
			if line, _, found := strings.Cut(stdout.String(), "\n"); found {
				select {
				case ready <- line:
				default:
				}
			}
		}
	})
	if err != nil {
		t.Fatalf("start remote debuggee: %v", err)
	}
	exit := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		exit <- process.Wait()
	}()
	t.Cleanup(func() {
		process.Stop()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("remote debuggee stayed active after cancellation")
		}
	})
	select {
	case line := <-ready:
		port, err := strconv.Atoi(line)
		if err != nil || port < 1 || port > 65535 {
			t.Fatalf("invalid remote debug port %q", line)
		}
		return port, exit
	case err := <-exit:
		t.Fatalf("remote debuggee exited before listening: %v", err)
	case <-ctx.Done():
		t.Fatalf("wait for remote debuggee to listen: %v", ctx.Err())
	}
	return 0, nil
}
