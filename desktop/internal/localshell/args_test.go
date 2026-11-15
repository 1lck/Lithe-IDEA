package localshell

import (
	"slices"
	"testing"
)

func TestGitBashStartsAsALoginShell(t *testing.T) {
	for _, test := range []struct {
		program string
		want    []string
	}{
		{`C:\Program Files\Git\bin\bash.exe`, []string{"--login", "-i"}},
		{`C:\Program Files\Git\usr\bin\bash.exe`, []string{"--login", "-i"}},
		{"C:/Program Files/Git/bin/BASH.EXE", []string{"--login", "-i"}},
		{`C:\Program Files\PowerShell\7\pwsh.exe`, nil},
		{`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, nil},
		{`C:\Windows\System32\cmd.exe`, nil},
		{"", nil},
	} {
		if got := ArgsFor(test.program); !slices.Equal(got, test.want) {
			t.Fatalf("ArgsFor(%q) = %q, want %q", test.program, got, test.want)
		}
	}
}
