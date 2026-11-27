package editorview

import (
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
)

var (
	testDocRenderIcon = gfx.Icon{ViewBox: 12, Commands: []gfx.PathCommand{
		gfx.MoveTo(1, 2), gfx.LineTo(11, 2), gfx.LineTo(11, 10), gfx.LineTo(1, 10), gfx.ClosePath(),
	}}
	testDocEditIcon = gfx.Icon{ViewBox: 12, Commands: []gfx.PathCommand{
		gfx.MoveTo(2, 10), gfx.LineTo(10, 2), gfx.LineTo(11, 3), gfx.LineTo(3, 11), gfx.ClosePath(),
	}}
	testFoldExpandedIcon = gfx.Icon{ViewBox: 10, Commands: []gfx.PathCommand{
		gfx.MoveTo(2, 3), gfx.LineTo(8, 3), gfx.LineTo(5, 7), gfx.ClosePath(),
	}}
	testFoldCollapsedIcon = gfx.Icon{ViewBox: 10, Commands: []gfx.PathCommand{
		gfx.MoveTo(3, 2), gfx.LineTo(7, 5), gfx.LineTo(3, 8), gfx.ClosePath(),
	}}
)

func makeTestMarkdownDoc(src string) markdown.Document {
	var doc markdown.Document
	doc.Parse(src)
	return doc
}

func makeTestDocWithLink(prefix, linkText, dest, suffix string) markdown.Document {
	var doc markdown.Document
	doc.AppendParagraph(0, 0, []markdown.Span{
		{Text: prefix},
		{Text: linkText, Link: dest},
		{Text: suffix},
	})
	return doc
}

func setupSimpleDocView(t *testing.T, text string, candidates []DocBlockCandidate, mdByHash map[uint64]markdown.Document, anchorsByHash map[uint64][]DocBlockAnchor) (*View, *gfx.Canvas) {
	t.Helper()
	v := newTestView(t, text)
	v.SetDocBlockIcons(testDocRenderIcon, testDocEditIcon)
	v.SetDocRenderDefault(true)
	v.SetDocBlockCallbacks(DocBlockCallbacks{
		RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
			doc, ok := mdByHash[contentHash]
			if !ok {
				return
			}
			v.InstallPreparedDocBlock(PreparedDocBlock{
				DocGeneration:    docGen,
				Revision:         revision,
				BlockID:          blockID,
				ContentHash:      contentHash,
				Doc:              doc,
				Anchors:          anchorsByHash[contentHash],
				EstimatedIRBytes: doc.AllocatedBytes(),
			})
		},
	})
	v.SetDocBlockCandidates(1, v.Revision(), candidates)
	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 640, Height: 400}, Look{
		Dark:       true,
		Background: gfx.RGB24(0x1E1F22),
		Foreground: gfx.RGB24(0xBCBEC4),
		Subtle:     gfx.RGB24(0x6F737A),
		Selection:  gfx.RGB24(0x214283),
	})
	return v, canvas
}

func TestDocBlockDisplayRowMappingNoWrapNoEnsureRows(t *testing.T) {
	text := strings.Join([]string{
		"package demo",
		"// Line 1 comment",
		"// Line 2 comment",
		"func Alpha() {}",
		"// Another doc",
		"// second line",
		"// third line",
		"func Beta() {}",
		"func Gamma() {}",
	}, "\n")

	doc1 := makeTestMarkdownDoc("# Alpha\n\nParagraph one.\n\nParagraph two.\n\nParagraph three.")
	doc2 := makeTestMarkdownDoc("Beta summary.")
	v, canvas := setupSimpleDocView(t, text, []DocBlockCandidate{
		{StartLine: 1, EndLine: 2, ContentHash: 101, ShellKind: "line", Dialect: "godoc"},
		{StartLine: 4, EndLine: 6, ContentHash: 202, ShellKind: "line", Dialect: "godoc"},
	}, map[uint64]markdown.Document{101: doc1, 202: doc2}, nil)

	// Unwrapped & unfolded: must NEVER trigger ensureRows full-file scan!
	if len(v.wraps) != 0 || len(v.rowStart) != 0 {
		t.Fatalf("unwrapped active doc blocks triggered ensureRows: wraps=%d rowStart=%d", len(v.wraps), len(v.rowStart))
	}
	if got := v.ActiveDocBlockCount(); got != 2 {
		t.Fatalf("ActiveDocBlockCount() = %d, want 2", got)
	}
	if !v.DocBlockRendered(1) || !v.DocBlockRendered(4) || v.DocBlockRendered(0) {
		t.Fatalf("DocBlockRendered mismatch: line1=%v line4=%v line0=%v", v.DocBlockRendered(1), v.DocBlockRendered(4), v.DocBlockRendered(0))
	}

	ab0 := v.docs.active[0]
	ab1 := v.docs.active[1]
	wantRows := 9 + (ab0.rows - 2) + (ab1.rows - 3)
	if got := v.rowCount(); got != wantRows {
		t.Fatalf("rowCount() = %d, want %d", got, wantRows)
	}
	if got := v.lineRow(0); got != 0 {
		t.Fatalf("lineRow(0) = %d, want 0", got)
	}
	if got := v.lineRow(1); got != 1 || v.lineRow(2) != 1 {
		t.Fatalf("lineRow(1..2) = (%d, %d), want (1, 1)", v.lineRow(1), v.lineRow(2))
	}
	if got, want := v.lineRow(3), 1+ab0.rows; got != want {
		t.Fatalf("lineRow(3) = %d, want %d", got, want)
	}
	if got, want := v.lineRow(7), 1+ab0.rows+1+ab1.rows; got != want {
		t.Fatalf("lineRow(7) = %d, want %d", got, want)
	}
	if got, want := v.lineRowEnd(2), 1+ab0.rows; got != want {
		t.Fatalf("lineRowEnd(2) = %d, want %d", got, want)
	}
	dr := v.displayRowAt(1)
	if dr.kind != displayDocBlock || dr.line != 1 || dr.sub != 0 || dr.block != 0 {
		t.Fatalf("displayRowAt(1) = %+v, want doc block 0 sub 0", dr)
	}
	drText := v.displayRowAt(1 + ab0.rows)
	if drText.kind != displayTextRow || drText.line != 3 || drText.sub != 0 || drText.block != -1 {
		t.Fatalf("displayRowAt(after block 0) = %+v, want text line 3", drText)
	}

	plain, ok := v.RenderedDocBlockText(1)
	if !ok || !strings.Contains(plain, "Alpha") || !strings.Contains(plain, "Paragraph three.") {
		t.Fatalf("RenderedDocBlockText(1) = (%q, %v), want rendered plain text", plain, ok)
	}
	if _, ok := v.RenderedDocBlockText(3); ok {
		t.Fatal("RenderedDocBlockText(3) returned true for non-doc line")
	}

	// Still zero wraps/rowStart after all mapping queries and a second paint.
	canvas.Reset()
	v.Paint(canvas, v.area, Look{Dark: true})
	if len(v.wraps) != 0 || len(v.rowStart) != 0 {
		t.Fatalf("second paint triggered ensureRows: wraps=%d rowStart=%d", len(v.wraps), len(v.rowStart))
	}
}

