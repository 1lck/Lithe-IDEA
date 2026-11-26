package workbench

// Steps before launch (#1616): a run configuration names steps that start, in order, before
// it does, as IntelliJ IDEA's "Before launch" list: another built-in process run, or a task a
// plugin declares (API-29, `beforeLaunchTasks`), such as running a build tool's command. Core
// expands the list and says whether a project file named it (`runConfig.beforeLaunch`); the
// host asks once per list a project file names, runs each step (a process run as its launch
// plan, a task as Core's plan of it, `build.beforeLaunchTaskPlan`, by the build tool the
// plugin's detected instance resolves), writes the output to the console of the configuration
// that starts, and starts the configuration only after every step exited with 0. Stopping the
// configuration stops the step that runs.
//
// Note: 决策见 .agents/notes/implemented/feature/2026-11-18-run-configuration-before-launch-steps.md

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// beforeLaunchApprovalsFile keeps, per project root, the fingerprints of the step lists a
// project file names that the user allowed to run. It lives in the app's own storage, never
// in the project, so a repository cannot approve its own steps.
const beforeLaunchApprovalsFile = "run-before-launch-approvals.json"

// beforeLaunchApprovalsLimit bounds the fingerprints kept per project; the oldest go first.
const beforeLaunchApprovalsLimit = 64

// beforeLaunchConfirmation is the open question whether to run the steps a project file
// names before op starts.
type beforeLaunchConfirmation struct {
	op          *buildOperation
	name        string
	steps       []core.RunBeforeLaunchItem
	fingerprint string
	// run continues the start once the user allowed the steps.
	run func()
}

// runBeforeLaunch runs the steps configuration id names before op starts, then calls start
// on the window thread. A list that cannot run, a step that fails and a stop end op instead,
// with the reason in its console.
func (a *App) runBeforeLaunch(p *project, op *buildOperation, id string, start func()) {
	root, kernel := p.root, a.kernel
	kinds, language := p.runConfigs.kinds(), a.language().Code()
	a.background(p, runPreparationTimeout, func(ctx context.Context) func(*App) {
		prepare, release := op.bind(ctx)
		defer release()
		steps, err := kernel.RunBeforeLaunch(prepare, root, id, a.runTypePlugins(prepare, kernel, kinds, language))
		return func(a *App) {
			if !a.ownsLiveOperation(p, op) {
				a.finishBuildError(p, op, context.Canceled)
				return
			}
			if err != nil {
				a.finishBuildError(p, op, err)
				return
			}
			if steps.Status != "ok" {
				a.refuseBeforeLaunch(p, op, steps.Refusal)
				return
			}
			if len(steps.Steps) == 0 {
				start()
				return
			}
			// A remote workspace runs a step that starts another built-in run on its host. A
			// plugin's task is planned by the plugin's backend on this computer, which reads no
			// host files (#2231 §2, R3), so a list naming one does not start.
			if p.remote != nil && slices.ContainsFunc(steps.Steps, func(step core.RunBeforeLaunchItem) bool { return step.Task != nil }) {
				message := i18n.Shared(a.language(), "desktop.run.remote.beforeLaunch")
				a.operationRejected("run_before_launch", "remote_workspace")
				a.notifyError(message)
				a.finishBuildError(p, op, errors.New(message))
				return
			}
			run := func() { a.runBeforeLaunchSteps(p, op, steps.Steps, start) }
			if steps.Confirmation == nil || a.beforeLaunchApproved(root, steps.Confirmation.Fingerprint) {
				run()
				return
			}
			p.runConfigs.beforeLaunch = &beforeLaunchConfirmation{
				op: op, name: op.session.label, steps: steps.Steps, fingerprint: steps.Confirmation.Fingerprint, run: run,
			}
		}
	})
}

// ownsLiveOperation reports whether op is still the window's and was not stopped.
func (a *App) ownsLiveOperation(p *project, op *buildOperation) bool {
	return a.project == p && p.build.owns(op) && !op.cancelled
}

// refuseBeforeLaunch ends op with why its steps cannot run. A refusal of a task step names
// the configuration that lists it and the task's kind.
func (a *App) refuseBeforeLaunch(p *project, op *buildOperation, refusal *core.RunBeforeLaunchRefusal) {
	code, step, task := "", "", ""
	if refusal != nil {
		code, step = refusal.Code, refusal.ConfigurationID
		if refusal.Task != nil {
			task = refusal.Task.Type
		}
	}
	if configuration := p.runConfigs.configuration(step); configuration != nil {
		step = configuration.Name
	}
	language := a.language()
	var message string
	switch code {
	case "notFound":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.notFound", map[string]string{"step": step})
	case "notAllowed":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.notAllowed", map[string]string{"step": step})
	case "unavailable":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.unavailable", map[string]string{"step": step})
	case "cycle":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.cycle", map[string]string{"step": step})
	case "tooLong":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.tooLong", map[string]string{"step": step})
	case "taskNotDeclared":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.taskNotDeclared", map[string]string{"step": step, "task": task})
	case "invalidTaskValues":
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.invalidTaskValues", map[string]string{"step": step, "task": task})
	default:
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.refused.other", map[string]string{"step": step})
	}
	a.operationRejected("run_before_launch", "refused")
	a.notifyError(message)
	a.finishBuildError(p, op, errors.New(message))
}

