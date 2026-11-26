package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Remote Development window opens a folder of this computer in its dev container (#2231, Dev
// Containers): the user chooses the folder, Core lists its devcontainer.json files
// (remote.devcontainerConfigs, which starts nothing), and Build runs the official Dev Container
// CLI's up under Docker or Podman (remote.devcontainerUp), whose log streams onto the page. Once
// the container runs, the window enters it as the configuration's remoteUser and opens its
// workspaceFolder, the way a listed container opens, the host's trust being asked as usual.
//
// Building runs the folder's code on this computer: its Dockerfile, features and lifecycle
// commands. So the folder must be trusted first, the same decision as opening it as a local
// project, asked on the page as Trust and Build. Lithe adds no mount, option or right of its own:
// the CLI does what devcontainer.json says (S32).
//
// Neither the folder, the configuration, the container nor its user is logged; the CLI's log is
// shown on the page and never logged.

const (
	// remoteDevcontainerReadTimeout bounds listing a folder's configurations and reading its
	// trust, both small reads of this computer.
	remoteDevcontainerReadTimeout = 15 * time.Second
	// remoteDevcontainerLines is how many of the CLI's latest lines the page keeps: Core sends at
	// most 2 MiB of them, and the newest tell what is happening.
	remoteDevcontainerLines = 5000
)

// errRemoteDevcontainerFailed is logged for an up the CLI itself reported failed, whose words are
// shown and never logged.
var errRemoteDevcontainerFailed = errors.New("the Dev Container CLI reported a failure")

// remoteDevcontainer is the page that opens a folder of this computer in its dev container.
type remoteDevcontainer struct {
	runtimes                                                                              core.ContainerRuntimes
	runtimeID                                                                             string
	detecting                                                                             bool
	detectCancel                                                                          context.CancelFunc
	readCancel                                                                            context.CancelFunc
	creating                                                                              bool
	create                                                                                bool
	nativeFolder                                                                          string
	source                                                                                string
	name, image, dockerfile, buildContext, remoteUser, workspaceFolder, ports, postCreate ui.Field

	// folder is the folder as typed or chosen; read is the one last read, "" before.
	folder ui.Field
	read   string
	// reads numbers the reads, so that a read for a folder edited since is dropped; reading is
	// set while one runs.
	reads   uint64
	reading bool
	// configs are the folder's devcontainer.json files and config the one chosen.
	configs []core.DevcontainerConfig
	config  string
	// engine is the engine to build with: core.ContainerEngineDocker or Podman.
	engine string
	// trust is the folder's trust as read; trusted is set when its code may run, and location
	// asks to trust the parent folder too when the folder is trusted on the page. trusting is set
	// while the decision is saved.
	trust    toolchain.WorkspaceTrust
	trusted  bool
	location bool
	trusting bool
	// build is the running up, nil while none runs; stopped is set once the user stopped one.
	build   *remoteProbe
	stopped bool
	// lines are the newest lines of the CLI's log, count how many arrived and seen how many the
	// list showed; truncated is set once Core dropped later lines.
	lines     []string
	count     int
	seen      int
	truncated bool
	log       ui.ListState
	// err is the page's failure and diagnostics the CLI's own words under it.
	err         string
	diagnostics string
}

// busy says whether the page is saving the trust or building: the folder, the choices and Cancel
// wait for it.
func (d *remoteDevcontainer) busy() bool {
	return d.trusting || d.creating || d.build != nil
}

// buildable says whether Build may start: the folder was read and has a configuration, and it is
// trusted or its trust can be saved.
func (d *remoteDevcontainer) buildable() bool {
	return !d.busy() && !d.detecting && !d.reading && d.runtimeAvailable() && d.read != "" && len(d.configs) > 0 && !d.create && (d.trusted || d.trust.Root != "")
}

// runtimeAvailable reflects Core's probe result for the selected environment.
func (d *remoteDevcontainer) runtimeAvailable() bool {
	for _, runtime := range d.runtimes.Runtimes {
		if runtime.ID == d.runtimeID {
			return runtime.Available
		}
	}
	return false
}

// forget drops what was read for the folder once it is edited, and any read still running.
func (d *remoteDevcontainer) forget() {
	if d.readCancel != nil {
		d.readCancel()
		d.readCancel = nil
	}
	d.reads++
	d.reading, d.read, d.configs, d.config = false, "", nil, ""
	d.nativeFolder = ""
	d.create = false
	d.trust, d.trusted, d.location = toolchain.WorkspaceTrust{}, false, false
	d.err, d.diagnostics = "", ""
}

// add appends one line of the CLI's log, keeping the newest remoteDevcontainerLines.
func (d *remoteDevcontainer) add(line core.DevcontainerOutput) {
	if line.Truncated {
		d.truncated = true
		return
	}
	d.lines = append(d.lines, line.Text)
	d.count++
	if extra := len(d.lines) - remoteDevcontainerLines; extra > 0 {
		d.lines = append(d.lines[:0:0], d.lines[extra:]...)
	}
}

// openRemoteDevcontainer shows the page, over the list's selection.
func (a *App) openRemoteDevcontainer() {
	r := &a.remote
	if !r.open || r.saving || r.connect != nil || r.devcontainer != nil || !a.leaveRemoteFlows() {
		return
	}
	a.performed("remote.devcontainer.open", surfaceButton)
	r.stopProbe()
	r.steps = nil
	r.devcontainer = &remoteDevcontainer{engine: core.ContainerEngineDocker, source: "image"}
	if r.containers.discovering {
		r.devcontainer.detecting = true
	} else if r.containers.discovered {
		a.applyRemoteDevcontainerRuntimes(r.devcontainer, r.containers.runtimes)
	} else {
		a.detectRemoteDevcontainerRuntimes(r.devcontainer)
	}
}

// leaveRemoteDevcontainer is Cancel and closing the window: a running build stops.
func (a *App) leaveRemoteDevcontainer() {
	r := &a.remote
	if d := r.devcontainer; d != nil && d.build != nil {
		d.build.cancel()
	}
	if d := r.devcontainer; d != nil {
		if d.detectCancel != nil {
			d.detectCancel()
		}
		if d.readCancel != nil {
			d.readCancel()
		}
	}
	r.devcontainer = nil
}

// chooseRemoteDevcontainerFolder asks for the folder with the system's dialog, off the window
// thread, and reads the one chosen.
func (a *App) chooseRemoteDevcontainerFolder() {
	r := &a.remote
	d := r.devcontainer
	if d == nil || d.busy() {
		return
	}
	a.performed("remote.devcontainer.choose", surfaceButton)
	generation, title := r.generation, i18n.Shared(a.language(), "desktop.remote.devcontainer.chooseTitle")
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			r := &a.remote
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：目录选择器没有选择结果。
				return
			}
			if err != nil {
				a.operationFailed("remote_devcontainer_choose", documentLogError(err))
			}
			if !r.open || r.generation != generation || r.devcontainer != d || d.busy() {
				// log-exempt: 用户取消：页面已离开或正在构建，不再应用目录选择结果。
				return
			}
			if err != nil {
				d.err = i18n.SharedFormat(a.language(), "desktop.remote.chooseFailed", map[string]string{"reason": documentLogError(err).Error()})
				return
			}
			d.folder.SetText(path)
			a.readRemoteDevcontainer()
		}
	})
}