func TestDocBlockWithWrapAndInlayHints(t *testing.T) {
	longLine0 := strings.Repeat("alpha ", 30)
	text := longLine0 + "\n// doc line 1\n// doc line 2\nconst x = 1\n" + strings.Repeat("beta ", 25)
	v := newTestView(t, text)
	v.SetWrap(true)
	v.SetDocRenderDefault(true)
	v.SetDocBlockCallbacks(DocBlockCallbacks{
		RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
			v.InstallPreparedDocBlock(PreparedDocBlock{
				DocGeneration: docGen,
				Revision:      revision,
				BlockID:       blockID,
				ContentHash:   contentHash,
				Doc:           makeTestMarkdownDoc("Rendered doc with **bold**."),
			})
		},
	})
	v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
		{StartLine: 1, EndLine: 2, ContentHash: 11, ShellKind: "line", Dialect: "godoc"},
	})
	installTestHints(t, v, InlayHintSpec{ID: 9, Line: 3, UTF16Column: 7, Label: ": int", Interactive: true})

	canvas := new(gfx.Canvas)
	v.Paint(canvas, gfx.Rect{Width: 320, Height: 400}, Look{})
	if !v.DocBlockRendered(1) {
		t.Fatal("expected doc block at line 1 to be active under wrap+inlays")
	}
	line0Rows := len(v.rowsOf(v.ref(0)))
	if line0Rows < 2 {
		t.Fatalf("expected line 0 to wrap to >=2 rows, got %d", line0Rows)
	}
	ab := v.docs.active[0]
	if ab.displayStartRow != line0Rows {
		t.Fatalf("doc block displayStartRow = %d, want %d", ab.displayStartRow, line0Rows)
	}
	if got, want := v.lineRow(3), line0Rows+ab.rows; got != want {
		t.Fatalf("lineRow(3) = %d, want %d", got, want)
	}
	// InlayHintAt over the rendered doc block must return false.
	docMidY := v.area.Y + (float32(ab.displayStartRow)+0.5)*v.lineH - v.scroll
	if _, _, ok := v.InlayHintAt(v.textLeft+4, docMidY); ok {
		t.Fatal("InlayHintAt returned hit inside rendered doc block")
	}
}

func TestDocBlockFoldPrecedenceAndMutualExclusion(t *testing.T) {
	lines := []string{
		"func outer() {", // 0: outer fold start
		"  // doc a",     // 1: doc start (also fold start 1..3)
		"  // doc b",     // 2
		"  // doc c",     // 3
		"  x := 1",       // 4
		"}",              // 5: outer fold end
		"// partial a",   // 6: doc start 6..8
		"// partial b",   // 7: fold start 7..9 (partial overlap)
		"// partial c",   // 8
		"y := 2",         // 9
	}
	text := strings.Join(lines, "\n")
	v, canvas := setupSimpleDocView(t, text, []DocBlockCandidate{
		{StartLine: 1, EndLine: 3, ContentHash: 1, ShellKind: "line", Dialect: "godoc"},
		{StartLine: 6, EndLine: 8, ContentHash: 2, ShellKind: "line", Dialect: "godoc"},
	}, map[uint64]markdown.Document{
		1: makeTestMarkdownDoc("Inner doc block"),
		2: makeTestMarkdownDoc("Partial overlap doc block"),
	}, nil)
	v.SetFoldIcons(testFoldExpandedIcon, testFoldCollapsedIcon)
	v.SetFoldRanges([]FoldRange{
		{StartLine: 0, EndLine: 5},
		{StartLine: 1, EndLine: 3},
		{StartLine: 7, EndLine: 9},
	})
	canvas.Reset()
	v.Paint(canvas, v.area, Look{})

	if !v.DocBlockRendered(1) || !v.DocBlockRendered(6) {
		t.Fatalf("expected both doc blocks active initially")
	}

	// 1. Outer collapsed fold hides [1..3], excludes from active, keeps wantRendered intact.
	if !v.ToggleFold(0) {
		t.Fatal("ToggleFold(0) failed")
	}
	if v.DocBlockRendered(1) {
		t.Fatal("doc block inside collapsed outer fold must not be active")
	}
	if !v.docs.blocks[0].wantRendered {
		t.Fatal("outer fold must preserve wantRendered")
	}
	// Unfolding outer fold restores doc block 1..3 automatically.
	if !v.ToggleFold(0) {
		t.Fatal("unfold ToggleFold(0) failed")
	}
	if !v.DocBlockRendered(1) {
		t.Fatal("unfolding outer fold must restore rendered doc block")
	}

	// 2. Same-line fold & rendered mutual exclusion: toggling fold exits rendered state.
	if !v.ToggleFold(1) {
		t.Fatal("ToggleFold(1) failed")
	}
	if !v.Folded(1) || v.DocBlockRendered(1) || v.docs.blocks[0].wantRendered {
		t.Fatalf("same-line ToggleFold must fold and exit rendered: folded=%v active=%v want=%v",
			v.Folded(1), v.DocBlockRendered(1), v.docs.blocks[0].wantRendered)
	}
	// Toggling doc block render on same line unfolds the fold and restores rendered state.
	if !v.ToggleDocBlock(1) {
		t.Fatal("ToggleDocBlock(1) failed")
	}
	if v.Folded(1) || !v.DocBlockRendered(1) {
		t.Fatalf("same-line ToggleDocBlock must unfold and render: folded=%v active=%v",
			v.Folded(1), v.DocBlockRendered(1))
	}

	// 3. Partial overlap with collapsed fold [7..9] rejects projection of [6..8].
	if !v.ToggleFold(7) {
		t.Fatal("ToggleFold(7) failed")
	}
	if v.DocBlockRendered(6) {
		t.Fatal("partial fold overlap [7..9] must reject projection of doc block [6..8]")
	}
	if !v.ToggleFold(7) {
		t.Fatal("unfold ToggleFold(7) failed")
	}
	if !v.DocBlockRendered(6) {
		t.Fatal("removing partial overlap fold must restore doc block [6..8]")
	}
}

