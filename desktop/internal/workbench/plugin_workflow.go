package workbench

import (
	"context"
	"net/url"
	"os"
	"slices"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/textview"
)

var _ pluginservice.WorkflowHost = pluginWorkbench{}

type pluginOutput struct {
	id, name string
	buffer   outputBuffer
	view     textview.View
}

// Only the window thread owns these presentation resources. The service owns
// their session/context leases and sends removal before a backend is forgotten.
type pluginWorkflowUI struct {
	outputs  []*pluginOutput
	selected string
	progress []pluginservice.ProgressUpdate
	status   []pluginservice.StatusUpdate
	menu     bool
}

type quickInputProjection struct {
	Indices []int
	Valid   bool
}

type quickInputState struct {
	request pluginservice.QuickInput
	value   string
	indices []int
	list    ui.ListState
	picked  map[string]bool
	filter  *ui.EffectState[quickInputProjection, string]
	invalid bool
	ready   bool
	result  *pluginservice.QuickResult
}

func (w pluginWorkbench) QuickInput(ctx context.Context, root string, request pluginservice.QuickInput) (*pluginservice.QuickResult, error) {
	state := &quickInputState{request: request, value: request.Value, picked: map[string]bool{}}
	for index, item := range request.Items {
		state.indices = append(state.indices, index)
		state.picked[item.ID] = item.Picked
	}
	state.list.Key = func(index int) int { return state.indices[index] + 1 }
	state.list.Label = func(index int) string { return request.Items[state.indices[index]].Label }
	state.filter = ui.NewEffectKeyed(func(effect context.Context, query string) (quickInputProjection, error) {
		bounded, cancel := context.WithTimeout(effect, kernelCallTimeout)
		defer cancel()
		stop := context.AfterFunc(ctx, cancel)
		defer stop()
		valid, err := request.Validate(bounded, query)
		result := quickInputProjection{Valid: valid}
		if err == nil && valid && request.Pick {
			result.Indices, err = request.Filter(bounded, query)
		}
		return result, err
	})
	prompt, err := onWindow(w.app, ctx, func(a *App) (*pluginPrompt, error) {
		if _, err := a.projectAt(root); err != nil {
			return nil, err
		}
		language := a.language()
		title := request.Title
		if title == "" {
			title = i18n.SharedFormat(language, "desktop.pluginHost.messageFrom", map[string]string{"plugin": request.PluginID})
		}
		return &pluginPrompt{title: title, quick: state, actions: []string{i18n.Shared(language, "desktop.files.cancel"), i18n.Shared(language, "desktop.pluginHost.messageOK")}}, nil
	})
	if err != nil {
		return nil, err
	}
	choice, err := w.app.askUser(ctx, prompt)
	if err != nil || choice == nil || *choice != 1 {
		return nil, err
	}
	return state.result, nil
}

