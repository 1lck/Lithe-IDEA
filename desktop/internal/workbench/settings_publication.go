package workbench

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Live native windows own subscriptions. There is no background polling or
// retained history; each queue is bounded and closing releases blocked writers.
var settingsWindows = struct {
	sync.Mutex
	live map[*App]*settingsSubscription
}{live: make(map[*App]*settingsSubscription)}

type settingsNotice struct {
	owner    core.PluginSettingsOwner
	root     *string
	delivery core.SettingsDelivery
}

type settingsSubscription struct {
	notices chan settingsNotice
	done    chan struct{}
	once    sync.Once
	// Shared by live native windows and project tabs using the same directory.
	editorPreferences *editorPreferencesPublication
	editorGeneration  uint64
}

func (a *App) subscribeSettings() {
	settingsWindows.Lock()
	if a.settingsSubscription != nil {
		settingsWindows.Unlock()
		return
	}
	sub := &settingsSubscription{notices: make(chan settingsNotice, 8), done: make(chan struct{})}
	sub.editorPreferences = &editorPreferencesPublication{latest: editorPreferencesSnapshot{
		stored: a.settings.EditorPreferences, resolved: a.editorPreferences, generation: 1,
	}, watch: &documentWatch{}}
	startWatch := true
	for target, existing := range settingsWindows.live {
		if samePreferencesDirectory(a, target) {
			sub.editorPreferences = existing.editorPreferences
			startWatch = false
			break
		}
	}
	a.settingsSubscription = sub
	settingsWindows.live[a] = sub
	settingsWindows.Unlock()
	if startWatch {
		a.startEditorPreferencesWatch(sub.editorPreferences)
	}
}

func (a *App) unsubscribeSettings() {
	settingsWindows.Lock()
	delete(settingsWindows.live, a)
	sub := a.settingsSubscription
	last := sub != nil
	for _, other := range settingsWindows.live {
		if sub != nil && sub.editorPreferences == other.editorPreferences {
			last = false
			break
		}
	}
	settingsWindows.Unlock()
	if sub != nil {
		sub.once.Do(func() { close(sub.done) })
		if last {
			sub.editorPreferences.Lock()
			watch := sub.editorPreferences.watch
			sub.editorPreferences.Unlock()
			watch.close()
		}
	}
}

// Publication has already committed. A page cancellation must not undo delivery;
// an independent deadline bounds native identity reads and backpressure instead.
func (a *App) publishSettings(editor pluginservice.SettingsEditor, scope string, effects []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	settingsWindows.Lock()
	targets := make(map[*App]*settingsSubscription, len(settingsWindows.live))
	for target, sub := range settingsWindows.live {
		targets[target] = sub
	}
	settingsWindows.Unlock()
	var failures []error
	for target, sub := range targets {
		select {
		case <-sub.done:
			continue
		default:
		}
		if target.plugins == nil {
			continue
		}
		root := target.toolchainRoot.Load()
		workspace := ""
		if root != nil {
			workspace = *root
		}
		delivery, err := target.plugins.PlanSettingsDelivery(ctx, editor, scope, effects, workspace)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		if !delivery.Refresh {
			continue
		}
		notice := settingsNotice{owner: editor.SettingsOwner(), root: root, delivery: delivery}
		select {
		case sub.notices <- notice:
			target.invalidator.Invalidate()
		case <-sub.done:
			// log-exempt: 预期的缺失：接收窗口已经关闭，不再需要这条刷新通知。
		case <-ctx.Done():
			failures = append(failures, ctx.Err())
		}
	}
	return errors.Join(failures...)
}

func (a *App) drainSettings() {
	sub := a.settingsSubscription
	if sub == nil {
		return
	}
	select {
	case <-sub.done:
		return
	default:
	}
	a.drainEditorPreferencesWatch()
	a.drainEditorPreferences()
	// Capture this frame's bounded batch; concurrent publishers request another wake.
	count := len(sub.notices)
	for i := 0; i < count; i++ {
		notice := <-sub.notices
		if a.settingsWindow != nil {
			a.settingsWindow.PluginSettingsChanged(notice.owner.PluginID)
		}
		if notice.root != a.toolchainRoot.Load() {
			continue
		}
		a.applyPluginSettingsEffects(notice.owner, notice.delivery.Effects)
	}
}
