package pluginservice

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
)

type remoteRunKernel interface {
	buildprocess.RemoteRunner
	CreateRemoteRunDirectory(context.Context, string) (string, error)
	WriteRemoteRunFile(context.Context, string, []byte) error
	ReleaseRemoteRunDirectory(context.Context, string) error
}

type remoteRun struct {
	workspace  WorkspaceContext
	connection *core.RemoteWorkspaceConnection
}

func (r *Runs) captureRemoteRun(workspace WorkspaceContext) (*remoteRun, *pluginhost.Failure) {
	if workspace.authorityKind() != "remote" {
		return nil, nil
	}
	binding := workspace.remote.binding
	if binding == nil {
		return nil, unsupportedRemoteWorkspace()
	}
	connection := binding.CaptureConnection()
	if connection == nil {
		return nil, failure(CodeRemoteDisconnected, "The remote workspace is disconnected.")
	}
	return &remoteRun{workspace: workspace, connection: connection}, nil
}

func (remote *remoteRun) refusal(ctx context.Context) *pluginhost.Failure {
	if remote.workspace.lifetime.Err() != nil {
		return contextFailure(ErrContextExpired)
	}
	if !remote.connection.IsCurrent() {
		return failure(CodeRemoteDisconnected, "The remote workspace connection changed.")
	}
	if err := ctx.Err(); err != nil {
		return hostFailureOf(err)
	}
	if remote.workspace.codeAllowed == nil || !remote.workspace.codeAllowed() {
		return failure(CodePermissionDenied, "Running a plugin command requires a trusted remote workspace.")
	}
	return nil
}

func (r *Runs) startRemote(ctx, lifetime context.Context, run *hostRun, remote *remoteRun, entry pluginmanager.Entry, manifest json.RawMessage, request runStartParams, params json.RawMessage, output func(buildprocess.Stream, string)) (runProcess, bool, *pluginhost.Failure) {
	host, ok := r.service.kernel.(remoteRunKernel)
	if !ok {
		return nil, false, unsupportedRemoteWorkspace()
	}
	lifetime = remote.connection.Context(lifetime)
	setup, cancelSetup := context.WithCancel(remote.connection.Context(ctx))
	defer cancelSetup()
	stopSetup := context.AfterFunc(lifetime, cancelSetup)
	defer stopSetup()
	setup = core.WithProjectCodeAllowed(setup, func() bool {
		return remote.refusal(ctx) == nil
	})

	temporary := ""
	if len(request.TemporaryFiles) != 0 {
		id := "run-" + rand.Text()
		run.cleanup = func() {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(lifetime), runStopTimeout)
			defer cancel()
			err := host.ReleaseRemoteRunDirectory(cleanup, id)
			if err != nil {
				r.recordRunIssue(cleanup, fmt.Errorf("release remote run directory: %w", err))
			}
		}
		var err error
		temporary, err = host.CreateRemoteRunDirectory(setup, id)
		if err != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
	}
	start, err := r.service.kernel.DecodeRunStart(setup, manifest, run.workspace.Path, temporary, params)
	if err != nil {
		return nil, false, remote.startFailure(ctx, err)
	}
	if refusal := remote.refusal(ctx); refusal != nil {
		return nil, false, refusal
	}
	launch := start.Debug != nil && start.Debug.Target.Kind == "launch"
	if start.Placement == core.ProcessPlacementUI || (start.Debug != nil && !launch && start.Debug.Target.Kind != "connection") {
		return nil, false, unsupportedRemoteWorkspace()
	}
	if launch && r.LaunchDebug == nil {
		return nil, false, failure("plugin.host.unavailable", "This host starts no debug sessions.")
	}
	executable, refusal := r.resolveRemoteRunExecutable(setup, entry, remote, manifest, start)
	if current := remote.refusal(ctx); current != nil {
		return nil, false, current
	}
	if refusal != nil {
		return nil, false, refusal
	}
	for _, file := range start.TemporaryFiles {
		data, err := file.Bytes()
		if err != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
		if err := host.WriteRemoteRunFile(setup, file.Path, data); err != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
	}

	environment := runEnvironment(executable.Environment, start.Environment)
	pathPrepend := executable.PathPrepend
	if _, explicit := start.Environment["PATH"]; explicit {
		pathPrepend = nil
	}
	if refusal := remote.refusal(ctx); refusal != nil {
		return nil, false, refusal
	}
	run.start = start
	cwd := core.RemoteScopedDirectory{Root: remote.workspace.remote.hostPath, Path: start.WorkingDirectory}
	if launch {
		resolver, ok := host.(interface {
			ResolveRemoteDebugLaunch(context.Context, core.RemoteScopedDirectory, *string, []string) (core.RemoteDebugLaunch, error)
		})
		if !ok {
			return nil, false, unsupportedRemoteWorkspace()
		}
		var pathOverride *string
		if value, ok := environment["PATH"]; ok {
			pathOverride = &value
		}
		facts, err := resolver.ResolveRemoteDebugLaunch(setup, cwd, pathOverride, pathPrepend)
		if err != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
		if !path.IsAbs(facts.Cwd) {
			return nil, false, remote.startFailure(ctx, errors.New("the remote launch directory is invalid"))
		}
		if facts.Path != nil {
			environment["PATH"] = *facts.Path
		}
		if refusal := remote.refusal(ctx); refusal != nil {
			return nil, false, refusal
		}
		process, err := r.startDebugLaunch(setup, run, executable.Path, facts.Cwd, environment)
		if err != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
		return process, true, nil
	}
	process, err := buildprocess.StartRemote(setup, lifetime, host, core.RemoteProcessOpen{
		Argv:        append([]string{executable.Path}, start.Arguments...),
		ScopedCwd:   &cwd,
		Environment: "login",
		Env:         environment,
		PathPrepend: pathPrepend,
		Label:       core.NewRemoteResourceLabel("run", start.Label),
	}, output)
	if err != nil {
		return nil, false, remote.startFailure(ctx, err)
	}
	return process, false, nil
}

