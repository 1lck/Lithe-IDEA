package workbench

// editorFeatures is the state of the editor's own features beyond the language popups. Each
// feature keeps its state in its own file's type; the App holds them here as one field so a
// new feature adds no field to the shared App.
type editorFeatures struct {
	nav navigationHistoryState
}
