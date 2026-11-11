package core

// DocumentLink is one link of Core's normalized textDocument/documentLink answer. Positions are
// zero-based lines and UTF-16 columns, as the editor's ranges are. A nil target means the server
// offers the link only after resolving it, so the host has nothing to open.
type DocumentLink struct {
	StartLine   int
	StartColumn int
	EndLine     int
	EndColumn   int
	Target      *string
	Tooltip     *string
}

// PluginServerDocumentLinks decodes the links of a completed documentLinks request.
func PluginServerDocumentLinks(event BackendEvent) ([]DocumentLink, error) {
	var payload struct {
		Links []struct {
			Range struct {
				Start struct {
					Line        int `json:"line"`
					UTF16Column int `json:"utf16Column"`
				} `json:"start"`
				End struct {
					Line        int `json:"line"`
					UTF16Column int `json:"utf16Column"`
				} `json:"end"`
			} `json:"range"`
			Target  *string `json:"target"`
			Tooltip *string `json:"tooltip"`
		} `json:"links"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	links := make([]DocumentLink, 0, len(payload.Links))
	for _, link := range payload.Links {
		links = append(links, DocumentLink{
			StartLine: link.Range.Start.Line, StartColumn: link.Range.Start.UTF16Column,
			EndLine: link.Range.End.Line, EndColumn: link.Range.End.UTF16Column,
			Target: link.Target, Tooltip: link.Tooltip,
		})
	}
	return links, nil
}

// WorkspaceSymbol is one symbol of Core's normalized workspace/symbol answer. Kind is the LSP
// SymbolKind number; URI is the document's file URI; Range is nil when the server gave none.
type WorkspaceSymbol struct {
	Name          string `json:"name"`
	Kind          int    `json:"kind"`
	ContainerName string `json:"containerName"`
	URI           string `json:"uri"`
	Range         *struct {
		Start struct {
			Line        int `json:"line"`
			UTF16Column int `json:"utf16Column"`
		} `json:"start"`
		End struct {
			Line        int `json:"line"`
			UTF16Column int `json:"utf16Column"`
		} `json:"end"`
	} `json:"range"`
}

// PluginWorkspaceSymbols decodes the symbols of a completed workspaceSymbols request.
func PluginWorkspaceSymbols(event BackendEvent) ([]WorkspaceSymbol, error) {
	var payload struct {
		Symbols []WorkspaceSymbol `json:"symbols"`
	}
	if err := decodePluginSemanticResult(event, &payload); err != nil {
		return nil, err
	}
	return payload.Symbols, nil
}
