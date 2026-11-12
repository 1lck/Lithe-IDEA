package term

import "strings"

// InputEnvironment is a current-shell report, never an instruction to change it.
type InputEnvironment struct {
	Charset string // utf8, other, unknown
	Locale  string // an installed, verified UTF-8 candidate, or empty
}

func (t *Terminal) SetInputEnvironment(fn func(InputEnvironment)) { t.inputEnvironmentFn = fn }

func (t *Terminal) inputEnvironmentReport(text []byte) {
	if t.promptToken == "" || t.inputEnvironmentFn == nil || len(text) > 400 {
		return
	}
	parts := strings.Split(string(text), ";")
	if len(parts) != 4 || parts[0] != "motty-input" || parts[1] != t.promptToken {
		return
	}
	if parts[2] != "utf8" && parts[2] != "other" && parts[2] != "unknown" {
		return
	}
	if len(parts[3]) > 128 {
		return
	}
	for _, r := range parts[3] {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("_.@-", r)) {
			return
		}
	}
	t.inputEnvironmentFn(InputEnvironment{Charset: parts[2], Locale: parts[3]})
}