func TestDocBlockIdentityShiftAndStaleRejection(t *testing.T) {
	text := strings.Join([]string{
		"package p",
		"// doc A line 1",
		"// doc A line 2",
		"func A() {}",
		"// doc B line 1",
		"// doc B line 2",
		"func B() {}",
	}, "\n")
	v, canvas := setupSimpleDocView(t, text, []DocBlockCandidate{
		{StartLine: 1, EndLine: 2, ContentHash: 10, ShellKind: "line", Dialect: "godoc"},
		{StartLine: 4, EndLine: 5, ContentHash: 20, ShellKind: "line", Dialect: "godoc"},
	}, map[uint64]markdown.Document{
		10: makeTestMarkdownDoc("Doc A"),
		20: makeTestMarkdownDoc("Doc B"),
	}, nil)

	idA := v.docs.blocks[0].blockID
	idB := v.docs.blocks[1].blockID
	if idA == 0 || idB <= idA {
		t.Fatalf("block IDs must be strictly monotonic: idA=%d idB=%d", idA, idB)
	}
	oldRev := v.Revision()

	// Insert 2 lines at line 0 (above both blocks): shifts ranges without changing IDs!
	v.edit(0, 0, "// header 1\n// header 2\n", editOther)
	if v.docs.blocks[0].blockID != idA || v.docs.blocks[1].blockID != idB {
		t.Fatalf("unaffected edit changed blockIDs: got (%d,%d), want (%d,%d)",
			v.docs.blocks[0].blockID, v.docs.blocks[1].blockID, idA, idB)
	}
	if v.docs.blocks[0].startLine != 3 || v.docs.blocks[1].startLine != 6 {
		t.Fatalf("shifted startLines = (%d, %d), want (3, 6)", v.docs.blocks[0].startLine, v.docs.blocks[1].startLine)
	}

	// Stale InstallPreparedDocBlock validations: wrong docGen, revision, blockID, contentHash.
	if v.InstallPreparedDocBlock(PreparedDocBlock{DocGeneration: 99, Revision: v.Revision(), BlockID: idB, ContentHash: 20, Doc: makeTestMarkdownDoc("x")}) {
		t.Fatal("accepted wrong docGen")
	}
	if v.InstallPreparedDocBlock(PreparedDocBlock{DocGeneration: 1, Revision: oldRev, BlockID: idB, ContentHash: 20, Doc: makeTestMarkdownDoc("x")}) {
		t.Fatal("accepted stale revision")
	}
	if v.InstallPreparedDocBlock(PreparedDocBlock{DocGeneration: 1, Revision: v.Revision(), BlockID: 9999, ContentHash: 20, Doc: makeTestMarkdownDoc("x")}) {
		t.Fatal("accepted unknown blockID")
	}
	if v.InstallPreparedDocBlock(PreparedDocBlock{DocGeneration: 1, Revision: v.Revision(), BlockID: idB, ContentHash: 999, Doc: makeTestMarkdownDoc("x")}) {
		t.Fatal("accepted mismatched contentHash")
	}

	// Edit inside doc A (now at lines 3..4): invalidates A, shifts/keeps B!
	startA := v.text.LineStart(3)
	v.edit(startA, startA, " ", editTyping)
	if v.DocBlockRendered(3) {
		t.Fatal("edited doc block A must immediately exit rendered state")
	}
	if !v.DocBlockRendered(6) {
		t.Fatal("unaffected doc block B must stay rendered")
	}

	// Re-submitting candidates for the new revision keeps B's ID & cache, and keeps A in source mode.
	v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
		{StartLine: 3, EndLine: 4, ContentHash: 11, ShellKind: "line", Dialect: "godoc"},
		{StartLine: 6, EndLine: 7, ContentHash: 20, ShellKind: "line", Dialect: "godoc"},
	})
	canvas.Reset()
	v.Paint(canvas, v.area, Look{})
	if v.docs.blocks[0].blockID != idA || v.docs.blocks[1].blockID != idB {
		t.Fatalf("candidate refresh lost stable blockIDs: got (%d,%d), want (%d,%d)",
			v.docs.blocks[0].blockID, v.docs.blocks[1].blockID, idA, idB)
	}
	if v.DocBlockRendered(3) {
		t.Fatal("doc block A being edited should remain in source mode across candidate refresh")
	}
	if !v.DocBlockRendered(6) {
		t.Fatal("unchanged doc block B should stay rendered")
	}
}

func TestDocBlockStaticAdmissionCaps(t *testing.T) {
	cases := []struct {
		name string
		doc  func() markdown.Document
	}{
		{
			name: "too-many-blocks",
			doc: func() markdown.Document {
				var d markdown.Document
				for range docMaxBlocks + 1 {
					d.AppendParagraph(0, 0, []markdown.Span{{Text: "a"}})
				}
				return d
			},
		},
		{
			name: "too-many-text-bytes",
			doc: func() markdown.Document {
				var d markdown.Document
				d.AppendParagraph(0, 0, []markdown.Span{{Text: strings.Repeat("x", docMaxTextBytes+1)}})
				return d
			},
		},
		{
			name: "too-many-spans",
			doc: func() markdown.Document {
				var d markdown.Document
				spans := make([]markdown.Span, docMaxSpans+1)
				for i := range spans {
					spans[i] = markdown.Span{Text: "a"}
				}
				d.AppendParagraph(0, 0, spans)
				return d
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			v := newTestView(t, "// big doc\nfunc f() {}")
			v.SetDocRenderDefault(true)
			parseCalls := 0
			v.SetDocBlockCallbacks(DocBlockCallbacks{
				RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
					parseCalls++
					ok := v.InstallPreparedDocBlock(PreparedDocBlock{
						DocGeneration: docGen,
						Revision:      revision,
						BlockID:       blockID,
						ContentHash:   contentHash,
						Doc:           tc.doc(),
					})
					if ok {
						t.Errorf("%s: over-cap block should be rejected", tc.name)
					}
				},
			})
			v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
				{StartLine: 0, EndLine: 0, ContentHash: 77, ShellKind: "line", Dialect: "godoc"},
			})
			canvas := new(gfx.Canvas)
			area := gfx.Rect{Width: 600, Height: 300}
			v.Paint(canvas, area, Look{})
			if v.DocBlockRendered(0) || !v.docs.blocks[0].rejectedAdmission {
				t.Fatalf("%s: expected rejectedAdmission and source mode", tc.name)
			}
			// Subsequent paints must NOT re-queue RequestParse while contentHash is unchanged.
			for range 3 {
				canvas.Reset()
				v.Paint(canvas, area, Look{})
			}
			if parseCalls != 1 {
				t.Fatalf("%s: RequestParse called %d times, want 1 (must not re-queue)", tc.name, parseCalls)
			}
		})
	}
}

