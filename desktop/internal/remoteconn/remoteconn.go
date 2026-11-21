// Package remoteconn keeps the SSH connections the user saved for remote development.
//
// The list lives in <preference root>/remote/connections.json, the path and the size limit Core
// names (remote.connections), inside the platform user preference directory (Application Support
// on macOS, LocalAppData on Windows). It is machine-local: it is never written to the app bundle,
// the installation directory, a plugin package or a workspace, so it does not affect code signing
// or Sparkle delta updates, and it is never copied across worktrees. It holds no secret: Core
// refuses entries that carry one, and private keys are kept as paths only (design S12, S15).
// Reading creates nothing; an edit publishes the whole document atomically against the bytes it
// was read from, and the caller reads the source again afterwards.
package remoteconn

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Kernel is the part of the Core client the saved connections use.
type Kernel interface {
	RemoteConnections(ctx context.Context, document *string) (core.RemoteConnectionsState, error)
	EditRemoteConnections(ctx context.Context, document *string, edit core.RemoteConnectionEdit) (core.RemoteConnectionsPublication, error)
}

var (
	// ErrUnavailable means there is no preference directory to keep the list in.
	ErrUnavailable = errors.New("remoteconn: no preference directory")
	// ErrDamaged means Core cannot decode the stored list; nothing can be saved until the user
	// repairs or removes the file at Source.Path.
	ErrDamaged = errors.New("remoteconn: the saved connections cannot be read")
	// ErrConflict means the file changed after it was read; nothing was written.
	ErrConflict = errors.New("remoteconn: the saved connections changed on disk")
)

// Source is the saved list with the bytes it was read from.
type Source struct {
	// Connections are the saved entries in their stored order.
	Connections []core.SavedRemoteConnection
	// Sections are the headings Core lists the entries under, in display order.
	Sections []core.RemoteConnectionSection
	root     string
	file     configfile.Snapshot
}

// Path is the file the list is kept in, for display.
func (s Source) Path() string { return s.file.Path() }

// Read reads the list kept under root, the platform preference directory. A list Core cannot
// decode fails with ErrDamaged joined to Core's error; the returned Source still names its Path.
func Read(ctx context.Context, kernel Kernel, root string) (Source, error) {
	if root == "" {
		return Source{}, ErrUnavailable
	}
	plan, err := kernel.RemoteConnections(ctx, nil)
	if err != nil {
		return Source{}, err
	}
	file, err := configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
	source := Source{root: root, file: file}
	if errors.Is(err, configfile.ErrTooLarge) || errors.Is(err, configfile.ErrEncoding) {
		return source, errors.Join(ErrDamaged, err)
	}
	if err != nil {
		return Source{}, err
	}
	text, err := file.Text()
	if err != nil {
		return source, errors.Join(ErrDamaged, err)
	}
	state, err := kernel.RemoteConnections(ctx, text)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			return source, errors.Join(ErrDamaged, err)
		}
		return Source{}, err
	}
	source.Connections = state.Connections
	source.Sections = state.Sections
	return source, nil
}

// Document is the text of the source, nil when the file does not exist, for the Core requests
// that check other hosts against the saved list.
func (s Source) Document() (*string, error) {
	if s.root == "" {
		return nil, ErrUnavailable
	}
	text, err := s.file.Text()
	if err != nil {
		return nil, errors.Join(ErrDamaged, err)
	}
	return text, nil
}

// Edit applies edit as Apply does and returns the id of the entry a save wrote.
func (s Source) Edit(ctx context.Context, kernel Kernel, edit core.RemoteConnectionEdit) (after Source, id string, committed bool, err error) {
	after, publication, committed, err := s.Apply(ctx, kernel, edit)
	return after, publication.ID, committed, err
}

// Apply applies edit to the bytes s was read from, publishes the result and reads the list again.
// It returns the list as it is now and Core's publication, whose ID and IDs name the entries a
// save or an import wrote. A refused entry fails with Core's error (core.RemoteConnectionFieldError
// names the field); a file changed since s was read fails with ErrConflict and writes nothing.
// committed reports that the new list reached the disk even when a later step failed.
func (s Source) Apply(ctx context.Context, kernel Kernel, edit core.RemoteConnectionEdit) (after Source, publication core.RemoteConnectionsPublication, committed bool, err error) {
	text, err := s.Document()
	if err != nil {
		return s, publication, false, err
	}
	publication, err = kernel.EditRemoteConnections(ctx, text, edit)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			err = errors.Join(ErrDamaged, err)
		}
		return s, publication, false, err
	}
	if publication.Changed {
		if publication.Document == nil {
			return s, publication, false, errors.New("remoteconn: Core changed the list without a document")
		}
		committed, err = s.file.Replace(ctx, []byte(*publication.Document), func() error { return s.file.Verify(ctx) })
		if errors.Is(err, configfile.ErrConflict) {
			err = errors.Join(ErrConflict, err)
		}
		if err != nil {
			return s, publication, committed, err
		}
	}
	after, err = Read(ctx, kernel, s.root)
	return after, publication, committed, err
}
