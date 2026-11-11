// Package agentbrand holds the vendor marks of the Agents the panel drives. The
// silhouettes are compiled ahead of time into icons.go from svg/ by `viva icons`;
// nothing is read or downloaded at runtime. A mark only identifies the selected
// Agent, and no affiliation is implied.
package agentbrand

import "github.com/vivaui/viva/gfx"

// Brand returns the mark of a Core-reported Agent ID and whether it has one. Claude
// keeps its orange star; the Codex knot is gray and follows the theme. An unknown
// Agent returns false so the caller can show the generic sparkle.
func Brand(agentID string, dark bool) (gfx.Icon, bool) {
	switch agentID {
	case "claude-acp":
		return Claude, true
	case "codex-acp":
		if dark {
			return CodexDark, true
		}
		return CodexLight, true
	}
	return gfx.Icon{}, false
}
