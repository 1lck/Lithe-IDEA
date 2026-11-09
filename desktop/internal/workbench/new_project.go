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
	"github.com/1lck/Lithe-IDEA/desktop/internal/sheet"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	newProjectScope       = tree.ID(shellPage, "new-project-scope")
	newProjectDismiss     = tree.ID(shellPage, "new-project-dismiss")
	newProjectSearch      = tree.ID(shellPage, "new-project-search")
	newProjectSearchClear = tree.ID(shellPage, "new-project-search-clear")
	newProjectMore        = tree.ID(shellPage, "new-project-more")
	newProjectName        = tree.ID(shellPage, "new-project-name")
	newProjectParent      = tree.ID(shellPage, "new-project-parent")
	newProjectChoose      = tree.ID(shellPage, "new-project-choose")
	newProjectGit         = tree.ID(shellPage, "new-project-git")
	newProjectGitText     = tree.ID(shellPage, "new-project-git-text")
	newProjectCancel      = tree.ID(shellPage, "new-project-cancel")
	newProjectCreate      = tree.ID(shellPage, "new-project-create")
)

// newProjectState is window-owned: an unfinished operation must not be attached
// to the project it may replace. created records a directory that was created
// successfully even if Git initialization subsequently failed.
type newProjectState struct {
	name, parent, search                                     ui.Field
	open, busy, git, cancelling                              bool
	generation                                               uint64
	cancel                                                   context.CancelFunc
	err, created                                             string
	returnFocus                                              gfx.ID
	restoreFocus                                             bool
	searchQuery                                              string
	searchRaw                                                string
	searchGeneration                                         uint64
	searchCancel                                             context.CancelFunc
	searchKnown, searchRunning, searchPending, searchVisible bool
	searchRestore                                            bool
}

func (a *App) openNewProject(surface string) {
	n := &a.newProject
	if n.open {
		return
	}
	n.generation++
	n.open, n.busy, n.git, n.cancelling = true, false, false, false
	n.err, n.created, n.restoreFocus = "", "", false
	n.returnFocus = welcomeNew
	if a.project != nil {
		n.returnFocus = chromeProjectButton
	}
	n.name.SetText(i18n.Shared(a.language(), "desktop.newProject.defaultName"))
	n.parent.SetText(filepath.Join("~", "LitheProjects"))
	n.search.SetText("")
	n.searchKnown, n.searchPending, n.searchVisible = false, false, true
	n.searchRestore = false
	a.performed("workspace.new", surface)
}

func (a *App) closeNewProject() {
	n := &a.newProject
	n.generation++
	if n.cancel != nil {
		n.cancel()
		n.cancel = nil
	}
	n.searchGeneration++
	if n.searchCancel != nil {
		n.searchCancel()
	}
	n.searchPending = false
	n.open, n.busy, n.cancelling = false, false, false
}

// updateNewProjectSearch retains only view state; matching remains in Core.
// At most one request is active, and a later query replaces queued work.
func (a *App) updateNewProjectSearch() {
	n := &a.newProject
	raw := n.search.Text()
	if n.searchKnown && n.searchRaw == raw {
		return
	}
	n.searchRaw = raw
	query := strings.TrimSpace(raw)
	if n.searchKnown && n.searchQuery == query {
		return
	}
	n.searchKnown, n.searchQuery = true, query
	n.searchGeneration++
	if n.searchCancel != nil {
		n.searchCancel()
	}
	n.searchPending = false
	if query == "" {
		n.searchVisible = true
		return
	}
	if len(query) > 4096 {
		n.searchVisible = false
		return
	}
	n.searchPending = true
	a.launchNewProjectSearch()
}

