package workbench

import (
	"context"
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds the list of files a stash or a shelf saved, as the Commit tool window's Stash
// and Shelf tabs show it: the files grouped by folder, as the Log tab groups a commit's, under
// the layer they were saved from when a shelf saved more than one.

// savedFiles is the files list of a Stash or Shelf tab.
type savedFiles struct {
	layers []savedLayer
	// closed are the folders the user closed, and file the selected file, the zero value for
	// none.
	closed map[savedPath]bool
	file   savedPath
	// rows are the rows as they show, collected on each paint, and selected the index of the
	// selected file's row among them, -1 for none.
	rows     []savedFileRow
	selected int
	list     ui.ListState
}

// savedLayer is one layer of saved files: the staged changes or the working tree's of a shelf,
// or everything a stash saved. A layer without a label shows no row of its own.
type savedLayer struct {
	label   string
	files   []core.GitDiffFile
	folders []logFolder
}

// savedPath names a folder or a file of one layer by its slash-separated path.
type savedPath struct {
	layer int
	path  string
}

// savedFileRow is one row of the list: a layer's label, with folder -1; a folder, at its index
// among the layer's folders, with file -1; or a file under it, at its index among the layer's
// files.
type savedFileRow struct {
	key, layer, folder, file int
	depth                    int
}

// newSavedLayer is a layer of files, grouped by folder through kernel.
func newSavedLayer(ctx context.Context, kernel changedFileGrouper, label string, files []core.GitDiffFile) (savedLayer, error) {
	paths := make([]string, len(files))
	for i, file := range files {
		paths[i] = file.Path
	}
	folders, err := groupLogFiles(ctx, kernel, paths)
	return savedLayer{label: label, files: files, folders: folders}, err
}

// holds says the folder g of the layer lists the file at file.
func (layer savedLayer) holds(g int, file string) bool {
	return layer.folders[g].holds(file, func(i int) string { return layer.files[i].Path })
}

// atTop says the layer lists the file at file at the top of the repository.
func (layer savedLayer) atTop(file string) bool {
	for g, folder := range layer.folders {
		if folder.dir == "" {
			return layer.holds(g, file)
		}
	}
	return false
}

// reset forgets the files, the folders the user closed and the selected file.
func (f *savedFiles) reset(layers ...savedLayer) {
	f.layers, f.closed, f.file = layers, nil, savedPath{}
}

// empty says no layer has a file.
func (f *savedFiles) empty() bool {
	for _, layer := range f.layers {
		if len(layer.files) > 0 {
			return false
		}
	}
	return true
}

// hasFolders says some layer has a folder to open or close.
func (f *savedFiles) hasFolders() bool {
	for _, layer := range f.layers {
		if len(layer.folders) > 0 {
			return true
		}
	}
	return false
}

// collect lists the rows the way they show: a layer's label when it has one, each folder but
// the top of the repository as a row of its own, and the files of the open ones under them.
func (f *savedFiles) collect() {
	f.rows, f.selected = f.rows[:0], -1
	base := 0
	for l, layer := range f.layers {
		indent := 0
		if layer.label != "" {
			f.rows = append(f.rows, savedFileRow{key: base, layer: l, folder: -1, file: -1})
			indent = 1
		}
		for g, folder := range layer.folders {
			depth := indent
			if folder.dir != "" {
				f.rows = append(f.rows, savedFileRow{key: base + 1 + g, layer: l, folder: g, file: -1, depth: indent})
				if f.closed[savedPath{l, folder.dir}] {
					continue
				}
				depth++
			}
			for _, i := range folder.files {
				if f.file == (savedPath{l, layer.files[i].Path}) {
					f.selected = len(f.rows)
				}
				f.rows = append(f.rows, savedFileRow{key: base + 1 + len(layer.folders) + i, layer: l, folder: g, file: i, depth: depth})
			}
		}
		base += 1 + len(layer.folders) + len(layer.files)
	}
}

// toggleFolder closes the folder g of layer l when it is open and opens it when it is closed.
// A selected file it closes over is no longer selected.
func (f *savedFiles) toggleFolder(l, g int) {
	folder := savedPath{l, f.layers[l].folders[g].dir}
	if f.closed[folder] {
		delete(f.closed, folder)
		return
	}
	if f.closed == nil {
		f.closed = map[savedPath]bool{}
	}
	f.closed[folder] = true
	if f.file.path != "" && f.file.layer == l && f.layers[l].holds(g, f.file.path) {
		f.file = savedPath{}
	}
}

// openFolders opens every folder, or closes every one but the top of the repository.
func (f *savedFiles) openFolders(open bool) {
	f.closed = nil
	if open {
		return
	}
	f.closed = map[savedPath]bool{}
	for l, layer := range f.layers {
		for _, folder := range layer.folders {
			if folder.dir != "" {
				f.closed[savedPath{l, folder.dir}] = true
			}
		}
	}
	if f.file.path != "" && !f.layers[f.file.layer].atTop(f.file.path) {
		f.file = savedPath{}
	}
}

// drawSavedFileList declares the list. Selecting a file keeps it for the Show Diff button;
// Enter or a double click opens its diff through open, and on a folder opens or closes it.
func (a *App) drawSavedFileList(c ui.C, f *savedFiles, open func(file savedPath)) {
	f.collect()
	if f.list.Key == nil {
		f.list.Key = func(i int) int { return f.rows[i].key }
		// A layer's label stays at the top while its files scroll under it.
		f.list.Header = func(i int) bool { return f.rows[i].folder < 0 }
	}
	if !f.list.Changed() && f.list.Selected() != f.selected {
		f.list.Select(f.selected)
	}
	ui.List(c, &f.list, len(f.rows), func(row ui.ListRow) { a.drawSavedFileRow(f, row) }).Grow(1).FillWidth()
	if f.list.Changed() {
		if i := f.list.Selected(); i >= 0 && i < len(f.rows) {
			if r := f.rows[i]; r.file >= 0 {
				f.file = savedPath{r.layer, f.layers[r.layer].files[r.file].Path}
			} else {
				f.file = savedPath{}
			}
		}
	}
	if i, ok := f.list.Submitted(); ok && i >= 0 && i < len(f.rows) {
		switch r := f.rows[i]; {
		case r.file >= 0:
			file := savedPath{r.layer, f.layers[r.layer].files[r.file].Path}
			c.After(func() { open(file) })
		case r.folder >= 0:
			c.After(func() { f.toggleFolder(r.layer, r.folder) })
		}
	}
}

// drawSavedFileRow declares one row: a layer's label; a folder's arrow, icon and path; or a
// file's change, icon and name in the color of its change.
func (a *App) drawSavedFileRow(f *savedFiles, row ui.ListRow) {
	r := f.rows[row.Index]
	layer := f.layers[r.layer]
	box := row.Element.Height(treelist.RowHeight).Items(ui.Center).Gap(treelist.Gap).
		PadSides(0, treelist.Gutter+treelist.Trailing, 0, float32(treelist.Gutter+r.depth*treelist.Indent)).
		Radius(a.theme.Metrics.RadiusItem())
	switch {
	case r.folder < 0:
	case row.Index == f.selected:
		box = box.Background(a.colors.Selection)
	default:
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	box.Children(func() {
		switch {
		case r.folder < 0:
			ui.Text(row.C, layer.label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		case r.file < 0:
			dir := layer.folders[r.folder].dir
			a.drawSavedFolderArrow(row.C, f, r, dir)
			ui.Icon(row.C, fileicons.ForDirectory(path.Base(dir), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
			ui.Text(row.C, dir).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis()
		default:
			file := layer.files[r.file]
			color := a.fileStatusColor(file.Status)
			ui.Row(row.C.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
			ui.Text(row.C, statusLetter(file.Status)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(color).Width(logFileStatus).Shrink(0)
			ui.Icon(row.C, fileicons.ForFile(path.Base(file.Path), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
			ui.Text(row.C, path.Base(file.Path)).FontSize(treeFontSize).Color(color).Ellipsis()
		}
	})
}

// drawSavedFolderArrow declares the arrow that opens or closes a folder of the list.
func (a *App) drawSavedFolderArrow(c ui.C, f *savedFiles, r savedFileRow, dir string) {
	open := !f.closed[savedPath{r.layer, dir}]
	name, chevron := i18n.Shared(a.language(), "native.collapseDirectory"), icons.ChevronDown
	if !open {
		name, chevron = i18n.Shared(a.language(), "native.expandDirectory"), icons.ChevronRight
	}
	k := c.Part("arrow")
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), name+" "+dir, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(k, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		layer, folder := r.layer, r.folder
		c.After(func() { f.toggleFolder(layer, folder) })
	}
}
