package workbench

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
)

// This file starts the built-in process runs: shell, PowerShell and batch scripts and
// programs. Core plans each run (`runConfig.createLaunchPlan`); the host only finds the
// executable, writes a script saved as text to a temporary file, and starts the process
// with its output in the Run window. No build plugin takes part, so these runs work while
// every plugin is missing or broken.
//
// Note: 内置运行和运行配置文件格式的决策见 .agents/notes/implemented/architecture/2026-11-18-builtin-process-runs-and-run-file-formats.md

// inlineScriptDirectoryPattern names the temporary directory a script saved as text runs
// from. It lives under the system's temporary directory, never in the app bundle or the
// project, and is removed once the process exits; one left by a crash is the system's to
// clean.
const inlineScriptDirectoryPattern = "lithe-run-script-"

// errRunProgramNotFound is a planned command that no PATH directory holds.
var errRunProgramNotFound = errors.New("run program not found")

// startProcessRun begins the run of a built-in process configuration, or of one of a kind a
// plugin declares, beside the window's other executions and starts it once unsaved documents
// are saved, so the process reads the files on disk. Rerun starts it again.
func (a *App) startProcessRun(p *project, configuration core.RunConfiguration) *buildOperation {
	id := configuration.ID
	op := a.beginRunOperation(p, configuration.Name, id, configurationRunKey(id), func(a *App, p *project) {
		a.runConfiguration(p, id)
	})
	a.saveProjectDocuments(p, func(ok bool) {
		if op.cancelled {
			a.finishBuildError(p, op, context.Canceled)
			return
		}
		if !ok {
			a.endBuildOperation(p, op, "failed", nil, "unsaved documents could not be saved", "")
			return
		}
		a.runBeforeLaunch(p, op, id, func() {
			if key, ok := configuration.RunTypeReference(); ok {
				a.launchDeclaredRun(p, op, id, key)
				return
			}
			if p.remote != nil {
				a.launchRemoteProcessRun(p, op, id)
				return
			}
			a.launchProcessRun(p, op, id)
		})
	})
	return op
}

