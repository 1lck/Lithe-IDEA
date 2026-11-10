package workbench

import (
	"net/url"
	"path/filepath"
	"strings"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// File references are user-selected context for the next message. Core's prompt
// and steer commands take them as `files` entries (a native file:// URL and the
// display name) and send ACP resource links; the host never reads or embeds file
// bytes, so neither does this file.
const agentFileLimit = 32

// agentFileRef is one attached file.
type agentFileRef struct {
	URI  string
	Name string
	Path string
}

// agentFileURL builds the native file URL Core expects for an absolute path.
func agentFileURL(path string) string {
	slashed := filepath.ToSlash(path)
	if len(slashed) >= 2 && slashed[1] == ':' {
		slashed = "/" + slashed
	}
	return (&url.URL{Scheme: "file", Path: slashed}).String()
}

// agentFileWire is the shape of Core's `files` field.
func agentFileWire(files []agentFileRef) []map[string]string {
	if len(files) == 0 {
		return nil
	}
	wire := make([]map[string]string, 0, len(files))
	for _, file := range files {
		wire = append(wire, map[string]string{"uri": file.URI, "name": file.Name})
	}
	return wire
}

// addAgentFiles attaches absolute paths to the draft. Duplicates and relative
// paths are ignored, and the list stays within Core's limit. It never sends.
func (a *App) addAgentFiles(p *project, paths []string) int {
	if p == nil {
		return 0
	}
	added := 0
	for _, path := range paths {
		path = strings.TrimSpace(path)
		if path == "" || !filepath.IsAbs(path) || len(p.agent.files) >= agentFileLimit {
			continue
		}
		path = filepath.Clean(path)
		duplicate := false
		for _, file := range p.agent.files {
			if file.Path == path {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		p.agent.files = append(p.agent.files, agentFileRef{URI: agentFileURL(path), Name: filepath.Base(path), Path: path})
		added++
	}
	if added > 0 {
		a.performed("agent.files.add", surfaceMenu)
	}
	return added
}

// removeAgentFile detaches one file from the draft.
func (a *App) removeAgentFile(p *project, index int) {
	if p == nil || index < 0 || index >= len(p.agent.files) {
		return
	}
	p.agent.files = append(p.agent.files[:index:index], p.agent.files[index+1:]...)
}

// agentTreeMenu gives a tree row the "Add to Agent conversation" item. The file becomes a
// reference in the next message's draft; nothing is sent or read.
func (a *App) agentTreeMenu(c ui.C, p *project, n *treeNode, target ui.Box) {
	if n == p.tree.root || !a.agentKernelReady() {
		return
	}
	path := filepath.Join(p.root, filepath.FromSlash(n.path))
	label := a.text.Agent.Activity.AddToAgent
	target.Hit(ui.ID(c.Key("agentctx/"+n.path)), n.name)
	ui.ContextMenu(c, target, func(menu *ui.MenuItems) {
		if menu.Item(label).Clicked() {
			c.After(func() { a.addAgentFiles(p, []string{path}) })
		}
	})
}

// agentFileDrop attaches files dropped on the composer. The drop must land inside the
// composer's rectangle, so other drop targets (opening files in the editor) are not taken.
func (a *App) agentFileDrop(event gfx.FileDropEvent) gfx.EventResult {
	p := a.project
	if p == nil {
		return gfx.EventResult{}
	}
	r := p.agent.composerRect
	if p.agent.conn == nil || r.Width <= 0 ||
		event.X < r.X || event.X > r.X+r.Width || event.Y < r.Y || event.Y > r.Y+r.Height {
		return gfx.EventResult{}
	}
	switch event.Phase {
	case gfx.FileDropOver:
		return gfx.EventResult{Handled: true}
	case gfx.FileDropDrop:
		if a.addAgentFiles(p, event.Paths) > 0 {
			return gfx.EventResult{Handled: true, Repaint: true}
		}
	}
	return gfx.EventResult{}
}
