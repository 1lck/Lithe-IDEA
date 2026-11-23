//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteConnections captures the Remote Development window: the first page with nothing
// saved, saved connections under their groups with the tested one's overview, its form, a new
// connection whose host Core refused under its field, OpenSSH's password question over the window
// with its Remember box, a refused test, the connection steps with OpenSSH's questions on the page
// (a remembered password the host refused among them) and a failure, the
// question whether to trust a folder, Motty's hosts to import, the host's folders and its running
// containers, a WSL
// distribution's page and a failed connection to one, a container's page and a failed connection
// to one, and a folder opening in its dev container, before and while it builds.
func TestVisualRemoteConnections(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	const gib = uint64(1) << 30
	probed := core.RemoteProbeResult{
		Status: core.RemoteProbeConnected,
		Host: &core.RemoteProbedHost{
			System: "Linux", Machine: "x86_64", HomeDirectory: "/home/dev", ServerTarget: "x86_64-unknown-linux-musl",
			Details: core.RemoteHostDetails{
				HostName: "build", OperatingSystem: "Ubuntu 24.04.1 LTS", Kernel: "6.8.0-49-generic",
				CPUCount: 16, MemoryBytes: 64 * gib, DiskTotalBytes: 512 * gib, DiskAvailableBytes: 301 * gib,
			},
		},
	}
	for _, look := range []struct{ theme, language, suffix string }{
		{"light", "en-US", "light-en-US"},
		{"dark", "zh-Hans", "dark-zh-CN"},
	} {
		t.Run(look.suffix, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			kernel := &remoteProbeKernel{testKernel: &testKernel{Client: core.NewClient()}, result: probed}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			shot := func(scene string) {
				t.Helper()
				// The scenes set the window's state directly, which does not ask for a frame.
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "remote-connections-"+scene+"-"+look.suffix+".png")); err != nil {
					t.Fatal(err)
				}
			}
			h.app.openRemote(surfaceMenu)
			h.settleChain()
			r := &h.app.remote
			// The counts come from this computer's Motty and ~/.ssh/config; the scenes show fixed
			// ones instead.
			r.imports = remoteImportCounts{loaded: true, motty: 4, sshConfig: 7}
			shot("empty")

			type saved struct {
				name, host, port, user, authentication, identityFile, proxyJump, group string
				color                                                                  core.RemoteConnectionColor
			}
			save := func(entry saved) {
				t.Helper()
				r.selectNew()
				r.form.name.SetText(entry.name)
				r.form.host.SetText(entry.host)
				r.form.port.SetText(entry.port)
				r.form.user.SetText(entry.user)
				r.form.authentication = entry.authentication
				r.form.identityFile.SetText(entry.identityFile)
				r.form.proxyJump.SetText(entry.proxyJump)
				r.form.color = entry.color
				r.form.group = remoteNewGroup
				r.form.newGroup.SetText(entry.group)
				h.app.saveRemote()
				h.settleChain()
				if r.err != "" || r.fieldErr.field != "" {
					t.Fatalf("saving %s: %q %+v", entry.name, r.err, r.fieldErr)
				}
			}
			save(saved{name: "Build box", host: "build.example", port: "2222", user: "dev", authentication: core.RemoteAuthenticationPrivateKey,
				identityFile: "/home/me/.ssh/id_ed25519", proxyJump: "bastion.example", group: "Production", color: core.RemoteConnectionRed})
			save(saved{name: "API gateway", host: "api.example", user: "deploy", authentication: core.RemoteAuthenticationAgent,
				group: "Production", color: core.RemoteConnectionOrange})
			save(saved{name: "Lab ARM", host: "lab-arm.internal", user: "dev", authentication: core.RemoteAuthenticationAgent,
				group: "Lab", color: core.RemoteConnectionGreen})
			save(saved{name: "Scratch VM", host: "10.0.4.17", authentication: core.RemoteAuthenticationAuto})
			buildBox := ""
			for _, entry := range r.source.Connections {
				if entry.Name == "Build box" {
					buildBox = entry.ID
				}
			}
			// What `ssh -G` resolves comes from this computer's SSH configuration; the scenes show
			// fixed values instead.
			jump := core.RemoteEffectiveText{Value: "bastion.example", Source: core.RemoteSettingFromConnection}
			for _, entry := range r.source.Connections {
				user := entry.Connection.User
				userSource := core.RemoteSettingFromConnection
				if user == "" {
					user, userSource = "dev", core.RemoteSettingDefault
				}
				port, portSource := uint32(entry.Connection.Port), core.RemoteSettingFromConnection
				if port == 0 {
					port, portSource = 22, core.RemoteSettingDefault
				}
				settings := core.RemoteEffectiveSettings{
					HostName:              core.RemoteEffectiveText{Value: entry.Connection.Host, Source: core.RemoteSettingFromConnection},
					Port:                  core.RemoteEffectiveNumber{Value: port, Source: portSource},
					User:                  core.RemoteEffectiveText{Value: user, Source: userSource},
					IdentityFiles:         core.RemoteEffectiveList{Value: []string{"~/.ssh/id_ed25519"}, Source: core.RemoteSettingFromSSHConfig},
					ConnectTimeoutSeconds: core.RemoteEffectiveNumber{Value: 10, Source: core.RemoteSettingFromSSHConfig},
					KeepAliveSeconds:      core.RemoteEffectiveNumber{Value: 30, Source: core.RemoteSettingDefault},
				}
				if entry.Name == "Build box" {
					settings.ProxyJump = &jump
				}
				if r.effective == nil {
					r.effective = map[core.SSHConnection]*remoteEffective{}
				}
				r.effective[remoteStored(entry.Connection)] = &remoteEffective{settings: settings}
			}
			r.selectEntry(buildBox)
			h.app.testRemote()
			h.settleChain()
			if r.result == nil {
				t.Fatal("the test did not report")
			}
			shot("overview")

			h.app.editSelectedRemote()
			r.form.advanced.Open = true
			shot("edit")

			h.app.newRemote()
			r.form.host.SetText("dev@build.example")
			r.form.color = core.RemoteConnectionPurple
			r.form.group = remoteNewGroup
			r.form.newGroup.SetText("Experiments")
			h.app.saveRemote()
			h.settleChain()
			if r.fieldErr.field != "host" {
				t.Fatalf("refusal = %+v, want the host", r.fieldErr)
			}
			shot("refused")

			r.selectEntry(buildBox)
			// A saved connection's password question offers to remember the answer.
			done := make(chan struct{})
			h.app.gitAuth.queue = append(h.app.gitAuth.queue, gitAuthQuestion{GitAuthChallenge: core.GitAuthChallenge{
				RequestID: "visual", Prompt: "dev@build.example's password: ", Secret: true, Attempt: 1, Remote: true,
				Kind: core.RemoteQuestionPassword, Done: done,
			}, answers: &remoteAnswers{owner: buildBox}, question: "visual"})
			shot("password")
			h.app.gitAuth.queue = nil
			close(done)

			refused := &remoteProbeOutcome{result: core.RemoteProbeResult{
				Status:      core.RemoteProbeAuthenticationFailed,
				Diagnostics: "dev@build.example: Permission denied (publickey,password).",
			}, at: h.app.now()}
			r.selectEntry(buildBox)
			h.app.editSelectedRemote()
			r.result = refused
			r.form.advanced.Open = false
			r.log.Open = true
			shot("test-failed")

			// A test that connects shows what the host is, with OpenSSH's output folded.
			connected := probed
			connected.Diagnostics = "debug1: Authentication succeeded (publickey)."
			r.result = &remoteProbeOutcome{result: connected, at: h.app.now()}
			r.log.Open = false
			shot("test-ok")

			// Connecting runs the steps on the page, with OpenSSH's questions under the step that
			// asks them.
			r.selectEntry(buildBox)
			steps := newRemoteSteps(*r.entry(buildBox), remoteHost{ssh: r.entry(buildBox).Connection}, "", h.app.now())
			r.steps = steps
			asked := make(chan struct{})
			h.app.gitAuth.queue = []gitAuthQuestion{{GitAuthChallenge: core.GitAuthChallenge{
				RequestID: "visual-key", Prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
				Remote: true, Kind: core.RemoteQuestionHostKey, KeyType: "ED25519",
				Fingerprint: "SHA256:7Yb0QaBf3c1uN0e9kVwq2XrJmZpT4sLhG8dEoUiAy6c", Attempt: 1, Done: asked,
			}}}
			shot("steps-host-key")
			steps.advance(h.app.now(), remoteStepAuthenticate)
			// The host refused the answer remembered last time, so the question is asked again with
			// Remember still ticked.
			h.app.gitAuth.queue = []gitAuthQuestion{{GitAuthChallenge: core.GitAuthChallenge{
				RequestID: "visual-password", Prompt: "dev@build.example's password: ", Secret: true, Remote: true, Attempt: 2,
				Kind: core.RemoteQuestionPassword, Done: asked,
			}, answers: &remoteAnswers{owner: buildBox}, question: "visual-password", remembered: true, refused: true}}
			shot("steps-password")
			h.app.gitAuth.queue = nil
			close(asked)
			steps.fail(h.app.now(), refused, h.app.language())
			r.log.Open = true
			shot("steps-failed")
			r.steps = nil

			// The first time a folder opens, the window asks whether to trust it.
			parent := "/home/dev"
			r.selectEntry(buildBox)
			r.trust = &remoteTrustPrompt{browser: &remoteBrowser{entryID: buildBox, name: "Build box", host: remoteHost{ssh: r.entry(buildBox).Connection}}, dir: "/home/dev/project", trust: remoteconn.Trust{
				State: core.RemoteWorkspaceTrustState{WorkspaceTrust: &core.RemoteWorkspaceTrustOf{
					State: core.WorkspaceTrustUnset, Workspace: "/home/dev/project", OfferedLocation: &parent,
				}},
			}}
			shot("trust")
			r.trust = nil

			r.importer = &remoteImporter{source: remoteImportMotty, keepGroups: true, keepColors: true,
				motty: core.RemoteMottyHosts{Database: "~/Library/Application Support/Motty/config.db", Format: "28", Groups: []string{"Production", "Staging", "Lab"},
					Candidates: []core.RemoteMottyCandidate{
						{Key: "1", Name: "Build box", Address: "dev@build.example:2222", System: "ubuntu", Color: core.RemoteConnectionRed, Group: "Production", Status: core.RemoteImportExists, ExistingID: buildBox},
						{Key: "2", Name: "Staging DB", Address: "postgres@db.staging.example", System: "debian", Color: core.RemoteConnectionBlue, Group: "Staging", Status: core.RemoteImportable},
						{Key: "3", Name: "GPU node", Address: "ml@gpu-07.lab.example", System: "ubuntu", Color: core.RemoteConnectionPurple, Group: "Lab", Status: core.RemoteImportPartial,
							Fields: []core.RemoteMottyField{
								{Motty: "label", Value: "GPU node", Lithe: "name"},
								{Motty: "address", Value: "gpu-07.lab.example", Lithe: "host"},
								{Motty: "user", Value: "ml", Lithe: "user"},
								{Motty: "ssh_options.identity_files", Value: "~/.ssh/lab_ed25519", Lithe: "identityFile"},
								{Motty: "ssh_options.server_alive_interval", Value: "30", Lithe: "keepAliveSeconds"},
								{Motty: "credential", Skip: core.RemoteMottySkipSecret},
								{Motty: "ssh_options.forward_agent", Value: "true", Skip: core.RemoteMottySkipNoSetting},
							}},
						{Key: "4", Name: "Router", Address: "admin@192.0.2.1", Group: "Lab", Status: core.RemoteImportUnsupported},
					}},
				mottyChosen: []bool{true, true, true, false}, opened: "3",
			}
			shot("import")

			r.importer = &remoteImporter{source: remoteImportSSH,
				ssh: core.RemoteSSHConfigHosts{Files: []string{"~/.ssh/config", "~/.ssh/config.d/lab"}, Hosts: []core.RemoteSSHConfigHost{
					{Alias: "build", Status: core.RemoteImportExists, ExistingID: buildBox, ExistingName: "Build box",
						Resolved: &core.RemoteResolvedHost{HostName: "build.example", User: "dev", Port: 2222}},
					{Alias: "bastion", Status: core.RemoteImportable, UsedAsJumpBy: []string{"gpu"},
						Resolved: &core.RemoteResolvedHost{HostName: "bastion.example", User: "ops", Port: 22}},
					{Alias: "gpu", Status: core.RemoteImportable,
						Resolved: &core.RemoteResolvedHost{HostName: "gpu-07.lab.example", User: "ml", Port: 22, ProxyJump: "bastion"}},
					{Alias: "*.internal", Status: core.RemoteImportPattern},
				}},
				sshChosen: []bool{false, true, true, false},
			}
			shot("import-ssh")
			r.importer = nil

			// Once connected, the page lists the host's folders to open one.
			r.selectEntry(buildBox)
			browser := &remoteBrowser{entryID: buildBox, name: "Build box", host: remoteHost{ssh: r.entry(buildBox).Connection},
				recent: []string{"/home/dev/src/lithe", "/srv/ci/workspace"},
				dir:    "/home/dev/src", folders: []string{"lithe", "lithe-core-rust", "scratch"}, files: []string{"README.txt"},
				repositories: map[string]bool{"lithe": true, "lithe-core-rust": true},
				session:      core.RemoteSession{HomeDirectory: "/home/dev"}}
			browser.path.SetText("/home/dev/src")
			r.browser = browser
			shot("folder")

			// The host's running Docker and Podman containers list in place of its folders, and one
			// is entered as the user typed. The containers come from the host's docker ps and podman
			// ps; the scene shows fixed ones.
			browser.containers = &remoteBrowserContainers{engines: 2, list: []remoteListedContainer{
				{engine: core.ContainerEngineDocker, RemoteContainer: core.RemoteContainer{
					ID: strings.Repeat("c", 64), Name: "api-server", Image: "golang:1.26-bookworm", Status: "Up 3 days"}},
				{engine: core.ContainerEngineDocker, RemoteContainer: core.RemoteContainer{
					ID: strings.Repeat("e", 64), Name: "redis-cache", Image: "redis:8-alpine", Status: "Up 3 days"}},
				{engine: core.ContainerEnginePodman, RemoteContainer: core.RemoteContainer{
					ID: strings.Repeat("d", 64), Name: "pg-main", Image: "postgres:17", Status: "Up 1 hour"}},
			}}
			// A list selects only among the rows it has drawn.
			h.app.invalidator.Invalidate()
			h.settleChain()
			browser.containers.rows.Select(0)
			browser.containers.user.SetText("app")
			shot("host-containers")
			browser.containers = nil
			r.browser = nil

			// This computer's WSL distributions list under their own heading, and one opens as the
			// Linux account typed on its page; one that does not start fails with WSL's own text.
			// The distributions come from wsl.exe; the scenes show fixed ones.
			r.wsl.loaded = true
			r.wsl.list = core.RemoteWSLDistributions{Available: true, Distributions: []string{"Ubuntu-24.04", "Debian"}}
			r.buildRows()
			r.selectRemoteWSL("Ubuntu-24.04")
			r.wsl.user.SetText("dev")
			shot("wsl")
			r.selectRemoteWSL("Debian")
			gone := &core.WSLConnection{Distribution: "Debian"}
			steps = newRemoteSteps(core.SavedRemoteConnection{ID: gone.Identity(), Name: "Debian"}, remoteHost{wsl: gone}, "", h.app.now())
			r.steps = steps
			steps.fail(h.app.now(), &remoteProbeOutcome{result: core.RemoteProbeResult{
				Status: core.RemoteProbeUnreachable, Diagnostics: "There is no distribution with the supplied name.",
			}, wsl: true, at: h.app.now()}, h.app.language())
			r.log.Open = true
			shot("wsl-failed")
			r.steps = nil

			// This computer's running Docker and Podman containers list after the distributions,
			// and one opens as the user typed on its page; one that stopped fails with the engine's
			// own text. The containers come from docker ps and podman ps; the scenes show fixed ones.
			r.log.Open = false
			r.containers.loaded = true
			r.containers.list = []remoteListedContainer{
				{engine: core.ContainerEngineDocker, RemoteContainer: core.RemoteContainer{
					ID: strings.Repeat("a", 64), Name: "web-frontend", Image: "node:22-bookworm", Status: "Up 2 hours"}},
				{engine: core.ContainerEnginePodman, RemoteContainer: core.RemoteContainer{
					ID: strings.Repeat("b", 64), Name: "pg-main", Image: "postgres:17", Status: "Up 5 minutes"}},
			}
			r.buildRows()
			r.selectRemoteContainer(r.containers.list[0])
			r.containers.user.SetText("node")
			shot("container")
			r.selectRemoteContainer(r.containers.list[1])
			stopped := &core.ContainerConnection{Engine: core.ContainerEnginePodman, Container: "pg-main"}
			steps = newRemoteSteps(core.SavedRemoteConnection{ID: stopped.Identity(), Name: "pg-main"}, remoteHost{container: stopped}, "", h.app.now())
			r.steps = steps
			steps.fail(h.app.now(), &remoteProbeOutcome{result: core.RemoteProbeResult{
				Status: core.RemoteProbeUnreachable, Diagnostics: "Error: can only create exec sessions on running containers: container state improper",
			}, engine: core.ContainerEnginePodman, at: h.app.now()}, h.app.language())
			r.log.Open = true
			shot("container-failed")
			r.steps = nil

			// A folder of this computer opens in its dev container: its devcontainer.json files
			// list, an untrusted folder offers Trust and Build, and the CLI's log streams while it
			// builds. The folder, its files and the log are fixed here.
			r.log.Open = false
			folder := "/Users/dev/src/payments-api"
			d := &remoteDevcontainer{engine: core.ContainerEngineDocker, read: folder, config: ".devcontainer/devcontainer.json",
				configs: []core.DevcontainerConfig{
					{Path: ".devcontainer/devcontainer.json", Name: "Go & PostgreSQL"},
					{Path: ".devcontainer/worker/devcontainer.json"},
				},
				trust: toolchain.WorkspaceTrust{Root: folder},
			}
			d.folder.SetText(folder)
			r.devcontainer = d
			shot("devcontainer")
			d.trusted, d.build = true, &remoteProbe{cancel: func() {}}
			for _, line := range []string{
				"[1 ms] @devcontainers/cli 0.75.0. Node.js v22.11.0. darwin 25.0.0 arm64.",
				"[4 ms] Start: Run: docker buildx build --load -t vsc-payments-api-features -f Dockerfile-with-features .",
				"#1 [internal] load build definition from Dockerfile-with-features",
				"#5 [dev_container_auto_added_stage_label 1/3] FROM mcr.microsoft.com/devcontainers/go:1.26",
				"#7 [dev_containers_target_stage 2/3] COPY --from=dev_containers_feature_content_normalize /tmp/build-features/ /tmp/dev-container-features",
				"#8 [dev_containers_target_stage 3/3] RUN /tmp/dev-container-features/postgresql_0/install.sh",
				"#8 DONE 12.4s",
				"[14821 ms] Start: Run: docker run --sig-proxy=false -a STDOUT -a STDERR --mount type=bind,source=/Users/dev/src/payments-api,target=/workspaces/payments-api",
				"[15302 ms] Start: Run in container: /bin/sh -c go mod download",
			} {
				d.add(core.DevcontainerOutput{Text: line})
			}
			shot("devcontainer-building")
			d.build = nil
			r.devcontainer = nil
			h.app.closeRemote()
			h.settleChain()
		})
	}
}
