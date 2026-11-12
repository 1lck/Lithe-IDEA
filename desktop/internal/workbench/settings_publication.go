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
}

func (a *App) subscribeSettings() {
	settingsWindows.Lock()
	defer settingsWindows.Unlock()
	if a.settingsSubscription != nil {
		return
	}
	sub := &settingsSubscription{notices: make(chan settingsNotice, 8), done: make(chan struct{})}
	a.settingsSubscription = sub
	settingsWindows.live[a] = sub
}

func (a *App) unsubscribeSettings() {
	settingsWindows.Lock()
	delete(settingsWindows.live, a)
	sub := a.settingsSubscription
	settingsWindows.Unlock()
	if sub != nil {
		sub.once.Do(func() { close(sub.done) })
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
			// log-exempt: 生命周期清理：接收窗口已经关闭，不再持有运行时或设置视图。
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