func (r *Runs) resolveRemoteRunExecutable(ctx context.Context, entry pluginmanager.Entry, remote *remoteRun, manifest json.RawMessage, start core.RunStart) (RunExecutable, *pluginhost.Failure) {
	switch start.Executable.Kind {
	case "toolchain":
		return r.resolveTool(ctx, remote.workspace.Path, start.WorkingDirectory, start.Executable.Value)
	case "packaged":
		deploy := r.service.RemoteDeployment(entry.Installed, manifest, remote.workspace.remote.platform, nil)
		directory, err := deploy(ctx, []string{start.Executable.Value})
		if err != nil {
			return RunExecutable{}, remote.startFailure(ctx, err)
		}
		executable := path.Join(directory, start.Executable.Value)
		return RunExecutable{Path: executable}, nil
	default:
		return RunExecutable{}, failure(codeInvalidParams, "The executable kind is unknown.")
	}
}

func (remote *remoteRun) startFailure(ctx context.Context, err error) *pluginhost.Failure {
	if refusal := remote.refusal(ctx); refusal != nil {
		return refusal
	}
	var coreErr *core.Error
	if errors.As(err, &coreErr) {
		switch coreErr.Code {
		case core.CodeConnectionClosed:
			return failure(CodeRemoteDisconnected, "The remote workspace is disconnected.")
		case core.CodeInvalidRequest, core.CodeWorkspaceNotFound:
			return failure(codeInvalidParams, coreErr.Message)
		case core.CodePermissionDenied:
			return failure(CodePermissionDenied, coreErr.Message)
		case core.CodeProcessFailed:
			var details struct {
				RemoteCode string `json:"remoteCode"`
			}
			if json.Unmarshal([]byte(coreErr.Details), &details) == nil {
				switch details.RemoteCode {
				case "UNKNOWN_METHOD", "UNSUPPORTED":
					return unsupportedRemoteWorkspace()
				case "INVALID_PATH", "NOT_A_DIRECTORY":
					return failure(codeInvalidParams, coreErr.Message)
				}
			}
		}
	}
	return runStartFailure(err)
}

func remoteRunDisconnected(err error) bool {
	var detail *core.Error
	return errors.As(err, &detail) && detail.Code == core.CodeConnectionClosed
}
