package pluginhost

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func echoHandler(result string) Handler {
	return func(context.Context, json.RawMessage) (json.RawMessage, *Failure) {
		return json.RawMessage(result), nil
	}
}

func TestServicesRegisterAndGrant(t *testing.T) {
	services := NewServices()
	for _, method := range []string{MethodPrefix + "workspace/stat", MethodPrefix + "documents/list"} {
		if err := services.Register(method, echoHandler(`{}`)); err != nil {
			t.Fatalf("register %s: %v", method, err)
		}
	}
	granted := services.Grant()
	want := []string{MethodPrefix + "documents/list", MethodPrefix + "workspace/stat"}
	if len(granted) != len(want) {
		t.Fatalf("grant = %v", granted)
	}
	for i := range want {
		if granted[i] != want[i] {
			t.Fatalf("grant = %v", granted)
		}
	}
	// Grant must be a copy: a caller must not be able to change the registry.
	granted[0] = "tampered"
	if services.Grant()[0] != want[0] {
		t.Fatal("Grant returned the registry's own slice")
	}
}

func TestServicesRefuseBadRegistrations(t *testing.T) {
	services := NewServices()
	cases := map[string]struct {
		method  string
		handler Handler
	}{
		"missing prefix": {method: "workspace/stat", handler: echoHandler(`{}`)},
		"empty method":   {method: "", handler: echoHandler(`{}`)},
		"bare prefix":    {method: MethodPrefix, handler: echoHandler(`{}`)},
		"bad character":  {method: MethodPrefix + "workspace stat", handler: echoHandler(`{}`)},
		"nil handler":    {method: MethodPrefix + "workspace/stat"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if err := services.Register(tc.method, tc.handler); !errors.Is(err, ErrServiceRegistration) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestServicesRefuseDuplicateRegistration(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "workspace/stat"
	if err := services.Register(method, echoHandler(`{"first":true}`)); err != nil {
		t.Fatal(err)
	}
	if err := services.Register(method, echoHandler(`{"second":true}`)); !errors.Is(err, ErrServiceRegistration) {
		t.Fatalf("err = %v", err)
	}
	result, failure := services.Respond(context.Background(), method, nil)
	if failure != nil {
		t.Fatalf("failure = %+v", failure)
	}
	if string(result) != `{"first":true}` {
		t.Fatalf("the second registration replaced the first: %s", result)
	}
}

func TestServicesReportUndeclaredMethods(t *testing.T) {
	services := NewServices()
	_, failure := services.Respond(context.Background(), MethodPrefix+"workspace/readFile", nil)
	if failure == nil || failure.Code != CodeMethodNotDeclared {
		t.Fatalf("failure = %+v", failure)
	}
}

func TestServicesPassThroughFailures(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "workspace/stat"
	if err := services.Register(method, func(context.Context, json.RawMessage) (json.RawMessage, *Failure) {
		return nil, &Failure{Code: CodePermissionDenied, Message: "not granted"}
	}); err != nil {
		t.Fatal(err)
	}
	result, failure := services.Respond(context.Background(), method, nil)
	if result != nil {
		t.Fatalf("result = %s", result)
	}
	if failure == nil || failure.Code != CodePermissionDenied {
		t.Fatalf("failure = %+v", failure)
	}
}

func TestServicesReportCancellation(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "documents/list"
	if err := services.Register(method, func(ctx context.Context, _ json.RawMessage) (json.RawMessage, *Failure) {
		<-ctx.Done()
		return json.RawMessage(`{"documents":[]}`), nil
	}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, failure := services.Respond(ctx, method, nil)
	if result != nil {
		t.Fatalf("a cancelled request returned a result: %s", result)
	}
	if failure == nil || failure.Code != CodeCancelled {
		t.Fatalf("failure = %+v", failure)
	}
}

func TestServicesBoundMachineRequests(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "documents/list"
	var bounded bool
	if err := services.Register(method, func(ctx context.Context, _ json.RawMessage) (json.RawMessage, *Failure) {
		_, bounded = ctx.Deadline()
		return json.RawMessage(`{}`), nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, failure := services.Respond(context.Background(), method, nil); failure != nil {
		t.Fatalf("failure = %+v", failure)
	}
	if !bounded {
		t.Fatal("the handler ran without a deadline")
	}
}

func TestServicesKeepCallerDeadline(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "documents/list"
	var remaining time.Duration
	if err := services.Register(method, func(ctx context.Context, _ json.RawMessage) (json.RawMessage, *Failure) {
		deadline, _ := ctx.Deadline()
		remaining = time.Until(deadline)
		return json.RawMessage(`{}`), nil
	}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, failure := services.Respond(ctx, method, nil); failure != nil {
		t.Fatalf("failure = %+v", failure)
	}
	if remaining > RequestTimeout {
		t.Fatalf("the caller's shorter deadline was replaced: %v", remaining)
	}
}

func TestServicesRefuseInvalidHandlerOutput(t *testing.T) {
	services := NewServices()
	method := MethodPrefix + "documents/list"
	if err := services.Register(method, echoHandler("not json")); err != nil {
		t.Fatal(err)
	}
	result, failure := services.Respond(context.Background(), method, nil)
	if result != nil {
		t.Fatalf("result = %s", result)
	}
	if failure == nil {
		t.Fatal("invalid handler output was accepted")
	}
}