func (a *App) launchNewProjectSearch() {
	n := &a.newProject
	if !n.open || !n.searchPending || n.searchRunning {
		return
	}
	n.searchPending, n.searchRunning = false, true
	generation, query := n.searchGeneration, n.searchQuery
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	n.searchCancel = cancel
	candidates := []core.RankCandidate{{Name: i18n.Shared(a.language(), "desktop.newProject.empty")}, {Name: "Empty Project"}}
	kernel := a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		indices, err := kernel.RankNames(ctx, query, candidates)
		return func(a *App) {
			n := &a.newProject
			n.searchRunning, n.searchCancel = false, nil
			if err != nil && !errors.Is(err, context.Canceled) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_search", err))
			}
			if n.open && n.searchGeneration == generation {
				if err != nil {
					n.searchVisible = true
				} else {
					n.searchVisible = len(indices) != 0
				}
			}
			if n.open && n.searchPending {
				a.launchNewProjectSearch()
			}
		}
	})
}

func (a *App) dismissNewProject() {
	if a.newProject.busy {
		return
	}
	a.closeNewProject()
	generation := a.newProject.generation
	a.post(func(a *App) {
		if !a.newProject.open && a.newProject.generation == generation {
			a.newProject.restoreFocus = true
		}
	})
}

// cancelNewProject waits for the worker to return, so a second attempt cannot
// race filesystem or Git operations still finishing from the first.
func (a *App) cancelNewProject() {
	n := &a.newProject
	if n.busy {
		n.cancelling = true
		if n.cancel != nil {
			n.cancel()
		}
		return
	}
	a.dismissNewProject()
}

func (a *App) chooseNewProjectParent() {
	n := &a.newProject
	generation := n.generation
	title := i18n.Shared(a.language(), "desktop.newProject.location")
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			n := &a.newProject
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：未选择目录。
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_choose_directory", documentLogError(err)))
				if n.open && n.generation == generation {
					n.err = i18n.Shared(a.language(), "desktop.newProject.chooseFailed")
				}
				return
			}
			if n.open && n.generation == generation && !n.busy && n.created == "" {
				n.parent.SetText(path)
				n.err = ""
			}
		}
	})
}

// projectParent expands the conventional home shorthand without interpreting
// any other shell syntax. Only an absolute path can be a destination.
func projectParent(path, home string) string {
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") || strings.HasPrefix(path, "~\\") {
		return filepath.Join(home, path[2:])
	}
	return path
}

type newProjectResult struct {
	path, reason string
	err          error
	created      bool
}

// createEmptyProject reserves the final directory with a single mkdir. It
// never replaces or removes a user's existing directory, including after a
// failed or cancelled Git initialization.
func createEmptyProject(ctx context.Context, kernel Kernel, parent, name string, git bool) newProjectResult {
	problem, err := kernel.CheckProjectName(ctx, name)
	if err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if problem != "" {
		return newProjectResult{reason: "invalidName", err: errors.New("invalid project name")}
	}
	destination, valid := cloneDestination(parent, name)
	if !valid {
		return newProjectResult{reason: "invalidLocation", err: errors.New("invalid project location")}
	}
	if err := ctx.Err(); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := ctx.Err(); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := os.Mkdir(destination, 0o755); err != nil {
		reason := "failed"
		if errors.Is(err, os.ErrExist) {
			reason = "exists"
		}
		return newProjectResult{reason: reason, err: err}
	}
	result := newProjectResult{path: destination, created: true}
	if err := ctx.Err(); err != nil {
		result.reason, result.err = "createdInterrupted", err
		return result
	}
	if git {
		if err := kernel.InitializeGit(ctx, destination); err != nil {
			result.reason, result.err = "gitFailed", err
		}
	}
	return result
}

