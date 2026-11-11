package workbench

// difftab_whitespace.go is the whitespace switch of the Diff tabs: a diff that ignores whitespace
// reads the change again with git diff's --ignore-all-space. The switch is remembered for the tabs
// opened after it, as the split and whole modes are. A stash's file was read with the stash and
// keeps its diff.

// setDiffWhitespace turns the whitespace rules of tab t on or off and reads its change again.
func (a *App) setDiffWhitespace(p *project, t *diffTab, ignore bool) {
	if t.stash != nil || t.ignoreSpace == ignore {
		return
	}
	t.ignoreSpace = ignore
	p.diffs.ignoreSpace = ignore
	t.expanded = nil
	a.loadDiff(p, t)
}
