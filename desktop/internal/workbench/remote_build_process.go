package workbench

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"path"
	"path/filepath"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
)

// buildProcess is the process lifetime the Run and Tests windows own.
type buildProcess interface {
	Wait() error
	Stop()
	Kill()
	Pid() int
}

// startBuildExecution runs the plan under the captured workspace attachment.
func (a *App) startBuildExecution(ctx context.Context, p *project, execution buildExecution, arguments []string, directory string, environment map[string]string, output func(buildprocess.Stream, string)) (buildProcess, error) {
	selection := execution.selection()
	remoteProcess := p.remote != nil && execution.Placement != core.ProcessPlacementUI
	if remoteProcess {
		// The host prepends these to its own login PATH.
		selection.PathPrepend = nil
	}
	spec := buildprocess.Spec{
		Kind: processledger.KindBuild, Executable: execution.Executable, Arguments: arguments,
		WorkingDirectory: directory, Environment: applyToolchainSelection(environment, selection),
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !remoteProcess {
		return buildprocess.Start(ctx, spec, output)
	}
	if core.RemoteWorkspaceOf(ctx) == nil {
		return nil, errors.New("remote execution has no workspace attachment")
	}
	relativeDirectory, err := filepath.Rel(p.root, spec.WorkingDirectory)
	if err != nil {
		return nil, err
	}
	cwd, err := remoteRunDirectory(p.remote.binding.RemoteRoot(), filepath.ToSlash(relativeDirectory))
	if err != nil {
		return nil, err
	}
	return buildprocess.StartRemote(ctx, ctx, a.kernel, core.RemoteProcessOpen{
		Argv:        append([]string{spec.Executable}, spec.Arguments...),
		ScopedCwd:   cwd,
		Environment: core.RemoteProcessEnvironmentLogin,
		Env:         spec.Environment,
		PathPrepend: execution.PathPrepend,
		Label:       core.NewRemoteResourceLabel(string(spec.Kind), spec.Executable),
	}, output)
}

// captureWorkspaceConnection takes the attachment on the window thread, before an
// operation is queued. A disconnected project has no attachment to run through.
func captureWorkspaceConnection(p *project) (*core.RemoteWorkspaceConnection, bool) {
	if p.remote == nil {
		return nil, true
	}
	connection := p.remote.binding.CaptureConnection()
	return connection, connection != nil
}

// attachedWorkspaceContext binds a queued operation to the captured attachment.
func attachedWorkspaceContext(ctx context.Context, connection *core.RemoteWorkspaceConnection) context.Context {
	if connection != nil {
		return connection.Context(ctx)
	}
	return ctx
}

// remoteBuildCandidate translates Core's planned candidate into a host lookup.
func (a *App) remoteBuildCandidate(ctx context.Context, p *project, candidate core.BuildExecutableCandidate) (buildExecution, bool, bool, error) {
	request := core.RemoteExecutableRequest{}
	terminal := candidate.Kind == "setting"
	switch candidate.Kind {
	case "setting":
		request.Kind, request.Value = "program", candidate.Path
	case "command":
		request.Kind, request.Value = "program", candidate.Command
	case "projectFile":
		request.Kind, request.Root, request.Path = "projectFile", p.remote.binding.RemoteRoot(), candidate.Path
		request.Requires = slices.Clone(candidate.Requires)
	case "environment":
		request.Kind, request.Variable, request.Path = "environment", candidate.Variable, candidate.Path
	default:
		return buildExecution{}, false, false, nil
	}
	if request.Kind == "program" && request.Value == "" {
		return buildExecution{}, false, false, nil
	}
	executable, err := a.kernel.ResolveRemoteExecutable(ctx, request)
	if err == nil && executable == "" && terminal {
		err = errors.New(a.text.Build.ExecutableMissing)
	}
	execution := buildExecution{Executable: executable}
	if terminal && executable != "" {
		execution.PathPrepend = []string{path.Dir(executable)}
	}
	return execution, terminal, executable != "", err
}

// buildScratch owns the private output location for one command until decoding
// is complete. A remote command receives package paths only after deployment.
type buildScratch struct {
	state, output, packageDirectory string
	release                         func() error
}

func (a *App) prepareBuildScratch(ctx context.Context, p *project, instance buildInstance, purpose string) (buildScratch, error) {
	cleanupCtx := context.WithoutCancel(ctx)
	if p.remote == nil {
		state := buildStateDirectory(a.plugins.Root, p.root, instance)
		if err := os.MkdirAll(state, 0o700); err != nil {
			return buildScratch{}, err
		}
		dir, err := os.MkdirTemp(state, purpose+"-")
		if err != nil {
			return buildScratch{}, err
		}
		return buildScratch{state: state, output: filepath.Join(dir, "output.json"), packageDirectory: instance.PackageDirectory,
			release: func() error {
				err := os.RemoveAll(dir)
				if err != nil {
					a.backgroundFailedIn(cleanupCtx, "build_scratch_cleanup", err)
				}
				return err
			},
		}, nil
	}
	id := "build-" + rand.Text()
	release := func() error {
		ctx, cancel := context.WithTimeout(cleanupCtx, buildStopTimeout)
		defer cancel()
		err := a.kernel.ReleaseRemoteRunDirectory(ctx, id)
		if err != nil {
			a.backgroundFailedIn(ctx, "build_scratch_cleanup", remoteLogError(err))
		}
		return err
	}
	dir, err := a.kernel.CreateRemoteRunDirectory(ctx, id)
	if err != nil {
		// Allocation can succeed on the host after the client cancels its wait.
		return buildScratch{}, errors.Join(err, release())
	}
	return buildScratch{state: dir, output: path.Join(dir, "output.json"), release: release}, nil
}

func (a *App) captureWorkspaceBuildProcess(ctx context.Context, p *project, execution buildExecution, arguments []string, directory string, environment map[string]string, documentOnStdout bool, log func(string)) (buildCommandOutput, error) {
	return collectBuildOutput(documentOnStdout, log, func(output func(buildprocess.Stream, string)) (buildProcess, error) {
		return a.startBuildExecution(ctx, p, execution, arguments, directory, environment, output)
	})
}
