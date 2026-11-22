package pluginsettings

import (
	"context"
	"encoding/json"
	"errors"
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// RemoteProjectStorage is the host-specific part of a settings publication.
// Core chooses the only eligible source and checks its revision on the host.
type RemoteProjectStorage interface {
	ReadProjectPluginSettings(context.Context) (core.ProjectPluginSettings, error)
	PublishProjectPluginSettings(context.Context, core.ProjectPluginSettingsBaseline, *string) (bool, bool, error)
}

// RemoteProject owns one captured attachment for the lifetime of an editor.
type RemoteProject struct {
	Connection *core.RemoteWorkspaceConnection
	Storage    RemoteProjectStorage
	Name       string
}

type remoteProjectSnapshot struct {
	project RemoteProject
	source  core.ProjectPluginSettings
	root    string
}

// LoadRemoteEditor reads the local user layer and the host project layer,
// keeping the host's baseline private so the same source can be saved.
func (s *Store) LoadRemoteEditor(ctx context.Context, manifest json.RawMessage, workspace string, presentation *Presentation, project RemoteProject) (Snapshot, error) {
	if !project.Connection.IsCurrent() {
		return Snapshot{}, remoteSourceChanged()
	}
	binding := core.RemoteWorkspaceOf(project.Connection.Context(ctx))
	if binding.LocalRoot() != workspace {
		return Snapshot{}, configfile.ErrConflict
	}
	baseline := &remoteProjectSnapshot{project: project, root: binding.RemoteRoot()}
	snapshot, err := s.load(core.WithoutRemoteWorkspace(ctx), manifest, workspace, presentation, func(ctx context.Context, relative string, _ int64) (*string, error) {
		source, err := project.Storage.ReadProjectPluginSettings(project.Connection.Context(ctx))
		if err != nil {
			return nil, err
		}
		if source.Path != relative || source.Baseline.WorkspaceIdentity == "" {
			return nil, configfile.ErrTarget
		}
		baseline.source = source
		return source.Text, nil
	})
	if err != nil {
		return Snapshot{}, err
	}
	if !project.Connection.IsCurrent() {
		return Snapshot{}, remoteSourceChanged()
	}
	snapshot.remote = baseline
	return snapshot, nil
}

func (s *remoteProjectSnapshot) displayPath() string {
	if s.source.Path == "" {
		return ""
	}
	return path.Join(s.root, s.source.Path)
}

func (s *remoteProjectSnapshot) publish(ctx context.Context, plan core.PluginSettingsEditPlan, check func() error) (bool, error) {
	if s.source.Baseline.WorkspaceIdentity == "" {
		return false, configfile.ErrTarget
	}
	if !s.project.Connection.IsCurrent() {
		return false, remoteSourceChanged()
	}
	if check != nil {
		if err := check(); err != nil {
			return false, err
		}
	}
	content := &plan.Document
	if plan.Delete {
		content = nil
	}
	committed, conflict, err := s.project.Storage.PublishProjectPluginSettings(s.project.Connection.Context(ctx), s.source.Baseline, content)
	if conflict {
		err = errors.Join(configfile.ErrConflict, err)
	}
	return committed, err
}

func (s *remoteProjectSnapshot) matches(plan core.PluginSettingsEditPlan) bool {
	if plan.Delete {
		return s.source.Text == nil
	}
	return s.source.Text != nil && *s.source.Text == plan.Document
}

func remoteSourceChanged() error {
	return &core.Error{Code: core.CodeConnectionClosed, Message: "The workspace connection changed."}
}
