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

// PluginSemanticTokens decodes a completed semanticTokens event.
func PluginSemanticTokens(event BackendEvent) (SemanticTokens, error) {
	var tokens SemanticTokens
	if err := decodePluginSemanticResult(event, &tokens); err != nil {
		return SemanticTokens{}, err
	}
	return tokens, nil
}