// beforeLaunchRun is what the steps of one start take from the window thread: the project,
// the kernel and language, the build messages and plugin directory a task's plan needs, and,
// per step that runs a plugin's task, the detected instances of the build system that
// declares it. remote runs a remote workspace's steps on its host, nil for a local project.
type beforeLaunchRun struct {
	root, pluginRoot string
	kernel           Kernel
	language         i18n.Language
	messages         i18n.BuildMessages
	instances        [][]buildInstance
	remote           *remoteRunHost
}

// runBeforeLaunchSteps starts each step in order off the window thread and waits for it;
// start runs once the last one exited with 0. Each step is bounded like a run's
// preparation and ends when op is stopped.
func (a *App) runBeforeLaunchSteps(p *project, op *buildOperation, steps []core.RunBeforeLaunchItem, start func()) {
	run := beforeLaunchRun{
		root: p.root, kernel: a.kernel, language: a.language(), messages: a.text.Build,
		instances: make([][]buildInstance, len(steps)),
	}
	if a.plugins != nil {
		run.pluginRoot = a.plugins.Root
	}
	for index, step := range steps {
		if step.Task != nil {
			run.instances[index] = p.runTypeInstances(step.Task.RunTypeKey)
		}
	}
	if p.remote != nil {
		host := a.remoteRunHostOf(p, op)
		run.remote = &host
	}
	a.background(p, 0, func(ctx context.Context) func(*App) {
		if run.remote != nil {
			run.remote.failed = func(operation string, err error) { a.backgroundFailedIn(ctx, operation, remoteLogError(err)) }
		}
		for index, step := range steps {
			header := i18n.SharedFormat(run.language, "desktop.runConfig.beforeLaunch.stepHeader", map[string]string{
				"index": fmt.Sprint(index + 1), "count": fmt.Sprint(len(steps)), "name": step.Name,
			})
			a.streamBuildOutput(p, op, "\x1b[2m"+header+"\x1b[0m\n")
			if err := a.runBeforeLaunchStep(ctx, p, op, run, run.instances[index], step); err != nil {
				return func(a *App) { a.failBeforeLaunch(p, op, step, err) }
			}
		}
		return func(a *App) {
			if !a.ownsLiveOperation(p, op) {
				a.finishBuildError(p, op, context.Canceled)
				return
			}
			start()
		}
	})
}

// runBeforeLaunchStep starts one step's process with its output in op's console and waits
// for it to exit. instances are the detected instances of the build system whose task the
// step runs, nil for a process run.
func (a *App) runBeforeLaunchStep(ctx context.Context, p *project, op *buildOperation, run beforeLaunchRun, instances []buildInstance, step core.RunBeforeLaunchItem) error {
	bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
	defer cancel()
	prepare, release := op.bind(bounded)
	defer release()
	output := func(text string) { a.streamBuildOutput(p, op, text) }
	if step.Task != nil {
		return a.runBeforeLaunchTask(prepare, p, run, instances, step, output)
	}
	if run.remote != nil {
		return run.remote.runStep(ctx, prepare, step)
	}
	process, cleanup, err := a.startConfiguredProcess(prepare, prepare, run.kernel, run.language, run.root, step.ConfigurationID, output)
	defer cleanup()
	if err != nil {
		return err
	}
	return process.Wait()
}

// runBeforeLaunchTask starts the process of a plugin's task step under ctx and waits for it:
// Core plans the build system's command with the saved values, at the step's working
// directory, and the build tool of the instance the plan picks runs it. A build system with
// no detected instance cannot run the task.
func (a *App) runBeforeLaunchTask(ctx context.Context, p *project, run beforeLaunchRun, instances []buildInstance, step core.RunBeforeLaunchItem, output func(string)) error {
	if len(instances) == 0 || run.pluginRoot == "" {
		return errors.New(run.messages.TargetMissing)
	}
	task := *step.Task
	spec, err := a.declaredProcessSpec(ctx, p, run.root, run.pluginRoot, instances, run.messages, func(manifest json.RawMessage, sources declaredPlanSources) (core.BuildPlan, error) {
		return run.kernel.PlanBeforeLaunchTask(ctx, manifest, task.BuildSystemID, run.root, core.BeforeLaunchTaskPlanRequest{
			Task: task, WorkingDirectory: step.WorkingDirectory, Instances: sources.instances,
			PluginDirectory: sources.pluginDirectory, WorkspaceStateDirectory: sources.stateDirectory,
			ProjectCodeAllowed: p.trust.allowed(),
		})
	})
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		return err
	}
	process, err := buildprocess.Start(ctx, spec, func(_ buildprocess.Stream, text string) { output(text) })
	if err != nil {
		return err
	}
	return process.Wait()
}

