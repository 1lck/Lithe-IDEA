package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
)

// PluginCodeLenses asks the document's code lens provider for its lenses. Each lens becomes an editor action
// without an icon: its title is shown at its line, and its invoke calls the same plugin function a click on
// an action would. The answer is Core's normalised {lenses}, with zero-based LSP ranges.
func (s *Service) PluginCodeLenses(ctx context.Context, root, path, languageID, documentID string, version int) ([]EditorAction, error) {
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
		if candidate.contextID == workspace.ContextID && candidate.codeLens != "" && candidate.matchesDocument(languageID, name) {
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
	answer, err := session.Call(ctx, binding.codeLens, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return nil, err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return nil, errors.New("editor providers need the Core that normalises their answers")
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "codeLens", "value": answer})
	if err != nil {
		return nil, err
	}
	var result struct {
		Result struct {
			Lenses []struct {
				Range struct {
					Start struct{ Line, Character int } `json:"start"`
					End   struct{ Line, Character int } `json:"end"`
				} `json:"range"`
				Title  string `json:"title"`
				Invoke struct {
					FunctionID string          `json:"functionID"`
					Params     json.RawMessage `json:"params"`
				} `json:"invoke"`
			} `json:"lenses"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return nil, err
	}
	actions := make([]EditorAction, 0, len(result.Result.Lenses))
	for index, lens := range result.Result.Lenses {
		if lens.Title == "" || !validFunctionID(lens.Invoke.FunctionID) {
			continue
		}
		actions = append(actions, EditorAction{
			ID:       "lens-" + strconv.Itoa(index),
			Title:    lens.Title,
			Range:    EditorActionRange{StartLine: lens.Range.Start.Line + 1, StartColumn: lens.Range.Start.Character + 1, EndLine: lens.Range.End.Line + 1, EndColumn: lens.Range.End.Character + 1},
			pluginID: binding.pluginID, sessionID: binding.sessionID, reference: binding.reference,
			invoke:     editorActionInvoke{function: lens.Invoke.FunctionID, params: lens.Invoke.Params},
			documentID: documentID, version: version,
		})
	}
	return actions, nil
}
