package remoteconn

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The remote workspace preferences (settings › Tools › Remote Workspace) live in
// <preference root>/remote/preferences.json, the path and the size limit Core names
// (remote.preferences), next to the saved connections in the platform user preference directory.
// They are machine-local and owned by this machine's user: created on the first change, holding
// only the values the user changed, and only ever replaced whole, atomically, against the bytes
// they were read from. They are never written to a host, a workspace, the app bundle or the
// installation directory, so they do not affect code signing or Sparkle delta updates, and they
// are not copied across worktrees. They hold no secret, only the SSH program's path, the
// reconnect limit and what closing a window does to the host's programs.

// PreferencesKernel is the part of the Core client the remote workspace preferences use.
type PreferencesKernel interface {
	RemotePreferences(ctx context.Context, document *string, homeDirectory string) (core.RemotePreferences, error)
	EditRemotePreferences(ctx context.Context, document *string, edit core.RemotePreferenceEdit) (changed bool, updated *string, err error)
}

// Preferences is the preference document with the bytes it was read from.
type Preferences struct {
	// State is Core's reading: the stored values and what each automatic one resolves to.
	State core.RemotePreferences
	root  string
	home  string
	file  configfile.Snapshot
}

// Path is the file the preferences are kept in, for display.
func (p Preferences) Path() string { return p.file.Path() }

// Exists says the file was there when the preferences were read; it is created on the first change.
func (p Preferences) Exists() bool { return p.file.Exists() }

// ReadPreferences reads the preferences kept under root, the platform preference directory.
// home, the user's home directory or empty, adds the SSH configuration file to State. Reading
// creates nothing. A document Core cannot decode fails with ErrDamaged joined to Core's error;
// the returned Preferences still names its Path.
func ReadPreferences(ctx context.Context, kernel PreferencesKernel, root, home string) (Preferences, error) {
	if root == "" {
		return Preferences{}, ErrUnavailable
	}
	plan, err := kernel.RemotePreferences(ctx, nil, "")
	if err != nil {
		return Preferences{}, err
	}
	file, err := configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
	preferences := Preferences{root: root, home: home, file: file}
	if errors.Is(err, configfile.ErrTooLarge) || errors.Is(err, configfile.ErrEncoding) {
		return preferences, errors.Join(ErrDamaged, err)
	}
	if err != nil {
		return Preferences{}, err
	}
	text, err := file.Text()
	if err != nil {
		return preferences, errors.Join(ErrDamaged, err)
	}
	state, err := kernel.RemotePreferences(ctx, text, home)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			return preferences, errors.Join(ErrDamaged, err)
		}
		return Preferences{}, err
	}
	preferences.State = state
	return preferences, nil
}

// PreferencesDocument is the text of the preferences kept under root, nil when there are none,
// for the Core requests that start OpenSSH. A damaged document fails with ErrDamaged, so no
// OpenSSH starts with a program the user did not choose.
func PreferencesDocument(ctx context.Context, kernel PreferencesKernel, root string) (*string, error) {
	preferences, err := ReadPreferences(ctx, kernel, root, "")
	if err != nil {
		return nil, err
	}
	return preferences.file.Text()
}

// Edit applies edit to the bytes p was read from, publishes the result and reads the preferences
// again. A refused value fails with Core's error (core.RemoteConnectionFieldError names the
// field); a file changed since p was read fails with ErrConflict and writes nothing. committed
// reports that the new document reached the disk even when a later step failed.
func (p Preferences) Edit(ctx context.Context, kernel PreferencesKernel, edit core.RemotePreferenceEdit) (after Preferences, committed bool, err error) {
	if p.root == "" {
		return p, false, ErrUnavailable
	}
	text, err := p.file.Text()
	if err != nil {
		return p, false, errors.Join(ErrDamaged, err)
	}
	changed, document, err := kernel.EditRemotePreferences(ctx, text, edit)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			err = errors.Join(ErrDamaged, err)
		}
		return p, false, err
	}
	if changed {
		if document == nil {
			return p, false, errors.New("remoteconn: Core changed the preferences without a document")
		}
		committed, err = p.file.Replace(ctx, []byte(*document), func() error { return p.file.Verify(ctx) })
		if errors.Is(err, configfile.ErrConflict) {
			err = errors.Join(ErrConflict, err)
		}
		if err != nil {
			return p, committed, err
		}
	}
	after, err = ReadPreferences(ctx, kernel, p.root, p.home)
	return after, committed, err
}
