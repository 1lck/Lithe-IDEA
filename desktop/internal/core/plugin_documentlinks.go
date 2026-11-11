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
