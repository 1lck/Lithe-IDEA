package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/vivaui/viva/ui"
)

func (d *remoteDevcontainer) runtimeTarget() *core.ContainerRuntimeTarget {
	for _, runtime := range d.runtimes.Runtimes {
		if runtime.ID == d.runtimeID {
			target := runtime.ContainerRuntimeTarget
			return &target
		}
	}
	return nil
}

func (a *App) detectRemoteDevcontainerRuntimes(d *remoteDevcontainer) {
	if d.detecting || d.busy() {
		return
	}
	d.detecting = true
	d.forget()
	generation, kernel := a.remote.generation, a.kernel
	d.detectCancel = a.background(nil, 80*time.Second, func(ctx context.Context) func(*App) {
		result, err := kernel.RemoteContainerRuntimes(ctx)
		return func(a *App) {
			if !a.remote.open || a.remote.generation != generation || a.remote.devcontainer != d {
				// log-exempt: 用户取消：页面已关闭，不应用过期探测结果。
				return
			}
			d.detecting, d.detectCancel = false, nil
			if err != nil {
				a.backgroundFailed("remote_container_runtimes", remoteLogError(err))
				d.err = i18n.SharedFormat(a.language(), "desktop.remote.devcontainer.detectFailed", map[string]string{"reason": remoteLogError(err).Error()})
				return
			}
			a.recordRemoteContainerRuntimes(result)
			a.applyRemoteDevcontainerRuntimes(d, result)
		}
	})
}

// applyRemoteDevcontainerRuntimes makes a changed execution host invalidate every folder read.
func (a *App) applyRemoteDevcontainerRuntimes(d *remoteDevcontainer, result core.ContainerRuntimes) {
	d.runtimes = result
	found := false
	for _, runtime := range result.Runtimes {
		if runtime.ID == d.runtimeID {
			found = true
		}
	}
	if !found {
		d.runtimeID = result.SelectedRuntime
	}
	if target := d.runtimeTarget(); target != nil {
		d.engine = target.Engine
	}
	d.forget()
	a.readRemoteDevcontainer()
}

// Discovery is recorded once when its result arrives; reusing a cached picker does not log again.
func (a *App) recordRemoteContainerRuntimes(result core.ContainerRuntimes) {
	for _, runtime := range result.Runtimes {
		if runtime.Diagnostics != "" {
			a.backgroundFailed("remote_container_runtime_probe", errors.New("container engine did not answer the info probe"))
			break
		}
	}
	if len(result.Diagnostics) > 0 {
		a.backgroundFailed("remote_container_runtime_discovery", errors.New("container discovery was incomplete"))
	}
}

func remoteDevcontainerRuntimeLabel(language i18n.Language, runtime core.ContainerRuntime) string {
	label := runtime.Label
	if runtime.Context != "" && runtime.Context != label {
		label = i18n.SharedFormat(language, "desktop.remote.devcontainer.runtimeContext", map[string]string{"name": label, "context": runtime.Context})
	}
	if runtime.WSL != "" {
		label = i18n.SharedFormat(language, "desktop.remote.devcontainer.runtimeWSL", map[string]string{"name": label, "distribution": runtime.WSL})
	}
	if !runtime.Available {
		label = i18n.SharedFormat(language, "desktop.remote.devcontainer.runtimeUnavailable", map[string]string{"name": label})
	}
	return label
}

func (a *App) remoteDevcontainerRuntimeView(c ui.C, language i18n.Language, d *remoteDevcontainer) {
	title := i18n.Shared(language, "desktop.remote.devcontainer.runtime")
	a.remoteSection(c, title, i18n.Shared(language, "desktop.remote.devcontainer.runtimeHelp"), nil, func() {
		ui.Row(c).FillWidth().Gap(8).Children(func() {
			if len(d.runtimes.Runtimes) > 0 {
				ids := make([]string, len(d.runtimes.Runtimes))
				for i, runtime := range d.runtimes.Runtimes {
					ids[i] = runtime.ID
				}
				runtimes := d.runtimes.Runtimes
				if ui.Select(c.Part("target"), &d.runtimeID, ids, func(id string) string {
					for _, runtime := range runtimes {
						if runtime.ID == id {
							return remoteDevcontainerRuntimeLabel(language, runtime)
						}
					}
					return id
				}).Label(title).Grow(1).Basis(0).MinWidth(0).Disabled(d.busy() || d.detecting).Changed() {
					c.After(func() {
						if target := d.runtimeTarget(); target != nil {
							d.engine = target.Engine
						}
						d.forget()
						a.readRemoteDevcontainer()
					})
				}
			} else {
				text := i18n.Shared(language, "desktop.remote.devcontainer.noRuntime")
				if d.detecting {
					text = i18n.Shared(language, "desktop.remote.devcontainer.detecting")
				}
				ui.Text(c, text).Color(a.colors.Subtle).Grow(1).MinWidth(0).Ellipsis()
			}
			if ui.Button(c.Part("refresh"), i18n.Shared(language, "desktop.remote.devcontainer.refreshRuntimes")).Icon(icons.RefreshCw).Outline().Disabled(d.busy() || d.detecting).Clicked() {
				c.After(func() {
					a.performed("remote.devcontainer.detect", surfaceButton)
					a.detectRemoteDevcontainerRuntimes(d)
				})
			}
		})
		for _, diagnostic := range d.runtimes.Diagnostics {
			if diagnostic != "" {
				a.remoteNotice(c.Part("discovery-error"), icons.Info, a.colors.Warning, diagnostic)
			}
		}
		for _, runtime := range d.runtimes.Runtimes {
			if runtime.ID == d.runtimeID && runtime.Diagnostics != "" {
				a.remoteNotice(c.Part("runtime-error"), icons.Info, a.colors.Warning, runtime.Diagnostics)
			}
		}
	})
}

