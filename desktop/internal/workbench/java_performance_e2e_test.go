package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// This opt-in probe measures real JDT/host processes and the production
// completion path. Its headless host RSS is not native-window memory evidence.
type javaPerformanceProbe struct {
	Label        string             `json:"label"`
	Test         string             `json:"test"`
	Platform     string             `json:"platform"`
	Architecture string             `json:"architecture"`
	ArchiveSHA   string             `json:"archiveSHA256"`
	Passed       bool               `json:"passed"`
	Milliseconds map[string]float64 `json:"milliseconds"`
	CompletionMS []float64          `json:"completionMilliseconds"`
	RSSBytes     map[string]uint64  `json:"rssBytes"`
}

func newJavaPerformanceProbe(t *testing.T, archive string) *javaPerformanceProbe {
	t.Helper()
	report := os.Getenv("LITHE_TEST_JAVA_PERFORMANCE_REPORT")
	if report == "" {
		return nil
	}
	file, err := os.Open(archive)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, hashErr := io.Copy(hash, file)
	closeErr := file.Close()
	if hashErr != nil || closeErr != nil {
		t.Fatalf("archive identity: read=%v close=%v", hashErr, closeErr)
	}
	probe := &javaPerformanceProbe{
		Label: os.Getenv("LITHE_TEST_JAVA_PERFORMANCE_LABEL"), Test: t.Name(),
		Platform: runtime.GOOS, Architecture: runtime.GOARCH,
		ArchiveSHA:   hex.EncodeToString(hash.Sum(nil)),
		Milliseconds: make(map[string]float64), RSSBytes: make(map[string]uint64),
	}
	t.Cleanup(func() {
		probe.Passed = !t.Failed()
		if err := os.MkdirAll(filepath.Dir(report), 0700); err != nil {
			t.Errorf("performance report directory: %v", err)
			return
		}
		file, err := os.OpenFile(report, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			t.Errorf("performance report: %v", err)
			return
		}
		if err := json.NewEncoder(file).Encode(probe); err != nil {
			t.Errorf("performance report record: %v", err)
		}
		if err := file.Close(); err != nil {
			t.Errorf("performance report close: %v", err)
		}
	})
	return probe
}

func (p *javaPerformanceProbe) elapsed(stage string, start time.Time) {
	if p != nil {
		p.Milliseconds[stage] = float64(time.Since(start)) / float64(time.Millisecond)
	}
}

func (p *javaPerformanceProbe) sample(t *testing.T, h *harness, d *document, stage string) {
	t.Helper()
	if p == nil {
		return
	}
	server, _ := h.app.documentSyncServer(d)
	if server == nil {
		t.Fatal("performance sample has no Java server")
	}
	for name, pid := range map[string]int{"jdt": server.session.Session.ProcessID, "headlessHostTree": os.Getpid()} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		sample, ok := pluginservice.SampleProcessTree(ctx, pid)
		cancel()
		if !ok || sample.MemoryBytes == 0 {
			t.Fatalf("performance sample unavailable: %s", name)
		}
		p.RSSBytes[stage+"."+name] = sample.MemoryBytes
	}
}

func (p *javaPerformanceProbe) completions(t *testing.T, h *harness, project *project, d *document, line, column int) {
	t.Helper()
	if p == nil {
		return
	}
	for range 12 {
		start := time.Now()
		h.app.startPluginCompletion(project, d, line, column)
		awaitStateWithin(t, h, 30*time.Second, "performance completion", func() bool {
			return len(h.app.semantics.completion.items) > 0
		})
		p.CompletionMS = append(p.CompletionMS, float64(time.Since(start))/float64(time.Millisecond))
		h.app.closeSemanticCompletion()
	}
	p.sample(t, h, d, "warmCompletion")
}
