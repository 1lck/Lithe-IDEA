package workbench

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"
)

const taskGroupTestTimeout = 2 * time.Second

// observedTaskGroupContext marks the select boundary after a waiter has captured
// its generation's idle channel. Tests can order completion without sleeping.
type observedTaskGroupContext struct {
	context.Context
	entered chan struct{}
	proceed <-chan struct{}
	once    sync.Once
}

func (c *observedTaskGroupContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.entered) })
	if c.proceed != nil {
		select {
		case <-c.proceed:
		case <-c.Context.Done():
		}
	}
	return c.Context.Done()
}

func awaitTaskGroupSignal(t *testing.T, signal <-chan struct{}, what string) {
	t.Helper()
	timer := time.NewTimer(taskGroupTestTimeout)
	defer timer.Stop()
	select {
	case <-signal:
	case <-timer.C:
		t.Fatalf("timed out waiting for %s", what)
	}
}

func startTaskGroupWaiter(t *testing.T, group *taskGroup, proceed <-chan struct{}) <-chan error {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), taskGroupTestTimeout)
	observed := &observedTaskGroupContext{Context: ctx, entered: make(chan struct{}), proceed: proceed}
	result := make(chan error, 1)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		result <- group.WaitContext(observed)
	}()
	t.Cleanup(func() {
		cancel()
		awaitTaskGroupSignal(t, finished, "task-group waiter cleanup")
	})
	awaitTaskGroupSignal(t, observed.entered, "task-group waiter registration")
	return result
}

func requireTaskGroupWaitResult(t *testing.T, result <-chan error) {
	t.Helper()
	timer := time.NewTimer(taskGroupTestTimeout)
	defer timer.Stop()
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("waiting for task completion: %v", err)
		}
	case <-timer.C:
		t.Fatal("completed task group did not release its waiter")
	}
}

func TestTaskGroupWaitContextCancelsWithoutChangingPendingTasks(t *testing.T) {
	var group taskGroup
	group.Add(1)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := group.WaitContext(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("active wait error = %v, want context.Canceled", err)
	}
	if count := group.Count(); count != 1 {
		t.Fatalf("cancelled wait changed pending tasks to %d", count)
	}
	group.Done()
	if err := group.WaitContext(ctx); err != nil {
		t.Fatalf("idle group should take priority over cancellation: %v", err)
	}
}

func TestTaskGroupWaitersIncludeTasksAddedBeforeZero(t *testing.T) {
	var group taskGroup
	group.Add(1)
	first := startTaskGroupWaiter(t, &group, nil)
	second := startTaskGroupWaiter(t, &group, nil)
	group.Add(1)
	group.Done()
	if count := group.Count(); count != 1 {
		t.Fatalf("pending tasks = %d, want 1", count)
	}
	for _, result := range []<-chan error{first, second} {
		select {
		case err := <-result:
			t.Fatalf("waiter finished before the added task: %v", err)
		default:
		}
	}
	group.Done()
	requireTaskGroupWaitResult(t, first)
	requireTaskGroupWaitResult(t, second)
}

func TestTaskGroupReuseDoesNotLoseThePreviousZeroTransition(t *testing.T) {
	var group taskGroup
	group.Add(1)
	proceed := make(chan struct{})
	previous := startTaskGroupWaiter(t, &group, proceed)
	group.Done()
	// Keep the old waiter at its select boundary until after reuse. A wait that
	// checks the current count again would miss this completed generation.
	group.Add(1)
	close(proceed)
	requireTaskGroupWaitResult(t, previous)
	current := startTaskGroupWaiter(t, &group, nil)
	if count := group.Count(); count != 1 {
		t.Fatalf("reused group pending tasks = %d, want 1", count)
	}
	select {
	case err := <-current:
		t.Fatalf("a reused group inherited the closed idle channel: %v", err)
	default:
	}
	group.Done()
	requireTaskGroupWaitResult(t, current)
	group.Wait()
}

func TestTaskGroupRejectsNegativeCounts(t *testing.T) {
	for _, initial := range []int{0, 1} {
		t.Run(strconv.Itoa(initial), func(t *testing.T) {
			var group taskGroup
			group.Add(initial)
			defer func() {
				if recover() == nil {
					t.Fatal("negative task count did not panic")
				}
			}()
			group.Add(-initial - 1)
		})
	}
}