func TestDocBlockMemoryBudgetZeroCapAndLRUEviction(t *testing.T) {
	// 1. Verify NO 64 KiB floor when remaining <= 0.
	t.Run("zero-remaining-budget-has-no-floor", func(t *testing.T) {
		v := newTestView(t, "// doc\nfunc f() {}")
		// Simulate high already-used overhead so remaining <= 0 under the real formula.
		v.joinedSize = 3 << 20
		if got := v.docCacheBudgetBytes(); got != 0 {
			t.Fatalf("docCacheBudgetBytes() = %d when remaining <= 0, want 0 (no 64 KiB floor)", got)
		}
		v.SetDocRenderDefault(true)
		v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
			{StartLine: 0, EndLine: 0, ContentHash: 1, ShellKind: "line", Dialect: "godoc"},
		})
		id := v.docs.blocks[0].blockID
		if v.InstallPreparedDocBlock(PreparedDocBlock{
			DocGeneration: 1, Revision: v.Revision(), BlockID: id, ContentHash: 1,
			Doc: makeTestMarkdownDoc("Hello"),
		}) {
			t.Fatal("expected InstallPreparedDocBlock to reject when cache budget is 0")
		}
		canvas := new(gfx.Canvas)
		canvas.BeginFrame()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})
		canvas.EndFrame()
		if v.DocBlockRendered(0) {
			t.Fatal("visible block must remain source when budget cap is 0")
		}
		if _, pending := canvas.NextFrame(); pending {
			t.Fatal("budget-deferred block must not trigger RequestFrame loop")
		}
	})

	// 2. Verify LRU eviction caps cacheEntries <= 32 and preserves measuredRows (no scrollbar shift!).
	t.Run("lru-eviction-preserves-scrollbar-height", func(t *testing.T) {
		var sb strings.Builder
		var cands []DocBlockCandidate
		mdByHash := make(map[uint64]markdown.Document)
		const totalBlocks = 40
		line := 0
		for i := range totalBlocks {
			fmt.Fprintf(&sb, "// doc block %d line 1\n// doc block %d line 2\nfunc f%d() {}\n\n\n\n\n\n", i, i, i)
			hash := uint64(1000 + i)
			cands = append(cands, DocBlockCandidate{StartLine: line, EndLine: line + 1, ContentHash: hash, ShellKind: "line", Dialect: "godoc"})
			mdByHash[hash] = makeTestMarkdownDoc(fmt.Sprintf("Heading %d\n\nBody paragraph %d line one.\n\nBody paragraph %d line two.", i, i, i))
			line += 8
		}
		v := newTestView(t, sb.String())
		v.SetDocRenderDefault(true)
		v.SetDocBlockCallbacks(DocBlockCallbacks{
			RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
				v.InstallPreparedDocBlock(PreparedDocBlock{
					DocGeneration: docGen, Revision: revision, BlockID: blockID, ContentHash: contentHash,
					Doc: mdByHash[contentHash],
				})
			},
		})
		v.SetDocBlockCandidates(1, v.Revision(), cands)
		canvas := new(gfx.Canvas)
		// Small viewport so only ~2 blocks are visible (pinned) at a time.
		area := gfx.Rect{Width: 600, Height: 160}
		v.Paint(canvas, area, Look{})
		for step := 0; step < totalBlocks; step++ {
			v.scroll = float32(v.lineRow(cands[step].StartLine)) * v.lineH
			// Paint twice if frame budget split multiple blocks.
			for range 2 {
				canvas.Reset()
				v.Paint(canvas, area, Look{})
			}
		}
		if v.docs.cacheEntries > docCacheMaxEntries {
			t.Fatalf("cacheEntries = %d, exceeded maxEntries=%d", v.docs.cacheEntries, docCacheMaxEntries)
		}
		// Block 0 was evicted from LRU, yet its measuredRows stayed intact so it remains in active!
		if v.docs.blocks[0].inCache {
			t.Fatal("expected earliest off-screen block 0 to be evicted from LRU cache")
		}
		if v.docs.blocks[0].measuredRows <= 0 || !v.DocBlockRendered(cands[0].StartLine) {
			t.Fatalf("evicted off-screen block lost height metadata: measuredRows=%d active=%v",
				v.docs.blocks[0].measuredRows, v.DocBlockRendered(cands[0].StartLine))
		}
	})
}

