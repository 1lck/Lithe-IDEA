package pluginservice

import (
	"context"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
)

// StartupLeftovers are the processes an earlier run of the app left behind that are still running
// and not settled yet. The start-up sweep has Core decide them; nothing is ended before that.
func (s *Service) StartupLeftovers() []processledger.Record {
	if s == nil {
		return nil
	}
	s.leftoversMu.Lock()
	defer s.leftoversMu.Unlock()
	return slices.Clone(s.startupLeftovers)
}

// SettleStartupLeftovers applies a decision about some of the pending leftovers: they are
// forgotten and, when end is true, ended, each given grace to stop before it is killed. They leave
// the pending list; the rest stay pending.
func (s *Service) SettleStartupLeftovers(ctx context.Context, settled []processledger.Record, end bool, grace time.Duration) (int, error) {
	if s == nil || len(settled) == 0 {
		return 0, nil
	}
	s.leftoversMu.Lock()
	s.startupLeftovers = slices.DeleteFunc(s.startupLeftovers, func(record processledger.Record) bool {
		return slices.Contains(settled, record)
	})
	s.leftoversMu.Unlock()
	return s.ledger.Settle(ctx, settled, end, grace)
}