// quickInputBody uses the framework's secure field and virtualized native list.
// Filtering is a cancellable Core effect; a late result cannot replace a new query.
func (a *App) quickInputBody(c ui.C, s *quickInputState) bool {
	request := s.request
	if request.Prompt != "" {
		ui.Wrap(c, request.Prompt).Shrink(0)
	}
	field := ui.TextField(c.Part("input"), &s.value, request.Title, request.Placeholder).FillWidth().AutoFocus()
	if request.Password {
		field = field.Secure()
	}
	submitted := field.Submitted()
	ui.Effect(c, s.filter, s.value)
	if result, err, ok := s.filter.Take(); ok {
		if err != nil {
			a.operationFailed("plugin_quick_pick_filter", err)
			s.ready = false
			s.invalid = false
		} else {
			previous := ""
			if at := s.list.Selected(); at >= 0 && at < len(s.indices) {
				previous = request.Items[s.indices[at]].ID
			}
			s.indices = result.Indices
			s.ready = result.Valid
			s.invalid = !result.Valid
			selected := -1
			for row, index := range s.indices {
				if request.Items[index].ID == previous || previous == "" && request.Items[index].Picked {
					selected = row
					break
				}
			}
			if selected < 0 && len(s.indices) > 0 {
				selected = 0
			}
			s.list.Select(selected)
		}
	}
	if field.Changed() {
		s.ready = false
		s.invalid = false
	}
	if s.invalid {
		ui.Text(c, i18n.Shared(a.language(), "desktop.pluginHost.inputLimit")).Color(a.colors.Subtle)
	}
	if !request.Pick {
		return submitted && s.ready
	}
	ui.List(c.Part("items"), &s.list, len(s.indices), func(row ui.ListRow) {
		item := request.Items[s.indices[row.Index]]
		row.Element.Items(ui.Center).Gap(8).Height(48).Children(func() {
			if request.CanPickMany {
				picked := s.picked[item.ID]
				if ui.Checkbox(row.C.Part("picked"), &picked, item.Label).Changed() {
					s.picked[item.ID] = picked
				}
			} else {
				ui.Text(row.C, item.Label).Grow(1).Ellipsis()
			}
			ui.Column(row.C).Grow(1).Children(func() {
				if item.Description != "" {
					ui.Text(row.C, item.Description).Color(a.colors.Subtle).Ellipsis()
				}
				if item.Detail != "" {
					ui.Text(row.C, item.Detail).Color(a.colors.Subtle).Ellipsis()
				}
			})
		})
	}).Scrollbars().Grow(1).FillWidth()
	if _, ok := s.list.Submitted(); ok {
		submitted = true
	}
	return submitted && s.ready
}

func (s *quickInputState) accept() {
	result := &pluginservice.QuickResult{Value: s.value, IDs: []string{}}
	if s.request.Pick {
		if s.request.CanPickMany {
			for _, item := range s.request.Items {
				if s.picked[item.ID] {
					result.IDs = append(result.IDs, item.ID)
				}
			}
		} else if row := s.list.Selected(); row >= 0 && row < len(s.indices) {
			result.IDs = append(result.IDs, s.request.Items[s.indices[row]].ID)
		}
	}
	s.result = result
	s.clear()
}

// clear removes input and cancels work even when a queued prompt is dismissed.
func (s *quickInputState) clear() {
	s.value = ""
	s.request.Value = ""
}

func (w pluginWorkbench) OpenPreview(ctx context.Context, root string, request pluginservice.PreviewRequest) (pluginservice.PreviewResult, error) {
	// Core has already checked the source type. Check native availability before
	// opening a document, so a refusal leaves no unrelated editor tab behind.
	if request.Kind == "HTML" {
		_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
			_, supported := a.kernel.(htmlKernel)
			if !supported || !a.previewWeb() || a.previews.siteFailed {
				return struct{}{}, hostError(pluginservice.CodeUnsupportedOption, "HTML preview is unavailable in this window.")
			}
			return struct{}{}, nil
		})
		if err != nil {
			return pluginservice.PreviewResult{}, err
		}
	}
	path := request.Path
	var opened pluginservice.OpenResult
	if path != "" {
		var err error
		opened, err = w.Open(ctx, root, pluginservice.OpenRequest{Path: path})
		if err != nil {
			return pluginservice.PreviewResult{}, err
		}
	} else {
		path = "lithe-plugin-preview://" + url.PathEscape(request.PluginID) + "/" + url.PathEscape(request.Owner) + "/" + url.PathEscape(request.ID)
		content := editorview.Prepare([]byte(request.Text))
		var err error
		opened, err = onWindow(w.app, ctx, func(a *App) (pluginservice.OpenResult, error) {
			p, err := a.projectAt(root)
			if err != nil {
				return pluginservice.OpenResult{}, err
			}
			d := p.docs.byPath(path)
			already := d != nil
			if d != nil {
				if d.previewKind != request.Kind {
					if d.html != nil && d.html.entry != nil {
						d.html.entry.close()
					}
					if d.markdown != nil && d.markdown.web != nil {
						d.markdown.web.entry.close()
					}
					d.html, d.markdown = nil, nil
				}
				d.view.ShowContent(content)
				d.name = request.Title
				a.selectDocument(p, d.id)
			} else {
				a.placeDocumentAs(p, path, request.Title, content, nil, "", true)
				d = p.docs.byPath(path)
			}
			if d == nil {
				return pluginservice.OpenResult{}, hostError(pluginservice.CodeLimitExceeded, "The preview tab could not be opened.")
			}
			d.previewKind = request.Kind
			return pluginservice.OpenResult{DocumentSummary: summarize(p, d), WasAlreadyOpen: already, WindowIsForeground: true}, nil
		})
		if err != nil {
			return pluginservice.PreviewResult{}, err
		}
	}
	return onWindow(w.app, ctx, func(a *App) (pluginservice.PreviewResult, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return pluginservice.PreviewResult{}, err
		}
		d := p.docs.byPath(path)
		if d == nil {
			return pluginservice.PreviewResult{}, hostError(pluginservice.CodeNotFound, "The preview document was closed.")
		}
		d.pageMode = pageSplit
		if request.Presentation == "previewOnly" {
			d.pageMode = pageOnly
		}
		if request.Range != nil {
			d.view.GoToNavigation(request.Range.Start.Line-1, request.Range.Start.Column-1, false)
			line, column := d.view.CaretUTF16()
			opened.AppliedSelection = &pluginservice.AppliedCaret{Kind: "caret", Line: line + 1, Column: column + 1}
		}
		opened.DocumentSummary = summarize(p, d)
		return pluginservice.PreviewResult{OpenResult: opened, UsesLiveBuffer: true, Presentation: request.Presentation}, nil
	})
}

