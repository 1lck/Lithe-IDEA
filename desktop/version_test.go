package desktop

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestVersionMatchesMakefileVersion(t *testing.T) {
	version := Version()
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(version) {
		t.Fatalf("Version() = %q, want MAJOR.MINOR.PATCH", version)
	}

	makefile, err := os.ReadFile("Makefile")
	if err != nil {
		t.Fatal(err)
	}
	const makefileAssignment = `VERSION := $(shell sed -n 's/^version = "\([0-9.]*\)"$$/\1/p' viva.toml)`
	if !strings.Contains(string(makefile), makefileAssignment) {
		t.Fatal("Makefile no longer reads VERSION from viva.toml with its sed expression")
	}

	manifest, err := os.ReadFile("viva.toml")
	if err != nil {
		t.Fatal(err)
	}
	sedPattern := regexp.MustCompile(`^version = "([0-9.]*)"$`)
	var makefileVersions []string
	for _, line := range strings.Split(string(manifest), "\n") {
		if match := sedPattern.FindStringSubmatch(line); match != nil {
			makefileVersions = append(makefileVersions, match[1])
		}
	}
	if len(makefileVersions) != 1 {
		t.Fatalf("Makefile sed expression reads %d versions, want exactly one", len(makefileVersions))
	}
	if version != makefileVersions[0] {
		t.Fatalf("Version() = %q, Makefile sed expression reads %q", version, makefileVersions[0])
	}
}
