package pluginservice

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"path"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type remoteSettingsHelperKernel interface {
	RunRemoteProcess(context.Context, core.RemoteProcessOpen, core.RemoteProcessEvents) (core.RemoteProcessExit, error)
	CreateRemoteRuntimeStaging(context.Context, string) (string, error)
	ReleaseRemoteRunDirectory(context.Context, string) error
	WriteRemoteRunFile(context.Context, string, []byte) error
}

const remoteSettingsOutputLimit = 2 * 1024 * 1024

// CheckRemoteSettingsWorkspace uses the live trust decision of the editor's
// original attachment. Read-back and publication share this check.
func (s *Service) CheckRemoteSettingsWorkspace(editor SettingsEditor) error {
	_, err := s.remoteSettingsWorkspace(editor)
	return err
}

func (s *Service) remoteSettingsWorkspace(editor SettingsEditor) (WorkspaceContext, error) {
	workspace, ok := s.Contexts.ByPath(editor.Snapshot.Workspace())
	if !ok || workspace.remote.binding == nil || workspace.lifetime.Err() != nil {
		return WorkspaceContext{}, configfile.ErrConflict
	}
	connection := workspace.remote.binding.CaptureConnection()
	if !connection.SameAttachment(editor.RemoteConnection()) || !connection.IsCurrent() {
		return WorkspaceContext{}, configfile.ErrConflict
	}
	if workspace.codeAllowed == nil || !workspace.codeAllowed() {
		return WorkspaceContext{}, &core.Error{Code: core.CodePermissionDenied, Message: "Native settings require a trusted remote workspace."}
	}
	return workspace, nil
}

// PrepareRemoteSettingsHelper uses the same approved package variant and lease
// as other native providers, with an invocation scoped to this workspace.
func (s *Service) PrepareRemoteSettingsHelper(ctx context.Context, editor SettingsEditor, plan core.PluginSettingsActionPlan, check func() error) (func(context.Context, json.RawMessage) (json.RawMessage, error), error) {
	if plan.Kind != "invoke" || !plan.SourceEditor {
		return nil, configfile.ErrConflict
	}
	if err := check(); err != nil {
		return nil, err
	}
	kernel, ok := s.kernel.(remoteSettingsHelperKernel)
	if !ok || plan.RemoteHelper == nil {
		return nil, &core.Error{Code: core.CodeNotSupported, Message: "This plugin does not provide a remote native settings helper."}
	}
	workspace, err := s.remoteSettingsWorkspace(editor)
	if err != nil {
		return nil, err
	}
	connection := editor.RemoteConnection()
	ctx, done := remoteSettingsHelperContext(ctx, workspace, connection)
	defer done()
	helper := plan.RemoteHelper
	required := append([]string{helper.Executable}, helper.Resources...)
	directory, err := s.prepareRemoteDeployment(ctx, editor.entry.Installed, editor.manifest, workspace.HostPlatform(), required, nil)
	if err != nil {
		return nil, err
	}
	argv := append([]string{path.Join(directory, helper.Executable)}, helper.Arguments...)
	return func(ctx context.Context, request json.RawMessage) (json.RawMessage, error) {
		return runRemoteSettingsHelper(ctx, kernel, workspace, connection, argv, request, check)
	}, nil
}

func remoteSettingsHelperContext(ctx context.Context, workspace WorkspaceContext, connection *core.RemoteWorkspaceConnection) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(connection.Context(ctx), 60*time.Second)
	stopClose := context.AfterFunc(workspace.lifetime, cancel)
	stopDetach := connection.AfterDetach(cancel)
	return ctx, func() {
		stopClose()
		stopDetach()
		cancel()
	}
}

func runRemoteSettingsHelper(ctx context.Context, kernel remoteSettingsHelperKernel, workspace WorkspaceContext, connection *core.RemoteWorkspaceConnection, argv []string, request json.RawMessage, check func() error) (_ json.RawMessage, err error) {
	if err := check(); err != nil {
		return nil, err
	}
	ctx, done := remoteSettingsHelperContext(ctx, workspace, connection)
	defer done()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	id := "settings-request-" + rand.Text()
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if cleanupErr := kernel.ReleaseRemoteRunDirectory(cleanup, id); cleanupErr != nil {
			err = errors.Join(err, cleanupErr)
		}
	}()
	directory, err := kernel.CreateRemoteRuntimeStaging(ctx, id)
	if err != nil {
		return nil, err
	}
	input := path.Join(directory, "request.json")
	if err := kernel.WriteRemoteRunFile(ctx, input, request); err != nil {
		return nil, err
	}
	if err := check(); err != nil {
		return nil, err
	}
	var output bytes.Buffer
	var oversized bool
	exit, err := kernel.RunRemoteProcess(ctx, core.RemoteProcessOpen{
		Argv:        append(append([]string(nil), argv...), input),
		ScopedCwd:   &core.RemoteScopedDirectory{Root: workspace.remote.hostPath},
		Environment: "login",
	}, core.RemoteProcessEvents{Output: func(stream string, data []byte) {
		if stream != "stdout" || oversized {
			return
		}
		if output.Len()+len(data) > remoteSettingsOutputLimit {
			oversized = true
			cancel()
			return
		}
		output.Write(data)
	}})
	if oversized {
		return nil, configfile.ErrTooLarge
	}
	if err != nil {
		return nil, err
	}
	if exit.ExitCode == nil || *exit.ExitCode != 0 || !json.Valid(output.Bytes()) {
		return nil, &core.Error{Code: core.CodeProcessFailed, Message: "The remote native settings helper did not return a valid result."}
	}
	if err := check(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