func (w pluginWorkbench) ShowTextDiff(ctx context.Context, root string, request pluginservice.DiffRequest) error {
	kernel, ok := w.app.kernel.(interface {
		CompareTexts(context.Context, string, string) (core.GitDiffFile, error)
	})
	if !ok {
		return hostError(pluginservice.CodeUnsupportedOption, "Text comparison is unavailable.")
	}
	file, err := kernel.CompareTexts(ctx, request.Original, request.Modified)
	if err != nil {
		return err
	}
	_, err = onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return struct{}{}, err
		}
		title := request.Title
		if title == "" {
			title = i18n.Shared(a.language(), "desktop.pluginHost.diff")
		}
		file.Path = "inline.txt"
		source := &savedSource{title: title, before: request.OriginalTitle, after: request.ModifiedTitle, files: []core.GitDiffFile{file}}
		if source.before == "" {
			source.before = i18n.Shared(a.language(), "desktop.pluginHost.original")
		}
		if source.after == "" {
			source.after = i18n.Shared(a.language(), "desktop.pluginHost.modified")
		}
		if a.showDiff(p, root, "plugin-inline:"+strconv.Itoa(p.diffs.next+1), core.GitChange{Path: file.Path, Status: "M"}, nil, diffOrigin{saved: source}) == nil {
			return struct{}{}, hostError(pluginservice.CodeUnsupportedOption, "The comparison tab could not be opened.")
		}
		return struct{}{}, nil
	})
	return err
}

func (w pluginWorkbench) UpdateOutput(ctx context.Context, root string, update pluginservice.OutputUpdate) error {
	_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			if update.Action == "dispose" {
				return struct{}{}, nil
			}
			return struct{}{}, err
		}
		state := &p.workflow
		var output *pluginOutput
		for _, candidate := range state.outputs {
			if candidate.id == update.ID {
				output = candidate
				break
			}
		}
		if update.Action == "create" && output == nil {
			output = &pluginOutput{id: update.ID, name: update.Name}
			state.outputs = append(state.outputs, output)
		}
		if output == nil {
			return struct{}{}, nil
		}
		switch update.Action {
		case "append":
			output.buffer.maxLines, output.buffer.maxBytes = update.MaxLines, update.MaxBytes
			chunk := outputChunk{open: styledLine{text: update.Open}}
			for _, line := range update.Lines {
				chunk.lines = append(chunk.lines, styledLine{text: line})
			}
			output.buffer.apply(chunk)
		case "clear":
			output.buffer.clear()
			output.buffer.open = styledLine{}
			output.view = textview.View{}
		case "show":
			state.selected = update.ID
			a.openToolWindow(itemOutput)
		case "dispose":
			for i, candidate := range state.outputs {
				if candidate == output {
					state.outputs = append(state.outputs[:i], state.outputs[i+1:]...)
					if state.selected == update.ID {
						state.selected = ""
					}
					break
				}
			}
		}
		return struct{}{}, nil
	})
	return err
}

