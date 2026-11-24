package core

// DocumentSymbol is one node of a document's symbol tree as Core normalizes it: a hierarchical
// answer keeps its tree, a flat one becomes childless symbols. Kind is the LSP SymbolKind
// integer, and positions are zero-based lines and UTF-16 columns.
type DocumentSymbol struct {
	Name           string              `json:"name"`
	Detail         *string             `json:"detail"`
	Kind           int                 `json:"kind"`
	Tags           []int               `json:"tags"`
	Deprecated     bool                `json:"deprecated"`
	Range          PluginDocumentRange `json:"range"`
	SelectionRange PluginDocumentRange `json:"selectionRange"`
	ContainerName  *string             `json:"containerName"`
	Children       []DocumentSymbol    `json:"children"`
}

// PluginDocumentSymbols decodes a completed documentSymbols event. An empty answer is a
// document without symbols, not an error.
func PluginDocumentSymbols(event BackendEvent) ([]DocumentSymbol, error) {
	var payload struct {
		Symbols []DocumentSymbol `json:"symbols"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Symbols, nil
}

// SemanticToken is one colored span of a document: a zero-based line, UTF-16 start column and
// length, an index into the legend's token types and a bitset of its token modifiers.
type SemanticToken struct {
	Line           int    `json:"line"`
	StartChar      int    `json:"startChar"`
	Length         int    `json:"length"`
	TokenType      int    `json:"tokenType"`
	TokenModifiers uint32 `json:"tokenModifiers"`
}

// SemanticTokens is Core's decoded semanticTokens answer: the legend the server negotiated and
// the tokens in document order.
type SemanticTokens struct {
	TokenTypes     []string        `json:"tokenTypes"`
	TokenModifiers []string        `json:"tokenModifiers"`
	Tokens         []SemanticToken `json:"tokens"`
}

// PluginColorLegendEntry is a stable color ID with its light- and dark-theme colors.
// Core validates each color against the provider's legend before returning it.
type PluginColorLegendEntry struct {
	ID    string `json:"id"`
	Light string `json:"light"`
	Dark  string `json:"dark"`
}

// PluginColorPosition is a zero-based LSP position with a UTF-16 character column.
type PluginColorPosition struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// PluginColorRange is a half-open range in LSP UTF-16 coordinates.
type PluginColorRange struct {
	Start PluginColorPosition `json:"start"`
	End   PluginColorPosition `json:"end"`
}

// PluginColorDecoration is a Core-normalized foreground color for one document range.
type PluginColorDecoration struct {
	SourceID string           `json:"sourceId"`
	ColorID  string           `json:"colorId"`
	Light    string           `json:"light"`
	Dark     string           `json:"dark"`
	Range    PluginColorRange `json:"range"`
}

// PluginSemanticTokens decodes a completed semanticTokens event.
func PluginSemanticTokens(event BackendEvent) (SemanticTokens, error) {
	var tokens SemanticTokens
	if err := decodePluginSemanticResult(event, &tokens); err != nil {
		return SemanticTokens{}, err
	}
	return tokens, nil
}

// FoldingRange is one range of Core's normalized foldingRanges answer, in zero-based lines.
type FoldingRange struct {
	StartLine     int    `json:"startLine"`
	EndLine       int    `json:"endLine"`
	Kind          string `json:"kind,omitempty"`
	CollapsedText string `json:"collapsedText,omitempty"`
}

// PluginFoldingRanges decodes the ranges of a completed foldingRanges request.
func PluginFoldingRanges(event BackendEvent) ([]FoldingRange, error) {
	var payload struct {
		Ranges []FoldingRange `json:"ranges"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Ranges, nil
}
