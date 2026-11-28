package editorview

import (
	"math"
	"slices"
	"sort"
	"strings"
	"time"
	"unsafe"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/base"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
)

var (
	docSyntaxComment  = syntax.Intern("comment")
	docSyntaxString   = syntax.Intern("string")
	docSyntaxNumber   = syntax.Intern("constant.numeric")
	docSyntaxKeyword  = syntax.Intern("keyword")
	docSyntaxFunction = syntax.Intern("entity.name.function")
	docSyntaxVariable = syntax.Intern("variable")
	docSyntaxFlag     = syntax.Intern("entity.other.attribute-name")
	docSyntaxKey      = syntax.Intern("support.type.property-name")
)

// DocBlockCandidate describes one comment range eligible for native in-editor
// Markdown rendering. StartLine and EndLine are zero-based inclusive document
// line numbers.
type DocBlockCandidate struct {
	StartLine, EndLine int
	ContentHash        uint64
	ShellKind, Dialect string
}

// DocBlockAnchor maps a local anchor identifier inside a rendered doc block to
// the top-level markdown.Document block index produced for it.
type DocBlockAnchor struct {
	ID         string
	BlockIndex int
}

// PreparedDocBlock carries a background-parsed markdown.Document and its local
// anchor table for one specific document generation, revision, block identity,
// and content fingerprint.
type PreparedDocBlock struct {
	DocGeneration    uint64
	Revision         int
	BlockID          uint64
	ContentHash      uint64
	Doc              markdown.Document
	Anchors          []DocBlockAnchor
	EstimatedIRBytes int
}

// DocBlockCallbacks wires host-side parsing, link activation, and fenced-code
// syntax highlighting for rendered doc blocks.
type DocBlockCallbacks struct {
	RequestParse  func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string)
	OnLinkClick   func(dest string, blockID uint64)
	HighlightCode func(language, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun
}

const (
	// docLinkPartBase reserves parts 0..3 of the Control's parts scope for the
	// minimap, minimap toggle, vertical scrollbar and horizontal scrollbar.
	docLinkPartBase = 4

	// Gutter toggle icon geometry.
	docToggleWidth    = float32(14)
	docToggleIconSize = float32(11)

	// Rendered doc block visual geometry inside the text area.
	docBlockPadY      = float32(6)
	docAccentBarWidth = float32(2)
	docAccentPadY     = float32(4)
	docContentInsetX  = float32(12)
	docContentPadR    = float32(12)

	// Static admission caps enforced before laying out any PreparedDocBlock.
	docMaxBlocks    = 256
	docMaxTextBytes = 32 << 10
	docMaxSpans     = 1024

	// Cache ceilings and per-frame / per-block time budgets.
	// docLayoutFrameLimit slices multi-block layout across frames; docLayoutSlowLimit
	// bounds any single pathological block while tolerating cold OS/CJK font shaping.
	docCacheMaxBytes    = 512 << 10
	docCacheMaxEntries  = 32
	docLayoutFrameLimit = 500 * time.Microsecond
	docLayoutSlowLimit  = 16 * time.Millisecond
)

// displayRowKind distinguishes a normal source row (possibly wrapped) from a
// rendered doc comment block row.
type displayRowKind uint8

const (
	displayTextRow displayRowKind = iota
	displayDocBlock
)

// displayRow is the explicit mapping of one visual row in the editor viewport.
type displayRow struct {
	kind  displayRowKind
	line  int
	sub   int
	block int
}

// activeDocBlock is one currently projected rendered doc block in display row
// space. v.docs.active is strictly non-overlapping and sorted by startLine.
type activeDocBlock struct {
	blockID         uint64
	blockIdx        int
	startLine       int
	endLine         int
	baseStartRow    int
	baseEndRow      int
	displayStartRow int
	rows            int
}

type docFontKey struct {
	face        gfx.MonoFace
	size        float32
	lineSpacing float32
	lineH       float32
}

type docBlockEntry struct {
	blockID     uint64
	startLine   int
	endLine     int
	contentHash uint64
	shellKind   string
	dialect     string

	wantRendered   bool
	active         bool
	invalidated    bool
	parseRequested bool

	rejectedAdmission bool
	rejectedSlow      bool
	rejectedSlowHash  uint64
	rejectedSlowWidth float32
	rejectedSlowFont  docFontKey
	deferredEpoch     uint64

	hasDoc           bool
	doc              markdown.Document
	anchors          []DocBlockAnchor
	estimatedIRBytes int
	view             *components.MarkdownView

	inCache     bool
	cachedBytes int
	pinned      bool
	lastUsed    uint64

	measuredHeight  float32
	measuredRows    int
	measuredWidth   float32
	measuredFontKey docFontKey
}

type docLinkSpan struct {
	blockID  uint64
	blockIdx int
	base     int
	count    int
}

type docScrollAnchor struct {
	valid           bool
	isDoc           bool
	blockID         uint64
	startLine       int
	sourceOffset    int
	renderedOffset  int
	useProportional bool
	proportion      float32
	pixelOff        float32
	oldLineH        float32
}

type docBlocksState struct {
	docGen        uint64
	nextBlockID   uint64
	renderDefault bool

	renderIcon gfx.Icon
	editIcon   gfx.Icon
	cb         DocBlockCallbacks

	blocks        []docBlockEntry
	byID          map[uint64]int
	active        []activeDocBlock
	totalRowDelta int
	activeDirty   bool
	activeGen     uint64

	editedThisFrame bool

	cacheBytes     int
	cacheEntries   int
	lruClock       uint64
	budgetEpoch    uint64
	lastPinnedHash uint64

	lastWidth   float32
	lastFontKey docFontKey
	gutterX     float32

	linkScope    gfx.Scope
	paintedLinks []docLinkSpan
	probeCanvas  gfx.Canvas

	paletteTheme        *syntax.Theme
	codePalette         [components.MarkdownCodeClasses]gfx.Color
	minimapCommentColor gfx.Color

	// Test-only deterministic hooks (zero in production).
	nowFn                func() time.Time
	hasBudgetCapOverride bool
	budgetCapOverride    int
}

// SetDocBlockIcons configures the gutter icons shown on a doc comment's first
// line: renderIcon while in source mode, editIcon while rendered.
func (v *View) SetDocBlockIcons(renderIcon, editIcon gfx.Icon) {
	v.docs.renderIcon = renderIcon
	v.docs.editIcon = editIcon
}

// SetDocBlockCallbacks installs host callbacks for async doc-comment parsing,
// link clicks, and fenced code highlighting.
func (v *View) SetDocBlockCallbacks(cb DocBlockCallbacks) {
	v.docs.cb = cb
}

// SetDocRenderDefault controls whether newly discovered doc block candidates
// start with rendered mode requested.
func (v *View) SetDocRenderDefault(on bool) {
	v.docs.renderDefault = on
}

// DocRenderDefault reports whether newly discovered doc block candidates start
// with rendered mode requested.
func (v *View) DocRenderDefault() bool {
	return v.docs.renderDefault
}

// ClearDocBlocks drops all document-scoped doc block candidates, active
// projections, and cached IR/layouts while preserving host callbacks, icons,
// and the render default.
func (v *View) ClearDocBlocks() {
	d := &v.docs
	hadActive := len(d.active) > 0
	if len(d.blocks) == 0 && len(d.active) == 0 && d.cacheEntries == 0 && d.cacheBytes == 0 {
		d.docGen = 0
		d.activeDirty = false
		d.editedThisFrame = false
		return
	}
	clear(d.blocks)
	d.blocks = d.blocks[:0]
	clear(d.byID)
	d.active = d.active[:0]
	d.paintedLinks = d.paintedLinks[:0]
	d.totalRowDelta = 0
	d.activeDirty = false
	d.editedThisFrame = false
	d.cacheBytes = 0
	d.cacheEntries = 0
	d.lastPinnedHash = 0
	d.docGen = 0
	d.budgetEpoch++
	if hadActive {
		d.activeGen++
		v.mm.key.valid = false
		if v.painted {
			v.clampScroll()
		}
	}
}