func (w pluginWorkbench) UpdateProgress(ctx context.Context, root string, update pluginservice.ProgressUpdate) error {
	_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			if update.Remove {
				return struct{}{}, nil
			}
			return struct{}{}, err
		}
		for i, item := range p.workflow.progress {
			if item.ID != update.ID {
				continue
			}
			if update.Remove {
				p.workflow.progress = append(p.workflow.progress[:i], p.workflow.progress[i+1:]...)
			} else {
				if update.Title != "" {
					item.Title = update.Title
				}
				if update.MessageSet {
					item.Message = update.Message
				}
				if update.Percentage != nil {
					item.Percentage = update.Percentage
				}
				p.workflow.progress[i] = item
			}
			return struct{}{}, nil
		}
		if !update.Remove {
			p.workflow.progress = append(p.workflow.progress, update)
		}
		return struct{}{}, nil
	})
	return err
}

func (w pluginWorkbench) UpdateStatus(ctx context.Context, root string, update pluginservice.StatusUpdate) error {
	_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			if update.Remove {
				return struct{}{}, nil
			}
			return struct{}{}, err
		}
		for i, item := range p.workflow.status {
			if item.ID != update.ID {
				continue
			}
			p.workflow.status = append(p.workflow.status[:i], p.workflow.status[i+1:]...)
			break
		}
		if !update.Remove {
			p.workflow.status = append(p.workflow.status, update)
		}
		if update.Order != nil {
			byID := map[string]pluginservice.StatusUpdate{}
			for _, item := range p.workflow.status {
				byID[item.ID] = item
			}
			ordered := make([]pluginservice.StatusUpdate, 0, len(byID))
			for _, id := range update.Order {
				if item, ok := byID[id]; ok {
					ordered = append(ordered, item)
					delete(byID, id)
				}
			}
			for _, item := range p.workflow.status {
				if _, ok := byID[item.ID]; ok {
					ordered = append(ordered, item)
				}
			}
			p.workflow.status = ordered
		}
		return struct{}{}, nil
	})
	return err
}

func (w pluginWorkbench) ReleaseWorkflow(root, kind, id string) {
	w.app.post(func(a *App) {
		p, err := a.projectAt(root)
		if err != nil {
			return // log-exempt: 预期的缺失：项目已关闭，呈现资源已经释放。
		}
		switch kind {
		case "output":
			p.workflow.outputs = slices.DeleteFunc(p.workflow.outputs, func(item *pluginOutput) bool { return item.id == id })
			if p.workflow.selected == id {
				p.workflow.selected = ""
			}
		case "progress":
			p.workflow.progress = slices.DeleteFunc(p.workflow.progress, func(item pluginservice.ProgressUpdate) bool { return item.ID == id })
		case "statusBar":
			p.workflow.status = slices.DeleteFunc(p.workflow.status, func(item pluginservice.StatusUpdate) bool { return item.ID == id })
		}
	})
}

func (w pluginWorkbench) ReadClipboard(ctx context.Context) (string, error) {
	return onWindow(w.app, ctx, func(*App) (string, error) { return app.ClipboardText() })
}
func (w pluginWorkbench) WriteClipboard(ctx context.Context, text string) error {
	_, err := onWindow(w.app, ctx, func(*App) (struct{}, error) { return struct{}{}, app.SetClipboardText(text) })
	return err
}
func (w pluginWorkbench) RevealResource(ctx context.Context, path string) error {
	_, err := onWindow(w.app, ctx, func(*App) (struct{}, error) { return struct{}{}, treeRevealPath(path) })
	return err
}