// launchProcessRun plans the run, starts its process and waits for it off the window
// thread. The plan is bounded by the run preparation time; the process runs until it
// exits, the user stops it or the project closes.
func (a *App) launchProcessRun(p *project, op *buildOperation, id string) {
	root, kernel, language := p.root, a.kernel, a.language()
	a.background(p, 0, func(ctx context.Context) func(*App) {
		bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
		defer cancel()
		prepare, release := op.bind(bounded)
		defer release()
		process, cleanup, err := a.startConfiguredProcess(prepare, ctx, kernel, language, root, id, func(text string) {
			a.streamBuildOutput(p, op, text)
		})
		defer cleanup()
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.post(func(a *App) { a.attachProcess(p, op, process) })
		err = process.Wait()
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// startConfiguredProcess plans the built-in process run id under prepare and starts its
// process under run, which ends it when it ends; output receives what the process prints.
// cleanup removes the temporary directory of a script saved as text once the process
// exited, and is always set. It runs off the window thread, with the kernel and language
// taken on it.
func (a *App) startConfiguredProcess(prepare, run context.Context, kernel Kernel, language i18n.Language, root, id string, output func(string)) (*buildprocess.Process, func(), error) {
	cleanup := func() {}
	scratch, err := os.MkdirTemp("", inlineScriptDirectoryPattern)
	if err != nil {
		return nil, cleanup, err
	}
	cleanup = func() {
		if err := os.RemoveAll(scratch); err != nil {
			a.backgroundFailedIn(run, "run_inline_script_cleanup", err)
		}
	}
	plan, err := kernel.CreateRunLaunchPlan(prepare, root, id, filepath.Join(scratch, "script"))
	if err != nil {
		return nil, cleanup, err
	}
	spec, err := a.processRunSpec(prepare, root, plan)
	if errors.Is(err, errRunProgramNotFound) {
		err = errors.New(i18n.SharedFormat(language, "desktop.runConfig.programNotFound", map[string]string{"program": plan.Executable.Command}))
	}
	if err == nil && plan.InlineScript != nil {
		err = writeInlineScript(scratch, *plan.InlineScript)
	}
	if err == nil {
		err = prepare.Err()
	}
	if err != nil {
		return nil, cleanup, err
	}
	process, err := buildprocess.Start(run, spec, func(_ buildprocess.Stream, text string) { output(text) })
	return process, cleanup, err
}

// processRunSpec turns a launch plan into the process to start: the executable found, the
// working directory under the project, and the environment the plan sets over the login
// environment. A toolchain executable brings its own variables and PATH entries.
func (a *App) processRunSpec(ctx context.Context, root string, plan core.RunLaunchPlan) (buildprocess.Spec, error) {
	directory, err := projectRunDirectory(root, plan.WorkingDirectory)
	if err != nil {
		return buildprocess.Spec{}, err
	}
	environment := make(map[string]string, len(plan.Environment)+len(plan.Env))
	maps.Copy(environment, plan.Environment)
	maps.Copy(environment, plan.Env)
	spec := buildprocess.Spec{
		Kind:             processledger.KindRun,
		Arguments:        plan.Arguments,
		WorkingDirectory: directory,
		CommandLine:      plan.CommandLine,
	}
	switch executable := plan.Executable; {
	case executable.Path != "":
		if !filepath.IsAbs(executable.Path) {
			return buildprocess.Spec{}, fmt.Errorf("run program path is not absolute: %s", executable.Path)
		}
		spec.Executable = executable.Path
	case executable.Command != "":
		searchPath, set := environment["PATH"]
		if !set {
			searchPath = loginenv.Path()
		}
		spec.Executable, err = runCommandOnPath(executable.Command, searchPath)
		if err != nil {
			return buildprocess.Spec{}, err
		}
	case executable.Toolchain != "":
		selection, err := a.resolveToolchainSelection(ctx, root, plan.WorkingDirectory, executable.Toolchain, "")
		if err != nil {
			return buildprocess.Spec{}, err
		}
		spec.Executable = selection.Executable
		environment = applyToolchainSelection(environment, selection)
	default:
		return buildprocess.Spec{}, errors.New("run launch plan has no executable")
	}
	spec.Environment = environment
	return spec, nil
}

// projectRunDirectory is the native path of a project-relative '/' working directory. Core
// keeps it inside the project; one that leaves it is refused here too.
func projectRunDirectory(root, directory string) (string, error) {
	native := filepath.FromSlash(directory)
	if directory == "" {
		native = "."
	}
	if !filepath.IsLocal(native) && filepath.Clean(native) != "." {
		return "", fmt.Errorf("run working directory is outside the project: %s", directory)
	}
	return filepath.Join(root, native), nil
}

// runCommandOnPath finds a bare command name in the absolute directories of searchPath, in
// order, with the platform's executable extensions on Windows. Relative entries are skipped,
// so a command never resolves against the current directory.
func runCommandOnPath(name, searchPath string) (string, error) {
	for _, directory := range filepath.SplitList(searchPath) {
		if directory == "" || !filepath.IsAbs(directory) {
			continue
		}
		if path, err := pluginhost.CommandInDirectory(directory, name); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("%w: %s: %w", errRunProgramNotFound, name, exec.ErrNotFound)
}

// writeInlineScript writes a script saved as text where Core planned it, which must be a
// new file directly in the run's temporary directory.
func writeInlineScript(scratch string, script core.RunInlineScript) error {
	if filepath.Dir(script.Path) != filepath.Clean(scratch) {
		return fmt.Errorf("inline script is outside its temporary directory: %s", script.Path)
	}
	file, err := os.OpenFile(script.Path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o700)
	if err != nil {
		return err
	}
	_, err = file.WriteString(script.Content)
	return errors.Join(err, file.Close())
}
