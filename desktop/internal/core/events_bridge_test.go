package core

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

type testRequestEvent struct {
	Type        string `json:"type"`
	OperationID string `json:"operationId"`
}

func TestCoreRequestEventsStayScoped(t *testing.T) {
	client := NewClient()
	type outcome struct {
		events                     []testRequestEvent
		observationErr, requestErr error
	}
	results := make(chan outcome, 2)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for i := 0; i < 2; i++ {
		go func() {
			var events []testRequestEvent
			var decodeErr error
			var result json.RawMessage
			observationErr, requestErr := client.ExecuteWithEvents(ctx, "core.ping", nil, &result, func(raw json.RawMessage) {
				var event testRequestEvent
				if err := json.Unmarshal(raw, &event); err != nil {
					decodeErr = err
					return
				}
				events = append(events, event)
			})
			if decodeErr != nil {
				observationErr = decodeErr
			}
			results <- outcome{events: events, observationErr: observationErr, requestErr: requestErr}
		}()
	}
	ids := make(map[string]bool)
	for i := 0; i < 2; i++ {
		select {
		case result := <-results:
			if result.observationErr != nil || result.requestErr != nil {
				t.Fatalf("observe=%v request=%v", result.observationErr, result.requestErr)
			}
			if len(result.events) != 2 || result.events[0].Type != "requestStarted" || result.events[1].Type != "requestFinished" {
				t.Fatalf("events = %#v", result.events)
			}
			id := result.events[0].OperationID
			if id == "" || result.events[1].OperationID != id || ids[id] {
				t.Fatalf("event identity mixed across requests: %#v", result.events)
			}
			ids[id] = true
		case <-ctx.Done():
			t.Fatal("concurrent observed requests did not finish")
		}
	}
}

func TestCoreObserverPanicDoesNotHideRequestResult(t *testing.T) {
	var result json.RawMessage
	observationErr, requestErr := NewClient().ExecuteWithEvents(testContext(t), "core.ping", nil, &result, func(json.RawMessage) {
		panic("fixture observer failure")
	})
	if !errors.Is(observationErr, ErrCoreEventsLost) || requestErr != nil || len(result) == 0 {
		t.Fatalf("observe=%v request=%v result=%s", observationErr, requestErr, result)
	}
}

func TestCoreRequestIDsUniqueAcrossClients(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	type startedRequest struct {
		index int
		id    string
	}
	type requestResult struct {
		index int
		err   error
	}
	started := make(chan startedRequest, 2)
	release := make(chan struct{})
	results := make(chan requestResult, 2)
	for i := 0; i < 2; i++ {
		go func(index int) {
			client := NewClient()
			observationErr, requestErr := client.ExecuteWithEvents(ctx, "core.ping", nil, nil, func(raw json.RawMessage) {
				var event testRequestEvent
				if json.Unmarshal(raw, &event) == nil && event.Type == "requestStarted" {
					started <- startedRequest{index: index, id: event.OperationID}
					select {
					case <-release:
					case <-ctx.Done():
					}
				}
			})
			results <- requestResult{index: index, err: errors.Join(observationErr, requestErr)}
		}(i)
	}
	var ids [2]string
	for count := 0; count < 2; count++ {
		select {
		case request := <-started:
			ids[request.index] = request.id
		case <-ctx.Done():
			close(release)
			t.Fatal("requests did not both start")
		}
	}
	unique := ids[0] != "" && ids[0] != ids[1]
	cancelled := cancelOperation(ids[0])
	close(release)
	for i := 0; i < 2; i++ {
		select {
		case result := <-results:
			if result.index == 0 {
				var failure *Error
				if !errors.As(result.err, &failure) || failure.Code != CodeCancelled {
					t.Errorf("cancelled request: %v", result.err)
				}
			} else if result.err != nil {
				t.Errorf("other request was affected: %v", result.err)
			}
		case <-ctx.Done():
			t.Fatal("requests did not finish")
		}
	}
	if !unique {
		t.Fatalf("separate clients used duplicate operation IDs: %q and %q", ids[0], ids[1])
	}
	if !cancelled {
		t.Fatal("active request was not registered for cancellation")
	}
}
