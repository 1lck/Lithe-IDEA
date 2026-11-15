package workbench

import (
	"context"
	"sync"

	"github.com/vivaui/viva/ui"
)

// keyedEffect is a page Effect whose run reads the request the page declared
// it with. ui.Effect starts the run function with only a context, so the
// request is handed over under a lock; a run that was already superseded by a
// newer key may read the newer request, which is harmless because its result
// is dropped.
type keyedEffect[T, R any] struct {
	state *ui.EffectState[T, string]
	mu    sync.Mutex
	req   R
	key   string
	set   bool
}

func newKeyedEffect[T, R any](run func(context.Context, R) (T, error)) *keyedEffect[T, R] {
	k := &keyedEffect[T, R]{}
	k.state = ui.NewEffect[T, string](func(ctx context.Context) (T, error) {
		k.mu.Lock()
		req := k.req
		k.mu.Unlock()
		return run(ctx, req)
	})
	return k
}

// declare starts the work for key unless it is already running or finished for
// it. A different key cancels the previous run.
func (k *keyedEffect[T, R]) declare(c ui.C, key string, req R) {
	if !k.set || k.key != key {
		k.mu.Lock()
		k.req, k.key, k.set = req, key, true
		k.mu.Unlock()
	}
	ui.Effect(c, k.state, key)
}

// take returns a finished result once.
func (k *keyedEffect[T, R]) take() (T, error, bool) { return k.state.Take() }
