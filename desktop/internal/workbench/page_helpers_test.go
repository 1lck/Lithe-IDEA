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