func (a *App) submitNewProject() {
	n := &a.newProject
	if !n.open || n.busy {
		return
	}
	if n.created != "" {
		path := n.created
		a.closeNewProject()
		a.openProject(path)
		return
	}
	parent := n.parent.Text()
	if parent == "~" || strings.HasPrefix(parent, "~/") || strings.HasPrefix(parent, "~\\") {
		home, err := os.UserHomeDir()
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_home", documentLogError(err)))
			n.err = i18n.Shared(a.language(), "desktop.newProject.invalidLocation")
			return
		}
		parent = projectParent(parent, home)
	}
	name, git := n.name.Text(), n.git
	n.busy, n.cancelling, n.err = true, false, ""
	generation := n.generation
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	n.cancel = cancel
	kernel := a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result := createEmptyProject(ctx, kernel, parent, name, git)
		return func(a *App) {
			n := &a.newProject
			if result.err != nil && !errors.Is(result.err, context.Canceled) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_create", documentLogError(result.err)))
			}
			if !n.open || n.generation != generation {
				// log-exempt: 用户取消：窗口已关闭，保留可能已创建的目录。
				return
			}
			n.cancel, n.busy = nil, false
			if n.cancelling {
				n.cancelling = false
				if result.created {
					n.created = result.path
					n.err = i18n.Shared(a.language(), "desktop.newProject.createdInterrupted")
				} else {
					a.dismissNewProject()
				}
				return
			}
			if result.err != nil {
				if result.created {
					n.created = result.path
				}
				message := i18n.Shared(a.language(), "desktop.newProject.failed")
				switch result.reason {
				case "invalidName":
					message = i18n.Shared(a.language(), "desktop.newProject.invalidName")
				case "invalidLocation":
					message = i18n.Shared(a.language(), "desktop.newProject.invalidLocation")
				case "exists":
					message = i18n.Shared(a.language(), "desktop.newProject.exists")
				case "gitFailed":
					message = i18n.Shared(a.language(), "desktop.newProject.gitFailed")
				case "createdInterrupted":
					message = i18n.Shared(a.language(), "desktop.newProject.createdInterrupted")
				}
				n.err = message
				return
			}
			a.closeNewProject()
			a.openProject(result.path)
		}
	})
}

