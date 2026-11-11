package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// This file is the references panel of the nested repositories (matrix id
// git-multi-repository-references): the branch popup lists, under the project's own references,
// the local branches and tags of each repository nested in the project folder, each repository in
// its own group. The panel is read-only: checking out or deleting a reference of another
// repository is not offered yet. The references are read when the popup opens.

// nestedReferences are the references of one nested repository as the panel last read them.
type nestedReferences struct {
	refs core.GitReferences
	err  error
}

// loadNestedReferences reads the references of every nested repository in the background. The
// answer of a reading that a newer one overtook is dropped.
func (a *App) loadNestedReferences(p *project) {
	kernel := a.kernel
	n := &p.nested
	n.refGen++
	gen := n.refGen
	repos := append([]nestedRepo(nil), n.repos...)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		out := make(map[string]nestedReferences, len(repos))
		for _, repo := range repos {
			refs, err := kernel.GitReferences(ctx, repo.root)
			out[repo.id] = nestedReferences{refs: refs, err: err}
		}
		return func(a *App) {
			if p.nested.refGen == gen {
				p.nested.references = out
			}
		}
	})
}

// drawNestedReferences declares the groups of the nested repositories in the branch popup: one
// foldable group per repository, with its local branches and its tags.
func (a *App) drawNestedReferences(c ui.C, p *project, t i18n.BranchMessages) {
	b := &a.branch
	for _, repo := range p.nested.repos {
		key := "nested/" + repo.id
		refs, loaded := p.nested.references[repo.id]
		collapsed := b.collapsed[key]
		if a.drawBranchSection(c, key, repo.id, collapsed, true) {
			c.After(func() { b.collapsed[key] = !b.collapsed[key] })
		}
		if collapsed {
			continue
		}
		switch {
		case !loaded:
			a.drawBranchNote(c, t.Loading)
		case refs.err != nil:
			a.drawBranchNote(c, t.LoadFailed(refs.err.Error()))
		default:
			for _, r := range refs.refs.References {
				if r.Kind != "local" && r.Kind != "tag" {
					continue
				}
				a.drawNestedReferenceRow(c, r)
			}
		}
	}
}

// drawNestedReferenceRow declares one reference of a nested repository: its icon in the color of
// its kind and its name.
func (a *App) drawNestedReferenceRow(c ui.C, r core.GitReference) {
	icon := icons.GitBranch
	if r.Kind == "tag" {
		icon = icons.Tag
	}
	ui.Row(c.Key("nestedref/" + r.FullName)).Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge + 12).Children(func() {
		ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(referenceColor(r.Kind, a.colors.Dark))
		ui.Text(c, r.ShortName).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Grow(1)
	})
}
