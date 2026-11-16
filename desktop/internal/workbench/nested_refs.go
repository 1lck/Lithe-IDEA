package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the references and the colors of the repositories of the project folder (matrix id
// git-multi-repository-references). The Git Log's reference pane lists, below its own sections, a
// group per repository the log does not walk, in Core's order and in each repository's color from
// Core; a click on a group or one of its references makes that repository the one the log walks
// (git_log_repo.go). The references are read with the log and again with the repositories; the
// colors are assigned with the repositories (nested_repos.go) and mark each repository in the branch
// popup, the change list, the Paths filter and the log rows.

// nestedReferences are the references of one repository as the pane last read them.
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

// repositorySwatchSize is the side of the square that marks a repository in its color.
const repositorySwatchSize = 10

// loadNestedReferences reads in the background the references of the repositories the log does not
// walk, the groups of the reference pane. The answer of a reading that a newer one overtook is
// dropped.
func (a *App) loadNestedReferences(p *project) {
	kernel := a.kernel
	n := &p.nested
	n.refGen++
	gen := n.refGen
	type read struct{ id, root string }
	var reads []read
	for _, id := range n.others {
		if root := p.rootOf(id); root != "" {
			reads = append(reads, read{id: id, root: root})
		}
	}
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		// The references are read again whenever a repository changes, so the console records
		// these reads only when it shows background branch reads.
		ctx = core.WithQueryCategory(ctx, core.GitQueryReferences)
		out := make(map[string]nestedReferences, len(reads))
		for _, r := range reads {
			refs, err := kernel.GitReferences(ctx, r.root)
			out[r.id] = nestedReferences{refs: refs, err: err}
		}
		return func(a *App) {
			if p.nested.refGen == gen {
				p.nested.references = out
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

// repositoryTint is the color a repository is drawn in: its Core slot in the palette when the view
// shows colors, the text color otherwise.
func (a *App) repositoryTint(p *project, id string) gfx.Color {
	slot, ok := p.repositorySlot(id)
	if !ok {
		return a.colors.Text
	}
	return repositoryColor(slot, a.colors.Dark)
}

// repositorySlot is the Core color slot of the repository with ID, "" for the project's own, and
// whether the view shows it in a color.
func (p *project) repositorySlot(id string) (int, bool) {
	if !p.nested.showColors {
		return 0, false
	}
	if p.isOwnID(id) {
		if own, ok := p.nested.own(); ok {
			id = own.ID
		}
	}
	slot, ok := p.nested.slots[id]
	return slot, ok
}

// drawRepositorySwatch declares the square that marks a repository in its color, as IDEA marks the
// roots of a project with several. Nothing is drawn while the view shows no colors.
func (a *App) drawRepositorySwatch(c ui.C, p *project, id string) {
	if _, ok := p.repositorySlot(id); !ok {
		return
	}
	ui.Row(c).Size(repositorySwatchSize, repositorySwatchSize).Shrink(0).Radius(2).Background(a.repositoryTint(p, id))
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

// appendNestedLogRows appends the groups of the other repositories to the reference pane: one row
// per repository with local branches or tags, then those references. A click on a group or a
// reference makes its repository the one the log walks. While the filter has text only the matching
// references show, and every group opens. It returns how many references the groups list.
func (a *App) appendNestedLogRows(rows []logRefRow, p *project, query string) ([]logRefRow, int) {
	shown := 0
	for _, id := range p.nested.others {
		refs, loaded := p.nested.references[id]
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
		key := "nested/" + id
		open := query != "" || !p.log.collapsed[key]
		rows = append(rows, logRefRow{
			kind: logRefRepository, label: p.repositoryName(id), short: id, repo: id, key: key, open: open,
			tint: a.repositoryTint(p, id),
		})
		if !open {
			continue
		}
		for i := range matches {
			ref := &matches[i]
			rows = append(rows, logRefRow{kind: logRefForeign, depth: 1, label: ref.ShortName, key: ref.FullName, short: ref.ShortName, ref: ref, repo: id})
		}
	}
	return rows, shown
}