// readRemoteDevcontainer lists the folder's configurations and reads its trust in the background,
// choosing the first configuration, the one the specification looks for first.
func (a *App) readRemoteDevcontainer() {
	r := &a.remote
	d := r.devcontainer
	if d == nil || d.busy() || d.detecting {
		return
	}
	folder := strings.TrimSpace(d.folder.Text())
	if filepath.IsAbs(folder) {
		folder = filepath.Clean(folder)
	}
	if folder == "" {
		return
	}
	d.forget()
	d.reading = true
	target := d.runtimeTarget()
	reads, generation, kernel, root, everyTrusted := d.reads, r.generation, a.kernel, a.globalToolchainRoot(), a.trustEveryWorkspace
	d.readCancel = a.background(nil, remoteDevcontainerReadTimeout, func(ctx context.Context) func(*App) {
		configs, err := kernel.RemoteDevcontainerRuntimeConfigs(ctx, folder, target)
		var trust toolchain.WorkspaceTrust
		var trustErr error
		if err == nil && !everyTrusted {
			trust, trustErr = toolchain.ReadWorkspaceTrust(ctx, kernel, root, configs.NativeFolder)
		}
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.devcontainer != d || d.reads != reads {
				// log-exempt: 用户取消：页面已离开或文件夹已改，不再应用读取结果。
				return
			}
			d.reading, d.readCancel = false, nil
			language := a.language()
			if err != nil {
				a.operationFailed("remote_devcontainer_configs", remoteLogError(err))
				var coreErr *core.Error
				switch {
				case errors.As(err, &coreErr) && coreErr.Code == core.CodeInvalidRequest:
					d.err = i18n.Shared(language, "desktop.remote.devcontainer.folderRelative")
				case errors.As(err, &coreErr) && coreErr.Code == core.CodeWorkspaceNotFound:
					d.err = i18n.Shared(language, "desktop.remote.devcontainer.folderMissing")
				default:
					d.err = i18n.SharedFormat(language, "desktop.remote.devcontainer.readFailed", map[string]string{"reason": remoteLogError(err).Error()})
				}
				return
			}
			d.read, d.nativeFolder, d.configs = folder, configs.NativeFolder, configs.Configs
			d.create = len(configs.Configs) == 0
			if len(configs.Configs) > 0 {
				d.config = configs.Configs[0].Path
			}
			switch {
			case everyTrusted:
				d.trusted = true
			case trustErr != nil:
				// Building waits for a trust that can be read: nothing says the folder's code may run.
				a.backgroundFailed("workspace_trust_read", documentLogError(trustErr))
				d.err = i18n.SharedFormat(language, "desktop.remote.devcontainer.trustFailed", map[string]string{"reason": documentLogError(trustErr).Error()})
			default:
				d.trust, d.trusted = trust, trust.State == core.WorkspaceTrusted
			}
		}
	})
}

