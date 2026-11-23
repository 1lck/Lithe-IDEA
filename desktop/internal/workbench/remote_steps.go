package workbench

import (
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// While Connect runs, the page beside the list shows its steps as Core reports them
// (core.WithRemoteStages), how long each took, the upload of the server build, and the questions
// OpenSSH asks, under the step that asks them: the host key under the connection, the rest under
// the authentication. The authentication dialog leaves those questions to the page while it is
// shown. A connection that fails stays on the page, at the step it failed, with why.
//
// A WSL distribution has no OpenSSH configuration to read and asks nothing, so its steps start at
// the connection, named as starting the distribution: Core reports the same stages once its shell
// answers.

// remoteStep is one step of a connection, in the order they run.
type remoteStep int

const (
	remoteStepConfig remoteStep = iota
	remoteStepConnect
	remoteStepAuthenticate
	remoteStepPlatform
	remoteStepInstall
	remoteStepSession
	remoteStepCount
)

// remoteStepName is step's name.
func remoteStepName(language i18n.Language, step remoteStep) string {
	switch step {
	case remoteStepConfig:
		return i18n.Shared(language, "desktop.remote.step.config")
	case remoteStepConnect:
		return i18n.Shared(language, "desktop.remote.step.connect")
	case remoteStepAuthenticate:
		return i18n.Shared(language, "desktop.remote.step.authenticate")
	case remoteStepPlatform:
		return i18n.Shared(language, "desktop.remote.step.platform")
	case remoteStepInstall:
		return i18n.Shared(language, "desktop.remote.step.install")
	default:
		return i18n.Shared(language, "desktop.remote.step.session")
	}
}

// remoteSteps is a connection the page shows running, or failed.
type remoteSteps struct {
	entry core.SavedRemoteConnection
	host  remoteHost
	// folder is what opens once connected, "" to choose one.
	folder string
	// reached is the step running, or the one that failed.
	reached remoteStep
	began   time.Time
	took    [remoteStepCount]time.Duration
	// sent and total are the bytes of the server build uploaded so far, while one is uploaded.
	sent, total uint64
	failed      bool
	outcome     *remoteProbeOutcome
}

// newRemoteSteps starts showing a connection to host, named as entry. The configuration is read
// before Core starts, so the connection itself runs first.
func newRemoteSteps(entry core.SavedRemoteConnection, host remoteHost, folder string, now time.Time) *remoteSteps {
	return &remoteSteps{entry: entry, host: host, folder: folder, reached: remoteStepConnect, began: now}
}

// shows says whether the page lists step: every step over SSH, a container on an SSH host
// included, and over WSL or into a container of this computer the steps after starting the
// distribution or entering the container, which read no configuration and ask nothing.
func (s *remoteSteps) shows(step remoteStep) bool {
	return s.host.overSSH() || (step != remoteStepConfig && step != remoteStepAuthenticate)
}

// name is step's name for this connection: over WSL, the connection starts the distribution, and
// into a container of this computer it enters the container. A container on a host is entered by
// the same command that logs in there, so its steps are its host's.
func (s *remoteSteps) name(language i18n.Language, step remoteStep) string {
	switch {
	case step == remoteStepConnect && s.host.container != nil && !s.host.hosted():
		return i18n.Shared(language, "desktop.remote.container.start")
	case step == remoteStepConnect && s.host.wsl != nil:
		return i18n.Shared(language, "desktop.remote.wsl.start")
	}
	return remoteStepName(language, step)
}

// advance ends the steps before to.
func (s *remoteSteps) advance(now time.Time, to remoteStep) {
	for s.reached < to {
		s.took[s.reached] = now.Sub(s.began)
		s.began = now
		s.reached++
	}
}

// observe takes a stage Core reported.
func (s *remoteSteps) observe(now time.Time, stage core.RemoteStage) {
	switch stage.Stage {
	case core.RemoteStageAuthenticated:
		s.advance(now, remoteStepPlatform)
	case core.RemoteStagePlatformChecked:
		s.advance(now, remoteStepInstall)
	case core.RemoteStageUploading:
		s.advance(now, remoteStepInstall)
		s.sent, s.total = stage.SentBytes, stage.TotalBytes
	case core.RemoteStageInstalled:
		s.advance(now, remoteStepSession)
	}
}

// fail ends the connection with outcome, at the step it says failed.
func (s *remoteSteps) fail(now time.Time, outcome *remoteProbeOutcome, language i18n.Language) {
	step := s.reached
	switch {
	case outcome.err != nil:
		if remoteConnectFailureText(language, outcome.err) != "" {
			step = remoteStepInstall
		}
	case outcome.result.Status == core.RemoteProbeUnreachable, outcome.result.Status == core.RemoteProbeHostKeyRejected:
		step = remoteStepConnect
	case outcome.result.Status == core.RemoteProbeAuthenticationFailed:
		step = remoteStepAuthenticate
	case outcome.result.Status == core.RemoteProbeUnsupportedPlatform:
		step = remoteStepPlatform
	}
	if step > s.reached {
		s.advance(now, step)
	} else {
		s.reached = step
	}
	s.failed, s.outcome = true, outcome
}

// remoteQuestion is the question OpenSSH asks now, nil when none is asked.
func (a *App) remoteQuestion() *gitAuthQuestion {
	if g := &a.gitAuth; len(g.queue) > 0 && g.queue[0].Remote {
		return &g.queue[0]
	}
	return nil
}

// remoteAsksOnPage says whether the page shows OpenSSH's questions, so the authentication dialog
// leaves them to it.
func (a *App) remoteAsksOnPage() bool {
	r := &a.remote
	return r.open && r.steps != nil && !r.steps.failed && r.importer == nil && r.trust == nil && r.browser == nil
}

// remoteStepsView declares the connection's steps.
func (a *App) remoteStepsView(c ui.C, language i18n.Language, s *remoteSteps) {
	question := a.remoteQuestion()
	reached := s.reached
	if question != nil && question.Kind != core.RemoteQuestionHostKey && reached == remoteStepConnect && !s.failed {
		// OpenSSH asks for a password once connected.
		reached = remoteStepAuthenticate
	}
	title := i18n.SharedFormat(language, "desktop.remote.steps.title", map[string]string{"name": s.entry.Name})
	if s.failed {
		title = i18n.SharedFormat(language, "desktop.remote.steps.failed", map[string]string{"name": s.entry.Name})
	}
	ui.Scroll(c.Part("steps")).Fill().Children(func() {
		ui.Column(c).FillWidth().Gap(18).PadSides(20, 24, 24, 24).Children(func() {
			ui.Row(c.Part("head")).FillWidth().Items(ui.Center).Gap(14).Children(func() {
				a.remoteTile(c.Part("tile"), remoteSystemMark(a.remote.probedOutcome(s.entry.Connection)), s.entry.Name, s.entry.Color, remoteHeroTile, 15)
				ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
					ui.Text(c, title).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().MinWidth(0)
					ui.Text(c, s.host.address()).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
				})
			})
			a.remoteBordered(c.Part("list")).Children(func() {
				first := true
				for step := remoteStepConfig; step < remoteStepCount; step++ {
					if !s.shows(step) {
						continue
					}
					k := c.KeyInt(int(step))
					if !first {
						ui.Row(k.Part("line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
					}
					first = false
					a.remoteStepRow(k, language, s, step, reached, question)
				}
			})
			if s.failed && s.outcome != nil {
				a.remoteOutcomeBox(c.Part("outcome"), language, s.outcome)
			}
		})
	})
}

// remoteStepRow declares a step: done, running, failed or still to come, and the question it
// asks.
func (a *App) remoteStepRow(c ui.C, language i18n.Language, s *remoteSteps, step, reached remoteStep, question *gitAuthQuestion) {
	small := a.theme.Metrics.FontSizeS
	done := step < reached
	current := step == reached
	ui.Column(c).FillWidth().Gap(10).PadSides(10, 12, 10, 12).Children(func() {
		ui.Row(c.Part("head")).FillWidth().Items(ui.Center).Gap(10).Children(func() {
			ui.Row(c.Part("mark")).Size(16, 16).Shrink(0).Center().Children(func() {
				switch {
				case done:
					ui.Icon(c, icons.CircleCheck).Size(16, 16).Color(a.colors.Success)
				case current && s.failed:
					ui.Icon(c, icons.CircleX).Size(16, 16).Color(a.theme.Danger)
				case current:
					ui.Spinner(c).Size(14, 14)
				default:
					ui.Row(c.Part("todo")).Size(12, 12).Radius(6).Stroke(1, a.colors.TabIdleBorder)
				}
			})
			color := a.colors.Text
			if !done && !current {
				color = a.colors.Subtle
			}
			label := ui.Text(c, s.name(language, step)).Color(color).Grow(1).MinWidth(0).Ellipsis()
			if current {
				label.Weight(gfx.WeightMedium)
			}
			if done && s.took[step] >= 100*time.Millisecond {
				ui.Text(c, remoteDuration(language, s.took[step])).Mono().FontSize(small).Color(a.colors.Subtle).Shrink(0)
			}
		})
		if step == remoteStepInstall && current && !s.failed && s.total > 0 {
			ui.Column(c.Part("upload")).FillWidth().Gap(4).PadSides(0, 0, 0, 26).Children(func() {
				ui.Progress(c.Part("progress"), float32(s.sent)/float32(s.total)).FillWidth()
				ui.Text(c, i18n.SharedFormat(language, "desktop.remote.steps.upload", map[string]string{
					"sent": memorySize(language, s.sent), "total": memorySize(language, s.total),
				})).Mono().FontSize(small).Color(a.colors.Subtle)
			})
		}
		if question == nil || s.failed {
			return
		}
		asks := remoteStepAuthenticate
		if question.Kind == core.RemoteQuestionHostKey {
			asks = remoteStepConnect
		}
		if step == asks {
			a.remoteQuestionCard(c.Part("question"), language, s, *question)
		}
	})
}

// remoteDuration says how long a step took.
func remoteDuration(language i18n.Language, took time.Duration) string {
	return i18n.SharedFormat(language, "desktop.remote.seconds", map[string]string{"count": strconv.FormatFloat(took.Seconds(), 'f', 1, 64)})
}

// remoteQuestionCard declares OpenSSH's question under the step that asks it: the host's key to
// trust, or a field for the answer.
func (a *App) remoteQuestionCard(c ui.C, language i18n.Language, s *remoteSteps, head gitAuthQuestion) {
	g := &a.gitAuth
	g.answering(head)
	small := a.theme.Metrics.FontSizeS
	id := head.RequestID
	answer := func(text string, confirm bool) {
		c.After(func() {
			if text != "" {
				a.gitAuth.field.SetText(text)
			}
			a.answerGitAuth(id, confirm)
		})
	}
	ui.Column(c).FillWidth().Gap(10).Pad(12).MarginLeft(26).Radius(6).Background(a.colors.Hover).Stroke(1, a.colors.Line).Children(func() {
		switch {
		case head.Kind == core.RemoteQuestionHostKey:
			ui.Text(c, i18n.SharedFormat(language, "desktop.remote.hostKey.title", map[string]string{"host": s.entry.Connection.Host})).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
			for index, item := range [][2]string{
				{i18n.Shared(language, "desktop.remote.hostKey.type"), head.KeyType},
				{i18n.Shared(language, "desktop.remote.hostKey.fingerprint"), head.Fingerprint},
			} {
				if item[1] == "" {
					continue
				}
				k := c.KeyInt(index)
				ui.Row(k).FillWidth().Items(ui.Center).Gap(10).Children(func() {
					ui.Text(c, item[0]).FontSize(small).Color(a.colors.Subtle).Width(80).Shrink(0)
					ui.Text(c, item[1]).Mono().FontSize(small).Ellipsis().Grow(1).MinWidth(0)
				})
			}
			ui.Paragraph(c, i18n.Shared(language, "desktop.remote.hostKey.hint"), 3).FontSize(small).Color(a.colors.Subtle)
			ui.Row(c.Part("buttons")).FillWidth().Gap(8).Children(func() {
				ui.Spacer(c)
				if ui.Button(c.Part("reject"), i18n.Shared(language, "desktop.remote.hostKey.reject")).Outline().Clicked() {
					answer("no", true)
				}
				if ui.Button(c.Part("trust"), i18n.Shared(language, "desktop.remote.hostKey.trust")).Clicked() {
					answer("yes", true)
				}
			})
		case head.Retry:
			ui.Paragraph(c, i18n.Shared(language, "desktop.gitAuth.retryMessage"), 3).Color(a.theme.Danger)
			ui.Row(c.Part("buttons")).FillWidth().Gap(8).Children(func() {
				ui.Spacer(c)
				if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Clicked() {
					answer("", false)
				}
				if ui.Button(c.Part("retry"), i18n.Shared(language, "desktop.gitAuth.retry")).Clicked() {
					answer("", true)
				}
			})
		default:
			ui.Text(c, i18n.Shared(language, "desktop.remote.question.asks")).Weight(gfx.WeightMedium)
			if prompt := strings.TrimSpace(head.Prompt); prompt != "" {
				ui.Paragraph(c, prompt, 3).Mono().FontSize(small).Color(a.colors.Subtle)
			}
			a.gitAuthAgain(c, language, head, small)
			field := ui.TextField(c.Part(head.RequestID), &g.field, i18n.Shared(language, "desktop.remote.question.answer"), "").FillWidth().AutoFocus()
			if head.Secret {
				field = field.Secure()
			}
			submitted := field.Submitted()
			a.gitAuthKeeping(c, language, head, small)
			ui.Row(c.Part("buttons")).FillWidth().Gap(8).Children(func() {
				ui.Spacer(c)
				if ui.Button(c.Part("cancel"), i18n.Shared(language, "desktop.remote.cancel")).Outline().Clicked() {
					answer("", false)
				}
				if ui.Button(c.Part("continue"), i18n.Shared(language, "desktop.remote.question.continue")).Clicked() || submitted {
					answer("", true)
				}
			})
		}
	})
}

// remoteStepsFooter declares the buttons under a connection: Stop while it runs; back to the
// connection, its form, or again once it failed. Only a saved connection has a form to go to;
// again connects to the same host, a container on a host included.
func (a *App) remoteStepsFooter(c ui.C, language i18n.Language, s *remoteSteps) {
	r := &a.remote
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		if !s.failed {
			ui.Spacer(c)
			if ui.Button(c.Part("stop"), i18n.Shared(language, "desktop.remote.stop")).Outline().Clicked() {
				c.After(a.stopRemoteConnect)
			}
			return
		}
		if ui.Button(c.Part("back"), i18n.Shared(language, "desktop.remote.steps.back")).Outline().Clicked() {
			c.After(func() { r.steps = nil })
		}
		ui.Spacer(c)
		if s.host.saved() && ui.Button(c.Part("edit"), i18n.Shared(language, "desktop.remote.steps.editConnection")).Outline().Disabled(!r.editable()).Clicked() {
			c.After(func() {
				r.steps = nil
				a.editSelectedRemote()
			})
		}
		if ui.Button(c.Part("retry"), i18n.Shared(language, "desktop.remote.steps.retry")).Clicked() {
			folder := s.folder
			c.After(func() {
				r.steps = nil
				if s.host.hosted() {
					a.connectRemoteTo(s.entry, s.host, folder)
					return
				}
				a.connectRemote(folder)
			})
		}
	})
}