// failBeforeLaunch ends op because step did not exit with 0, naming the step and its exit
// code; a stop ends it as stopped.
func (a *App) failBeforeLaunch(p *project, op *buildOperation, step core.RunBeforeLaunchItem, err error) {
	if !a.ownsLiveOperation(p, op) || errors.Is(err, context.Canceled) {
		a.finishBuildError(p, op, context.Canceled)
		return
	}
	language := a.language()
	// A local process ends with an *exec.ExitError, a host process with a remoteRunExit.
	var exit interface{ ExitCode() int }
	message := i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.failed", map[string]string{"name": step.Name, "reason": err.Error()})
	if errors.As(err, &exit) {
		message = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.exited", map[string]string{"name": step.Name, "code": fmt.Sprint(exit.ExitCode())})
	}
	a.writeBuildOutputNow(p, op, message+"\n")
	a.finishBuildError(p, op, errors.New(message))
}

// beforeLaunchApproved reports whether the user allowed the step list fingerprint in the
// project at root. A store that cannot be read approves nothing, so the user is asked.
func (a *App) beforeLaunchApproved(root, fingerprint string) bool {
	if a.store == nil {
		return false
	}
	all := map[string][]string{}
	if _, err := a.store.Load(beforeLaunchApprovalsFile, &all); err != nil {
		a.backgroundFailed("run_before_launch_approvals", err)
		return false
	}
	return slices.Contains(all[root], fingerprint)
}

// approveBeforeLaunch remembers that the user allowed fingerprint in the project at root.
func (a *App) approveBeforeLaunch(root, fingerprint string) {
	if a.store == nil {
		return
	}
	all := map[string][]string{}
	if _, err := a.store.Load(beforeLaunchApprovalsFile, &all); err != nil {
		a.backgroundFailed("run_before_launch_approvals", err)
		all = map[string][]string{}
	}
	approved := slices.DeleteFunc(all[root], func(known string) bool { return known == fingerprint })
	approved = append(approved, fingerprint)
	if len(approved) > beforeLaunchApprovalsLimit {
		approved = approved[len(approved)-beforeLaunchApprovalsLimit:]
	}
	all[root] = approved
	if err := a.store.Save(beforeLaunchApprovalsFile, all); err != nil {
		a.backgroundFailed("run_before_launch_approvals", err)
	}
}

// cancelBeforeLaunch closes the open question and ends its configuration without starting it.
func (a *App) cancelBeforeLaunch(p *project) {
	ask := p.runConfigs.beforeLaunch
	if ask == nil {
		return
	}
	p.runConfigs.beforeLaunch = nil
	a.finishBuildError(p, ask.op, context.Canceled)
}

// drawBeforeLaunchConfirmation declares the question whether to run the steps a project file
// names: each step's name and what it starts. Run remembers the list for this project; Cancel
// does not start the configuration. A stop while it is open closes it.
func (a *App) drawBeforeLaunchConfirmation(c ui.C, p *project) {
	ask := p.runConfigs.beforeLaunch
	if ask == nil {
		return
	}
	cancel := func() { a.cancelBeforeLaunch(p) }
	if !a.ownsLiveOperation(p, ask.op) {
		c.After(cancel)
		return
	}
	language := a.language()
	open := true
	title := i18n.Shared(language, "desktop.runConfig.beforeLaunch.confirmTitle")
	closed := ui.Modal(c, &open, title, ui.ModalSpec{Width: 520}, func() {
		k := c.Part("run-before-launch-confirm")
		ui.Column(k).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, i18n.SharedFormat(language, "desktop.runConfig.beforeLaunch.confirmBody", map[string]string{"name": ask.name}), 4).Color(a.colors.Text)
			for index, step := range ask.steps {
				row := k.Part(fmt.Sprint(index))
				ui.Column(row).FillWidth().Gap(2).Children(func() {
					ui.Text(c, fmt.Sprintf("%d. %s", index+1, step.Name)).Weight(gfx.WeightSemibold).Color(a.colors.Text).Ellipsis()
					if step.Summary != "" {
						ui.Text(c, step.Summary).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
					}
				})
			}
		})
	}, func() {
		ui.Row(c.Part("run-before-launch-confirm-footer")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Spacer(c)
			if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
				c.After(func() {
					a.performed("run.beforeLaunch.cancel", surfaceButton)
					cancel()
				})
			}
			if ui.Button(c, i18n.Shared(language, "desktop.runConfig.beforeLaunch.confirmRun")).Clicked() {
				c.After(func() {
					p.runConfigs.beforeLaunch = nil
					a.performed("run.beforeLaunch.allow", surfaceButton)
					a.approveBeforeLaunch(p.root, ask.fingerprint)
					ask.run()
				})
			}
		})
	})
	if closed {
		c.After(cancel)
	}
}
