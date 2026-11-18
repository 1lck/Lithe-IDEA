package pluginservice

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
)

// ErrRuntimeBusy reports a stop still owning a plugin's files. A new approved
// installation can retry after that operation finishes; it cannot reopen admission.
var ErrRuntimeBusy = errors.New("plugin runtime preparation is stopping")

type runtimePreparationKey struct{ root, plugin string }

// Preparations from different workbenches share the same package and runtime files.
// The coordinator keeps only unfinished work and ongoing lifecycle operations;
// each Service owns its persistent admission choices.
var runtimePreparationCoordinator = struct {
	sync.Mutex
	active map[runtimePreparationKey]map[*runtimePreparation]struct{}
	stops  map[runtimePreparationKey]int
}{active: make(map[runtimePreparationKey]map[*runtimePreparation]struct{}), stops: make(map[runtimePreparationKey]int)}

type runtimePreparation struct {
	service      *Service
	key          runtimePreparationKey
	ctx          context.Context
	cancel       context.CancelFunc
	done         chan struct{}
	cleanupErr   error
	retryCleanup func(context.Context) error
}

func (s *Service) preparationKey(id string) runtimePreparationKey {
	return runtimePreparationKey{root: filepath.Clean(s.Root), plugin: id}
}

func (s *Service) beginRuntimePreparation(ctx context.Context, id string) (context.Context, *runtimePreparation, error) {
	runtimePreparationCoordinator.Lock()
	defer runtimePreparationCoordinator.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	key := s.preparationKey(id)
	if s.runtimeBlocked[id] || runtimePreparationCoordinator.stops[key] != 0 {
		return nil, nil, ErrRuntimeBusy
	}
	ctx, preparation := s.newRuntimePreparationLocked(ctx, key)
	return ctx, preparation, nil
}

func (s *Service) newRuntimePreparationLocked(ctx context.Context, key runtimePreparationKey) (context.Context, *runtimePreparation) {
	ctx, cancel := context.WithCancel(ctx)
	preparation := &runtimePreparation{service: s, key: key, ctx: ctx, cancel: cancel, done: make(chan struct{})}
	if runtimePreparationCoordinator.active[key] == nil {
		runtimePreparationCoordinator.active[key] = make(map[*runtimePreparation]struct{})
	}
	runtimePreparationCoordinator.active[key][preparation] = struct{}{}
	return ctx, preparation
}

// finish follows all process/file cleanup. Only cleanup failures remain registered:
// a rejected artifact or a cancelled download does not make an uninstall unsafe.
func (p *runtimePreparation) finish(cleanupErr error) {
	p.cancel()
	runtimePreparationCoordinator.Lock()
	defer runtimePreparationCoordinator.Unlock()
	p.cleanupErr = cleanupErr
	if cleanupErr == nil {
		p.forgetLocked()
	}
	close(p.done)
}

func (p *runtimePreparation) forgetLocked() {
	delete(runtimePreparationCoordinator.active[p.key], p)
	if len(runtimePreparationCoordinator.active[p.key]) == 0 {
		delete(runtimePreparationCoordinator.active, p.key)
	}
}

// holdRuntimeStop closes cross-window admission for the whole lifecycle action,
// including the file removal after stopPrograms. Concurrent approvals return busy.
func (s *Service) holdRuntimeStop(id string) func() {
	key := s.preparationKey(id)
	runtimePreparationCoordinator.Lock()
	runtimePreparationCoordinator.stops[key]++
	runtimePreparationCoordinator.Unlock()
	return func() {
		runtimePreparationCoordinator.Lock()
		defer runtimePreparationCoordinator.Unlock()
		runtimePreparationCoordinator.stops[key]--
		if runtimePreparationCoordinator.stops[key] == 0 {
			delete(runtimePreparationCoordinator.stops, key)
		}
	}
}

// AllowRuntimePreparation reopens admission only for an explicit installation or
// enable. It never overrides a running stop or an unfinished cancelled attempt.
func (s *Service) AllowRuntimePreparation(id string) error {
	runtimePreparationCoordinator.Lock()
	defer runtimePreparationCoordinator.Unlock()
	return s.allowRuntimePreparationLocked(id)
}

func (s *Service) allowRuntimePreparationLocked(id string) error {
	key := s.preparationKey(id)
	if runtimePreparationCoordinator.stops[key] != 0 {
		return ErrRuntimeBusy
	}
	for preparation := range runtimePreparationCoordinator.active[key] {
		if preparation.ctx.Err() != nil || preparation.cleanupErr != nil {
			return ErrRuntimeBusy
		}
	}
	delete(s.runtimeBlocked, id)
	return nil
}

// BeginRuntimeInstallation belongs after package approval. Its lifetime includes
// preparation and publication, so an uninstall either refuses this start or waits
// until it can no longer publish a package or recreate the removed state.
func (s *Service) BeginRuntimeInstallation(ctx context.Context, id string) (context.Context, func(), error) {
	runtimePreparationCoordinator.Lock()
	defer runtimePreparationCoordinator.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if err := s.allowRuntimePreparationLocked(id); err != nil {
		return nil, nil, err
	}
	ctx, preparation := s.newRuntimePreparationLocked(ctx, s.preparationKey(id))
	return ctx, func() { preparation.finish(nil) }, nil
}

func (s *Service) stopRuntimePreparations(ctx context.Context, id string) error {
	runtimePreparationCoordinator.Lock()
	s.blockRuntimePreparationLocked(id)
	var pending []*runtimePreparation
	for preparation := range runtimePreparationCoordinator.active[s.preparationKey(id)] {
		preparation.service.blockRuntimePreparationLocked(id)
		preparation.cancel()
		pending = append(pending, preparation)
	}
	runtimePreparationCoordinator.Unlock()

	ctx, cancel := context.WithTimeout(ctx, backendStopTimeout)
	defer cancel()
	var failures []error
	for _, preparation := range pending {
		select {
		case <-preparation.done:
		case <-ctx.Done():
			return errors.Join(append(failures, ctx.Err())...)
		}
		runtimePreparationCoordinator.Lock()
		err := preparation.cleanupErr
		runtimePreparationCoordinator.Unlock()
		if err != nil && preparation.retryCleanup != nil {
			err = preparation.retryCleanup(ctx)
			runtimePreparationCoordinator.Lock()
			preparation.cleanupErr = err
			if err == nil {
				preparation.forgetLocked()
			}
			runtimePreparationCoordinator.Unlock()
		}
		failures = append(failures, err)
	}
	return errors.Join(failures...)
}

func (s *Service) blockRuntimePreparationLocked(id string) {
	if s.runtimeBlocked == nil {
		s.runtimeBlocked = make(map[string]bool)
	}
	s.runtimeBlocked[id] = true
}