func (a *App) pluginOutputView(c ui.C, p *project) {
	state := &p.workflow
	if len(state.outputs) == 0 {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.pluginHost.noOutput"), a.colors.Subtle)
		return
	}
	selected := 0
	choices := make([]int, len(state.outputs))
	for i, output := range state.outputs {
		choices[i] = i
		if output.id == state.selected {
			selected = i
		}
	}
	ui.Select(c.Part("channel"), &selected, choices, func(i int) string { return state.outputs[i].name }).FillWidth()
	output := state.outputs[selected]
	state.selected = output.id
	a.outputList(c.Part(output.id), p, &output.view, "plugin:"+output.id, output.name, &output.buffer, 0, false, nil).Fill()
}

func (a *App) pluginWorkflowStatus(c ui.C) {
	p := a.project
	if p == nil {
		return
	}
	state := &p.workflow
	if len(state.status) > 0 {
		status := state.status[0]
		button := ui.Button(c.Key(status.ID), status.Text).MaxWidth(180).Ghost().Tooltip(status.Tooltip).Disabled(status.CommandID == "")
		if button.Clicked() {
			item := status
			c.After(func() { a.runPluginCommand(p, item.PluginID, item.CommandID) })
		}
	}
	if len(state.progress) == 0 && len(state.status) <= 1 {
		return
	}
	anchor := ui.Button(c.Part("workflowMenu"), i18n.Shared(a.language(), "desktop.pluginHost.backgroundTasks")).Ghost()
	if anchor.Clicked() {
		state.menu = true
	}
	ui.Menu(c.Part("workflowMenu"), anchor, &state.menu, func(menu *ui.MenuItems) {
		menu.Above()
		for _, progress := range state.progress {
			label := progress.Title
			if progress.Percentage != nil {
				label += " " + strconv.FormatFloat(*progress.Percentage, 'f', 0, 64) + "%"
			}
			if progress.Cancel == nil {
				menu.Item(label).Description(progress.Message).Disabled(true)
				continue
			}
			menu.Sub(label, func(sub *ui.MenuItems) {
				if sub.Item(i18n.Shared(a.language(), "desktop.files.cancel")).Clicked() {
					cancel := progress.Cancel
					c.After(func() {
						a.performed("plugin.progress.cancel", surfaceMenu)
						a.background(p, 5*time.Second, func(context.Context) func(*App) { cancel(); return nil })
					})
				}
			}).Description(progress.Message)
		}
		for _, status := range state.status {
			if menu.Item(status.Text).Description(status.Tooltip).Disabled(status.CommandID == "").Clicked() {
				item := status
				c.After(func() { a.runPluginCommand(p, item.PluginID, item.CommandID) })
			}
		}
	})
}

func (a *App) runPluginCommand(p *project, pluginID, commandID string) {
	if a.plugins == nil {
		return
	}
	a.performed("plugin.command.run", surfaceButton)
	a.background(p, contentOpenTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.NotifyCommandRun(ctx, pluginID, commandID, p.root)
		return func(a *App) {
			if err != nil {
				a.operationFailed("plugin_command", err)
				a.notifyError(i18n.Shared(a.language(), "desktop.pluginHost.commandFailed"))
			}
		}
	})
}

// OpenBrowserResource opens only saved HTML, leaving a dirty editor untouched.
func (w pluginWorkbench) OpenBrowserResource(ctx context.Context, root, path, unsaved string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, hostError(pluginservice.CodeUnsupportedOption, "The browser resource is not a regular file.")
	}
	dirty, err := onWindow(w.app, ctx, func(a *App) (bool, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return false, err
		}
		if d := p.docs.byPath(path); d != nil && (d.dirty() || d.saving) {
			if unsaved == "requireSaved" {
				return false, hostError(pluginservice.CodeBusy, "Save the document before opening it in a browser.")
			}
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		return false, err
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	return dirty, app.OpenPathInBrowser(path)
}