// SetDocBlockCandidates updates the document's doc comment candidates for the
// exact (docGen, revision), preserving stable block identities, user toggle
// state, and cached IR/layouts for unchanged blocks.
func (v *View) SetDocBlockCandidates(docGen uint64, revision int, candidates []DocBlockCandidate) {
	d := &v.docs
	if revision != v.revision {
		return
	}
	if d.docGen != 0 && docGen < d.docGen {
		return
	}
	var anchor docScrollAnchor
	if v.painted && len(d.active) > 0 {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	if d.docGen != 0 && docGen > d.docGen {
		// New document generation replaces all prior identities and caches.
		clear(d.blocks)
		d.blocks = d.blocks[:0]
		clear(d.byID)
		d.active = d.active[:0]
		d.paintedLinks = d.paintedLinks[:0]
		d.totalRowDelta = 0
		d.cacheBytes = 0
		d.cacheEntries = 0
		d.lastPinnedHash = 0
		d.budgetEpoch++
	}
	d.docGen = docGen

	lines := v.text.LineCount()
	clean := make([]DocBlockCandidate, 0, len(candidates))
	for _, c := range candidates {
		if c.StartLine < 0 || c.EndLine < c.StartLine || c.EndLine >= lines {
			continue
		}
		clean = append(clean, c)
	}
	sort.Slice(clean, func(i, j int) bool {
		if clean[i].StartLine != clean[j].StartLine {
			return clean[i].StartLine < clean[j].StartLine
		}
		return clean[i].EndLine < clean[j].EndLine
	})
	deduped := clean[:0]
	for _, c := range clean {
		if len(deduped) > 0 && c.StartLine <= deduped[len(deduped)-1].EndLine {
			continue
		}
		deduped = append(deduped, c)
	}

	old := d.blocks
	used := make([]bool, len(old))
	matched := make([]int, len(deduped))
	for i := range matched {
		matched[i] = -1
	}

	// Pass 1: exact (startLine, endLine) match.
	for ci, c := range deduped {
		oi := sort.Search(len(old), func(k int) bool { return old[k].startLine >= c.StartLine })
		if oi < len(old) && !used[oi] && old[oi].startLine == c.StartLine && old[oi].endLine == c.EndLine {
			matched[ci] = oi
			used[oi] = true
		}
	}
	// Pass 2: fallback to same startLine for edited comments whose endLine moved.
	for ci, c := range deduped {
		if matched[ci] >= 0 {
			continue
		}
		oi := sort.Search(len(old), func(k int) bool { return old[k].startLine >= c.StartLine })
		if oi < len(old) && !used[oi] && old[oi].startLine == c.StartLine {
			matched[ci] = oi
			used[oi] = true
		}
	}

	// Evict cache accounting for dropped old entries.
	freed := false
	for oi := range old {
		if !used[oi] && old[oi].inCache {
			v.evictDocBlockCache(&old[oi])
			freed = true
		}
	}

	next := make([]docBlockEntry, len(deduped))
	for ci, c := range deduped {
		if oi := matched[ci]; oi >= 0 {
			entry := old[oi]
			sameContent := !entry.invalidated &&
				entry.contentHash == c.ContentHash &&
				entry.shellKind == c.ShellKind &&
				entry.dialect == c.Dialect
			entry.startLine = c.StartLine
			entry.endLine = c.EndLine
			entry.contentHash = c.ContentHash
			entry.shellKind = c.ShellKind
			entry.dialect = c.Dialect
			entry.invalidated = false
			if !sameContent {
				if entry.inCache {
					v.evictDocBlockCache(&entry)
					freed = true
				}
				entry.hasDoc = false
				entry.doc = markdown.Document{}
				entry.anchors = nil
				entry.estimatedIRBytes = 0
				entry.view = nil
				entry.parseRequested = false
				entry.rejectedAdmission = false
				entry.rejectedSlow = false
				entry.deferredEpoch = 0
				entry.measuredHeight = 0
				entry.measuredRows = 0
				entry.measuredWidth = 0
				entry.measuredFontKey = docFontKey{}
				entry.active = false
			}
			next[ci] = entry
			continue
		}
		d.nextBlockID++
		next[ci] = docBlockEntry{
			blockID:      d.nextBlockID,
			startLine:    c.StartLine,
			endLine:      c.EndLine,
			contentHash:  c.ContentHash,
			shellKind:    c.ShellKind,
			dialect:      c.Dialect,
			wantRendered: d.renderDefault,
		}
	}
	d.blocks = next
	v.rebuildDocBlockIndex()
	if freed {
		d.budgetEpoch++
	}
	if v.rebuildActiveDocBlocks() && anchor.valid {
		v.restoreDocScrollAnchor(anchor)
	}
	if v.painted && !d.editedThisFrame && d.cb.RequestParse != nil {
		v.requestVisibleDocBlockParses()
	}
}

// InstallPreparedDocBlock installs a background-parsed IR for one doc block if
// its generation, revision, identity, and content fingerprint still match and
// it passes static admission caps and cache memory admission.
func (v *View) InstallPreparedDocBlock(prepared PreparedDocBlock) bool {
	d := &v.docs
	if prepared.DocGeneration != d.docGen || prepared.Revision != v.revision || prepared.BlockID == 0 {
		return false
	}
	idx, ok := d.byID[prepared.BlockID]
	if !ok || idx < 0 || idx >= len(d.blocks) {
		return false
	}
	entry := &d.blocks[idx]
	if entry.invalidated || entry.contentHash != prepared.ContentHash {
		return false
	}
	entry.parseRequested = false

	blocks, spans, textBytes := measureDocIR(&prepared.Doc)
	if blocks == 0 || blocks > docMaxBlocks || textBytes > docMaxTextBytes || spans > docMaxSpans {
		entry.rejectedAdmission = true
		if entry.inCache {
			v.evictDocBlockCache(entry)
			d.budgetEpoch++
		}
		entry.hasDoc = false
		entry.doc = markdown.Document{}
		entry.anchors = nil
		entry.view = nil
		entry.measuredHeight = 0
		entry.measuredRows = 0
		v.rebuildActiveDocBlocksWithAnchor()
		return false
	}

	irBytes := max(prepared.EstimatedIRBytes, prepared.Doc.AllocatedBytes())
	budgetCap := v.docCacheBudgetBytes()

	// Release any previous cached payload on this entry before reserving the new IR.
	if entry.inCache {
		v.evictDocBlockCache(entry)
	}
	if !v.makeDocCacheRoom(irBytes, 1, budgetCap, entry.blockID) {
		entry.deferredEpoch = d.budgetEpoch
		entry.hasDoc = false
		entry.doc = markdown.Document{}
		entry.view = nil
		entry.measuredHeight = 0
		entry.measuredRows = 0
		v.rebuildActiveDocBlocksWithAnchor()
		return false
	}

	entry.doc = prepared.Doc
	entry.anchors = slices.Clone(prepared.Anchors)
	entry.estimatedIRBytes = prepared.EstimatedIRBytes
	entry.hasDoc = true
	entry.view = nil
	entry.rejectedAdmission = false
	entry.rejectedSlow = false
	entry.deferredEpoch = 0
	entry.inCache = true
	entry.cachedBytes = irBytes
	d.cacheBytes += irBytes
	d.cacheEntries++
	d.lruClock++
	entry.lastUsed = d.lruClock
	return true
}

// ToggleDocBlock toggles rendered mode for the doc comment starting on
// startLine. It enforces same-line mutual exclusion with code folds.
func (v *View) ToggleDocBlock(startLine int) bool {
	d := &v.docs
	idx := v.findDocBlockByStartLine(startLine)
	if idx < 0 {
		return false
	}
	var anchor docScrollAnchor
	if v.painted {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	entry := &d.blocks[idx]
	next := !entry.wantRendered
	if next {
		if _, folded := v.fold.collapsed[startLine]; folded {
			delete(v.fold.collapsed, startLine)
			v.refold()
		}
		entry.wantRendered = true
		entry.deferredEpoch = 0
		if !entry.hasDoc && !entry.parseRequested && !entry.rejectedAdmission && d.cb.RequestParse != nil {
			entry.parseRequested = true
			d.cb.RequestParse(d.docGen, v.revision, entry.blockID, entry.startLine, entry.endLine, entry.contentHash, entry.shellKind, entry.dialect)
		}
	} else {
		entry.wantRendered = false
		entry.pinned = false
		d.budgetEpoch++
	}
	if v.rebuildActiveDocBlocks() && anchor.valid {
		v.restoreDocScrollAnchor(anchor)
	}
	return true
}

// SetAllDocBlocksRendered switches all known doc blocks to rendered (on=true)
// or source (on=false) mode.
func (v *View) SetAllDocBlocksRendered(on bool) {
	d := &v.docs
	if len(d.blocks) == 0 {
		return
	}
	var anchor docScrollAnchor
	if v.painted {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	unfolded := false
	for i := range d.blocks {
		entry := &d.blocks[i]
		if on {
			if _, folded := v.fold.collapsed[entry.startLine]; folded {
				delete(v.fold.collapsed, entry.startLine)
				unfolded = true
			}
			entry.wantRendered = true
			entry.deferredEpoch = 0
		} else {
			entry.wantRendered = false
			entry.pinned = false
		}
	}
	if unfolded {
		v.refold()
	}
	if !on {
		d.budgetEpoch++
	}
	if v.rebuildActiveDocBlocks() && anchor.valid {
		v.restoreDocScrollAnchor(anchor)
	}
	if on && v.painted && !d.editedThisFrame && d.cb.RequestParse != nil {
		v.requestVisibleDocBlockParses()
	}
}

// ActiveDocBlockCount returns how many doc blocks are currently projected in
// rendered form.
func (v *View) ActiveDocBlockCount() int {
	v.ensureActiveDocBlocks()
	return len(v.docs.active)
}

// RequestedDocBlockCount returns how many known doc blocks currently have
// rendering requested, including off-screen candidates waiting for viewport
// layout.
func (v *View) RequestedDocBlockCount() int {
	n := 0
	for i := range v.docs.blocks {
		if v.docs.blocks[i].wantRendered {
			n++
		}
	}
	return n
}

// CanRenderAllDocBlocks reports whether SetAllDocBlocksRendered(true) has work
// to do: either at least one known doc block is not yet requested for
// rendering, or a collapsed fold starting on a doc block's StartLine is
// currently blocking it from projecting.
func (v *View) CanRenderAllDocBlocks() bool {
	for i := range v.docs.blocks {
		entry := &v.docs.blocks[i]
		if !entry.wantRendered {
			return true
		}
		if _, folded := v.fold.collapsed[entry.startLine]; folded {
			return true
		}
	}
	return false
}

// DocBlockCount returns the total number of known doc comment candidates in
// the current document, regardless of whether they are rendered or in source.
func (v *View) DocBlockCount() int {
	return len(v.docs.blocks)
}

// DocBlockAtLine reports whether zero-based source line lies inside a known
// doc comment block (either rendered or in source mode).
func (v *View) DocBlockAtLine(line int) (startLine int, rendered bool, ok bool) {
	idx := v.findDocBlockContainingLine(line)
	if idx < 0 {
		return 0, false, false
	}
	v.ensureActiveDocBlocks()
	entry := &v.docs.blocks[idx]
	return entry.startLine, entry.active, true
}

// DocBlockRendered reports whether the doc block starting on startLine is
// currently projected in rendered form.
func (v *View) DocBlockRendered(startLine int) bool {
	v.ensureActiveDocBlocks()
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].startLine >= startLine })
	return i < len(a) && a[i].startLine == startLine
}