func TestDocBlockTypingFrameSkipAndTimeBudgets(t *testing.T) {
	t.Run("typing-frame-skips-layout-and-requests-next-frame-only-when-pending", func(t *testing.T) {
		v := newTestView(t, "// doc\nfunc f() {}\n")
		v.SetDocRenderDefault(true)
		v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
			{StartLine: 0, EndLine: 0, ContentHash: 1, ShellKind: "line", Dialect: "godoc"},
		})
		id := v.docs.blocks[0].blockID
		if !v.InstallPreparedDocBlock(PreparedDocBlock{
			DocGeneration: 1, Revision: v.Revision(), BlockID: id, ContentHash: 1,
			Doc: makeTestMarkdownDoc("Pending on typing frame"),
		}) {
			t.Fatal("InstallPreparedDocBlock failed")
		}

		// Simulate typing on an unrelated line below the doc block.
		v.edit(v.text.LineEnd(1), v.text.LineEnd(1), " ", editTyping)
		if !v.docs.editedThisFrame {
			t.Fatal("expected editedThisFrame=true after edit")
		}
		canvas := new(gfx.Canvas)
		canvas.BeginFrame()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})
		canvas.EndFrame()
		if v.DocBlockRendered(0) {
			t.Fatal("typing frame must skip laying out new doc blocks")
		}
		if _, requested := canvas.NextFrame(); !requested {
			t.Fatal("typing frame with pending visible doc block must call canvas.RequestFrame()")
		}

		// Next (non-typing) frame lays out and activates the block atomically.
		canvas.Reset()
		canvas.BeginFrame()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})
		canvas.EndFrame()
		if !v.DocBlockRendered(0) {
			t.Fatal("non-typing follow-up frame must lay out and activate doc block")
		}

		// Another typing frame with NO pending visible doc blocks must NOT request an extra frame.
		v.edit(v.text.LineEnd(1), v.text.LineEnd(1), " ", editTyping)
		canvas.Reset()
		canvas.BeginFrame()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 300}, Look{})
		canvas.EndFrame()
		if _, requested := canvas.NextFrame(); requested {
			t.Fatal("typing frame with no pending doc blocks must not call canvas.RequestFrame()")
		}
	})

	t.Run("frame-500us-budget-and-2ms-circuit-breaker", func(t *testing.T) {
		v := newTestView(t, "// b0\nc0\n// b1\nc1\n// b2\nc2\n")
		v.SetDocRenderDefault(true)
		v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
			{StartLine: 0, EndLine: 0, ContentHash: 1, ShellKind: "line", Dialect: "godoc"},
			{StartLine: 2, EndLine: 2, ContentHash: 2, ShellKind: "line", Dialect: "godoc"},
			{StartLine: 4, EndLine: 4, ContentHash: 3, ShellKind: "line", Dialect: "godoc"},
		})
		for i := range 3 {
			id := v.docs.blocks[i].blockID
			v.InstallPreparedDocBlock(PreparedDocBlock{
				DocGeneration: 1, Revision: v.Revision(), BlockID: id, ContentHash: uint64(i + 1),
				Doc: makeTestMarkdownDoc(fmt.Sprintf("Block %d", i)),
			})
		}

		// Inject deterministic clock: each block layout takes 300 µs (below 2 ms breaker).
		// Frame 1 checks elapsed after block 0 (300 µs < 500 µs), lays out block 1 (600 µs >= 500 µs),
		// defers block 2 to frame 2 with RequestFrame().
		now := time.Unix(1000, 0)
		// docNow() is called at: frameStart (1), start b0 (2), end b0 (3), check b1 (4), start b1 (5), end b1 (6), check b2 (7).
		steps := []time.Duration{
			0,
			0, 300 * time.Microsecond, // b0 takes 300µs
			0, 0, 300 * time.Microsecond, // b1 takes 300µs (total 600µs >= 500µs)
			0, // check before b2 sees 600µs >= 500µs -> defers b2
		}
		stepIdx := 0
		v.docs.nowFn = func() time.Time {
			if stepIdx < len(steps) {
				now = now.Add(steps[stepIdx])
				stepIdx++
			}
			return now
		}
		canvas := new(gfx.Canvas)
		canvas.BeginFrame()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
		canvas.EndFrame()
		if !v.DocBlockRendered(0) || !v.DocBlockRendered(2) || v.DocBlockRendered(4) {
			t.Fatalf("expected 500us frame budget to activate b0 & b1 and defer b2: active=(%v,%v,%v)",
				v.DocBlockRendered(0), v.DocBlockRendered(2), v.DocBlockRendered(4))
		}
		if _, requested := canvas.NextFrame(); !requested {
			t.Fatal("expected RequestFrame when 500us budget deferred remaining visible blocks")
		}

		// Frame 2: make b2 take 20 ms -> triggers single-block slow circuit breaker!
		steps = []time.Duration{
			0,                        // frameStart
			0, 20 * time.Millisecond, // b2 takes 20ms > docLayoutSlowLimit!
		}
		stepIdx = 0
		canvas.Reset()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
		if v.DocBlockRendered(4) || !v.docs.blocks[2].rejectedSlow {
			t.Fatalf("expected b2 to trip slow-block circuit breaker: active=%v rejectedSlow=%v",
				v.DocBlockRendered(4), v.docs.blocks[2].rejectedSlow)
		}

		// Subsequent paint at same (hash, width, fontKey) must NOT retry b2!
		clockCalls := 0
		v.docs.nowFn = func() time.Time {
			clockCalls++
			return now
		}
		canvas.Reset()
		v.Paint(canvas, gfx.Rect{Width: 600, Height: 400}, Look{})
		if v.DocBlockRendered(4) || clockCalls != 0 {
			t.Fatalf("rejectedSlow block retried on same geometry: active=%v clockCalls=%d", v.DocBlockRendered(4), clockCalls)
		}
	})
}

func TestDocBlockTextOffsetScrollAnchoring(t *testing.T) {
	// 1. Top row is displayTextRow: activating doc block above viewport keeps top code line fixed.
	t.Run("text-row-anchor-on-toggle", func(t *testing.T) {
		var sb strings.Builder
		sb.WriteString("// doc line 0\n// doc line 1\n")
		for i := range 60 {
			fmt.Fprintf(&sb, "line_%02d := %d\n", i, i)
		}
		v := newTestView(t, sb.String())
		v.SetDocRenderDefault(false)
		v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
			{StartLine: 0, EndLine: 1, ContentHash: 5, ShellKind: "line", Dialect: "godoc"},
		})
		id := v.docs.blocks[0].blockID
		v.InstallPreparedDocBlock(PreparedDocBlock{
			DocGeneration: 1, Revision: v.Revision(), BlockID: id, ContentHash: 5,
			Doc: makeTestMarkdownDoc("# Tall Doc\n\nP1.\n\nP2.\n\nP3.\n\nP4.\n\nP5."),
		})
		canvas := new(gfx.Canvas)
		area := gfx.Rect{Width: 500, Height: 240}
		v.Paint(canvas, area, Look{})
		// Lay out while visible, then toggle off and scroll down to line 20 + 4px.
		v.ToggleDocBlock(0)
		canvas.Reset()
		v.Paint(canvas, area, Look{})
		if !v.DocBlockRendered(0) {
			t.Fatal("expected block 0 to render")
		}
		v.ToggleDocBlock(0)
		part := float32(4)
		v.scroll = float32(v.lineRow(20))*v.lineH + part
		canvas.Reset()
		v.Paint(canvas, area, Look{})

		// Toggle doc block 0 (above viewport) back ON: line 20 must remain at exact same pixel!
		v.ToggleDocBlock(0)
		wantScroll := float32(v.lineRow(20))*v.lineH + part
		if math.Abs(float64(v.scroll-wantScroll)) > 0.05 {
			t.Fatalf("after activating doc above viewport: scroll=%v, want %v", v.scroll, wantScroll)
		}
	})

	// 2. Top row is displayDocBlock: resizing viewport preserves rendered text offset!
	t.Run("doc-block-text-offset-anchor-on-resize", func(t *testing.T) {
		var md strings.Builder
		for i := range 24 {
			fmt.Fprintf(&md, "Paragraph %02d contains multiple words so that resizing the editor width reflows the wrapped lines noticeably across widths.\n\n", i)
		}
		v, canvas := setupSimpleDocView(t, "// tall doc\n// end\nfunc after() {}\n", []DocBlockCandidate{
			{StartLine: 0, EndLine: 1, ContentHash: 88, ShellKind: "line", Dialect: "godoc"},
		}, map[uint64]markdown.Document{88: makeTestMarkdownDoc(md.String())}, nil)

		wide := gfx.Rect{Width: 720, Height: 200}
		narrow := gfx.Rect{Width: 340, Height: 200}
		canvas.Reset()
		v.Paint(canvas, wide, Look{})
		v.scroll = v.maxScroll() / 2
		canvas.Reset()
		v.Paint(canvas, wide, Look{})

		entry := &v.docs.blocks[0]
		beforeOff, ok := entry.view.OffsetAt(gfx.Point{X: v.textLeft + docContentInsetX, Y: wide.Y})
		if !ok || beforeOff <= 0 {
			t.Fatalf("failed to capture rendered offset before resize: off=%d ok=%v", beforeOff, ok)
		}
		// Resize narrower: block reflows taller, scroll must follow beforeOff!
		canvas.Reset()
		v.Paint(canvas, narrow, Look{})
		afterOff, ok := entry.view.OffsetAt(gfx.Point{X: v.textLeft + docContentInsetX, Y: narrow.Y})
		if !ok {
			t.Fatal("failed to read rendered offset after resize")
		}
		if diff := absInt(afterOff - beforeOff); diff > 64 {
			t.Fatalf("resize jumped rendered text offset: before=%d after=%d (diff=%d)", beforeOff, afterOff, diff)
		}

		// Font size change: rendered text offset stays pinned across font resize too!
		beforeFontOff := afterOff
		v.SetFont(Font{Size: 18, LineSpacing: 1.4})
		canvas.Reset()
		v.Paint(canvas, narrow, Look{})
		afterFontOff, ok := entry.view.OffsetAt(gfx.Point{X: v.textLeft + docContentInsetX, Y: narrow.Y})
		if !ok {
			t.Fatal("failed to read rendered offset after font change")
		}
		if diff := absInt(afterFontOff - beforeFontOff); diff > 64 {
			t.Fatalf("font change jumped rendered text offset: before=%d after=%d (diff=%d)", beforeFontOff, afterFontOff, diff)
		}
	})

	// 3. Rule-only doc block (TextLen() == 0) uses proportional fallback without panicking.
	t.Run("empty-text-proportional-fallback", func(t *testing.T) {
		var ruleDoc markdown.Document
		for range 12 {
			ruleDoc.AppendRule(0)
		}
		v, canvas := setupSimpleDocView(t, "// rules\nfunc after() {}\n", []DocBlockCandidate{
			{StartLine: 0, EndLine: 0, ContentHash: 99, ShellKind: "line", Dialect: "godoc"},
		}, map[uint64]markdown.Document{99: ruleDoc}, nil)
		area := gfx.Rect{Width: 500, Height: 120}
		canvas.Reset()
		v.Paint(canvas, area, Look{})
		if v.docs.blocks[0].view.TextLen() != 0 {
			t.Fatalf("expected TextLen()==0, got %d", v.docs.blocks[0].view.TextLen())
		}
		v.scroll = v.maxScroll() / 2
		canvas.Reset()
		v.Paint(canvas, area, Look{})
		// Resize: should keep proportional scroll cleanly.
		canvas.Reset()
		v.Paint(canvas, gfx.Rect{Width: 320, Height: 120}, Look{})
		if v.scroll <= 0 {
			t.Fatalf("proportional fallback lost scroll position: %v", v.scroll)
		}
	})
}