// startRemoteDevcontainer is Build: it builds at once in a trusted folder, and otherwise first
// saves the folder as trusted, as Trust and Build says.
func (a *App) startRemoteDevcontainer() {
	r := &a.remote
	d := r.devcontainer
	if d == nil || !d.buildable() {
		return
	}
	if d.trusted {
		a.buildRemoteDevcontainer(d)
		return
	}
	d.trusting, d.err, d.diagnostics = true, "", ""
	generation := r.generation
	a.saveWorkspaceTrust(d.trust, true, d.location && d.trust.OfferedLocation != nil, func(saved bool) {
		d.trusting = false
		r := &a.remote
		if !saved || !r.open || r.generation != generation || r.devcontainer != d {
			// log-exempt: 用户取消：信任未保存（已提示并记录）或页面已离开，不再构建。
			return
		}
		d.trusted = true
		a.buildRemoteDevcontainer(d)
	})
}

// buildRemoteDevcontainer runs the CLI's up for the page's folder and configuration in the
// background, showing its log as it comes, and enters the container it started.
func (a *App) buildRemoteDevcontainer(d *remoteDevcontainer) {
	r := &a.remote
	a.performed("remote.devcontainer.build", surfaceButton)
	ctx, cancel := context.WithCancel(a.operationContext(context.Background()))
	build := &remoteProbe{cancel: cancel}
	d.build, d.stopped = build, false
	d.lines, d.count, d.seen, d.truncated, d.log = nil, 0, 0, false, ui.ListState{}
	d.err, d.diagnostics = "", ""
	request := core.DevcontainerUpRequest{Folder: d.read, Config: d.config, Engine: d.engine, ProjectCodeAllowed: true, Runtime: d.runtimeTarget()}
	generation, kernel := r.generation, a.kernel
	output := func(line core.DevcontainerOutput) {
		a.post(func(a *App) {
			if a.remote.devcontainer == d && d.build == build {
				d.add(line)
			}
		})
	}
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result, err := kernel.RemoteDevcontainerUp(ctx, request, output)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.devcontainer != d || d.build != build {
				// log-exempt: 用户取消：构建已停止或窗口已关闭，不再进入容器。
				return
			}
			d.build = nil
			a.finishRemoteDevcontainer(d, result, err)
		}
	})
}