func (a *App) drawNewProjectDialog(f *ui.Frame) {
	n := &a.newProject
	if !n.open {
		return
	}
	language := a.language()
	submitted := false
	cancelled, confirmed := false, false
	background, sidebar, footer, divider := gfx.RGB24(0xF7F8FA), gfx.RGB24(0xECECEE), gfx.RGB24(0xF7F8FA), gfx.RGB24(0xD9DADF)
	if a.colors.Dark {
		background, sidebar, footer, divider = gfx.RGB24(0x242529), gfx.RGB24(0x232427), gfx.RGB24(0x191A1C), gfx.RGB24(0x333438)
	}
	dismissed := sheet.Draw(f, sheet.Options{Width: 880, Height: 660, Background: background,
		Scope: newProjectScope, Dismiss: newProjectDismiss, InitialFocus: newProjectSearch,
		DismissLabel: i18n.Shared(language, "desktop.newProject.cancel")}, func() {
		f.Row().FillWidth().Grow(1).Children(func() {
			f.Column().Width(240).FillHeight().Shrink(0).Draw(func(d *ui.DrawContext) { sheet.PaintLeadingBackground(d, sidebar) }).Children(func() {
				f.Column().FillWidth().Grow(1).PadSides(10, 12, 0, 12).Gap(12).Children(func() {
					var input ui.Box
					frame := f.Row().FillWidth().Height(30).Items(ui.Center).PadX(8).Gap(6).
						Border(1, a.theme.Input).Radius(a.theme.Metrics.RadiusControl).
						Focused(ui.Look{}.Border(a.theme.Primary).Ring(1, a.theme.Primary))
					frame.Children(func() {
						f.Icon(icons.Search).Size(15, 15).Shrink(0).Color(a.colors.Subtle)
						input = f.FieldBase(&n.search, newProjectSearch, i18n.Shared(language, "search.search"), i18n.Shared(language, "search.search")).Grow(1).MinWidth(0).Height(28).FontSize(13).Color(a.colors.Text)
						if n.search.Text() != "" && a.drawSearchClear(f, newProjectSearchClear) {
							n.search.SetText("")
							generation := n.generation
							a.post(func(a *App) {
								if a.newProject.open && a.newProject.generation == generation {
									a.newProject.searchRestore = true
								}
							})
						}
					})
					frame.StateFrom(input)
					if n.searchRestore {
						f.Canvas().RequestFocus(newProjectSearch)
						n.searchRestore = false
					}
					a.updateNewProjectSearch()
					f.Text(i18n.Shared(language, "desktop.newProject.section")).Muted()
					if n.searchVisible {
						selection := gfx.RGB24(0xE4E6EA)
						if a.colors.Dark {
							selection = gfx.RGB24(0x303137)
						}
						f.Row().FillWidth().Height(24).Items(ui.Center).Gap(8).PadX(10).Radius(4).Background(selection).Children(func() {
							f.Icon(icons.Folder).Size(15, 15).Color(a.colors.Subtle)
							f.Text(i18n.Shared(language, "desktop.newProject.empty"))
						})
					}
				})
				f.Row().FillWidth().Height(1).Shrink(0).Background(divider)
				f.Row().FillWidth().Height(40).Shrink(0).Items(ui.Center).PadX(14).Children(func() {
					label := i18n.Shared(language, "native.getMoreLanguagesAndFrameworksFromPlugins")
					if f.Text(label).FontSize(12).Color(a.colors.Accent).HitWith(newProjectMore, label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).Clicked() {
						a.openPluginSettings(surfaceButton)
					}
				})
			})
			f.Column().Width(1).FillHeight().Shrink(0).Background(divider)
			f.Column().Grow(1).FillHeight().PadSides(20, 24, 0, 24).Gap(12).Children(func() {
				f.Text(i18n.Shared(language, "desktop.newProject.description")).FontSize(12.5).Muted()
				f.Row().FillWidth().Items(ui.Center).Gap(12).Children(func() {
					f.Text(i18n.Shared(language, "desktop.newProject.name")).Width(120).Shrink(0)
					submitted = f.Field(&n.name, newProjectName, i18n.Shared(language, "desktop.newProject.name"), "").Grow(1).MaxWidth(360).Disabled(n.busy || n.created != "").Submitted()
				})
				f.Row().FillWidth().Items(ui.Center).Gap(12).Children(func() {
					f.Text(i18n.Shared(language, "desktop.newProject.location")).Width(120).Shrink(0)
					f.Field(&n.parent, newProjectParent, i18n.Shared(language, "desktop.newProject.location"), "").Grow(1).Disabled(n.busy || n.created != "")
					if a.logIconButton(f, newProjectChoose, i18n.Shared(language, "desktop.newProject.choose"), icons.Folder, false, n.busy || n.created != "") {
						a.chooseNewProjectParent()
					}
				})
				f.Row().FillWidth().PadSides(0, 0, 0, 132).Children(func() {
					f.Text(i18n.SharedFormat(language, "desktop.newProject.pathPreview", map[string]string{"path": filepath.Join(n.parent.Text(), n.name.Text())})).Muted()
				})
				f.Row().FillWidth().Items(ui.Center).PadSides(0, 0, 0, 132).Gap(4).Children(func() {
					disabled := n.busy || n.created != ""
					checked := f.Checkbox(newProjectGit, n.git).Label(i18n.Shared(language, "desktop.newProject.git")).Disabled(disabled).Clicked()
					label := f.Text(i18n.Shared(language, "desktop.newProject.git")).HitWith(newProjectGitText, i18n.Shared(language, "desktop.newProject.git"), gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true}).Clicked()
					if !disabled && (checked || label) {
						n.git = !n.git
					}
				})
				if n.err != "" {
					f.Paragraph(n.err, 4).Color(a.theme.Danger)
				}
			})
		})
		f.Row().FillWidth().Height(1).Shrink(0).Background(divider)
		f.Row().FillWidth().Height(56).Shrink(0).Items(ui.Center).Justify(ui.End).PadX(14).Gap(8).
			Draw(func(d *ui.DrawContext) { sheet.PaintFooterBackground(d, footer) }).Children(func() {
			cancelled = f.Button(newProjectCancel, i18n.Shared(language, "desktop.newProject.cancel")).Outline().Disabled(n.cancelling).Clicked()
			label := i18n.Shared(language, "desktop.newProject.create")
			if n.busy {
				label = i18n.Shared(language, "desktop.newProject.creating")
			} else if n.created != "" {
				label = i18n.Shared(language, "desktop.newProject.openCreated")
			}
			confirmed = f.Button(newProjectCreate, label).Disabled(n.busy).Clicked()
		})
	})
	if cancelled || dismissed {
		a.cancelNewProject()
	} else if confirmed || submitted {
		a.submitNewProject()
	}
}
