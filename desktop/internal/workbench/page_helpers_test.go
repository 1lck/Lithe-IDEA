package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/i18n"

// clickShared clicks the control a page declares with the shared text id.
func (h *harness) clickShared(id string) {
	h.t.Helper()
	h.clickNamed(i18n.Shared(h.app.language(), id))
}

// focusedName is the accessible name of the control that has the keyboard, empty
// when none does.
func (h *harness) focusedName() string {
	snapshot := h.driver.Snapshot()
	for _, hit := range snapshot.Hits {
		if hit.ID == snapshot.Focused && !hit.IsLabel {
			return hit.Label
		}
	}
	return ""
}

// instanceOptions is the name of the button that opens the options of p's selected build instance.
func (h *harness) instanceOptions(p *project) string {
	h.t.Helper()
	instance := p.selectedBuildInstance()
	if instance == nil {
		h.t.Fatal("no build instance is selected")
	}
	return i18n.SharedFormat(h.app.language(), "desktop.build.instanceOptions", map[string]string{"name": buildSystemName(instance)})
}
