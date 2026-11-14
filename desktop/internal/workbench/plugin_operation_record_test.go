package workbench

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// pluginOperationWait bounds the wait for a recorded result. The paths that record run real
// processes and real Core requests, so it is generous; a result that arrives returns at once.
const pluginOperationWait = 30 * time.Second

// recordedPluginOperation is one result the host sent Core, with Core's answer.
type recordedPluginOperation struct {
	operation core.PluginOperation
	err       error
}

// recordingPluginKernel is the real plugin kernel that also hands each recorded result to the
// test, so a test sees what the host recorded and that Core took it.
type recordingPluginKernel struct {
	pluginservice.Kernel
	recorded chan recordedPluginOperation
}

func newRecordingPluginKernel() *recordingPluginKernel {
	return &recordingPluginKernel{Kernel: &testKernel{Client: core.NewClient()}, recorded: make(chan recordedPluginOperation, 16)}
}

func (k *recordingPluginKernel) RecordPluginOperation(ctx context.Context, operation core.PluginOperation) error {
	err := k.Kernel.RecordPluginOperation(ctx, operation)
	k.recorded <- recordedPluginOperation{operation: operation, err: err}
	return err
}

// next is the next recorded result, which Core must have taken.
func (k *recordingPluginKernel) next(t *testing.T, what string) core.PluginOperation {
	t.Helper()
	select {
	case recorded := <-k.recorded:
		if recorded.err != nil {
			t.Fatalf("Core refused %+v: %v", recorded.operation, recorded.err)
		}
		return recorded.operation
	case <-time.After(pluginOperationWait):
		t.Fatalf("no result was recorded for %s", what)
	}
	return core.PluginOperation{}
}

// none fails when anything was recorded. A caller first waits for every path that could record.
func (k *recordingPluginKernel) none(t *testing.T) {
	t.Helper()
	select {
	case recorded := <-k.recorded:
		t.Fatalf("recorded %+v, want nothing", recorded.operation)
	default:
	}
}

// wantPluginOperation checks a recorded result against the rest of want, after checking that
// its duration is a monotonic one, which no test can predict.
func wantPluginOperation(t *testing.T, got, want core.PluginOperation) {
	t.Helper()
	if got.DurationMs < 0 {
		t.Fatalf("duration = %d, want a monotonic duration", got.DurationMs)
	}
	got.DurationMs = 0
	if got != want {
		t.Fatalf("recorded %+v, want %+v", got, want)
	}
}
