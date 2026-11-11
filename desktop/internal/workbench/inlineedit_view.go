package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// inlineEditView declares the inline edit dialog: the instruction first, then the diff of the
// model's replacement to accept or reject.
func (a *App) inlineEditView(c ui.C, p *project) {
	s := &a.inline
	if !s.open {
		return
	}
	t := a.text.AI.InlineEdit
	title := t.Title
	if s.hasResult {
		title = t.ReviewTitle
	}
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 640}, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if !s.hasResult {
				scope := i18n.Shared(a.language(), "desktop.ai.inlineEdit.editSelection")
				if s.currentLine {
					scope = i18n.Shared(a.language(), "desktop.ai.inlineEdit.editCurrentLine")
				}
				ui.Text(c, scope).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				a.inlineEditProviderPicker(c, s)
				field := ui.TextField(c.Part("instruction"), &s.instruction, t.Instruction, t.Instruction).FillWidth().Disabled(s.running).AutoFocus()
				if field.Submitted() && !s.running {
					c.After(func() { a.runInlineEdit(p) })
				}
				if s.running {
					ui.Text(c, t.Running).Color(a.colors.Subtle)
				}
			} else {
				if s.result == "" {
					ui.Paragraph(c, t.Empty, 2).Color(a.colors.Warning)
				} else if s.result == s.selected {
					ui.Text(c, t.Unchanged).Color(a.colors.Subtle)
				}
				ui.Scroll(c).FillWidth().MaxHeight(360).Children(func() {
					for i, line := range s.diff {
						color, mark := a.colors.Text, "  "
						switch line.kind {
						case diffRemoved:
							color, mark = a.colors.Deleted, "- "
						case diffAdded:
							color, mark = a.colors.Success, "+ "
						}
						ui.Text(c.KeyInt(i), mark+line.text).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(color)
					}
				})
			}
			if s.failure != "" {
				ui.Paragraph(c, s.failure, 3).Color(a.colors.Warning)
			}
		})
	}, func() {
		if s.hasResult {
			if ui.Button(c, t.Reject).Outline().Clicked() {
				c.After(a.closeInlineEdit)
			}
			if ui.Button(c, t.Accept).Clicked() {
				c.After(func() { a.acceptInlineEdit(p) })
			}
			return
		}
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.closeInlineEdit)
		}
		if ui.Button(c, t.Run).Disabled(s.running).Clicked() {
			c.After(func() { a.runInlineEdit(p) })
		}
	})
	if closed {
		c.After(a.closeInlineEdit)
	}
}

// inlineEditChoices are the picker's rows: the AI settings' default, then each configuration.
var inlineEditChoices = []string{"", "codex", "claude"}

// inlineEditProviderPicker declares the provider choice of the next edit. The model is the one
// the chosen configuration declares, as the commit message generation uses it.
func (a *App) inlineEditProviderPicker(c ui.C, s *inlineEditState) {
	t := a.text.AI.InlineEdit
	selected := 0
	for i, choice := range inlineEditChoices {
		if choice == s.source {
			selected = i
		}
	}
	indices := make([]int, len(inlineEditChoices))
	for i := range indices {
		indices[i] = i
	}
	if ui.Select(c.Part("provider"), &selected, indices, func(i int) string {
		switch inlineEditChoices[i] {
		case "codex":
			return t.ProviderCodex
		case "claude":
			return t.ProviderClaude
		}
		return t.ProviderDefault
	}).Label(t.Provider).Height(26).Disabled(s.running); selected != indexOfString(inlineEditChoices, s.source) {
		choice := inlineEditChoices[selected]
		c.After(func() { s.source = choice })
	}
}
