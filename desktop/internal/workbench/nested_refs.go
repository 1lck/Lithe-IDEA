package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the references and the colors of the repositories of the project folder (matrix id
// git-multi-repository-references). In a folder with several repositories the Git Log's reference
// pane lists, below HEAD, a node per repository in Core's order and in each repository's color from
// Core, each with its own local, remote and tag sections; a click on another repository's reference
// walks that reference in its repository (git_log_repo.go). The references of the repository the log
// reads its references with come with the history; the others are read with the log and again with
// the repositories. The colors are assigned with the repositories (nested_repos.go) and mark each
// repository in the branch popup, the change list, the Paths filter and the log rows.

// nestedReferences are the references of one repository as the pane last read them, in the
// sections of its node.
type nestedReferences struct {
	sections [3]logSection
	err      error
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

// loadNestedReferences reads in the background the references of the repositories besides the
// one whose references the log reads with its history: the nodes of the reference pane. The answer
// of a reading that a newer one overtook is dropped.
func (a *App) loadNestedReferences(p *project) {
	kernel := a.kernel
	n := &p.nested
	n.refGen++
	gen := n.refGen
	type read struct{ id, root string }
	var reads []read
	active := p.logRepoID()
	for _, repo := range p.workspaceRepositories() {
		if repo.id != active {
			reads = append(reads, read{id: repo.id, root: repo.root})
		}
	}
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		// The references are read again whenever a repository changes, so the console records
		// these reads only when it shows background branch reads.
		ctx = core.WithQueryCategory(ctx, core.GitQueryReferences)
		out := make(map[string]nestedReferences, len(reads))
		for _, r := range reads {
			_, sections, _, err := readReferences(ctx, kernel, r.root)
			out[r.id] = nestedReferences{sections: sections, err: err}
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

// appendRepositoryLogRows appends a node per repository of the project folder to the reference
// pane, in Core's order, each with its own sections of local branches, remote branches and tags, as
// IDEA's branches pane groups a project with several roots. The references of the repository whose
// history the log reads its references with act on it; a click on another repository's reference
// walks that reference in its repository. While the filter has text only the matching references
// show, and every node opens. It returns how many references the nodes list.
func (a *App) appendRepositoryLogRows(rows []logRefRow, p *project, query string) ([]logRefRow, int) {
	shown := 0
	active := p.logRepoID()
	for _, repo := range p.workspaceRepositories() {
		sections, foreign := &p.log.sections, ""
		if repo.id != active {
			refs, loaded := p.nested.references[repo.id]
			if !loaded || refs.err != nil {
				continue
			}
			sections, foreign = &refs.sections, repo.id
		}
		key := logRepoRefKey(repo.id)
		open := query != "" || !p.log.collapsed[key]
		node := len(rows)
		rows = append(rows, logRefRow{
			kind: logRefRepository, label: repo.name, short: repo.id, repo: repo.id, key: key, open: open,
			tint: a.repositoryTint(p, repo.id),
		})
		var count int
		if open {
			rows, count = a.appendLogSections(rows, p, key+"/", foreign, sections, 1, query)
		} else {
			count = sectionRefCount(sections)
		}
		if query != "" && count == 0 {
			rows = rows[:node]
			continue
		}
		shown += count
	}
	return rows, shown
}

// logRepoRefKey is the key of a repository's node in the reference pane; its sections and folders
// are keyed under it.
func logRepoRefKey(id string) string { return "r/" + id }

// sectionRefCount is how many references sections hold.
func sectionRefCount(sections *[3]logSection) int {
	n := 0
	for i := range sections {
		n += len(sections[i].refs)
	}
	return n
}
