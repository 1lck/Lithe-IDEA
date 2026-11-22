package pluginsettings

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"path"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// RemoteSourceHost operates on captured host files. Neither a baseline nor a
// staged output includes the native document's bytes.
type RemoteSourceHost interface {
	InspectRemoteNativeSettings(context.Context, []core.RemoteNativeSettingsTarget) ([]core.RemoteNativeSettingsBaseline, error)
	StageRemoteNativeSettings(context.Context, string, []core.RemoteNativeSettingsBaseline) ([]string, error)
	PublishRemoteNativeSettings(context.Context, string, []core.RemoteNativeSettingsReplacement) ([]uint16, bool, error)
	CreateRemoteRuntimeStaging(context.Context, string) (string, error)
	ReleaseRemoteRunDirectory(context.Context, string) error
}

type remoteSources struct {
	host       RemoteSourceHost
	connection *core.RemoteWorkspaceConnection
	baselines  map[string]core.RemoteNativeSettingsBaseline
}

// CaptureRemoteSources independently checks every writable namespace binding
// against the host before exposing its path or admitting edits.
func CaptureRemoteSources(ctx context.Context, host RemoteSourceHost, connection *core.RemoteWorkspaceConnection, state core.SourceSettingsState) (SourceEditor, error) {
	if !connection.IsCurrent() {
		return SourceEditor{}, configfile.ErrConflict
	}
	editor := SourceEditor{State: state, remote: &remoteSources{
		host: host, connection: connection, baselines: make(map[string]core.RemoteNativeSettingsBaseline),
	}}
	editor.State.Snapshot.Sources = append([]core.SettingsSource(nil), state.Snapshot.Sources...)
	targets := make([]core.RemoteNativeSettingsTarget, 0, len(state.Snapshot.Sources))
	indices := make([]int, 0, len(state.Snapshot.Sources))
	for index, source := range state.Snapshot.Sources {
		switch source.Scope {
		case "workspace", "home":
			targets = append(targets, core.RemoteNativeSettingsTarget{Scope: source.Scope, Path: source.Path})
			indices = append(indices, index)
		case "hostReadOnly":
			// Core admits only absolute paths with writable=false in this scope.
		default:
			return SourceEditor{}, configfile.ErrTarget
		}
	}
	if len(targets) != 0 {
		baselines, err := host.InspectRemoteNativeSettings(connection.Context(ctx), targets)
		if err != nil {
			return SourceEditor{}, remoteSourceError(err)
		}
		if len(baselines) != len(targets) {
			return SourceEditor{}, configfile.ErrConflict
		}
		for index, baseline := range baselines {
			source := &editor.State.Snapshot.Sources[indices[index]]
			if baseline.Target != targets[index] || baseline.Identity == "" ||
				baseline.Revision != source.Revision || !path.IsAbs(baseline.HostPath) {
				return SourceEditor{}, configfile.ErrConflict
			}
			source.Writable = source.Writable && baseline.Writable
			editor.remote.baselines[source.ID] = baseline
		}
	}
	if !connection.IsCurrent() {
		return SourceEditor{}, configfile.ErrConflict
	}
	return editor, ctx.Err()
}

// IsRemote identifies a source projection captured on a remote attachment.
func (s SourceEditor) IsRemote() bool { return s.remote != nil }

// DisplayPath returns the path the native host verified for this binding.
func (s SourceEditor) DisplayPath(source core.SettingsSource) string {
	if s.remote != nil {
		if baseline, ok := s.remote.baselines[source.ID]; ok {
			return baseline.HostPath
		}
	}
	return source.Path
}

// MatchesConnection prevents a source editor from moving to a new attachment.
func (s SourceEditor) MatchesConnection(connection *core.RemoteWorkspaceConnection) bool {
	if s.remote == nil {
		return connection == nil
	}
	return s.remote.connection.SameAttachment(connection) && s.remote.connection.IsCurrent()
}

func (s *remoteSources) apply(ctx context.Context, kernel SourceKernel, writes []core.SourceSettingsWrite, call func(context.Context, json.RawMessage) (json.RawMessage, error), check func() error) (map[string]string, error) {
	ctx = s.connection.Context(ctx)
	baselines := make([]core.RemoteNativeSettingsBaseline, len(writes))
	for index, write := range writes {
		baseline, ok := s.baselines[write.SourceID]
		if !ok || !baseline.Writable || baseline.Target.Path != write.Path || baseline.Revision != write.Revision {
			return nil, configfile.ErrConflict
		}
		baselines[index] = baseline
	}

	id := "settings-" + rand.Text()
	return s.withStaging(ctx, id, func(directory string) (map[string]string, error) {
		files, err := s.host.StageRemoteNativeSettings(ctx, id, baselines)
		if err != nil {
			return nil, remoteSourceError(err)
		}
		if len(files) != len(writes) {
			return nil, configfile.ErrConflict
		}
		var replacements []core.RemoteNativeSettingsReplacement
		for index, write := range writes {
			if path.Dir(files[index]) != directory {
				return nil, configfile.ErrTarget
			}
			if err := check(); err != nil {
				return nil, err
			}
			params, err := sourceEditRequest(write, files[index], baselines[index].HostPath)
			if err != nil {
				return nil, err
			}
			result, err := call(ctx, params)
			if err != nil {
				return nil, err
			}
			receipt, err := kernel.DecodeSourceSettingsReceipt(ctx, write, result)
			if err != nil {
				return nil, err
			}
			if receipt.Changed {
				replacements = append(replacements, core.RemoteNativeSettingsReplacement{
					Slot: uint16(index), Baseline: baselines[index], Revision: receipt.Revision,
				})
			}
		}
		if len(replacements) == 0 {
			return nil, nil
		}
		if err := check(); err != nil {
			return nil, err
		}
		committed, uncertain, err := s.host.PublishRemoteNativeSettings(ctx, id, replacements)
		published := make(map[string]string, len(committed))
		// The host acknowledges a prefix in the same order it was asked to publish.
		for index, slot := range committed {
			if index >= len(replacements) || replacements[index].Slot != slot {
				return published, errors.Join(ErrSourcesCommitted, configfile.ErrConflict, err)
			}
			published[writes[slot].SourceID] = replacements[index].Revision
		}
		if uncertain || (err == nil && len(committed) != len(replacements)) {
			return published, errors.Join(ErrSourcesCommitted, configfile.ErrConflict, err)
		}
		return published, remoteSourceError(err)
	})
}

func (s *remoteSources) withStaging(ctx context.Context, id string, use func(string) (map[string]string, error)) (published map[string]string, err error) {
	// Allocation can succeed remotely while the client loses its reply.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		err = errors.Join(err, s.host.ReleaseRemoteRunDirectory(cleanup, id))
	}()
	dir, err := s.host.CreateRemoteRuntimeStaging(ctx, id)
	if err != nil {
		return nil, err
	}
	return use(dir)
}

func remoteSourceError(err error) error {
	if core.IsRemoteNativeSettingsConflict(err) {
		return errors.Join(configfile.ErrConflict, err)
	}
	return err
}
