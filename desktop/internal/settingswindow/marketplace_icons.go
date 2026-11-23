package settingswindow

import (
	"context"
	"errors"
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	marketIconCacheEntries = 64
	marketIconConcurrency  = 4
	marketIconTimeout      = 10 * time.Second
)

// marketplaceIcons owns only presentation resources, by the index's icon URL.
// Visible list rows and the detail declare their own page Effects, so scrolling
// away cancels an unfinished read. Finished icons and failures use a bounded LRU
// cache. A new catalog, leaving the tab or closing the window releases it.
type marketplaceIcons struct {
	load    func(context.Context, string) (gfx.Icon, error)
	report  func(error)
	slots   chan struct{}
	entries map[string]*marketIconEntry
	catalog uint64
	clock   uint64
}

type marketIconEntry struct {
	effect *ui.EffectState[gfx.Icon, string]
	icon   gfx.Icon
	done   bool
	used   uint64
}

func newMarketplaceIcons(load func(context.Context, string) (gfx.Icon, error), report func(error)) marketplaceIcons {
	return marketplaceIcons{load: load, report: report, slots: make(chan struct{}, marketIconConcurrency)}
}

func (s *marketplaceIcons) reset(catalog uint64) {
	s.entries, s.catalog = nil, catalog
}

// take applies completions before declaring any row, so a result that arrives
// mid-paint cannot leave the row and detail showing different avatars at rest.
func (s *marketplaceIcons) take() {
	for _, entry := range s.entries {
		if entry.done {
			continue
		}
		if icon, err, ok := entry.effect.Take(); ok {
			entry.icon, entry.done = icon, true
			// log-exempt: 同一次失败已经记录过：后台读取边界已记录降级原因。
			if err != nil {
				entry.icon = gfx.Icon{}
			}
		}
	}
}

func (s *marketplaceIcons) lookup(c ui.C, address string) (gfx.Icon, bool) {
	if s.load == nil || address == "" {
		return gfx.Icon{}, false
	}
	s.clock++
	entry := s.entries[address]
	if entry == nil {
		if s.entries == nil {
			s.entries = make(map[string]*marketIconEntry)
		}
		if len(s.entries) == marketIconCacheEntries {
			var oldest string
			var used uint64 = ^uint64(0)
			for url, cached := range s.entries {
				if cached.used < used {
					oldest, used = url, cached.used
				}
			}
			delete(s.entries, oldest)
		}
		// Capture dependencies rather than the window-owned cache. Its map can be
		// cleared while a cancelled worker finishes.
		load, report, slots := s.load, s.report, s.slots
		entry = &marketIconEntry{effect: ui.NewEffectKeyed[gfx.Icon, string](func(parent context.Context, url string) (icon gfx.Icon, err error) {
			ctx, cancel := context.WithTimeout(parent, marketIconTimeout)
			defer cancel()
			defer func() {
				// log-exempt: 用户取消：滚动离屏、切换目录或关闭窗口结束图标读取。
				if err != nil && !errors.Is(err, context.Canceled) && report != nil {
					report(err)
				}
			}()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				return gfx.Icon{}, ctx.Err()
			}
			if err := ctx.Err(); err != nil {
				return gfx.Icon{}, err
			}
			return load(ctx, url)
		}).Sequential()}
		s.entries[address] = entry
	}
	entry.used = s.clock
	if !entry.done {
		ui.Effect(c, entry.effect, address)
	}
	return entry.icon, len(entry.icon.Commands) > 0 || len(entry.icon.Layers) > 0
}
