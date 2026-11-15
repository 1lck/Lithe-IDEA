package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
)

// EditorLink is one document link a plugin's provider returned: a zero-based, UTF-16 range that
// opens an absolute target. Core has already checked the shape and the target URI.
type EditorLink struct {
	StartLine   int
	StartColumn int
	EndLine     int
	EndColumn   int
	Target      string
	Tooltip     string
}

// PluginDocumentLinks asks the document's document link provider for its links. The answer is Core's
// normalised {links} with absolute targets; a link whose range is empty is dropped.
func (s *Service) PluginDocumentLinks(ctx context.Context, root, path, languageID, documentID string, version int) ([]EditorLink, error) {
	if s == nil || s.providers2 == nil {
		return nil, nil
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return nil, nil
	}
	name := filepath.Base(path)
	s.providers2.mu.Lock()
	var binding *editorProviderBinding
	for _, candidate := range s.providers2.list {
		if candidate.contextID == workspace.ContextID && candidate.documentLink != "" && candidate.matchesDocument(languageID, name) {
			binding = candidate
			break
		}
	}
	s.providers2.mu.Unlock()
	if binding == nil {
		return nil, nil
	}
	session := s.Host.Running(binding.pluginID)
	if session == nil || session.Session.ID != binding.sessionID {
		return nil, ErrBackendUnavailable
	}
	argument := mustMarshal(map[string]any{"document": map[string]any{"documentID": documentID, "version": version}})
	answer, err := session.Call(ctx, binding.documentLink, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return nil, err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return nil, errors.New("editor providers need the Core that normalises their answers")
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "documentLink", "value": answer})
	if err != nil {
		return nil, err
	}
	var result struct {
		Result struct {
			Links []struct {
				Range struct {
					Start struct{ Line, Character int } `json:"start"`
					End   struct{ Line, Character int } `json:"end"`
				} `json:"range"`
				Target  string `json:"target"`
				Tooltip string `json:"tooltip"`
			} `json:"links"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return nil, err
	}
	links := make([]EditorLink, 0, len(result.Result.Links))
	for _, link := range result.Result.Links {
		if link.Target == "" {
			continue
		}
		start, end := link.Range.Start, link.Range.End
		if end.Line < start.Line || (end.Line == start.Line && end.Character <= start.Character) {
			continue
		}
		links = append(links, EditorLink{
			StartLine: start.Line, StartColumn: start.Character,
			EndLine: end.Line, EndColumn: end.Character,
			Target: link.Target, Tooltip: link.Tooltip,
		})
	}
	return links, nil
}
