package workbench

import (
	"context"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// Native documentation comment rendering inside the editor (without a WebView).
//
// Discovery runs off the window thread using a completed TextMate lexical pass
// (syntax.ExtractDocComments). Visible blocks that want rendered view request
// Rust Core's editor.renderDocComment over the borrowed-document C ABI and
// publish their markdown.Document into editorview.View under strict
// (docGen, revision, blockID, contentHash) staleness guards.

const (
	// docCommentsScanDelay debounces full lexical rescanning after edits while
	// initial document open scans immediately.
	docCommentsScanDelay = 250 * time.Millisecond
	// docCommentsScanTimeout bounds one background TextMate doc-comment pass.
	docCommentsScanTimeout = 10 * time.Second
	// docCommentsMaxBytes caps the file size eligible for full lexical discovery.
	docCommentsMaxBytes = 2 << 20
	// docCommentsMaxSliceBytes matches Rust Core's single-comment input cap.
	docCommentsMaxSliceBytes = 64 << 10
	// docCommentsMaxCodeTokens bounds per-document highlighted code-line cache.
	docCommentsMaxCodeTokens = 256
)

type docCommentsState struct {
	// scanDelay overrides docCommentsScanDelay in tests; negative disables delay.
	scanDelay time.Duration
}

type docCommentMenuClick struct {
	startLine int
	rendered  bool
	menuShown bool
}

type documentDocComments struct {
	docGen          uint64
	scannedRevision int
	scannedLang     string
	seenRevision    int
	changedAt       time.Time
	scanning        bool
	scanCancel      context.CancelFunc
	parseCtx        context.Context
	parseCancel     context.CancelFunc
	codeTokens      map[hoverCodeKey][]syntax.Token
	menuClick       *docCommentMenuClick
}

// setupDocComments wires gutter icons, initial render-default policy, and host
// parse/link/highlight callbacks on a newly created document view.
func (a *App) setupDocComments(p *project, d *document) {
	if d == nil || d.view == nil {
		return
	}
	d.docComments = documentDocComments{
		docGen:          1,
		scannedRevision: -1,
		seenRevision:    -1,
	}
	d.view.SetDocBlockIcons(icons.Eye, icons.Pencil)
	d.view.SetDocRenderDefault(a.docRenderDefaultFor(d))
	d.view.SetDocBlockCallbacks(editorview.DocBlockCallbacks{
		RequestParse: func(docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
			a.requestDocCommentParse(p, d, docGen, revision, blockID, startLine, endLine, contentHash, shellKind, dialect)
		},
		OnLinkClick: func(dest string, _ uint64) {
			a.handleDocCommentLink(d, dest)
		},
		HighlightCode: func(info, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun {
			return a.docCommentCodeRuns(d, info, line, dst)
		},
	})
}

func (a *App) docRenderDefaultFor(d *document) bool {
	if a.editorPreferences.RenderDocComments {
		return true
	}
	return d != nil && d.view != nil && d.view.ReadOnly() && a.editorPreferences.RenderDocCommentsInReadOnly
}

func (a *App) clearDocumentDocComments(d *document) {
	if d == nil {
		return
	}
	dc := &d.docComments
	if dc.scanCancel != nil {
		dc.scanCancel()
		dc.scanCancel = nil
	}
	if dc.parseCancel != nil {
		dc.parseCancel()
		dc.parseCancel = nil
		dc.parseCtx = nil
	}
	dc.docGen++
	dc.scanning = false
	dc.scannedRevision = -1
	dc.seenRevision = -1
	dc.codeTokens = nil
	dc.menuClick = nil
	if d.view != nil {
		d.view.ClearDocBlocks()
	}
}

func (a *App) resetDocumentDocComments(d *document) {
	a.clearDocumentDocComments(d)
	if d != nil && d.view != nil {
		d.view.SetDocRenderDefault(a.docRenderDefaultFor(d))
	}
	a.invalidator.Invalidate()
}

// docCommentsSync schedules off-thread TextMate doc-comment discovery for a
// shown document once its text has settled after an edit (or immediately on
// initial open).
func (a *App) docCommentsSync(c ui.C, p *project, d *document) {
	if p == nil || d == nil || d.view == nil || d.grammar == nil {
		return
	}
	dialects := d.grammar.DocComments()
	if dialects.Block == "" && dialects.Line == "" {
		return
	}
	dc := &d.docComments
	if dc.docGen == 0 {
		dc.docGen = 1
		dc.scannedRevision = -1
		dc.seenRevision = -1
	}

	revision := d.view.Revision()
	lang := a.language().Code()
	if dc.scannedLang != "" && dc.scannedLang != lang {
		// UI language changed: drop cached localized section labels so visible
		// rendered blocks re-parse cleanly in the active language.
		if dc.scanCancel != nil {
			dc.scanCancel()
			dc.scanCancel = nil
		}
		if dc.parseCancel != nil {
			dc.parseCancel()
			dc.parseCancel = nil
			dc.parseCtx = nil
		}
		dc.docGen++
		dc.scanning = false
		dc.scannedRevision = -1
		dc.scannedLang = lang
		dc.codeTokens = nil
		d.view.ClearDocBlocks()
	}

	if dc.scanning {
		if dc.seenRevision != revision {
			dc.seenRevision = revision
			dc.changedAt = a.now()
		}
		return
	}
	if dc.scannedRevision == revision {
		return
	}

	now := a.now()
	if dc.seenRevision != revision {
		dc.seenRevision = revision
		dc.changedAt = now
	}
	if dc.scannedRevision >= 0 {
		delay := a.editor.docComments.scanDelay
		if delay == 0 {
			delay = docCommentsScanDelay
		}
		if delay > 0 {
			if wait := dc.changedAt.Add(delay).Sub(now); wait > 0 {
				c.Canvas().RequestFrameIn(wait)
				return
			}
		}
	}

	dc.scanning = true
	dc.scannedLang = lang
	docGen := dc.docGen
	snap := d.view.TextSnapshot()
	grammar := d.grammar
	scanCtx, cancel := context.WithTimeout(p.ctx, docCommentsScanTimeout)
	dc.scanCancel = cancel

	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		ranges, _ := syntax.ExtractDocComments(scanCtx, grammar, snap, docCommentsMaxBytes)
		candidates := make([]editorview.DocBlockCandidate, len(ranges))
		for i, r := range ranges {
			candidates[i] = editorview.DocBlockCandidate{
				StartLine:   r.StartLine,
				EndLine:     r.EndLine,
				ContentHash: r.ContentHash,
				ShellKind:   r.ShellKind,
				Dialect:     r.Dialect,
			}
		}
		return func(a *App) {
			if dc.docGen == docGen {
				dc.scanning = false
				dc.scanCancel = nil
			}
			if a.project != p || p.docs.find(d.id) != d || dc.docGen != docGen {
				return
			}
			if d.view.Revision() != revision {
				a.invalidator.Invalidate()
				return
			}
			dc.scannedRevision = revision
			d.view.SetDocBlockCandidates(docGen, revision, candidates)
			a.invalidator.Invalidate()
		}
	})
}

