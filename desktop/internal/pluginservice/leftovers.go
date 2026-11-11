package pluginservice

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
)

// StartupLeftovers are the processes an earlier run of the app left behind that are still running.
// The start-up confirmation lists them; nothing is ended before the user answers.
func (s *Service) StartupLeftovers() []processledger.Record {
	if s == nil {
		return nil
	}
	return s.startupLeftovers
}

// SettleStartupLeftovers applies the user's answer: the leftovers are forgotten, and ended when end
// is true. It clears the pending list either way.
func (s *Service) SettleStartupLeftovers(ctx context.Context, end bool) (int, error) {
	if s == nil {
		return 0, nil
	}
	leftovers := s.startupLeftovers
	s.startupLeftovers = nil
	return s.ledger.Settle(ctx, leftovers, end)
}