// finishRemoteDevcontainer shows a failed up on the page, or enters the container it started and
// opens its workspace folder.
func (a *App) finishRemoteDevcontainer(d *remoteDevcontainer, result core.DevcontainerUp, err error) {
	r := &a.remote
	language := a.language()
	if err != nil {
		a.operationFailed("remote_devcontainer_up", remoteLogError(err))
		var coreErr *core.Error
		code := core.CodeUnknown
		if errors.As(err, &coreErr) {
			code = coreErr.Code
		}
		switch code {
		case core.CodeRuntimeMissing:
			d.err = i18n.Shared(language, "desktop.remote.devcontainer.missing")
		case core.CodeTimedOut:
			d.err = i18n.Shared(language, "desktop.remote.devcontainer.timedOut")
		case core.CodeParseFailed:
			d.err = i18n.Shared(language, "desktop.remote.devcontainer.unusable")
		case core.CodeDevcontainerUntrustedFolder:
			d.trusted = false
			d.err = i18n.Shared(language, "desktop.remote.devcontainer.untrustedRefused")
		default:
			reason := err.Error()
			if coreErr != nil {
				reason = coreErr.Message
			}
			d.err = i18n.SharedFormat(language, "desktop.remote.devcontainer.upFailed", map[string]string{"reason": reason})
		}
		return
	}
	c := result.Container
	if c == nil {
		a.operationFailed("remote_devcontainer_up", errRemoteDevcontainerFailed)
		d.err, d.diagnostics = i18n.Shared(language, "desktop.remote.devcontainer.failed"), result.Diagnostics
		return
	}
	r.devcontainer = nil
	r.selectRemoteContainer(remoteListedContainer{engine: c.Engine, RemoteContainer: core.RemoteContainer{ID: c.ContainerID, Name: c.Container}, runtime: c.Runtime})
	r.containers.user.SetText(c.User)
	// The list shows the container once listed again, with its image and state.
	a.loadRemoteContainers()
	a.connectRemote(c.WorkspaceFolder)
}

// stopRemoteDevcontainer is Stop: the CLI is stopped, and the page keeps its log.
func (a *App) stopRemoteDevcontainer() {
	d := a.remote.devcontainer
	if d == nil || d.build == nil {
		return
	}
	a.performed("remote.devcontainer.stop", surfaceButton)
	d.build.cancel()
	d.build, d.stopped = nil, true
}

// remoteDevcontainerConfigLabel names a configuration in the picker: its name with its path, or
// its path.
func remoteDevcontainerConfigLabel(language i18n.Language, configs []core.DevcontainerConfig, path string) string {
	for _, config := range configs {
		if config.Path == path && config.Name != "" {
			return i18n.SharedFormat(language, "desktop.remote.devcontainer.configNamed", map[string]string{"name": config.Name, "path": path})
		}
	}
	return path
}

