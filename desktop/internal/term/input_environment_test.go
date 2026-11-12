package term

import "testing"

func TestInputEnvironmentRequiresOwnedTokenAndValidatedFields(t *testing.T) {
	for _, test := range []struct {
		name, report string
		want         int
	}{
		{"valid", "motty-input;owner;other;C.UTF-8", 1},
		{"utf8", "motty-input;owner;utf8;", 1},
		{"unknown", "motty-input;owner;unknown;", 1},
		{"foreign", "motty-input;other;other;C.UTF-8", 0},
		{"missing-token", "motty-input;;other;C.UTF-8", 0},
		{"invalid-charset", "motty-input;owner;C;C.UTF-8", 0},
		{"unsafe-locale", "motty-input;owner;other;C.UTF-8$(id)", 0},
		{"extra-field", "motty-input;owner;other;C.UTF-8;extra", 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			screen := New(80, 24, 0)
			screen.SetPromptToken("owner")
			calls := 0
			screen.SetInputEnvironment(func(environment InputEnvironment) {
				calls++
				if test.name == "valid" && (environment.Charset != "other" || environment.Locale != "C.UTF-8") {
					t.Fatalf("wrong environment: %+v", environment)
				}
			})
			for _, b := range []byte("\x1b]777;" + test.report + "\x07") {
				screen.Write([]byte{b})
			}
			if calls != test.want || screen.RowText(0) != "" {
				t.Fatalf("calls=%d want=%d; report leaked to screen %q", calls, test.want, screen.RowText(0))
			}
		})
	}
	screen := New(80, 24, 0)
	screen.SetInputEnvironment(func(InputEnvironment) { t.Fatal("unowned terminal trusted environment") })
	screen.Write([]byte("\x1b]777;motty-input;;other;C.UTF-8\x07"))
}
