package pluginservice

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

// CancelLanguageOperation asks Core to cancel one pending semantic operation of
// a language session. Cancelling an operation that already finished is
// harmless; the late result is still dropped by the host's generation check.
func (s *Service) CancelLanguageOperation(ctx context.Context, session *LanguageSession, operation string) error {
	if s == nil || session == nil {
		return pluginbackend.ErrNoSession
	}
	return s.Backend.Cancel(ctx, session.Session, operation)
}