func TestDocBlockRenderingAndInteractions(t *testing.T) {
	text := strings.Join([]string{
		"package demo",
		"// doc 1 line 1",
		"// doc 1 line 2",
		"func One() {}",
		"// doc 2 line 1",
		"// doc 2 line 2",
		"func Two() {}",
		"func Three() {}",
	}, "\n")

	var doc1 markdown.Document
	doc1.AppendHeading(0, 2, []markdown.Span{{Text: "Overview"}})
	doc1.AppendParagraph(0, 0, []markdown.Span{
		{Text: "See "},
		{Text: "External", Link: "https://example.com"},
		{Text: " and "},
		{Text: "Details", Link: "anchor:details"},
	})
	var doc2 markdown.Document
	doc2.AppendHeading(0, 2, []markdown.Span{{Text: "Details"}})
	doc2.AppendParagraph(0, 0, []markdown.Span{{Text: "Details body."}})

	v := newTestView(t, text)
	var tree gfx.Tree
	scope := tree.Feature("editor")
	v.Bind(tree.ID(scope, "hit"), scope)
	v.SetDocBlockIcons(testDocRenderIcon, testDocEditIcon)
	v.SetDocRenderDefault(true)
	var clickedDest string
	var clickedBlockID uint64
	v.SetDocBlockCallbacks(DocBlockCallbacks{
		RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
			switch contentHash {
			case 1:
				v.InstallPreparedDocBlock(PreparedDocBlock{
					DocGeneration: docGen, Revision: revision, BlockID: blockID, ContentHash: contentHash,
					Doc: doc1, Anchors: []DocBlockAnchor{{ID: "overview", BlockIndex: 0}},
				})
			case 2:
				v.InstallPreparedDocBlock(PreparedDocBlock{
					DocGeneration: docGen, Revision: revision, BlockID: blockID, ContentHash: contentHash,
					Doc: doc2, Anchors: []DocBlockAnchor{{ID: "details", BlockIndex: 0}},
				})
			}
		},
		OnLinkClick: func(dest string, blockID uint64) {
			clickedDest = dest
			clickedBlockID = blockID
		},
	})
	v.SetDocBlockCandidates(1, v.Revision(), []DocBlockCandidate{
		{StartLine: 1, EndLine: 2, ContentHash: 1, ShellKind: "line", Dialect: "godoc"},
		{StartLine: 4, EndLine: 5, ContentHash: 2, ShellKind: "line", Dialect: "godoc"},
	})

	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 640, Height: 400}
	look := Look{Dark: true, Background: gfx.RGB24(0x1E1F22), Foreground: gfx.RGB24(0xBCBEC4), Subtle: gfx.RGB24(0x6F737A)}
	v.Paint(canvas, area, look)

	if !v.DocBlockRendered(1) || !v.DocBlockRendered(4) {
		t.Fatal("expected both doc blocks rendered")
	}

	// 1. KeyDown from line 0 steps cleanly across rendered block 1..2 to line 3 without expanding!
	v.moveTo(0, false)
	v.press(gfx.KeyDown, 0)
	if line, _ := v.Caret(); line != 3 {
		t.Fatalf("KeyDown across doc block landed on line %d, want 3", line)
	}
	if !v.DocBlockRendered(1) {
		t.Fatal("KeyDown across doc block must not expand it")
	}
	// KeyUp from line 3 steps cleanly back across block 1..2 to line 0 without expanding!
	v.press(gfx.KeyUp, 0)
	if line, _ := v.Caret(); line != 0 {
		t.Fatalf("KeyUp across doc block landed on line %d, want 0", line)
	}
	if !v.DocBlockRendered(1) {
		t.Fatal("KeyUp across doc block must not expand it")
	}

	// 2. Link hits & Owns & anchor jump.
	if len(v.docs.paintedLinks) == 0 {
		t.Fatal("expected painted doc link spans")
	}
	extLinkID := scope.At(v.docs.paintedLinks[0].base)
	anchorLinkID := scope.At(v.docs.paintedLinks[0].base + 1)
	if !v.Owns(extLinkID) {
		t.Fatal("v.Owns must return true for doc link hit ID")
	}
	// Click external link -> fires OnLinkClick(dest, blockID).
	res, ok := v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, Target: extLinkID})
	if !ok || !res.Handled || clickedDest != "https://example.com" || clickedBlockID != v.docs.blocks[0].blockID {
		t.Fatalf("external link click = (%+v, %v, %q, %d)", res, ok, clickedDest, clickedBlockID)
	}
	// Click anchor:details -> jumps directly via JumpToDocAnchor without calling OnLinkClick.
	clickedDest = ""
	smallArea := gfx.Rect{Width: 640, Height: 60}
	canvas.Reset()
	v.Paint(canvas, smallArea, look)
	res, ok = v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, Target: anchorLinkID})
	if !ok || !res.Handled || clickedDest != "" {
		t.Fatalf("anchor link click = (%+v, %v, clickedDest=%q)", res, ok, clickedDest)
	}
	if v.scroll <= 0 {
		t.Fatalf("anchor:details jump did not scroll down: scroll=%v", v.scroll)
	}
	v.scroll = 0
	canvas.Reset()
	v.Paint(canvas, area, look)

	// 3. Single click and secondary click inside rendered doc block do NOT expand it;
	//    DocBlockAtPoint reports (startLine, rendered=true, ok=true).
	ab0 := v.docs.active[0]
	bodyX := v.textLeft + 24
	bodyY := area.Y + (float32(ab0.displayStartRow)+0.5)*v.lineH - v.scroll
	startLine, rendered, found := v.DocBlockAtPoint(bodyX, bodyY)
	if !found || startLine != 1 || !rendered {
		t.Fatalf("DocBlockAtPoint = (%d, %v, %v), want (1, true, true)", startLine, rendered, found)
	}
	v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 1, Target: v.cfg.HitID, X: bodyX, Y: bodyY})
	if !v.DocBlockRendered(1) {
		t.Fatal("single click must not expand rendered doc block")
	}
	secRes, secOK := v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonSecondary, ClickCount: 1, Target: v.cfg.HitID, X: bodyX, Y: bodyY})
	if !secOK || secRes.Handled || !v.DocBlockRendered(1) {
		t.Fatalf("secondary click should leave unhandled for context menu without expanding: res=%+v ok=%v rendered=%v", secRes, secOK, v.DocBlockRendered(1))
	}

	// 4. Double-clicking anywhere inside rendered doc block expands to source and places caret on StartLine!
	dblRes, dblOK := v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 2, Target: v.cfg.HitID, X: bodyX, Y: bodyY})
	if !dblOK || !dblRes.Handled || v.DocBlockRendered(1) {
		t.Fatalf("double-click did not expand doc block: res=%+v ok=%v rendered=%v", dblRes, dblOK, v.DocBlockRendered(1))
	}
	if line, col := v.Caret(); line != 1 || col != 0 {
		t.Fatalf("double-click caret = (%d,%d), want (1,0)", line, col)
	}
	startLine, rendered, found = v.DocBlockAtPoint(bodyX, area.Y+1.5*v.lineH-v.scroll)
	if !found || startLine != 1 || rendered {
		t.Fatalf("DocBlockAtPoint in source mode = (%d, %v, %v), want (1, false, true)", startLine, rendered, found)
	}

	// 5. Clicking gutter toggle icon re-renders block 1!
	gutterClickX := v.docs.gutterX + docToggleWidth/2
	gutterClickY := area.Y + float32(v.lineRow(1))*v.lineH + v.lineH/2 - v.scroll
	gRes, gOK := v.Pointer(gfx.PointerEvent{Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary, ClickCount: 1, Target: v.cfg.HitID, X: gutterClickX, Y: gutterClickY})
	if !gOK || !gRes.Handled || !v.DocBlockRendered(1) {
		t.Fatalf("gutter toggle click did not re-render block 1: res=%+v ok=%v rendered=%v", gRes, gOK, v.DocBlockRendered(1))
	}

	// 6. GoToNavigation, SetSelection (search jump), and IME auto-expand!
	if !v.GoToNavigation(2, 0, false) || v.DocBlockRendered(1) {
		t.Fatal("GoToNavigation into doc block lines must auto-expand it")
	}
	v.SetAllDocBlocksRendered(true)
	if !v.DocBlockRendered(1) || !v.DocBlockRendered(4) {
		t.Fatal("SetAllDocBlocksRendered(true) did not restore both blocks")
	}
	if !v.SetSelection(v.text.LineStart(5), v.text.LineEnd(5)) || v.DocBlockRendered(4) {
		t.Fatal("SetSelection (search jump) into doc block must auto-expand it")
	}
	v.SetAllDocBlocksRendered(true)
	// Place caret silently at line 4 (without moveTo) and start IME composition.
	v.anchor, v.caret = v.text.LineStart(4), v.text.LineStart(4)
	v.applyText(app.TextEvent{Kind: app.TextSetMarked, Text: "注"})
	if v.DocBlockRendered(4) {
		t.Fatal("IME composition inside rendered doc block must auto-expand it")
	}
	v.applyText(app.TextEvent{Kind: app.TextUnmark})

	// 7. Minimap renders doc block rows as placeholder bars without duplicating source lines.
	v.SetAllDocBlocksRendered(true)
	v.SetMinimap(true)
	canvas.Reset()
	v.Paint(canvas, gfx.Rect{Width: 800, Height: 400}, look)
	if len(v.mm.marks) == 0 {
		t.Fatal("expected minimap marks with rendered doc blocks")
	}
	ab0 = v.docs.active[0]
	docMarks := 0
	for _, m := range v.mm.marks {
		if int(m.row) >= ab0.displayStartRow && int(m.row) < ab0.displayStartRow+ab0.rows {
			docMarks++
		}
	}
	if docMarks != ab0.rows {
		t.Fatalf("minimap doc block marks = %d, want 1 placeholder bar per rendered row (%d)", docMarks, ab0.rows)
	}

	// 8. ClearDocBlocks cleans up cleanly.
	v.ClearDocBlocks()
	if v.ActiveDocBlockCount() != 0 || len(v.docs.blocks) != 0 {
		t.Fatalf("ClearDocBlocks left state behind: active=%d blocks=%d", v.ActiveDocBlockCount(), len(v.docs.blocks))
	}
}

