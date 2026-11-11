package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the references of the nested repositories (matrix id
// git-multi-repository-references). The branch popup lists, under the project's own references,
// the local branches and tags of each repository nested in the project folder, each repository in
// its own group, read-only. The Git Log's reference pane lists the repository groups below its own
// sections, with each repository's color from Core; a click on a group or one of its references makes
// that repository the one the log walks (git_log_repo.go). The references are read when the popup
// opens, and again with the log and the nested repositories.

// nestedReferences are the references of one nested repository as the panel last read them.
type nestedReferences struct {
	refs core.GitReferences
	err  error
}

// repositoryColorer is the part of the kernel that assigns the repository colors. Core's client
// implements it; a kernel that does not shows no colors.
type repositoryColorer interface {
	AssignRepositoryColors(ctx context.Context, request core.RepositoryColorRequest) (core.RepositoryColors, error)
}

// repositoryColorPage is the most identities one color request carries, as Core bounds it.
const repositoryColorPage = 128

// loadNestedReferences reads the references of the repository groups the reference pane lists in
// the background, and the color slot of every repository of the workspace with them. The answer of
// a reading that a newer one overtook is dropped.
func (a *App) loadNestedReferences(p *project) {
	kernel := a.kernel
	n := &p.nested
	n.refGen++
	gen := n.refGen
	// The branch popup lists every nested repository, so all of them are read; the project's own is
	// read too while the log walks a nested repository, to list it as a group.
	reads := append([]nestedRepo(nil), n.repos...)
	if n.logRepo != "" {
		reads = append([]nestedRepo{{id: commitRepositoryID, root: p.root}}, reads...)
	}
	ids := p.workspaceRepositoryIDs()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		out := make(map[string]nestedReferences, len(reads))
		for _, repo := range reads {
			refs, err := kernel.GitReferences(ctx, repo.root)
			out[repo.id] = nestedReferences{refs: refs, err: err}
		}
		slots, showColors := assignRepositoryColors(ctx, kernel, ids)
		return func(a *App) {
			if p.nested.refGen == gen {
				p.nested.references = out
				p.nested.slots, p.nested.showColors = slots, showColors
			}
		}
	})
}

// assignRepositoryColors asks Core for the color slot of each repository in ids, a page at a time,
// and whether the view shows colors at all. A kernel that cannot assign them, or a failed request,
// shows none.
func assignRepositoryColors(ctx context.Context, kernel Kernel, ids []string) (map[string]int, bool) {
	colorer, ok := kernel.(repositoryColorer)
	if !ok || len(ids) == 0 {
		return nil, false
	}
	slots := make(map[string]int, len(ids))
	showColors := false
	for offset := 0; offset < len(ids); offset += repositoryColorPage {
		end := min(offset+repositoryColorPage, len(ids))
		colors, err := colorer.AssignRepositoryColors(ctx, core.RepositoryColorRequest{
			Offset: offset, TotalCount: len(ids), RepositoryIDs: ids[offset:end],
		})
		if err != nil {
			return nil, false
		}
		for _, assignment := range colors.Assignments {
			slots[assignment.ID] = assignment.Slot
		}
		showColors = showColors || colors.ShowColors
	}
	return slots, showColors
}

// repositoryTint is the color a repository's group is drawn in: its Core slot in the palette when
// the view shows colors, the text color otherwise.
func (a *App) repositoryTint(p *project, id string) gfx.Color {
	slot, ok := p.nested.slots[id]
	if !ok || !p.nested.showColors {
		return a.colors.Text
	}
	return repositoryColor(slot, a.colors.Dark)
}

// repositoryPalette is the pair of colors of each slot: the color on a dark surface, then on a
// light one. Slots past the palette repeat.
var repositoryPalette = [...][2]uint32{
	{0x5FAD65, 0x369650},
	{0xB589EC, 0x834DF0},
	{0x4DA3E8, 0x1F6FD1},
	{0xE5A04B, 0xC06A12},
	{0xE06C75, 0xC2353F},
	{0x4DC4B5, 0x14897A},
	{0xD67FC1, 0xA53C92},
	{0x9AB84A, 0x6C8F1E},
}

// repositoryColor is the color of slot on the dark or the light surface.
func repositoryColor(slot int, dark bool) gfx.Color {
	n := len(repositoryPalette)
	pair := repositoryPalette[((slot%n)+n)%n]
	return pick(dark, pair[0], pair[1])
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

// appendNestedLogRows appends the groups of the other repositories to the reference pane: one row
// per repository with local branches or tags, then those references. A click on a group or a
// reference makes its repository the one the log walks. While the filter has text only the matching
// references show, and every group opens. It returns how many references the groups list.
func (a *App) appendNestedLogRows(rows []logRefRow, p *project, query string) ([]logRefRow, int) {
	shown := 0
	for _, repo := range p.referenceGroups() {
		refs, loaded := p.nested.references[repo.id]
		if !loaded || refs.err != nil {
			continue
		}
		var matches []core.GitReference
		for _, r := range refs.refs.References {
			if r.Kind != "local" && r.Kind != "tag" {
				continue
			}
			if query != "" && !strings.Contains(strings.ToLower(r.ShortName), query) {
				continue
			}
			matches = append(matches, r)
		}
		if len(matches) == 0 {
			continue
		}
		shown += len(matches)
		key := "nested/" + repo.id
		open := query != "" || !p.log.collapsed[key]
		rows = append(rows, logRefRow{
			kind: logRefRepository, label: p.repositoryName(repo.id), short: repo.id, repo: repo.id, key: key, open: open,
			tint: a.repositoryTint(p, repo.id),
		})
		if !open {
			continue
		}
		for i := range matches {
			ref := &matches[i]
			rows = append(rows, logRefRow{kind: logRefForeign, depth: 1, label: ref.ShortName, key: ref.FullName, short: ref.ShortName, ref: ref, repo: repo.id})
		}
	}
	return rows, shown
}