// remoteDevcontainerView declares the page: what it does, the folder, its configuration and
// engine, its trust, and the CLI's log.
func (a *App) remoteDevcontainerView(c ui.C, language i18n.Language, d *remoteDevcontainer) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c.Part("devcontainer")).Fill().Gap(8).Children(func() {
		body := c.Part("form-scroll")
		ui.Scroll(body).Scrollbars().FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
			ui.Column(body).FillWidth().Gap(16).PadSides(20, 24, 16, 24).Children(func() {
				h := c.Part("hero")
				ui.Row(h).FillWidth().Shrink(0).Items(ui.Center).Gap(14).Children(func() {
					ui.Row(h.Part("mark")).Size(40, 40).Shrink(0).Center().Radius(10).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
						ui.Icon(h, icons.FileCode).Size(20, 20).Color(a.colors.Subtle)
					})
					ui.Column(h).Grow(1).Basis(0).MinWidth(0).Gap(4).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.remote.devcontainer.title")).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().MinWidth(0)
						a.remoteHelp(c, i18n.Shared(language, "desktop.remote.devcontainer.about"))
					})
				})
				a.remoteDevcontainerRuntimeView(c.Part("runtime"), language, d)
				label := i18n.Shared(language, "desktop.remote.devcontainer.folder")
				a.remoteSection(c.Part("folder"), label, "", nil, func() {
					field := ui.TextField(c.Part("folder-field"), &d.folder, label, i18n.Shared(language, "desktop.remote.devcontainer.folderPlaceholder")).
						Mono().FillWidth().Disabled(d.busy()).Action(icons.FolderOpen, i18n.Shared(language, "desktop.remote.devcontainer.choose"))
					if field.Changed() {
						c.After(d.forget)
					}
					if field.Submitted() {
						c.After(func() {
							a.performed("remote.devcontainer.read", surfaceShortcut)
							a.readRemoteDevcontainer()
						})
					}
					if field.ActionClicked() {
						c.After(a.chooseRemoteDevcontainerFolder)
					}
					if d.reading {
						ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(small).Color(a.colors.Subtle)
					}
				})
				if d.read != "" {

					configLabel := i18n.Shared(language, "desktop.remote.devcontainer.config")
					a.remoteSection(c.Part("config"), configLabel, i18n.Shared(language, "desktop.remote.devcontainer.configHelp"), nil, func() {
						paths := make([]string, len(d.configs))
						for i, config := range d.configs {
							paths[i] = config.Path
						}
						if len(paths) > 0 && !d.create {
							configs := d.configs
							ui.Select(c.Part("config-select"), &d.config, paths, func(path string) string {
								return remoteDevcontainerConfigLabel(language, configs, path)
							}).Label(configLabel).FillWidth().Disabled(d.busy())
						}
						if len(paths) == 0 {
							ui.Text(c, i18n.Shared(language, "desktop.remote.devcontainer.createMissing")).FontSize(small).Color(a.colors.Subtle)
						}
					})
					if d.create {
						a.remoteDevcontainerFormView(c.Part("basic-form"), language, d)
					}

					if !d.trusted && d.trust.Root != "" {
						ui.Column(c.Part("trust")).FillWidth().Shrink(0).Gap(8).Children(func() {
							a.remoteNotice(c, icons.ShieldCheck, a.colors.Warning, i18n.Shared(language, "desktop.remote.devcontainer.untrusted"))
							if offered := d.trust.OfferedLocation; offered != nil {
								home, _ := os.UserHomeDir()
								text := i18n.SharedFormat(language, "desktop.trust.location", map[string]string{"folder": trustFolderLabel(*offered, home)})
								ui.Checkbox(c.Part("location"), &d.location, text).Disabled(d.busy())
							}
						})
					}
				}
				if d.err != "" {
					ui.Column(c.Part("error")).FillWidth().Shrink(0).Gap(8).Children(func() {
						a.remoteNotice(c, icons.CircleX, a.theme.Danger, d.err)
						if d.diagnostics != "" {
							l := c.Part("diagnostics")
							ui.Scroll(l).Scrollbars().FillWidth().MaxHeight(120).Children(func() {
								ui.Column(l).FillWidth().Pad(10).Radius(6).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
									ui.Paragraph(c, d.diagnostics, 40).Mono().FontSize(small).Color(a.colors.Subtle)
								})
							})
						}
					})
				}
				if d.stopped {
					a.remoteNotice(c.Part("stopped"), icons.Info, a.colors.Subtle, i18n.Shared(language, "desktop.remote.devcontainer.stopped"))
				}
			})
		})
		if d.build != nil || len(d.lines) > 0 {
			a.remoteDevcontainerLog(c.Part("log"), language, d)
		}
	})
}