func TestDocBlockTallBlockExceedingViewportPaintedOnce(t *testing.T) {
	var md strings.Builder
	for i := range 60 {
		fmt.Fprintf(&md, "UniqueSectionMarker%02d with descriptive text.\n\n", i)
	}
	v, canvas := setupSimpleDocView(t, "// tall\nfunc end() {}", []DocBlockCandidate{
		{StartLine: 0, EndLine: 0, ContentHash: 42, ShellKind: "line", Dialect: "godoc"},
	}, map[uint64]markdown.Document{42: makeTestMarkdownDoc(md.String())}, nil)

	// Short viewport (120px) over a very tall rendered block.
	area := gfx.Rect{Width: 600, Height: 120}
	canvas.Reset()
	v.Paint(canvas, area, Look{Dark: true, Foreground: gfx.RGB24(0xBCBEC4), Subtle: gfx.RGB24(0x6F737A)})
	ab := v.docs.active[0]
	if float32(ab.rows)*v.lineH <= area.Height*3 {
		t.Fatalf("expected tall block exceeding viewport, got height=%v viewport=%v", float32(ab.rows)*v.lineH, area.Height)
	}
	// Scroll midway through the tall block.
	v.scroll = float32(ab.rows) * v.lineH / 2
	canvas.Reset()
	v.Paint(canvas, area, Look{Dark: true, Foreground: gfx.RGB24(0xBCBEC4), Subtle: gfx.RGB24(0x6F737A)})

	// Each visible marker must appear at most once (proving tall block painted once, clipped to viewport).
	counts := map[string]int{}
	for _, txt := range canvas.Texts() {
		if strings.Contains(txt.Value, "UniqueSectionMarker") {
			counts[txt.Value]++
		}
	}
	if len(counts) == 0 || len(counts) >= 30 {
		t.Fatalf("expected only visible slice of tall block painted, got %d visible markers", len(counts))
	}
	for val, n := range counts {
		if n != 1 {
			t.Fatalf("tall block text %q painted %d times, want 1", val, n)
		}
	}
}

