package i18n

// toolMessages reads tools labels from the shared catalog.
func toolMessages(language Language) ToolMessages {
	return ToolMessages{
		Output:        Shared(language, "desktop.pluginHost.output"),
		Project:       Shared(language, "workbench.project"),
		Commit:        Shared(language, "workbench.commit"),
		Structure:     Shared(language, "desktop.tools.structure"),
		Find:          Shared(language, "search.search"),
		Git:           Shared(language, "settings.tabs.git"),
		Terminal:      Shared(language, "workbench.terminal"),
		Problems:      Shared(language, "native.problems"),
		References:    Shared(language, "desktop.semantics.references"),
		Run:           Shared(language, "workbench.run"),
		Build:         Shared(language, "workbench.build"),
		Tests:         Shared(language, "native.tests"),
		Security:      Shared(language, "native.security"),
		Debug:         Shared(language, "native.debug"),
		Notifications: Shared(language, "notifications.title"),
		Background:    Shared(language, "desktop.tools.background"),
		Ports:         Shared(language, "desktop.remote.ports.title"),
		ToolWindows:   Shared(language, "native.toolWindows"),
		DragHint:      Shared(language, "desktop.tools.dragHint"),
	}
}

// dockMessages reads dock labels from the shared catalog.
func dockMessages(language Language) DockMessages {
	return DockMessages{
		MoveLeftTop:     Shared(language, "native.moveToLeftTop"),
		MoveLeftBottom:  Shared(language, "native.moveToLeftBottom"),
		MoveBottomLeft:  Shared(language, "native.moveToBottomLeft"),
		MoveRightTop:    Shared(language, "native.moveToRightTop"),
		MoveRightBottom: Shared(language, "native.moveToRightBottom"),
		MoveBottomRight: Shared(language, "native.moveToBottomRight"),
	}
}

// panelMessages reads panel labels from the shared catalog.
func panelMessages(language Language) PanelMessages {
	return PanelMessages{
		Hide:        Shared(language, "desktop.panel.hide"),
		Placeholder: Shared(language, "desktop.panel.placeholder"),
		Resize:      Shared(language, "image.resize"),
	}
}