// remoteDevcontainerLog declares the CLI's log: its newest lines, in a list that follows new lines
// while it shows its end.
func (a *App) remoteDevcontainerLog(c ui.C, language i18n.Language, d *remoteDevcontainer) {
	small := a.theme.Metrics.FontSizeS
	title := i18n.Shared(language, "desktop.remote.devcontainer.log")
	ui.Column(c).FillWidth().Height(200).Shrink(0).Gap(8).Children(func() {
		ui.Row(c.Part("head")).FillWidth().Height(22).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
			ui.Text(c, title).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Shrink(0)
			a.remoteHelp(c, i18n.Shared(language, "desktop.remote.devcontainer.logHelp"))
		})
		a.remoteBordered(c.Part("box")).Grow(1).Basis(0).MinHeight(0).Background(a.colors.Hover).Children(func() {
			box := c.Part("box")
			if len(d.lines) == 0 {
				ui.Row(box.Part("waiting")).FillWidth().Pad(10).Items(ui.Center).Gap(8).Children(func() {
					ui.Text(box, i18n.Shared(language, "desktop.remote.devcontainer.logWaiting")).FontSize(small).Color(a.colors.Subtle)
				})
				return
			}
			list := &d.log
			if d.seen != d.count {
				if d.seen == 0 || list.AtEnd() {
					list.ScrollToEnd()
				}
				d.seen = d.count
			}
			lines := d.lines
			list.Label = func(i int) string { return lines[i] }
			ui.List(box, list, len(lines), func(row ui.ListRow) {
				row.Element.Height(18).PadX(10).Items(ui.Center)
				ui.Text(row.C, lines[row.Index]).FontSize(12).Mono().Color(a.colors.Text).Ellipsis().MinWidth(0)
			}).Scrollbars().Label(title).Fill()
		})
		if d.truncated {
			ui.Text(c, i18n.Shared(language, "desktop.remote.devcontainer.truncated")).FontSize(small).Color(a.colors.Subtle)
		}
	})
}

// remoteDevcontainerFooter declares the buttons under the page: Cancel, and Build, or Stop while
// it builds.
func (a *App) remoteDevcontainerFooter(c ui.C, language i18n.Language, d *remoteDevcontainer) {
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		status := ""
		if d.build != nil {
			status = i18n.Shared(language, "desktop.remote.devcontainer.building")
		}
		ui.Text(c, status).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).MinWidth(0).Ellipsis()
		if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Disabled(d.trusting || d.creating).Clicked() {
			c.After(func() {
				a.performed("remote.devcontainer.cancel", surfaceButton)
				a.leaveRemoteDevcontainer()
			})
		}
		if d.build != nil {
			if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Icon(icons.Square).Clicked() {
				c.After(a.stopRemoteDevcontainer)
			}
			return
		}
		if d.create && d.read != "" {
			if ui.Button(c.Part("create"), i18n.Shared(language, "desktop.remote.devcontainer.createConfig")).Disabled(d.busy() || d.reading).Clicked() {
				c.After(a.createRemoteDevcontainerConfig)
			}
			return
		}
		label := i18n.Shared(language, "desktop.remote.devcontainer.build")
		if !d.trusted && d.trust.Root != "" {
			label = i18n.Shared(language, "desktop.remote.devcontainer.trustAndBuild")
		}
		if ui.Button(c.Part("build"), label).Icon(icons.Play).Disabled(!d.buildable()).Clicked() {
			c.After(a.startRemoteDevcontainer)
		}
	})
}
