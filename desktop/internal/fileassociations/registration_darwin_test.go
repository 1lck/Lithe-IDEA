package fileassociations

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestFileAssociationsMacContentTypeAliases(t *testing.T) {
	// Resolve actual macOS types without publishing any default handlers.
	java, err := contentType(".java")
	if err != nil {
		t.Fatal(err)
	}
	alias, err := contentType(".jav")
	if err != nil {
		t.Fatal(err)
	}
	if java == "" || java != alias {
		t.Fatalf("macOS Java content types differ: %q, %q", java, alias)
	}
}

func TestFileAssociationsMacReadIsStable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	formats := []core.FileAssociationFormat{{Extension: ".java", Language: "java"}, {Extension: ".js", Language: "javascript"}}
	before, err := readNative(ctx, formats)
	if err != nil {
		t.Fatal(err)
	}
	after, err := readNative(ctx, formats)
	if err != nil {
		t.Fatal(err)
	}
	for i, handler := range before.Handlers {
		if handler != after.Handlers[i] {
			t.Fatalf("read-only native observations changed: %+v, %+v", handler, after.Handlers[i])
		}
	}
}

func TestFileAssociationsMacCanceledApplyDoesNotRegister(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := applyNative(ctx, nativeState{}, []string{".txt"}, ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled apply: %v", err)
	}
}
