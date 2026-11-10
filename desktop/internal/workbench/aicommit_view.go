package workbench

import "github.com/vivaui/viva/ui"

// drawGenerateCommitButton declares the commit area's "generate message" button, which turns
// into "cancel" while a generation runs.
func (a *App) drawGenerateCommitButton(c ui.C, p *project) {
	t := a.text.AI.Commit
	if p.commit.ai.running {
		if ui.Button(c.Part("ai"), t.Cancel).Ghost().Clicked() {
			c.After(func() { a.cancelCommitGeneration(p) })
		}
		return
	}
	if ui.Button(c.Part("ai"), t.Generate).Ghost().Disabled(!a.canGenerateCommit(p)).Clicked() {
		c.After(func() { a.generateCommitMessage(p) })
	}
}

// drawGeneratedMessageConfirm declares the question asked before a generated message replaces
// the text already typed.
func (a *App) drawGeneratedMessageConfirm(c ui.C, p *project) {
	if !p.commit.ai.hasPending {
		return
	}
	t := a.text.AI.Commit
	open := true
	closed := ui.ModalWith(c, &open, t.ReplaceTitle, ui.ModalSpec{Description: t.ReplaceBody, Width: 420}, func() {
		ui.Paragraph(c, firstLine(p.commit.ai.pending), 2)
	}, func() {
		if ui.Button(c, t.Keep).Outline().Clicked() {
			c.After(func() { a.confirmGeneratedMessage(p, false) })
		}
		if ui.Button(c, t.Replace).Clicked() {
			c.After(func() { a.confirmGeneratedMessage(p, true) })
		}
	})
	if closed {
		c.After(func() { a.confirmGeneratedMessage(p, false) })
	}
}