// RenderedDocBlockText returns the plain rendered text of the active rendered
// doc block starting on startLine, for "Copy Rendered Comment Text".
func (v *View) RenderedDocBlockText(startLine int) (string, bool) {
	v.ensureActiveDocBlocks()
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].startLine >= startLine })
	if i >= len(a) || a[i].startLine != startLine {
		return "", false
	}
	entry := &v.docs.blocks[a[i].blockIdx]
	if entry.view != nil {
		n := entry.view.TextLen()
		if n == 0 {
			return "", true
		}
		return entry.view.SelectedText(base.TextRange{Anchor: 0, Focus: n}), true
	}
	if entry.hasDoc {
		return extractDocPlainText(&entry.doc), true
	}
	return "", false
}

// DocBlockAtPoint reports whether window point (x, y) lies on a known doc
// comment block (either rendered or in source mode).
func (v *View) DocBlockAtPoint(x, y float32) (startLine int, rendered bool, ok bool) {
	if !v.painted || v.lineH <= 0 || len(v.docs.blocks) == 0 {
		return 0, false, false
	}
	if y < v.area.Y || y >= v.area.Y+v.area.Height || x < v.area.X || x >= v.textRight {
		return 0, false, false
	}
	row := int((y - v.area.Y + v.scroll) / v.lineH)
	if row < 0 || row >= v.rowCount() {
		return 0, false, false
	}
	dr := v.displayRowAt(row)
	if dr.kind == displayDocBlock {
		ab := v.docs.active[dr.block]
		return ab.startLine, true, true
	}
	idx := v.findDocBlockContainingLine(dr.line)
	if idx < 0 {
		return 0, false, false
	}
	entry := &v.docs.blocks[idx]
	return entry.startLine, entry.active, true
}

// JumpToDocAnchor scrolls the editor to the rendered block section (or source
// block start) matching anchorID.
func (v *View) JumpToDocAnchor(anchorID string) bool {
	return v.JumpToDocAnchorFrom(0, anchorID)
}

// JumpToDocAnchorFrom resolves anchorID inside originBlockID first (when
// non-zero) before falling back to document-order lookup across all blocks.
func (v *View) JumpToDocAnchorFrom(originBlockID uint64, anchorID string) bool {
	if anchorID == "" || len(v.docs.blocks) == 0 {
		return false
	}
	v.ensureActiveDocBlocks()
	jumpTo := func(entry *docBlockEntry, a DocBlockAnchor) bool {
		lineH := max(v.lineH, 1)
		if entry.active {
			abIdx := v.activeDocBlockByStartLine(entry.startLine)
			if abIdx >= 0 {
				ab := v.docs.active[abIdx]
				target := float32(ab.displayStartRow) * lineH
				if entry.view != nil {
					if y, ok := entry.view.BlockAnchorTop(a.BlockIndex); ok {
						target += docBlockPadY + y
					}
				}
				v.scroll = target
				v.reveal = false
				if v.painted {
					v.clampScroll()
				}
				return true
			}
		}
		// Source mode or hidden under outer fold: unfold any hiding fold and jump to StartLine.
		if v.fold.hides(entry.startLine) {
			for start, end := range v.fold.collapsed {
				if start < entry.startLine && entry.startLine <= end {
					delete(v.fold.collapsed, start)
				}
			}
			v.refold()
		}
		v.scroll = float32(v.lineRow(entry.startLine)) * lineH
		v.reveal = false
		if v.painted {
			v.clampScroll()
		}
		return true
	}
	if originBlockID != 0 {
		if idx, ok := v.docs.byID[originBlockID]; ok && idx >= 0 && idx < len(v.docs.blocks) {
			entry := &v.docs.blocks[idx]
			if entry.blockID == originBlockID {
				for _, a := range entry.anchors {
					if a.ID == anchorID {
						return jumpTo(entry, a)
					}
				}
			}
		}
	}
	for i := range v.docs.blocks {
		entry := &v.docs.blocks[i]
		for _, a := range entry.anchors {
			if a.ID == anchorID {
				return jumpTo(entry, a)
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Explicit displayRow mapping (O(log B), 0 allocs; never calls ensureRows when
// unwrapped and unfolded)
// ---------------------------------------------------------------------------

func (v *View) hasActiveDocBlocks() bool {
	if v.docs.activeDirty {
		v.ensureActiveDocBlocks()
	}
	return len(v.docs.active) > 0
}

func (v *View) ensureActiveDocBlocks() {
	if v.docs.activeDirty {
		v.rebuildActiveDocBlocks()
	}
}

func (v *View) markDocBlocksActiveDirty() {
	if len(v.docs.blocks) > 0 || len(v.docs.active) > 0 {
		v.docs.activeDirty = true
	}
}

// displayRowAt resolves a visual display row to either a source displayTextRow
// or a rendered displayDocBlock row.
func (v *View) displayRowAt(row int) displayRow {
	if v.docs.activeDirty {
		v.ensureActiveDocBlocks()
	}
	a := v.docs.active
	if len(a) == 0 {
		line, sub := v.baseRowLine(row)
		return displayRow{kind: displayTextRow, line: line, sub: sub, block: -1}
	}
	rows := v.rowCount()
	if rows <= 0 {
		return displayRow{kind: displayTextRow, block: -1}
	}
	row = min(max(row, 0), rows-1)
	i := sort.Search(len(a), func(k int) bool {
		return a[k].displayStartRow+a[k].rows > row
	})
	if i < len(a) && row >= a[i].displayStartRow {
		return displayRow{
			kind:  displayDocBlock,
			line:  a[i].startLine,
			sub:   row - a[i].displayStartRow,
			block: i,
		}
	}
	delta := 0
	if i > 0 {
		prev := a[i-1]
		delta = (prev.displayStartRow + prev.rows) - prev.baseEndRow
	}
	line, sub := v.baseRowLine(row - delta)
	return displayRow{kind: displayTextRow, line: line, sub: sub, block: -1}
}

func (v *View) docOverlayRowCount() int {
	v.ensureActiveDocBlocks()
	return v.baseRowCount() + v.docs.totalRowDelta
}

func (v *View) docOverlayLineRow(line int) int {
	v.ensureActiveDocBlocks()
	lines := v.text.LineCount()
	if lines <= 0 {
		return 0
	}
	line = min(max(line, 0), lines-1)
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= line })
	if i < len(a) && line >= a[i].startLine {
		return a[i].displayStartRow
	}
	delta := 0
	if i > 0 {
		prev := a[i-1]
		delta = (prev.displayStartRow + prev.rows) - prev.baseEndRow
	}
	return v.baseLineRow(line) + delta
}

func (v *View) docOverlayLineRowEnd(line int) int {
	v.ensureActiveDocBlocks()
	lines := v.text.LineCount()
	if lines <= 0 {
		return 0
	}
	line = min(max(line, 0), lines-1)
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= line })
	if i < len(a) && line >= a[i].startLine {
		return a[i].displayStartRow + a[i].rows
	}
	delta := 0
	if i > 0 {
		prev := a[i-1]
		delta = (prev.displayStartRow + prev.rows) - prev.baseEndRow
	}
	return v.baseLineRowEnd(line) + delta
}

// activeDocBlockAtLine returns the index in v.docs.active covering line
// ([startLine..endLine]), or -1 if none.
func (v *View) activeDocBlockAtLine(line int) int {
	if v.docs.activeDirty {
		v.ensureActiveDocBlocks()
	}
	a := v.docs.active
	if len(a) == 0 {
		return -1
	}
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= line })
	if i < len(a) && line >= a[i].startLine {
		return i
	}
	return -1
}

func (v *View) activeDocBlockByStartLine(startLine int) int {
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].startLine >= startLine })
	if i < len(a) && a[i].startLine == startLine {
		return i
	}
	return -1
}

// docBlockHidesLine reports whether line is a non-first line strictly inside an
// active rendered doc block (StartLine < line <= EndLine).
func (v *View) docBlockHidesLine(line int) bool {
	if v.docs.activeDirty {
		v.ensureActiveDocBlocks()
	}
	a := v.docs.active
	if len(a) == 0 {
		return false
	}
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= line })
	return i < len(a) && line > a[i].startLine && line <= a[i].endLine
}

