package workbench

import (
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/vivaui/viva/ui"
)

// runConfigShellCustom is the entry of an interpreter list that asks for a program of the
// user's own. It cannot be a path, so it never stands for a value.
const runConfigShellCustom = "\x00custom"

// runConfigShellPick is the state of one interpreter list. choice is the entry shown, bound by
// its address, so the list keeps its identity across paints; custom says Custom… is chosen,
// which shows the field for a program of the user's own until another entry is chosen.
type runConfigShellPick struct {
	choice string
	custom bool
}

// shellPick is the state of field's interpreter list, made the first time it is drawn.
func (f *runConfigForm) shellPick(field string) *runConfigShellPick {
	if f.shellPicks == nil {
		f.shellPicks = map[string]*runConfigShellPick{}
	}
	if f.shellPicks[field] == nil {
		f.shellPicks[field] = &runConfigShellPick{}
	}
	return f.shellPicks[field]
}

// runConfigShellKind is the shell family Core names on an interpreter field; ok is false for a
// family this host does not know, whose field is then drawn as a plain program field.
func runConfigShellKind(family string) (shellkind.Kind, bool) {
	switch family {
	case "posix":
		return shellkind.POSIX, true
	case "powershell":
		return shellkind.PowerShell, true
	case "cmd":
		return shellkind.Cmd, true
	}
	return shellkind.Unknown, false
}

// runConfigFamilyShells is the installed shells of kind, in the order the terminal lists them.
// A WSL distribution's login shell has no program path a run could start, so it is left out.
func runConfigFamilyShells(shells []localshell.Choice, kind shellkind.Kind) []localshell.Choice {
	var kept []localshell.Choice
	for _, shell := range shells {
		if !strings.HasPrefix(shell.Path, "wsl:") && shellkind.FromProgram(shell.Path) == kind {
			kept = append(kept, shell)
		}
	}
	return kept
}

// sameRunConfigProgram says whether two paths name the same program; Windows ignores case.
func sameRunConfigProgram(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// runConfigShellChoices is the entries of an interpreter list for value, the field's text, and
// the words of each: automatic, which names the program Core runs while the field is empty;
// each installed shell of the family, with its path; value itself when it is none of them; and
// Custom…. current is the entry value stands for.
func runConfigShellChoices(language i18n.Language, automatic *string, shells []localshell.Choice, value string) (choices []string, labels map[string]string, current string) {
	labels = map[string]string{}
	add := func(choice, label string) {
		if _, ok := labels[choice]; !ok {
			choices = append(choices, choice)
			labels[choice] = label
		}
	}
	if automatic != nil && *automatic != "" {
		add("", i18n.SharedFormat(language, "desktop.runConfig.automaticValue", map[string]string{"value": *automatic}))
	} else {
		add("", i18n.Shared(language, "desktop.runConfig.interpreterAutomatic"))
	}
	current = value
	for _, shell := range shells {
		add(shell.Path, i18n.SharedFormat(language, "desktop.runConfig.interpreterShell", map[string]string{"name": shell.Name, "path": shell.Path}))
		if value != "" && sameRunConfigProgram(shell.Path, value) {
			current = shell.Path
		}
	}
	add(current, current)
	add(runConfigShellCustom, i18n.Shared(language, "desktop.runConfig.interpreterCustom"))
	return choices, labels, current
}

// drawRunConfigShellPicker declares an interpreter field Core names a shell family for, as the
// toolchain settings choose a tool: one list of the automatic interpreter, the installed shells
// of the family the new-terminal menu finds, and Custom…, which shows a field for a command
// name or a path, with a button that picks a file. It reports false, drawing nothing, for a
// family this host does not know. The installed shells are looked for again once per form,
// off the window thread, so a shell installed since the menu last looked is listed, and the
// list fills in when they are found.
func (a *App) drawRunConfigShellPicker(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, label string, ready bool) bool {
	kind, ok := runConfigShellKind(field.ShellFamily)
	text := f.texts[field.ID]
	if !ok || text == nil {
		return false
	}
	// Asked on this paint, not through ui.C.After: the form first shows in a paint that may
	// deliver no click, and such a paint drops what is deferred. The search runs in the
	// background, so asking here does not hold the paint.
	if !f.shellsAsked {
		f.shellsAsked = true
		a.findShells()
	}
	language := a.language()
	pick := f.shellPick(field.ID)
	choices, labels, current := runConfigShellChoices(language, field.Automatic, runConfigFamilyShells(a.term.shells.list, kind), *text)
	if pick.custom {
		pick.choice = runConfigShellCustom
	} else {
		pick.choice = current
	}
	shown := pick.choice
	ui.Column(c.Part("shell")).Grow(1).MinWidth(0).Gap(6).Children(func() {
		ui.Select(c.Part("choice"), &pick.choice, choices, func(choice string) string { return labels[choice] }).
			FillWidth().MinWidth(0).Label(label).Disabled(!ready)
		if pick.choice != shown {
			pick.custom = pick.choice == runConfigShellCustom
			if !pick.custom && pick.choice != *text {
				*text = pick.choice
				c.After(func() {
					a.performed("run.configuration.form.interpreter.choose", surfaceMenu)
					a.runConfigFormEdited(p, f)
				})
			}
		}
		if !pick.custom {
			return
		}
		// The field is named apart from the list above it, as the toolchain settings name theirs.
		named := i18n.Shared(language, "desktop.runConfig.interpreterCustomField")
		box := ui.TextField(c.Part("custom"), text, named, runConfigFieldPlaceholder(language, field)).FillWidth().MinWidth(0).Disabled(!ready).
			Action(icons.FolderOpen, i18n.Shared(language, "desktop.runConfig.browse"))
		if box.Changed() {
			c.After(func() { a.runConfigFormEdited(p, f) })
		}
		if box.ActionClicked() {
			c.After(func() { a.browseRunConfigField(p, f, field, label) })
		}
	})
	return true
}