func (a *App) remoteDevcontainerFormView(c ui.C, language i18n.Language, d *remoteDevcontainer) {
	field := func(c ui.C, id string, value *ui.Field, title, help, placeholder string) {
		a.remoteSection(c.Part(id), title, help, nil, func() {
			ui.TextField(c.Part(id+"-field"), value, title, placeholder).FillWidth().Disabled(d.busy())
		})
	}
	ui.Column(c).FillWidth().Gap(12).Children(func() {
		field(c, "name", &d.name, i18n.Shared(language, "desktop.remote.devcontainer.form.name"), i18n.Shared(language, "desktop.remote.devcontainer.form.nameHelp"), "")
		title := i18n.Shared(language, "desktop.remote.devcontainer.form.source")
		a.remoteSection(c.Part("source"), title, i18n.Shared(language, "desktop.remote.devcontainer.form.sourceHelp"), nil, func() {
			ui.Select(c.Part("source-select"), &d.source, []string{"image", "dockerfile"}, func(source string) string {
				if source == "dockerfile" {
					return i18n.Shared(language, "desktop.remote.devcontainer.form.source.dockerfile")
				}
				return i18n.Shared(language, "desktop.remote.devcontainer.form.source.image")
			}).Label(title).FillWidth().Disabled(d.busy())
		})
		if d.source == "dockerfile" {
			field(c, "dockerfile", &d.dockerfile, i18n.Shared(language, "desktop.remote.devcontainer.form.dockerfile"), i18n.Shared(language, "desktop.remote.devcontainer.form.dockerfileHelp"), "Dockerfile")
			field(c, "buildContext", &d.buildContext, i18n.Shared(language, "desktop.remote.devcontainer.form.buildContext"), i18n.Shared(language, "desktop.remote.devcontainer.form.buildContextHelp"), ".")
		} else {
			field(c, "image", &d.image, i18n.Shared(language, "desktop.remote.devcontainer.form.image"), i18n.Shared(language, "desktop.remote.devcontainer.form.imageHelp"), "debian:bookworm-slim")
		}
		ui.Row(c.Part("user-folder")).FillWidth().Gap(16).Children(func() {
			user, folder := c.Part("user"), c.Part("folder")
			ui.Column(user).Grow(1).Basis(0).MinWidth(0).Children(func() {
				field(user, "remoteUser", &d.remoteUser, i18n.Shared(language, "desktop.remote.devcontainer.form.remoteUser"), i18n.Shared(language, "desktop.remote.devcontainer.form.remoteUserHelp"), "")
			})
			ui.Column(folder).Grow(1).Basis(0).MinWidth(0).Children(func() {
				field(folder, "workspaceFolder", &d.workspaceFolder, i18n.Shared(language, "desktop.remote.devcontainer.form.workspaceFolder"), i18n.Shared(language, "desktop.remote.devcontainer.form.workspaceFolderHelp"), "")
			})
		})
		field(c, "ports", &d.ports, i18n.Shared(language, "desktop.remote.devcontainer.form.ports"), i18n.Shared(language, "desktop.remote.devcontainer.form.portsHelp"), "3000, 8080")
		field(c, "postCreateCommand", &d.postCreate, i18n.Shared(language, "desktop.remote.devcontainer.form.postCreateCommand"), i18n.Shared(language, "desktop.remote.devcontainer.form.postCreateCommandHelp"), "")
		a.remoteNotice(c.Part("destination"), icons.FileCode, a.colors.Subtle, i18n.SharedFormat(language, "desktop.remote.devcontainer.configDestination", map[string]string{"path": filepath.Join(d.nativeFolder, ".devcontainer", "devcontainer.json")}))
	})
}