// stepRowAcrossDocBlocks advances row in direction dir (-1 or +1) past any
// displayDocBlock rows so KeyUp/KeyDown/PageUp/PageDown step cleanly across
// rendered comments without expanding them. Returns -1 if no text row exists in
// that direction.
func (v *View) stepRowAcrossDocBlocks(row, dir int) int {
	if !v.hasActiveDocBlocks() {
		return row
	}
	rows := v.rowCount()
	for row >= 0 && row < rows {
		dr := v.displayRowAt(row)
		if dr.kind != displayDocBlock {
			return row
		}
		ab := v.docs.active[dr.block]
		if dir > 0 {
			row = ab.displayStartRow + ab.rows
		} else {
			row = ab.displayStartRow - 1
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Fold precedence, edit shifting, and auto-expansion on navigation / edit / IME
// ---------------------------------------------------------------------------

// docBlockBlockedByFold reports whether any collapsed fold hides, starts on, or
// partially overlaps [entry.startLine..entry.endLine].
func (v *View) docBlockBlockedByFold(entry *docBlockEntry) bool {
	if len(v.fold.collapsed) == 0 {
		return false
	}
	if v.fold.hides(entry.startLine) {
		return true
	}
	if _, ok := v.fold.collapsed[entry.startLine]; ok {
		return true
	}
	for start, end := range v.fold.collapsed {
		if start <= entry.endLine && end >= entry.startLine {
			return true
		}
	}
	return false
}

// exitDocBlockAtLine enforces same-line mutual exclusion when a fold starting
// on line is collapsed.
func (v *View) exitDocBlockAtLine(line int) {
	idx := v.findDocBlockByStartLine(line)
	if idx < 0 {
		return
	}
	entry := &v.docs.blocks[idx]
	if entry.wantRendered {
		entry.wantRendered = false
		entry.pinned = false
		v.docs.budgetEpoch++
		v.docs.activeDirty = true
	}
}

// expandDocBlockAtLine exits rendered mode for any active doc block containing
// line (used by GoToLine, GoToNavigation, moveTo, IME, etc.).
func (v *View) expandDocBlockAtLine(line int) bool {
	if !v.hasActiveDocBlocks() {
		return false
	}
	abIdx := v.activeDocBlockAtLine(line)
	if abIdx < 0 {
		return false
	}
	return v.expandDocBlockByIndex(v.docs.active[abIdx].blockIdx)
}

// expandDocBlocksInLineRange exits rendered mode for every active doc block
// intersecting [firstLine..lastLine] (used by SetSelection / search jump).
func (v *View) expandDocBlocksInLineRange(firstLine, lastLine int) bool {
	if !v.hasActiveDocBlocks() {
		return false
	}
	if lastLine < firstLine {
		firstLine, lastLine = lastLine, firstLine
	}
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= firstLine })
	if i >= len(a) || a[i].startLine > lastLine {
		return false
	}
	var anchor docScrollAnchor
	if v.painted {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	changed := false
	for ; i < len(a) && a[i].startLine <= lastLine; i++ {
		entry := &v.docs.blocks[a[i].blockIdx]
		if entry.wantRendered {
			entry.wantRendered = false
			entry.pinned = false
			changed = true
		}
	}
	if changed {
		v.docs.budgetEpoch++
		if v.rebuildActiveDocBlocks() && anchor.valid {
			v.restoreDocScrollAnchor(anchor)
		}
	}
	return changed
}

func (v *View) expandDocBlockByIndex(blockIdx int) bool {
	if blockIdx < 0 || blockIdx >= len(v.docs.blocks) {
		return false
	}
	entry := &v.docs.blocks[blockIdx]
	if !entry.wantRendered && !entry.active {
		return false
	}
	var anchor docScrollAnchor
	if v.painted {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	entry.wantRendered = false
	entry.pinned = false
	v.docs.budgetEpoch++
	if v.rebuildActiveDocBlocks() && anchor.valid {
		v.restoreDocScrollAnchor(anchor)
	}
	return true
}

// shiftDocBlocks updates doc block line ranges after an edit replacing lines
// [first..oldLast] with [first..newLast]. Unaffected blocks shift without
// changing blockID; intersected blocks are invalidated/expanded immediately.
func (v *View) shiftDocBlocks(first, oldLast, newLast int) {
	d := &v.docs
	d.editedThisFrame = true
	if len(d.blocks) == 0 {
		return
	}
	delta := newLast - oldLast
	lines := v.text.LineCount()
	kept := d.blocks[:0]
	freed := false
	changed := false
	for i := range d.blocks {
		entry := d.blocks[i]
		switch {
		case entry.endLine < first:
			// Completely above edit: untouched.
			kept = append(kept, entry)
		case entry.startLine > oldLast:
			// Completely below edit: shift range without touching blockID or cache.
			entry.startLine += delta
			entry.endLine += delta
			if entry.startLine >= 0 && entry.endLine >= entry.startLine && entry.endLine < lines {
				kept = append(kept, entry)
				if delta != 0 {
					changed = true
				}
			} else {
				if entry.inCache {
					v.evictDocBlockCache(&entry)
					freed = true
				}
				changed = true
			}
		default:
			// Edit intersected [entry.startLine..entry.endLine]: invalidate & expand to source.
			if entry.inCache {
				v.evictDocBlockCache(&entry)
				freed = true
			}
			changed = true
			// If the edit stayed strictly within the comment's outer span, keep the
			// entry's blockID with wantRendered=false so ongoing edits in source
			// mode do not snap back to rendered when candidates refresh.
			if first >= entry.startLine && oldLast <= entry.endLine {
				entry.endLine += delta
				if entry.endLine >= entry.startLine && entry.endLine < lines {
					entry.wantRendered = false
					entry.active = false
					entry.invalidated = true
					entry.contentHash = 0
					entry.hasDoc = false
					entry.doc = markdown.Document{}
					entry.anchors = nil
					entry.view = nil
					entry.parseRequested = false
					entry.rejectedAdmission = false
					entry.rejectedSlow = false
					entry.deferredEpoch = 0
					entry.measuredHeight = 0
					entry.measuredRows = 0
					entry.measuredWidth = 0
					entry.measuredFontKey = docFontKey{}
					kept = append(kept, entry)
				}
			}
		}
	}
	clear(d.blocks[len(kept):])
	d.blocks = kept
	v.rebuildDocBlockIndex()
	if freed {
		d.budgetEpoch++
	}
	if changed || len(d.active) > 0 {
		d.activeDirty = true
	}
}

func (v *View) rebuildDocBlockIndex() {
	d := &v.docs
	if len(d.blocks) == 0 {
		clear(d.byID)
		return
	}
	if d.byID == nil {
		d.byID = make(map[uint64]int, len(d.blocks))
	} else {
		clear(d.byID)
	}
	for i := range d.blocks {
		d.byID[d.blocks[i].blockID] = i
	}
}

func (v *View) findDocBlockByStartLine(startLine int) int {
	b := v.docs.blocks
	i := sort.Search(len(b), func(k int) bool { return b[k].startLine >= startLine })
	if i < len(b) && b[i].startLine == startLine {
		return i
	}
	return -1
}

func (v *View) findDocBlockContainingLine(line int) int {
	b := v.docs.blocks
	i := sort.Search(len(b), func(k int) bool { return b[k].endLine >= line })
	if i < len(b) && line >= b[i].startLine && line <= b[i].endLine {
		return i
	}
	return -1
}

// rebuildActiveDocBlocks projects all eligible rendered blocks into the sparse
// sorted v.docs.active slice and reports whether the projection changed.
func (v *View) rebuildActiveDocBlocks() bool {
	d := &v.docs
	d.activeDirty = false
	if len(d.blocks) == 0 {
		changed := len(d.active) > 0 || d.totalRowDelta != 0
		d.active = d.active[:0]
		d.totalRowDelta = 0
		if changed {
			d.activeGen++
			v.mm.key.valid = false
		}
		return changed
	}

	prevLen := len(d.active)
	prevDelta := d.totalRowDelta
	// Compare in place against previous entries after rebuilding into scratch?
	// Keep 0 allocs by comparing element-by-element while rewriting or hashing.
	var oldHash uint64
	for _, ab := range d.active {
		oldHash = mixDocHash(oldHash, ab.blockID, ab.startLine, ab.endLine, ab.baseStartRow, ab.baseEndRow, ab.displayStartRow, ab.rows)
	}

	d.active = d.active[:0]
	delta := 0
	lines := v.text.LineCount()
	for i := range d.blocks {
		entry := &d.blocks[i]
		entry.active = false
		if !entry.wantRendered || entry.invalidated || entry.rejectedAdmission || entry.measuredRows <= 0 {
			continue
		}
		if entry.startLine < 0 || entry.endLine < entry.startLine || entry.endLine >= lines {
			continue
		}
		if entry.rejectedSlow &&
			entry.rejectedSlowHash == entry.contentHash &&
			entry.rejectedSlowWidth == d.lastWidth &&
			entry.rejectedSlowFont == d.lastFontKey {
			continue
		}
		if v.docBlockBlockedByFold(entry) {
			continue
		}
		baseStart := v.baseLineRow(entry.startLine)
		baseEnd := v.baseLineRowEnd(entry.endLine)
		if baseEnd <= baseStart {
			continue
		}
		ab := activeDocBlock{
			blockID:         entry.blockID,
			blockIdx:        i,
			startLine:       entry.startLine,
			endLine:         entry.endLine,
			baseStartRow:    baseStart,
			baseEndRow:      baseEnd,
			displayStartRow: baseStart + delta,
			rows:            entry.measuredRows,
		}
		d.active = append(d.active, ab)
		entry.active = true
		delta += ab.rows - (baseEnd - baseStart)
	}
	d.totalRowDelta = delta

	var newHash uint64
	for _, ab := range d.active {
		newHash = mixDocHash(newHash, ab.blockID, ab.startLine, ab.endLine, ab.baseStartRow, ab.baseEndRow, ab.displayStartRow, ab.rows)
	}
	changed := prevLen != len(d.active) || prevDelta != d.totalRowDelta || oldHash != newHash
	if changed {
		d.activeGen++
		v.mm.key.valid = false
	}
	return changed
}

func (v *View) rebuildActiveDocBlocksWithAnchor() {
	var anchor docScrollAnchor
	if v.painted {
		anchor = v.captureDocScrollAnchor(v.lineH, v.area.Y, v.textLeft, v.scrollX)
	}
	if v.rebuildActiveDocBlocks() && anchor.valid {
		v.restoreDocScrollAnchor(anchor)
	}
}

func mixDocHash(h uint64, id uint64, a, b, c, d, e, f int) uint64 {
	const prime = 1099511628211
	h ^= id
	h *= prime
	for _, x := range [6]int{a, b, c, d, e, f} {
		h ^= uint64(x)
		h *= prime
	}
	return h
}

// ---------------------------------------------------------------------------
// Budget admission, LRU cache, typing-frame skip, 500 µs frame budget,
// 2 ms slow-block circuit breaker
// ---------------------------------------------------------------------------

func (v *View) docNow() time.Time {
	if v.docs.nowFn != nil {
		return v.docs.nowFn()
	}
	return time.Now()
}

// docCacheBudgetBytes computes the per-document doc-render cache cap:
//
//	docTotalBudget = 2 MiB + (3 * v.text.Len()) / 2
//	remaining = docTotalBudget - conservativeUsed
//	cap = min(512 KiB, max(0, remaining / 4))
//
// There is intentionally no 64 KiB floor when remaining <= 0.
func (v *View) docCacheBudgetBytes() int {
	if v.docs.hasBudgetCapOverride {
		return max(v.docs.budgetCapOverride, 0)
	}
	textLen := v.text.Len()
	docTotalBudget := (2 << 20) + (3*textLen)/2

	wrapBytes := cap(v.wraps)*int(unsafe.Sizeof(lineWrap{})) +
		cap(v.rowStart)*int(unsafe.Sizeof(int32(0)))
	auxBytes := v.joinedSize +
		len(v.fold.hidden) +
		cap(v.mm.marks)*int(unsafe.Sizeof(minimapMark{})) +
		cap(v.decor.colors)*int(unsafe.Sizeof(colorDecorationSpan{}))
	// Conservative syntax/rope/buffer floor.
	syntaxFloor := (256 << 10) + textLen/4

	used := textLen + wrapBytes + auxBytes + syntaxFloor
	remaining := docTotalBudget - used
	if remaining <= 0 {
		return 0
	}
	return min(docCacheMaxBytes, remaining/4)
}

func (v *View) makeDocCacheRoom(needBytes, needEntries, budgetCap int, skipBlockID uint64) bool {
	d := &v.docs
	if budgetCap <= 0 || needBytes > budgetCap || needEntries > docCacheMaxEntries {
		return false
	}
	for d.cacheBytes+needBytes > budgetCap || d.cacheEntries+needEntries > docCacheMaxEntries {
		victim := -1
		for i := range d.blocks {
			e := &d.blocks[i]
			if !e.inCache || e.pinned || e.blockID == skipBlockID {
				continue
			}
			if victim < 0 || e.lastUsed < d.blocks[victim].lastUsed {
				victim = i
			}
		}
		if victim < 0 {
			return false
		}
		v.evictDocBlockCache(&d.blocks[victim])
	}
	return true
}

// evictDocBlockCache releases heavy IR and MarkdownView memory while preserving
// compact height metadata (measuredHeight, measuredRows, measuredWidth,
// measuredFontKey) so off-screen LRU eviction never shifts scrollbars.
func (v *View) evictDocBlockCache(entry *docBlockEntry) {
	d := &v.docs
	if entry.inCache {
		d.cacheBytes = max(d.cacheBytes-entry.cachedBytes, 0)
		d.cacheEntries = max(d.cacheEntries-1, 0)
		entry.inCache = false
		entry.cachedBytes = 0
	}
	entry.view = nil
	entry.doc = markdown.Document{}
	entry.hasDoc = false
	entry.parseRequested = false
}

func measureDocIR(doc *markdown.Document) (blocks, spans, textBytes int) {
	blocks = len(doc.Blocks)
	for i := range doc.Blocks {
		b := &doc.Blocks[i]
		switch b.Kind {
		case markdown.Code:
			textBytes += len(b.Info) + len(b.Text)
		case markdown.Table:
			for _, cell := range doc.Cells(b) {
				cs := doc.CellSpans(cell)
				spans += len(cs)
				for _, sp := range cs {
					textBytes += len(sp.Text) + len(sp.Link) + len(sp.Image)
				}
			}
		case markdown.Labeled:
			ls := doc.LabelSpans(b)
			spans += len(ls)
			for _, sp := range ls {
				textBytes += len(sp.Text) + len(sp.Link) + len(sp.Image)
			}
			vs := doc.Spans(b)
			spans += len(vs)
			for _, sp := range vs {
				textBytes += len(sp.Text) + len(sp.Link) + len(sp.Image)
			}
		case markdown.Rule:
		default:
			vs := doc.Spans(b)
			spans += len(vs)
			for _, sp := range vs {
				textBytes += len(sp.Text) + len(sp.Link) + len(sp.Image)
			}
		}
	}
	return blocks, spans, textBytes
}

func (v *View) docContentWidth() float32 {
	w := v.textRight - v.textLeft - docContentInsetX - docContentPadR
	return max(float32(math.Floor(float64(w))), 40)
}

func (v *View) currentDocFontKey() docFontKey {
	return docFontKey{
		face:        v.font.Face,
		size:        v.font.Size,
		lineSpacing: v.font.LineSpacing,
		lineH:       v.lineH,
	}
}

func (v *View) docMarkdownStyle() components.MarkdownStyle {
	return components.MarkdownStyle{
		Size:       v.font.Size,
		LineHeight: v.lineH,
		MonoFace:   v.font.Face,
		Highlight:  v.docs.cb.HighlightCode,
	}
}

func (v *View) visibleDocLineBounds() (firstLine, lastLine int, ok bool) {
	return v.visibleDocLineBoundsAt(v.lineH)
}

func (v *View) visibleDocLineBoundsAt(lineH float32) (firstLine, lastLine int, ok bool) {
	rows := v.rowCount()
	if rows <= 0 || lineH <= 0 || v.area.Height <= 0 {
		return 0, 0, false
	}
	firstRow := min(max(int(v.scroll/lineH), 0), rows-1)
	lastRow := min(max(int((v.scroll+v.area.Height)/lineH), firstRow), rows-1)
	firstDR := v.displayRowAt(firstRow)
	lastDR := v.displayRowAt(lastRow)
	firstLine = firstDR.line
	lastLine = lastDR.line
	if lastDR.kind == displayDocBlock {
		lastLine = v.docs.active[lastDR.block].endLine
	}
	return firstLine, lastLine, true
}

func (v *View) requestVisibleDocBlockParses() {
	d := &v.docs
	if d.cb.RequestParse == nil || len(d.blocks) == 0 {
		return
	}
	firstLine, lastLine, ok := v.visibleDocLineBounds()
	if !ok {
		return
	}
	i := sort.Search(len(d.blocks), func(k int) bool { return d.blocks[k].endLine >= firstLine })
	for ; i < len(d.blocks) && d.blocks[i].startLine <= lastLine; i++ {
		entry := &d.blocks[i]
		if !entry.wantRendered || entry.invalidated || entry.rejectedAdmission || entry.hasDoc || entry.parseRequested {
			continue
		}
		if entry.deferredEpoch == d.budgetEpoch || v.docBlockBlockedByFold(entry) {
			continue
		}
		entry.parseRequested = true
		d.cb.RequestParse(d.docGen, v.revision, entry.blockID, entry.startLine, entry.endLine, entry.contentHash, entry.shellKind, entry.dialect)
	}
}

// prepareDocBlocks runs during Paint before painting rows. It coordinates
// wrap/font/width changes, typing-frame layout skipping, bounded 500 µs layout
// slices, 2 ms slow-block circuit breaking, budget admission, and atomic
// activation with text-offset scroll anchoring.
//
// On steady Paint & Scroll with warm doc blocks it allocates 0 B/op.
func (v *View) prepareDocBlocks(canvas *gfx.Canvas, cols int, wasPainted bool, wasLineH, wasAreaY, wasTextLeft, wasScrollX float32) {
	d := &v.docs
	v.ensureActiveDocBlocks()

	contentWidth := v.docContentWidth()
	fontKey := v.currentDocFontKey()
	wrapChanged := cols != v.wrapCols
	lineHChanged := wasLineH != v.lineH

	// Determine visible candidate slice before any changes using wasLineH so
	// font-size changes locate the true visible blocks before scroll conversion.
	queryLineH := v.lineH
	if wasPainted && wasLineH > 0 {
		queryLineH = wasLineH
	}
	visFirst, visLast, hasVis := v.visibleDocLineBoundsAt(queryLineH)
	visIdxLo := len(d.blocks)
	visIdxHi := len(d.blocks)
	if hasVis {
		visIdxLo = sort.Search(len(d.blocks), func(k int) bool { return d.blocks[k].endLine >= visFirst })
		visIdxHi = visIdxLo
		for visIdxHi < len(d.blocks) && d.blocks[visIdxHi].startLine <= visLast {
			visIdxHi++
		}
	}

	// Update pinned state for currently visible blocks without allocating.
	var pinnedHash uint64
	for i := range d.blocks {
		inVis := i >= visIdxLo && i < visIdxHi && d.blocks[i].wantRendered
		d.blocks[i].pinned = inVis
		if inVis {
			pinnedHash = mixDocHash(pinnedHash, d.blocks[i].blockID, i, 0, 0, 0, 0, 0)
		}
	}
	if pinnedHash != d.lastPinnedHash {
		d.lastPinnedHash = pinnedHash
		d.budgetEpoch++
	}

	// Fast check: does any visible block need work on this frame?
	needsWork := wrapChanged || lineHChanged
	hasPendingLayout := false
	hasPendingParse := false
	for i := visIdxLo; i < visIdxHi; i++ {
		e := &d.blocks[i]
		if !e.wantRendered || e.invalidated || e.rejectedAdmission || v.docBlockBlockedByFold(e) {
			continue
		}
		if e.rejectedSlow && e.rejectedSlowHash == e.contentHash && e.rejectedSlowWidth == contentWidth && e.rejectedSlowFont == fontKey {
			if e.active {
				needsWork = true
			}
			continue
		}
		if e.deferredEpoch == d.budgetEpoch {
			continue
		}
		if !e.hasDoc {
			if d.cb.RequestParse != nil && !e.parseRequested {
				hasPendingParse = true
			} else if d.cb.RequestParse == nil && e.active && e.view == nil {
				e.measuredRows = 0
				e.measuredHeight = 0
				needsWork = true
			}
			continue
		}
		if e.view == nil || e.measuredWidth != contentWidth || e.measuredFontKey != fontKey || !e.active {
			hasPendingLayout = true
			needsWork = true
		}
	}

	// Typing frames skip new doc block layout and only request a follow-up frame
	// when visible blocks are still waiting to be laid out or parsed.
	if d.editedThisFrame {
		if wrapChanged || lineHChanged {
			var anchor docScrollAnchor
			if wasPainted {
				anchor = v.captureDocScrollAnchor(wasLineH, wasAreaY, wasTextLeft, wasScrollX)
			}
			v.setWrapColsNoScroll(cols)
			d.lastWidth, d.lastFontKey = contentWidth, fontKey
			v.rebuildActiveDocBlocks()
			if anchor.valid {
				v.restoreDocScrollAnchor(anchor)
			}
		} else {
			d.lastWidth, d.lastFontKey = contentWidth, fontKey
		}
		if hasPendingLayout || hasPendingParse {
			canvas.RequestFrame()
		}
		return
	}

	// Fast steady-state path: nothing changed, nothing to lay out or parse.
	if !needsWork && !hasPendingParse {
		d.lastWidth, d.lastFontKey = contentWidth, fontKey
		for i := visIdxLo; i < visIdxHi; i++ {
			e := &d.blocks[i]
			if e.inCache && e.active {
				d.lruClock++
				e.lastUsed = d.lruClock
			}
		}
		return
	}

	// Capture text-offset scroll anchor BEFORE wrap/layout mutates rows or MarkdownView.
	var anchor docScrollAnchor
	if wasPainted && (wrapChanged || lineHChanged || hasPendingLayout || hasPendingParse) {
		anchor = v.captureDocScrollAnchor(wasLineH, wasAreaY, wasTextLeft, wasScrollX)
	}
	if wrapChanged {
		v.setWrapColsNoScroll(cols)
	}
	d.lastWidth, d.lastFontKey = contentWidth, fontKey

	// Lay out visible pending blocks within the 500 µs per-frame budget.
	style := v.docMarkdownStyle()
	budgetCap := v.docCacheBudgetBytes()
	frameStart := v.docNow()
	layoutsDone := 0
	hasMorePending := false

	for i := visIdxLo; i < visIdxHi && i < len(d.blocks); i++ {
		e := &d.blocks[i]
		if !e.wantRendered || e.invalidated || e.rejectedAdmission || v.docBlockBlockedByFold(e) {
			continue
		}
		if !e.hasDoc {
			if e.deferredEpoch != d.budgetEpoch && d.cb.RequestParse != nil && !e.parseRequested {
				e.parseRequested = true
				d.cb.RequestParse(d.docGen, v.revision, e.blockID, e.startLine, e.endLine, e.contentHash, e.shellKind, e.dialect)
				if i >= len(d.blocks) {
					break
				}
				e = &d.blocks[i]
			}
			if !e.hasDoc || e.rejectedAdmission {
				continue
			}
		}
		if e.view != nil && e.measuredWidth == contentWidth && e.measuredFontKey == fontKey {
			d.lruClock++
			e.lastUsed = d.lruClock
			continue
		}
		if e.rejectedSlow && e.rejectedSlowHash == e.contentHash && e.rejectedSlowWidth == contentWidth && e.rejectedSlowFont == fontKey {
			continue
		}
		if e.deferredEpoch == d.budgetEpoch {
			continue
		}
		if layoutsDone > 0 && v.docNow().Sub(frameStart) >= docLayoutFrameLimit {
			hasMorePending = true
			break
		}
		v.layoutDocBlockEntry(canvas, e, style, contentWidth, fontKey, budgetCap)
		layoutsDone++
	}

	activeChanged := v.rebuildActiveDocBlocks()
	if anchor.valid && (wrapChanged || lineHChanged || activeChanged) {
		v.restoreDocScrollAnchor(anchor)
	}
	if hasMorePending {
		canvas.RequestFrame()
	}
}

func (v *View) layoutDocBlockEntry(canvas *gfx.Canvas, entry *docBlockEntry, style components.MarkdownStyle, contentWidth float32, fontKey docFontKey, budgetCap int) bool {
	d := &v.docs
	irBytes := max(entry.estimatedIRBytes, entry.doc.AllocatedBytes())

	// Conservative pre-layout reservation before building MarkdownView.
	estViewBytes := max(irBytes*2, 4096)
	if entry.view != nil {
		estViewBytes = max(estViewBytes, entry.view.AllocatedBytes())
	}
	estTotal := irBytes + estViewBytes
	needBytes := max(estTotal-entry.cachedBytes, 0)
	needEntry := 0
	if !entry.inCache {
		needEntry = 1
	}
	if !v.makeDocCacheRoom(needBytes, needEntry, budgetCap, entry.blockID) {
		entry.deferredEpoch = d.budgetEpoch
		// If this block was previously active without a live view, return to source.
		if entry.view == nil {
			entry.measuredRows = 0
			entry.measuredHeight = 0
		}
		return false
	}

	if entry.view == nil {
		entry.view = new(components.MarkdownView)
	}
	start := v.docNow()
	height := entry.view.Layout(canvas, style, &entry.doc, contentWidth)
	elapsed := v.docNow().Sub(start)

	// Per-block circuit breaker (> docLayoutSlowLimit): permanently reject for this (blockID, hash, width, fontKey).
	if elapsed > docLayoutSlowLimit {
		entry.view = nil
		entry.rejectedSlow = true
		entry.rejectedSlowHash = entry.contentHash
		entry.rejectedSlowWidth = contentWidth
		entry.rejectedSlowFont = fontKey
		entry.measuredHeight = 0
		entry.measuredRows = 0
		if entry.inCache {
			d.cacheBytes = max(d.cacheBytes-entry.cachedBytes, 0) + irBytes
			entry.cachedBytes = irBytes
		}
		return false
	}

	actualBytes := entry.doc.AllocatedBytes() + entry.view.AllocatedBytes()
	delta := actualBytes - entry.cachedBytes
	if delta > 0 && !v.makeDocCacheRoom(delta, needEntry, budgetCap, entry.blockID) {
		entry.view = nil
		entry.deferredEpoch = d.budgetEpoch
		entry.measuredHeight = 0
		entry.measuredRows = 0
		if entry.inCache {
			d.cacheBytes = max(d.cacheBytes-entry.cachedBytes, 0) + irBytes
			entry.cachedBytes = irBytes
		}
		return false
	}

	d.cacheBytes = max(d.cacheBytes-entry.cachedBytes, 0) + actualBytes
	entry.cachedBytes = actualBytes
	if !entry.inCache {
		entry.inCache = true
		d.cacheEntries++
	}
	d.lruClock++
	entry.lastUsed = d.lruClock

	entry.measuredHeight = height
	entry.measuredRows = max(1, int(math.Ceil(float64(height+2*docBlockPadY)/float64(max(v.lineH, 1)))))
	entry.measuredWidth = contentWidth
	entry.measuredFontKey = fontKey
	entry.deferredEpoch = 0
	return true
}

// ---------------------------------------------------------------------------
// Text-offset scroll anchoring
// ---------------------------------------------------------------------------

func (v *View) captureDocScrollAnchor(oldLineH, oldAreaY, oldTextLeft, oldScrollX float32) docScrollAnchor {
	lineH := max(oldLineH, 1)
	rows := v.rowCount()
	if rows <= 0 {
		return docScrollAnchor{}
	}
	row := min(max(int(v.scroll/lineH), 0), rows-1)
	dr := v.displayRowAt(row)
	if dr.kind == displayTextRow {
		l := v.ref(dr.line)
		wraps := v.rowsOf(l)
		byteAt := 0
		if dr.sub >= 0 && dr.sub < len(wraps) {
			byteAt = wraps[dr.sub].at
		}
		return docScrollAnchor{
			valid:        true,
			isDoc:        false,
			startLine:    dr.line,
			sourceOffset: l.start + byteAt,
			pixelOff:     v.scroll - float32(row)*lineH,
			oldLineH:     lineH,
		}
	}

	ab := v.docs.active[dr.block]
	entry := &v.docs.blocks[ab.blockIdx]
	anchor := docScrollAnchor{
		valid:     true,
		isDoc:     true,
		blockID:   ab.blockID,
		startLine: ab.startLine,
		oldLineH:  lineH,
	}
	blockTop := float32(ab.displayStartRow) * lineH
	blockH := max(float32(ab.rows)*lineH, 1)

	if entry.view != nil && entry.view.TextLen() > 0 {
		blockTextX := oldTextLeft + docContentInsetX - oldScrollX
		if off, ok := entry.view.OffsetAt(gfx.Point{X: blockTextX, Y: oldAreaY}); ok {
			if rect, ok := entry.view.CaretAt(off); ok {
				anchor.renderedOffset = off
				anchor.pixelOff = oldAreaY - rect.Y
				return anchor
			}
		}
	}
	// Fallback to proportional offset only when TextLen() == 0 (or view was unmounted).
	anchor.useProportional = true
	anchor.proportion = min(max((v.scroll-blockTop)/blockH, 0), 1)
	return anchor
}

func (v *View) restoreDocScrollAnchor(anchor docScrollAnchor) {
	if !anchor.valid || v.lineH <= 0 {
		return
	}
	scale := v.lineH / max(anchor.oldLineH, 1)
	if !anchor.isDoc {
		offset := min(max(anchor.sourceOffset, 0), v.text.Len())
		line := v.text.LineOf(offset)
		if abIdx := v.activeDocBlockAtLine(line); abIdx >= 0 {
			ab := v.docs.active[abIdx]
			v.scroll = float32(ab.displayStartRow)*v.lineH + min(max(anchor.pixelOff*scale, 0), float32(ab.rows)*v.lineH)
			return
		}
		l := v.ref(line)
		wraps := v.rowsOf(l)
		sub := 0
		if len(wraps) > 1 {
			sub = rowIndex(wraps, offset-l.start)
		}
		v.scroll = float32(v.lineRow(line)+sub)*v.lineH + anchor.pixelOff*scale
		return
	}

	// Anchored inside a rendered doc block: find it by stable blockID.
	if idx, ok := v.docs.byID[anchor.blockID]; ok && idx >= 0 && idx < len(v.docs.blocks) {
		entry := &v.docs.blocks[idx]
		if entry.active {
			if abIdx := v.activeDocBlockByStartLine(entry.startLine); abIdx >= 0 {
				ab := v.docs.active[abIdx]
				blockTop := float32(ab.displayStartRow) * v.lineH
				blockH := float32(ab.rows) * v.lineH
				if !anchor.useProportional && entry.view != nil && entry.view.TextLen() > 0 {
					if localY, ok := v.docCaretLocalY(entry.view, anchor.renderedOffset); ok {
						v.scroll = blockTop + docBlockPadY + localY + anchor.pixelOff*scale
						return
					}
				}
				v.scroll = blockTop + anchor.proportion*blockH
				return
			}
		}
		// Block switched to source mode: anchor at its StartLine.
		v.scroll = float32(v.lineRow(entry.startLine)) * v.lineH
		return
	}
	v.scroll = float32(v.lineRow(min(max(anchor.startLine, 0), max(v.text.LineCount()-1, 0)))) * v.lineH
}

// docCaretLocalY returns the y coordinate of offset inside mv (relative to mv's
// top-left). When mv was just laid out and has not yet painted, a zero-visible
// clip probe activates CaretAt without emitting draw commands to the real canvas.
func (v *View) docCaretLocalY(mv *components.MarkdownView, offset int) (float32, bool) {
	v.docs.probeCanvas.Reset()
	mv.Paint(&v.docs.probeCanvas, components.MarkdownPaint{
		X:    0,
		Y:    0,
		Clip: gfx.Rect{X: 0, Y: -100000, Width: 1, Height: 1},
	})
	rect, ok := mv.CaretAt(offset)
	if !ok {
		return 0, false
	}
	return rect.Y, true
}

// ---------------------------------------------------------------------------
// Painting (native IDEA-inspired look, 0 allocs/op on steady Paint)
// ---------------------------------------------------------------------------

// docGutterColumn returns the width reserved in the gutter for doc-comment
// toggle icons: zero when there are no doc blocks or no toggle icons configured.
func (v *View) docGutterColumn() float32 {
	if len(v.docs.blocks) == 0 || (v.docs.renderIcon.ViewBox <= 0 && v.docs.editIcon.ViewBox <= 0) {
		return 0
	}
	return docToggleWidth
}

func (v *View) docMarkdownLook(look Look) components.MarkdownLook {
	d := &v.docs
	if d.paletteTheme != v.theme {
		d.paletteTheme = v.theme
		d.codePalette = [components.MarkdownCodeClasses]gfx.Color{}
		if v.theme != nil {
			d.codePalette[components.CodeComment] = uiColor(v.theme.Style(docSyntaxComment).Foreground)
			d.codePalette[components.CodeString] = uiColor(v.theme.Style(docSyntaxString).Foreground)
			d.codePalette[components.CodeNumber] = uiColor(v.theme.Style(docSyntaxNumber).Foreground)
			d.codePalette[components.CodeKeyword] = uiColor(v.theme.Style(docSyntaxKeyword).Foreground)
			d.codePalette[components.CodeFunction] = uiColor(v.theme.Style(docSyntaxFunction).Foreground)
			d.codePalette[components.CodeVariable] = uiColor(v.theme.Style(docSyntaxVariable).Foreground)
			d.codePalette[components.CodeFlag] = uiColor(v.theme.Style(docSyntaxFlag).Foreground)
			d.codePalette[components.CodeKey] = uiColor(v.theme.Style(docSyntaxKey).Foreground)
			d.minimapCommentColor = d.codePalette[components.CodeComment]
		}
	}

	linkColor := gfx.RGB24(0x3B76D1)
	if look.Dark {
		linkColor = gfx.RGB24(0x589DF6)
	}
	codeFill := look.Foreground
	if look.Dark {
		codeFill.Alpha *= 0.07
	} else {
		codeFill.Alpha *= 0.05
	}
	inlineFill := look.Foreground
	inlineFill.Alpha *= 0.07
	lineColor := look.Subtle
	lineColor.Alpha *= 0.35

	return components.MarkdownLook{
		Text:           look.Foreground,
		Muted:          look.Subtle,
		Link:           linkColor,
		CodeFill:       codeFill,
		InlineCodeFill: inlineFill,
		Line:           lineColor,
		Code:           d.codePalette,
		Selection:      look.Selection,
		Radius:         4,
	}
}

func (v *View) docMinimapColor() gfx.Color {
	if v.theme != nil {
		if v.docs.paletteTheme != v.theme {
			v.docs.minimapCommentColor = uiColor(v.theme.Style(docSyntaxComment).Foreground)
		}
		if v.docs.minimapCommentColor.Alpha > 0 {
			return v.docs.minimapCommentColor
		}
		return uiColor(v.theme.Default().Foreground)
	}
	return gfx.RGB24(0x7A8699)
}

func (v *View) activeDocBlockContainingLine(line int) int {
	a := v.docs.active
	i := sort.Search(len(a), func(k int) bool { return a[k].endLine >= line })
	if i < len(a) && a[i].startLine <= line && line <= a[i].endLine {
		return i
	}
	return -1
}

// docBlockSelected reports whether any active editor selection overlaps the
// source byte span of rendered doc block ab.
func (v *View) docBlockSelected(ab activeDocBlock, selStart, selEnd int) bool {
	blockStart := v.text.LineStart(ab.startLine)
	blockEnd := v.lineEnd(ab.endLine)
	if blockEnd <= blockStart {
		return false
	}
	if selStart < selEnd && selStart < blockEnd && selEnd > blockStart {
		return true
	}
	for _, c := range v.extra {
		a, b := c.anchor, c.caret
		if a > b {
			a, b = b, a
		}
		if a < b && a < blockEnd && b > blockStart {
			return true
		}
	}
	return false
}

// paintDocBlock draws one active rendered doc block once for the frame using
// its displayStartRow top Y and textArea clip.
func (v *View) paintDocBlock(canvas *gfx.Canvas, textArea gfx.Rect, look Look, ab activeDocBlock, top, blockH float32, selected bool, linkBase *int) {
	entry := &v.docs.blocks[ab.blockIdx]

	if selected && look.Selection.Alpha > 0 {
		selTop := max(top, textArea.Y)
		selBottom := min(top+blockH, textArea.Y+textArea.Height)
		if selBottom > selTop {
			canvas.Fill(gfx.Rect{X: textArea.X, Y: selTop, Width: textArea.Width, Height: selBottom - selTop}, look.Selection)
		}
	}

	// Left accent vertical bar (2px wide, subtle muted color).
	barTop := max(top+docAccentPadY, textArea.Y)
	barBottom := min(top+blockH-docAccentPadY, textArea.Y+textArea.Height)
	if barBottom > barTop {
		accent := look.Subtle
		if accent.Alpha == 0 {
			accent = look.Foreground
		}
		accent.Alpha *= 0.45
		barX := v.textLeft - v.scrollX
		canvas.Rounded(gfx.Rect{X: barX, Y: barTop, Width: docAccentBarWidth, Height: barBottom - barTop}, 1, accent)
	}

	if entry.view == nil {
		// Evicted off-screen block re-entering view while async parse is in-flight:
		// draw subtle source fallback inside the reserved height so no blank gap appears.
		v.paintDocBlockFallback(canvas, textArea, ab, top, blockH)
		return
	}

	mdLook := v.docMarkdownLook(look)
	paintX := v.textLeft + docContentInsetX - v.scrollX
	paintY := top + docBlockPadY

	var linksScope gfx.Scope
	baseIdx := *linkBase
	if !v.docs.linkScope.IsZero() && entry.view.LinkCount() > 0 {
		linksScope = v.docs.linkScope
	}
	entry.view.Paint(canvas, components.MarkdownPaint{
		Look:  mdLook,
		X:     paintX,
		Y:     paintY,
		Clip:  textArea,
		Links: linksScope,
		Base:  baseIdx,
	})
	if !linksScope.IsZero() {
		count := entry.view.LinkCount()
		v.docs.paintedLinks = append(v.docs.paintedLinks, docLinkSpan{
			blockID:  ab.blockID,
			blockIdx: ab.blockIdx,
			base:     baseIdx,
			count:    count,
		})
		*linkBase = baseIdx + count
	}
}

func (v *View) paintDocBlockFallback(canvas *gfx.Canvas, textArea gfx.Rect, ab activeDocBlock, top, blockH float32) {
	y := top
	limit := min(top+blockH, textArea.Y+textArea.Height)
	for line := ab.startLine; line <= ab.endLine && y < limit; line++ {
		if y+v.lineH > textArea.Y {
			l := v.ref(line)
			v.tokens = v.hl.Line(v.tokens[:0], line)
			from, to := v.visibleCells()
			p := v.part(l, wrapRow{}, l.size, from, to)
			v.paintRow(canvas, p.text, p.base, p.row, from, to, 0, y)
		}
		y += v.lineH
	}
}

// paintDocGutterIcons draws the render/edit toggle icon on StartLine of every
// doc block in [firstLine..lastLine].
func (v *View) paintDocGutterIcons(canvas *gfx.Canvas, area gfx.Rect, look Look, firstLine, lastLine int) {
	if v.docGutterColumn() == 0 {
		return
	}
	d := &v.docs
	side := min(v.lineH-2, docToggleIconSize)
	i := sort.Search(len(d.blocks), func(k int) bool { return d.blocks[k].startLine >= firstLine })
	for ; i < len(d.blocks) && d.blocks[i].startLine <= lastLine; i++ {
		entry := &d.blocks[i]
		if v.fold.hides(entry.startLine) {
			continue
		}
		icon := d.renderIcon
		color := look.Subtle
		color.Alpha *= 0.6
		if entry.active {
			icon = d.editIcon
			color = look.Subtle
			color.Alpha *= 0.75
		}
		if icon.ViewBox <= 0 {
			continue
		}
		top := area.Y + float32(v.lineRow(entry.startLine))*v.lineH - v.scroll
		canvas.DrawIcon(icon, gfx.Rect{
			X:      d.gutterX + (docToggleWidth-side)/2,
			Y:      top + (v.lineH-side)/2,
			Width:  side,
			Height: side,
		}, color)
	}
}

// ---------------------------------------------------------------------------
// Pointer interactions: link clicks, gutter toggle icon, double-click body
// ---------------------------------------------------------------------------

func (v *View) docBlockOwnsHit(id gfx.ID) bool {
	if v.docs.linkScope.IsZero() {
		return false
	}
	idx, ok := id.In(v.docs.linkScope)
	return ok && idx >= docLinkPartBase
}

// docLinkPointer handles clicks on links rendered inside a MarkdownView.
func (v *View) docLinkPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if !v.painted || v.docs.linkScope.IsZero() || len(v.docs.paintedLinks) == 0 {
		return gfx.EventResult{}, false
	}
	idx, ok := event.Target.In(v.docs.linkScope)
	if !ok || idx < docLinkPartBase {
		return gfx.EventResult{}, false
	}
	if event.Kind != gfx.PointerDown {
		return gfx.EventResult{}, false
	}
	if event.Button != gfx.PointerButtonPrimary {
		// Secondary click on a link opens the editor context menu without expanding.
		return gfx.EventResult{Repaint: true, Focus: v.cfg.HitID}, true
	}
	for _, span := range v.docs.paintedLinks {
		if idx >= span.base && idx < span.base+span.count {
			if span.blockIdx >= 0 && span.blockIdx < len(v.docs.blocks) {
				entry := &v.docs.blocks[span.blockIdx]
				if entry.blockID == span.blockID && entry.view != nil {
					dest := entry.view.Link(idx - span.base)
					if dest != "" {
						if anchorID, ok := strings.CutPrefix(dest, "anchor:"); ok {
							v.JumpToDocAnchorFrom(span.blockID, anchorID)
							return gfx.EventResult{Handled: true, Repaint: true, Focus: v.cfg.HitID}, true
						}
						if v.docs.cb.OnLinkClick != nil {
							v.docs.cb.OnLinkClick(dest, span.blockID)
						}
					}
				}
			}
			return gfx.EventResult{Handled: true, Repaint: true, Focus: v.cfg.HitID}, true
		}
	}
	return gfx.EventResult{Handled: true, Focus: v.cfg.HitID}, true
}

// docGutterPointer handles primary clicks on a doc comment's gutter toggle icon.
func (v *View) docGutterPointer(event gfx.PointerEvent) bool {
	if event.Button != gfx.PointerButtonPrimary || v.docGutterColumn() == 0 {
		return false
	}
	if event.X < v.docs.gutterX || event.X >= v.docs.gutterX+docToggleWidth {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	if row < 0 || row >= v.rowCount() {
		return false
	}
	dr := v.displayRowAt(row)
	if dr.sub != 0 {
		return false
	}
	return v.ToggleDocBlock(dr.line)
}

// docBodyPointer handles presses inside an active rendered doc block body:
// double-click switches to source mode and places the caret on StartLine;
// single primary click focuses without expanding; secondary click leaves
// unhandled for context menu without moving the caret into hidden lines.
func (v *View) docBodyPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if !v.hasActiveDocBlocks() || event.Kind != gfx.PointerDown || event.Target != v.cfg.HitID {
		return gfx.EventResult{}, false
	}
	if event.X < v.textLeft-textPad || event.X >= v.textRight || event.Y < v.area.Y || event.Y >= v.area.Y+v.area.Height {
		return gfx.EventResult{}, false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	if row < 0 || row >= v.rowCount() {
		return gfx.EventResult{}, false
	}
	dr := v.displayRowAt(row)
	if dr.kind != displayDocBlock {
		return gfx.EventResult{}, false
	}
	if event.Button != gfx.PointerButtonPrimary {
		return gfx.EventResult{Repaint: true, Focus: v.cfg.HitID}, true
	}
	if event.ClickCount >= 2 {
		ab := v.docs.active[dr.block]
		startLine := ab.startLine
		v.expandDocBlockByIndex(ab.blockIdx)
		offset := v.text.LineStart(startLine)
		v.extra = nil
		v.dragging = false
		v.columnDrag = false
		v.anchor, v.caret = offset, offset
		v.clearCursorHistory()
		v.lastKind = editOther
		v.moved()
		return gfx.EventResult{Handled: true, Repaint: true, Focus: v.cfg.HitID}, true
	}
	return gfx.EventResult{Handled: true, Focus: v.cfg.HitID}, true
}

// extractDocPlainText builds plain text from a markdown.Document when its
// MarkdownView is not resident.
func extractDocPlainText(doc *markdown.Document) string {
	var b strings.Builder
	writeSpans := func(spans []markdown.Span) {
		for _, sp := range spans {
			b.WriteString(sp.Text)
		}
	}
	for i := range doc.Blocks {
		blk := &doc.Blocks[i]
		if i > 0 && b.Len() > 0 && b.String()[b.Len()-1] != '\n' {
			b.WriteByte('\n')
		}
		switch blk.Kind {
		case markdown.Code:
			b.WriteString(blk.Text)
		case markdown.Rule:
		case markdown.Labeled:
			ls := doc.LabelSpans(blk)
			vs := doc.Spans(blk)
			writeSpans(ls)
			if len(ls) > 0 && len(vs) > 0 {
				b.WriteByte(' ')
			}
			writeSpans(vs)
		case markdown.Table:
			cells := doc.Cells(blk)
			cols := blk.Columns
			if cols <= 0 {
				continue
			}
			rows := len(cells) / cols
			for r := 0; r < rows; r++ {
				if r > 0 {
					b.WriteByte('\n')
				}
				for c := 0; c < cols; c++ {
					if c > 0 {
						b.WriteByte(' ')
					}
					writeSpans(doc.CellSpans(cells[r*cols+c]))
				}
			}
		default:
			writeSpans(doc.Spans(blk))
		}
	}
	return b.String()
}
