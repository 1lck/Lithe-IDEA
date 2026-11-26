package editorview

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
)

// RainbowCandidates reads the editor's existing incremental grammar worker. Waiting and
// aggregation belong on a cancellable worker; this method never tokenizes a second time.
func (v *View) RainbowCandidates(ctx context.Context, text rope.Rope) (syntax.CandidateSnapshot, error) {
	return v.hl.Candidates(ctx, text)
}
