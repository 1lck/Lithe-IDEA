// Package fileassociations reads the system's actual text-file handlers and
// publishes explicit registrations. It never writes into the installed package.
package fileassociations

// Note: 系统默认应用与只读包边界见 .agents/notes/implemented/feature/2026-11-23-system-file-associations.md

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
)

var ErrConflict = errors.New("system file associations changed; refresh before applying")
var ErrNotPackaged = errors.New("file association registration requires an installed application")
var ErrUnsupported = errors.New("file association registration is not supported on this platform")
var ErrConfirmationPending = errors.New("a previous macOS default-application confirmation is still pending")

// FormatError preserves the exact suffixes and native failures in a partial batch.
// The settings view localizes the message; the operation log retains the cause.
type FormatError struct {
	Extensions []string
	Err        error
}

func (e *FormatError) Error() string { return strings.Join(e.Extensions, ", ") + ": " + e.Err.Error() }
func (e *FormatError) Unwrap() error { return e.Err }

// Handler is an OS observation, rather than a stored Lithe preference.
type Handler struct {
	Extension, DefaultID, DefaultName string
	IsDefault, Registered             bool
	registration                      string
}

// State retains an optimistic baseline for the explicit apply action.
type State struct {
	Formats   []core.FileAssociationFormat
	Handlers  []Handler
	Available bool
	native    nativeState
}

// Manager serializes this controller's reads and writes. Opening settings and
// changing draft checkboxes never create files or publish OS registrations.
type Manager struct {
	mu     sync.Mutex
	Kernel *core.Client
}

func New() *Manager { return &Manager{Kernel: core.NewClient()} }

// Catalog uses the exact metadata of the built-in editor, including whether a
// grammar is actually bundled. Core owns filtering, deduplication and ordering.
func Catalog(ctx context.Context, kernel *core.Client) ([]core.FileAssociationFormat, error) {
	observed := syntax.BundledFileTypes()
	languages := make([]core.FileAssociationLanguage, len(observed))
	for i, language := range observed {
		languages[i] = core.FileAssociationLanguage{
			ID: language.ID, Highlighted: language.Highlighted,
			Extensions: language.Extensions,
		}
	}
	return kernel.FileAssociationCatalog(ctx, languages)
}

func (m *Manager) Read(ctx context.Context) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	formats, err := Catalog(ctx, m.Kernel)
	if err != nil {
		return State{}, err
	}
	return readNative(ctx, formats)
}

func observations(state State) []core.FileAssociationObservation {
	result := make([]core.FileAssociationObservation, len(state.Handlers))
	for i, handler := range state.Handlers {
		result[i] = core.FileAssociationObservation{
			Extension: handler.Extension, DefaultID: handler.DefaultID,
			Registration: handler.registration,
		}
	}
	return result
}

// Apply requests changes for explicitly selected formats; macOS content-type
// aliases may share the resulting default. Native failures are followed by
// readback too, so a partially applied batch is never displayed as success.
func (m *Manager) Apply(ctx context.Context, baseline State, selected []string, menuLabel string) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	formats, err := Catalog(ctx, m.Kernel)
	if err != nil {
		return State{}, err
	}
	current, err := readNative(ctx, formats)
	if err != nil {
		return State{}, err
	}
	if !current.Available {
		return current, ErrNotPackaged
	}
	plan, err := m.Kernel.PlanFileAssociations(ctx, formats, selected, observations(baseline), observations(current))
	if err != nil {
		return current, err
	}
	if plan.Conflict {
		return current, ErrConflict
	}
	err = applyNative(ctx, current.native, plan.Extensions, menuLabel)
	// A consent timeout can follow successful writes. Keep the readback bounded
	// independently so cancellation cannot make the pre-write snapshot look current.
	readCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	after, readErr := readNative(readCtx, formats)
	if readErr != nil {
		return current, errors.Join(err, readErr)
	}
	return after, err
}