func (a *App) requestDocCommentParse(p *project, d *document, docGen uint64, revision int, blockID uint64, startLine, endLine int, contentHash uint64, shellKind, dialect string) {
	if p == nil || d == nil || d.view == nil || a.project != p || d.docComments.docGen != docGen || d.view.Revision() != revision {
		return
	}
	snap := d.view.TextSnapshot()
	lines := snap.LineCount()
	if startLine < 0 || endLine < startLine || endLine >= lines {
		return
	}
	startByte := snap.LineStart(startLine)
	endByte := snap.LineEnd(endLine)
	if endByte <= startByte || endByte-startByte > docCommentsMaxSliceBytes {
		return
	}
	slice := snap.AppendRange(nil, startByte, endByte)

	dc := &d.docComments
	if dc.parseCtx == nil {
		dc.parseCtx, dc.parseCancel = context.WithCancel(p.ctx)
	}
	parseCtx := dc.parseCtx
	language := a.language()
	fallbackLang := d.languageID
	registry := a.syntaxRegistry()
	opCtx := a.operationContext(parseCtx)

	a.background(p, 0, func(context.Context) func(*App) {
		callCtx, cancel := context.WithTimeout(opCtx, kernelCallTimeout)
		defer cancel()
		ir, err := core.NewClient().RenderDocComment(callCtx, slice, shellKind, dialect, fallbackLang)
		if err != nil {
			if parseCtx.Err() != nil {
				// log-exempt: 文档关闭、重载或切换语言主动取消进行中的文档注释解析。
				return nil
			}
			return func(a *App) {
				a.backgroundFailed("editor_doc_comment", err)
			}
		}
		if ir.FallbackToSource || len(ir.Blocks) == 0 {
			return nil
		}

		var doc markdown.Document
		populateMarkdownFromDocIR(&doc, ir, func(tagKind string) string {
			return localizeDocTag(language, tagKind)
		})
		if len(doc.Blocks) == 0 {
			return nil
		}

		var codeBlocks []hoverCodeBlock
		for i := range doc.Blocks {
			b := &doc.Blocks[i]
			if b.Kind != markdown.Code {
				continue
			}
			if lang := hoverCodeLanguage(b.Info, fallbackLang); lang != "" {
				codeBlocks = append(codeBlocks, hoverCodeBlock{language: lang, text: b.Text})
			}
		}
		var tokens map[hoverCodeKey][]syntax.Token
		if len(codeBlocks) > 0 && registry != nil {
			tokens = hoverCodeTokens(registry, codeBlocks)
		}

		anchors := make([]editorview.DocBlockAnchor, len(ir.Anchors))
		for i, anchor := range ir.Anchors {
			anchors[i] = editorview.DocBlockAnchor{
				ID:         anchor.ID,
				BlockIndex: anchor.BlockIndex,
			}
		}
		estimated := doc.AllocatedBytes()

		return func(a *App) {
			if a.project != p || p.docs.find(d.id) != d || d.docComments.docGen != docGen || d.view.Revision() != revision {
				return
			}
			if len(tokens) > 0 {
				if d.docComments.codeTokens == nil || len(d.docComments.codeTokens)+len(tokens) > docCommentsMaxCodeTokens {
					d.docComments.codeTokens = make(map[hoverCodeKey][]syntax.Token, min(len(tokens), docCommentsMaxCodeTokens))
				}
				for k, v := range tokens {
					if len(d.docComments.codeTokens) >= docCommentsMaxCodeTokens {
						break
					}
					d.docComments.codeTokens[k] = v
				}
			}
			d.view.InstallPreparedDocBlock(editorview.PreparedDocBlock{
				DocGeneration:    docGen,
				Revision:         revision,
				BlockID:          blockID,
				ContentHash:      contentHash,
				Doc:              doc,
				Anchors:          anchors,
				EstimatedIRBytes: estimated,
			})
			a.invalidator.Invalidate()
		}
	})
}

