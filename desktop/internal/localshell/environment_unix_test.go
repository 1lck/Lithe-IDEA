//go:build !windows

package localshell

import (
	"slices"
	"strings"
	"testing"
	"time"
)

func TestShellLocaleFillsOnlyAnEnvironmentThatNamesNoLocale(t *testing.T) {
	for _, test := range []struct {
		name string
		env  []string
		want []string
	}{
		{"nothing set", []string{"HOME=/tmp"}, []string{"HOME=/tmp", "LANG=C.UTF-8"}},
		{"empty settings", []string{"LANG=", "LC_CTYPE=", "HOME=/tmp"}, []string{"HOME=/tmp", "LANG=C.UTF-8"}},
		{"a locale", []string{"LANG=en_US.UTF-8"}, []string{"LANG=en_US.UTF-8"}},
		{"a character type", []string{"LC_CTYPE=zh_CN.UTF-8", "HOME=/tmp"}, []string{"LC_CTYPE=zh_CN.UTF-8", "HOME=/tmp"}},
		{"an explicit C locale", []string{"LC_ALL=C"}, []string{"LC_ALL=C"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := withUTF8Locale(slices.Clone(test.env)); !slices.Equal(got, test.want) {
				t.Fatalf("withUTF8Locale(%q) = %q, want %q", test.env, got, test.want)
			}
		})
	}
}

func TestShellEnvironmentOverridesInheritedValue(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://inherited:8080")
	shell, err := Start(Config{Shell: "/bin/sh", Args: []string{"-c", `printf 'proxy=%s' "$HTTP_PROXY"`}, Env: []string{"HTTP_PROXY="}, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer shell.Close()
	var output []byte
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		output = shell.Drain(output)
		if strings.Contains(string(output), "proxy=") {
			if strings.TrimSpace(string(output)) != "proxy=" {
				t.Fatalf("output = %q", output)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no proxy output: %q", output)
}