func TestDocBlockLinkCleanupAndUnmatchedAnchor(t *testing.T) {
	var doc markdown.Document
	doc.Reset()
	doc.AppendParagraph(0, 0, []markdown.Span{
		{Text: "Missing anchor", Link: "anchor:does-not-exist"},
	})

	var clicked []string
	v, canvas := setupSimpleDocView(t, "// link doc\nfunc end() {}", []DocBlockCandidate{
		{StartLine: 0, EndLine: 0, ContentHash: 99, ShellKind: "line", Dialect: "godoc"},
	}, map[uint64]markdown.Document{99: doc}, nil)
	var tree gfx.Tree
	scope := tree.Feature("editor-link-cleanup")
	v.Bind(tree.ID(scope, "hit"), scope)
	v.docs.cb.OnLinkClick = func(dest string, _ uint64) { clicked = append(clicked, dest) }

	area := gfx.Rect{Width: 600, Height: 240}
	canvas.Reset()
	v.Paint(canvas, area, Look{Dark: true, Foreground: gfx.RGB24(0xBCBEC4), Subtle: gfx.RGB24(0x6F737A)})
	if len(v.docs.paintedLinks) == 0 {
		t.Fatal("expected paintedLinks to record the rendered anchor link")
	}

	// Clicking an unmatched anchor: link must be swallowed without invoking OnLinkClick.
	linkHit := scope.At(v.docs.paintedLinks[0].base)
	res, ok := v.Pointer(gfx.PointerEvent{Target: linkHit, Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary})
	if !ok || !res.Handled {
		t.Fatalf("expected unmatched anchor press to be handled, got ok=%v res=%+v", ok, res)
	}
	if len(clicked) != 0 {
		t.Fatalf("unmatched anchor: link leaked to OnLinkClick: %v", clicked)
	}

	// Toggling the last rendered doc block back to source must clear paintedLinks on the next paint.
	if !v.ToggleDocBlock(0) {
		t.Fatal("expected ToggleDocBlock(0) to toggle back to source")
	}
	canvas.Reset()
	v.Paint(canvas, area, Look{Dark: true, Foreground: gfx.RGB24(0xBCBEC4), Subtle: gfx.RGB24(0x6F737A)})
	if len(v.docs.paintedLinks) != 0 {
		t.Fatalf("paintedLinks = %d after toggling off last doc block, want 0", len(v.docs.paintedLinks))
	}
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func benchDocBlockView(b *testing.B, canvas *gfx.Canvas) *View {
	b.Helper()
	var sb strings.Builder
	var cands []DocBlockCandidate
	mdByHash := make(map[uint64]markdown.Document)
	line := 0
	for i := range 20 {
		fmt.Fprintf(&sb, "// Function %d documentation summary.\n// Describes parameters and return behavior.\nfunc Func%d(x int) int {\n\treturn x + %d\n}\n\n", i, i, i)
		hash := uint64(i + 1)
		cands = append(cands, DocBlockCandidate{StartLine: line, EndLine: line + 1, ContentHash: hash, ShellKind: "line", Dialect: "godoc"})
		mdByHash[hash] = makeTestMarkdownDoc(fmt.Sprintf("**Func%d** computes `x + %d`.\n\n- Fast path\n- Zero allocations", i, i))
		line += 6
	}
	cfg := Config{
		HitID:           gfx.Item(1),
		Label:           "bench-doc",
		Content:         Prepare([]byte(sb.String())),
		OnEdit:          func(Edit) {},
		MinimapID:       gfx.Item(2),
		MinimapToggleID: gfx.Item(3),
		VerticalBarID:   gfx.Item(4),
		HorizontalBarID: gfx.Item(5),
	}
	v := New(cfg)
	b.Cleanup(v.Close)
	v.hl.Close()
	v.SetDocBlockIcons(testDocRenderIcon, testDocEditIcon)
	v.SetDocRenderDefault(true)
	v.SetDocBlockCallbacks(DocBlockCallbacks{
		RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
			v.InstallPreparedDocBlock(PreparedDocBlock{
				DocGeneration: docGen, Revision: revision, BlockID: blockID, ContentHash: contentHash,
				Doc: mdByHash[contentHash],
			})
		},
	})
	v.SetDocBlockCandidates(1, v.Revision(), cands)

	// Warm all blocks across the scroll range so steady Paint & Scroll have warm views.
	for i := range cands {
		v.scroll = float32(v.lineRow(cands[i].StartLine)) * max(v.lineH, 18)
		frame(v, canvas)
		frame(v, canvas)
	}
	v.scroll = float32(v.lineRow(cands[5].StartLine)) * v.lineH
	frame(v, canvas)
	frame(v, canvas)
	if v.ActiveDocBlockCount() == 0 {
		b.Fatal("benchDocBlockView has no active doc blocks")
	}
	return v
}

func BenchmarkDocBlockPaint(b *testing.B) {
	b.ReportAllocs()
	canvas := new(gfx.Canvas)
	v := benchDocBlockView(b, canvas)
	for b.Loop() {
		frame(v, canvas)
	}
}

func BenchmarkDocBlockScroll(b *testing.B) {
	b.ReportAllocs()
	canvas := new(gfx.Canvas)
	v := benchDocBlockView(b, canvas)
	step := 3 * v.lineH
	// Warm the exact two scroll positions before timing so canvas buffers are sized.
	v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: step, Precise: true})
	frame(v, canvas)
	v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: -step, Precise: true})
	frame(v, canvas)
	for i := 0; b.Loop(); i++ {
		delta := step
		if i%2 != 0 {
			delta = -step
		}
		res, ok := v.Scroll(gfx.ScrollEvent{Target: v.cfg.HitID, DeltaY: delta, Precise: true})
		if !ok || !res.Repaint {
			b.Fatalf("iteration %d did not scroll", i)
		}
		frame(v, canvas)
	}
}