func localizeDocTag(lang i18n.Language, tagKind string) string {
	switch tagKind {
	case "param":
		return i18n.Shared(lang, "desktop.docComment.tag.param")
	case "typeParam":
		return i18n.Shared(lang, "desktop.docComment.tag.typeParam")
	case "returns":
		return i18n.Shared(lang, "desktop.docComment.tag.returns")
	case "throws":
		return i18n.Shared(lang, "desktop.docComment.tag.throws")
	case "since":
		return i18n.Shared(lang, "desktop.docComment.tag.since")
	case "see":
		return i18n.Shared(lang, "desktop.docComment.tag.see")
	case "author":
		return i18n.Shared(lang, "desktop.docComment.tag.author")
	case "deprecated":
		return i18n.Shared(lang, "desktop.docComment.tag.deprecated")
	case "version":
		return i18n.Shared(lang, "desktop.docComment.tag.version")
	default:
		return ""
	}
}

func (a *App) docCommentCodeRuns(d *document, info, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun {
	if d == nil || len(d.docComments.codeTokens) == 0 {
		return dst
	}
	tokens := d.docComments.codeTokens[hoverCodeKey{language: hoverCodeLanguage(info, d.languageID), line: line}]
	if len(tokens) == 0 {
		return dst
	}
	for i, token := range tokens {
		start, end := int(token.Start), len(line)
		if i+1 < len(tokens) {
			end = int(tokens[i+1].Start)
		}
		if start < 0 || start >= end || end > len(line) {
			continue
		}
		class := docCodeClassForScope(token.Name)
		if class == 0 {
			continue
		}
		if n := len(dst); n > 0 && dst[n-1].Class == class && dst[n-1].End == start {
			dst[n-1].End = end
			continue
		}
		dst = append(dst, components.MarkdownCodeRun{Start: start, End: end, Class: class})
	}
	return dst
}

// docCodeClassForScope maps a TextMate scope to the fixed MarkdownCodeClass
// slots populated by editorview.View.docMarkdownLook.
func docCodeClassForScope(name syntax.Name) components.MarkdownCodeClass {
	scope := name.String()
	switch {
	case strings.HasPrefix(scope, "comment"):
		return components.CodeComment
	case strings.HasPrefix(scope, "string"):
		return components.CodeString
	case strings.HasPrefix(scope, "constant.numeric"):
		return components.CodeNumber
	case strings.HasPrefix(scope, "keyword"), strings.HasPrefix(scope, "storage"):
		return components.CodeKeyword
	case strings.HasPrefix(scope, "entity.name.function"), strings.HasPrefix(scope, "support.function"):
		return components.CodeFunction
	case strings.HasPrefix(scope, "entity.other.attribute-name"):
		return components.CodeFlag
	case strings.HasPrefix(scope, "support.type.property-name"), strings.HasPrefix(scope, "entity.name.tag"):
		return components.CodeKey
	case strings.HasPrefix(scope, "variable"), strings.HasPrefix(scope, "entity.name.type"), strings.HasPrefix(scope, "support.type"), strings.HasPrefix(scope, "constant.language"):
		return components.CodeVariable
	default:
		return 0
	}
}

func (a *App) handleDocCommentLink(d *document, dest string) {
	if dest == "" {
		return
	}
	switch {
	case strings.HasPrefix(dest, "anchor:"):
		if d != nil && d.view != nil {
			if d.view.JumpToDocAnchor(strings.TrimPrefix(dest, "anchor:")) {
				a.invalidator.Invalidate()
			}
		}
	case strings.HasPrefix(dest, "symbol:"), strings.HasPrefix(dest, "external:"):
		// Symbol references and non-web external schemes are not speculatively
		// navigated without a language server definition resolution.
	default:
		a.followHoverLink(dest)
	}
}

func (a *App) applyDocCommentPreferences() {
	p := a.project
	if p == nil {
		return
	}
	for _, d := range p.docs.list {
		if d == nil || d.view == nil {
			continue
		}
		want := a.docRenderDefaultFor(d)
		d.view.SetDocRenderDefault(want)
		d.view.SetAllDocBlocksRendered(want)
	}
	a.invalidator.Invalidate()
}

func (a *App) updateDocCommentReadOnly(d *document) {
	if d == nil || d.view == nil {
		return
	}
	want := a.docRenderDefaultFor(d)
	d.view.SetDocRenderDefault(want)
	if a.editorPreferences.RenderDocCommentsInReadOnly && !a.editorPreferences.RenderDocComments {
		d.view.SetAllDocBlocksRendered(want)
	}
	a.invalidator.Invalidate()
}

func (a *App) docCommentMenuTarget(d *document) (startLine int, rendered bool, ok bool) {
	if d == nil || d.view == nil {
		return 0, false, false
	}
	if click := d.docComments.menuClick; click != nil {
		return click.startLine, d.view.DocBlockRendered(click.startLine), true
	}
	line, _ := d.view.CaretUTF16()
	return d.view.DocBlockAtLine(line)
}

func (a *App) docCommentMenuPainted(d *document, shown bool) {
	if d == nil {
		return
	}
	click := d.docComments.menuClick
	if click == nil {
		return
	}
	switch {
	case shown:
		click.menuShown = true
	case click.menuShown:
		d.docComments.menuClick = nil
	}
}

// docCommentMenuItems appends documentation-comment render/edit/copy actions to
// the editor context menu when the document contains doc comments.
func (a *App) docCommentMenuItems(c ui.C, d *document, menu *ui.MenuItems) {
	if d == nil || d.view == nil || d.view.DocBlockCount() == 0 {
		return
	}
	language := a.language()
	startLine, rendered, hasTarget := a.docCommentMenuTarget(d)
	menu.Separator()
	if hasTarget {
		if rendered {
			if menu.Item(i18n.Shared(language, "desktop.editor.editDocComment")).Clicked() {
				line := startLine
				c.After(func() { a.toggleDocCommentAtLine(d, line) })
			}
			if menu.Item(i18n.Shared(language, "desktop.editor.copyRenderedDocComment")).Clicked() {
				line := startLine
				c.After(func() { a.copyRenderedDocComment(d, line) })
			}
		} else {
			if menu.Item(i18n.Shared(language, "desktop.editor.renderDocComment")).Clicked() {
				line := startLine
				c.After(func() { a.toggleDocCommentAtLine(d, line) })
			}
		}
	}
	if d.view.ActiveDocBlockCount() < d.view.DocBlockCount() {
		if menu.Item(i18n.Shared(language, "desktop.editor.renderAllDocComments")).Clicked() {
			c.After(func() { a.setAllDocCommentsRendered(d, true) })
		}
	}
	if d.view.ActiveDocBlockCount() > 0 {
		if menu.Item(i18n.Shared(language, "desktop.editor.editAllDocComments")).Clicked() {
			c.After(func() { a.setAllDocCommentsRendered(d, false) })
		}
	}
}

func (a *App) toggleDocCommentAtLine(d *document, startLine int) {
	if d == nil || d.view == nil {
		return
	}
	if d.view.ToggleDocBlock(startLine) {
		a.invalidator.Invalidate()
	}
}

func (a *App) toggleDocCommentAtCaret(d *document) {
	if d == nil || d.view == nil {
		return
	}
	line, _ := d.view.CaretUTF16()
	startLine, _, ok := d.view.DocBlockAtLine(line)
	if !ok {
		return
	}
	a.toggleDocCommentAtLine(d, startLine)
}

func (a *App) setAllDocCommentsRendered(d *document, on bool) {
	if d == nil || d.view == nil {
		return
	}
	d.view.SetAllDocBlocksRendered(on)
	a.invalidator.Invalidate()
}

func (a *App) copyRenderedDocComment(d *document, startLine int) {
	if d == nil || d.view == nil {
		return
	}
	text, ok := d.view.RenderedDocBlockText(startLine)
	if !ok {
		return
	}
	if err := app.SetClipboardText(text); err != nil {
		a.operationFailed("clipboard_copy", err)
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.copyFailed", map[string]string{"reason": err.Error()}))
	}
}
