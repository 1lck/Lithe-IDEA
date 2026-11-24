package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// A form can omit fields it does not support and show several validation errors
// below its header. Neither case may rename a following element or another error.
func TestRunConfigFormOptionalErrorsKeepTheirOwnIdentity(t *testing.T) {
	for _, errors := range []map[string]string{nil, {
		"name": "required", "storeAsProjectFile": "invalidValue", "future": "unavailable",
	}} {
		name := "clean"
		if errors != nil {
			name = "invalid"
		}
		t.Run(name, func(t *testing.T) {
			a := &App{theme: ui.LightTheme()}
			text, flag := "Example", false
			f := &runConfigForm{
				fields: []core.RunEditorField{
					{ID: "name", Kind: runFieldText, Placement: "header"},
					{ID: "storeAsProjectFile", Kind: runFieldCheckbox, Placement: "header"},
					{ID: "future", Kind: "futureControl"},
				},
				texts:  map[string]*string{"name": &text},
				flags:  map[string]*bool{"storeAsProjectFile": &flag},
				errors: errors,
			}
			page := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
				ui.Column(c).Fill().Children(func() {
					a.drawRunConfigFormFields(c, &project{}, f, true)
					ui.Text(c, "After the form")
					ui.Text(c, "End")
				})
			}})
			driver, err := app.NewDriver(ui.Configure(page, app.Config{Width: 800, Height: 600}), nil)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(driver.Close)
			for _, code := range errors {
				want := runConfigFieldError(a.language(), code)
				found := false
				for _, label := range driver.Snapshot().Labels {
					found = found || label.Value == want
				}
				if !found {
					t.Errorf("the form did not show validation message %q", want)
				}
			}
		})
	}
}