// createRemoteDevcontainerConfig publishes only on Create; opening and typing remain read-only.
func (a *App) createRemoteDevcontainerConfig() {
	d := a.remote.devcontainer
	if d == nil || !d.create || d.read == "" || d.busy() {
		return
	}
	a.performed("remote.devcontainer.create", surfaceButton)
	form := core.DevcontainerForm{Name: d.name.Text(), RemoteUser: d.remoteUser.Text(), WorkspaceFolder: d.workspaceFolder.Text(), Ports: d.ports.Text(), PostCreateCommand: d.postCreate.Text()}
	if d.source == "dockerfile" {
		form.Dockerfile, form.BuildContext = d.dockerfile.Text(), d.buildContext.Text()
	} else {
		form.Image = d.image.Text()
	}
	d.creating, d.err = true, ""
	folder, generation, kernel := d.nativeFolder, a.remote.generation, a.kernel
	a.background(nil, remoteDevcontainerReadTimeout, func(ctx context.Context) func(*App) {
		prepared, err := kernel.RemoteDevcontainerPrepare(ctx, form)
		if err == nil {
			err = writeRemoteDevcontainerConfig(ctx, folder, prepared)
		}
		return func(a *App) {
			if !a.remote.open || a.remote.generation != generation || a.remote.devcontainer != d {
				// log-exempt: 用户取消：创建操作已离开页面，写入错误仍记录到操作日志。
				if err != nil {
					a.operationFailed("remote_devcontainer_create", documentLogError(err))
				}
				return
			}
			d.creating = false
			if err != nil {
				a.operationFailed("remote_devcontainer_create", documentLogError(err))
				var coreErr *core.Error
				var detail struct {
					Field string `json:"field"`
				}
				if errors.As(err, &coreErr) && coreErr.Code == core.CodeInvalidRequest && json.Unmarshal([]byte(coreErr.Details), &detail) == nil && detail.Field != "" {
					d.err = i18n.SharedFormat(a.language(), "desktop.remote.devcontainer.invalidField", map[string]string{"field": remoteDevcontainerFieldLabel(a.language(), detail.Field)})
				} else if errors.Is(err, configfile.ErrConflict) {
					d.err = i18n.Shared(a.language(), "desktop.remote.devcontainer.configConflict")
				} else {
					d.err = i18n.SharedFormat(a.language(), "desktop.remote.devcontainer.createFailed", map[string]string{"reason": documentLogError(err).Error()})
				}
				return
			}
			a.readRemoteDevcontainer()
		}
	})
}

func remoteDevcontainerFieldLabel(language i18n.Language, field string) string {
	switch field {
	case "name":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.name")
	case "dockerfile":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.dockerfile")
	case "buildContext":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.buildContext")
	case "remoteUser":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.remoteUser")
	case "workspaceFolder":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.workspaceFolder")
	case "ports":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.ports")
	case "postCreateCommand":
		return i18n.Shared(language, "desktop.remote.devcontainer.form.postCreateCommand")
	default:
		return i18n.Shared(language, "desktop.remote.devcontainer.form.image")
	}
}

// writeRemoteDevcontainerConfig writes the user's workspace, never installation resources.
// The standard config belongs to that workspace for its lifetime; no app cache or bundle changes.
func writeRemoteDevcontainerConfig(ctx context.Context, folder string, prepared core.PreparedDevcontainer) error {
	installation, err := installedpackage.Root()
	if err != nil {
		return err
	}
	installation, err = filepath.EvalSymlinks(installation)
	if err != nil {
		return err
	}
	resolved, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(installation, resolved)
	if err == nil && (relative == "." || filepath.IsLocal(relative)) {
		return configfile.ErrTarget
	}
	snapshot, err := configfile.Capture(ctx, resolved, prepared.Path, 1024*1024)
	if err != nil {
		return err
	}
	if snapshot.Exists() {
		return configfile.ErrConflict
	}
	// Recheck an existing parent at publication as well: a workspace may contain the
	// installation as a descendant, and an internal symlink must not redirect into it.
	check := func() error {
		parent := filepath.Dir(filepath.Join(resolved, filepath.FromSlash(prepared.Path)))
		real, err := filepath.EvalSymlinks(parent)
		if errors.Is(err, os.ErrNotExist) {
			// log-exempt: 预期的缺失：首次创建的 .devcontainer 目录由有根文件适配器建立。
			return nil
		}
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(installation, real)
		if err == nil && (relative == "." || filepath.IsLocal(relative)) {
			return configfile.ErrTarget
		}
		return nil
	}
	if err := check(); err != nil {
		return err
	}
	_, err = snapshot.Replace(ctx, []byte(prepared.Content), check)
	return err
}
