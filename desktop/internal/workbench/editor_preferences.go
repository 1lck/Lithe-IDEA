package workbench

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
)

// Only the resolved preferences reach drawing; defaults and scheme migration live in Core.
func (a *App) loadEditorEssentials() {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	client := core.NewClient()
	prefs, err := client.ResolveEditorPreferences(ctx, a.settings.EditorPreferences)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_preferences", err))
	} else {
		a.editorPreferences = prefs
	}
	schemes, err := client.ReduceKeymapSchemes(ctx, core.KeymapSchemeRequest{State: a.settings.KeymapSchemes, Current: a.settings.Keymap})
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("keymap_schemes", err))
	} else {
		a.settings.KeymapSchemes = schemes.State
		a.settings.Keymap = shortcuts.Overrides(schemes.Bindings)
	}
}
