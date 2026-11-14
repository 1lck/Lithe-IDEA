package pluginservice

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// RecordOperation records the result of a declarative contribution the host ran, such as a
// build command or a debug adapter start, on the plugin's own log channel. A result Core
// refuses goes to RecordFailed; the caller has nothing more to do about it.
func (s *Service) RecordOperation(ctx context.Context, operation core.PluginOperation) {
	if s == nil || s.kernel == nil {
		return
	}
	if err := s.kernel.RecordPluginOperation(ctx, operation); err != nil && s.RecordFailed != nil {
		s.RecordFailed(ctx, err)
	}
}

// EndAttempt records an attempt that stopped with err at stage, unless it is not the host's to
// record: Core owns a handed-off attempt, and a cancelled one is never recorded. Recording does
// not use ctx, since the attempt may have ended because ctx did.
func (s *Service) EndAttempt(ctx context.Context, attempt *core.PluginAttempt, stage core.PluginStage, err error) {
	if result, ok := attempt.Ended(ctx, stage, err); ok {
		s.RecordOperation(context.WithoutCancel(ctx), result)
	}
}
