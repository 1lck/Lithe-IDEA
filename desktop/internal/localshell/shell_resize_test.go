package localshell

import (
	"fmt"
	"io"
	"reflect"
	"testing"
	"testing/synctest"
	"time"
)

type resizeTestIO struct{ write func([]byte) }

func (stream resizeTestIO) Read([]byte) (int, error) { return 0, io.EOF }
func (stream resizeTestIO) Close() error             { return nil }
func (stream resizeTestIO) Write(data []byte) (int, error) {
	if stream.write != nil {
		stream.write(data)
	}
	return len(data), nil
}

func resizeTestShell(b backend) *Shell {
	return &Shell{
		b: b, input: make(chan []byte, 16), done: make(chan struct{}),
		resizeWake: make(chan struct{}, 1),
		wantCols:   80, wantRows: 24, curCols: 80, curRows: 24,
	}
}

func TestContinuousResizeKeepsUpdatingTheProgram(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var sizes [][2]int
		shell := resizeTestShell(backend{resize: func(cols, rows int) {
			sizes = append(sizes, [2]int{cols, rows})
		}})
		go shell.resizeLoop()
		defer close(shell.resizeWake)
		for cols := 81; cols <= 100; cols++ {
			shell.Resize(cols, 24)
			synctest.Wait()
			time.Sleep(resizeInterval / 4)
		}
		synctest.Wait()
		if len(sizes) < 3 || len(sizes) > 6 {
			t.Fatalf("updates during continuous drag = %v, want regular coalesced updates", sizes)
		}
		// The last requested size must reach the program even with no more events.
		time.Sleep(resizeInterval)
		synctest.Wait()
		if got := sizes[len(sizes)-1]; got != [2]int{100, 24} {
			t.Fatalf("final size = %v, want [100 24]", got)
		}
	})
}

func TestInputFlushesTheLatestSizeOnTheWriter(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var events []string
		shell := resizeTestShell(backend{
			resize: func(cols, rows int) { events = append(events, fmt.Sprintf("resize %d %d", cols, rows)) },
			io:     resizeTestIO{write: func(data []byte) { events = append(events, string(data)) }},
		})
		shell.Resize(90, 24)
		shell.Resize(100, 30)
		if !shell.Write([]byte("input")) {
			t.Fatal("Write refused input")
		}
		if len(events) != 0 {
			t.Fatalf("window thread called the backend: %v", events)
		}
		go shell.writeLoop()
		defer close(shell.input)
		go shell.resizeLoop()
		defer close(shell.resizeWake)
		synctest.Wait()
		if want := []string{"resize 100 30", "input"}; !reflect.DeepEqual(events, want) {
			t.Fatalf("backend calls = %v, want %v", events, want)
		}
		time.Sleep(2 * resizeInterval)
		synctest.Wait()
		if len(events) != 2 {
			t.Fatalf("an old timer repeated the resize: %v", events)
		}
	})
}

func TestSlowResizeDoesNotBlockOrOverlapNewInput(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		entered, release := make(chan struct{}), make(chan struct{})
		var events []string
		shell := resizeTestShell(backend{
			resize: func(cols, rows int) {
				events = append(events, fmt.Sprintf("resize %d %d", cols, rows))
				if cols == 90 {
					close(entered)
					<-release
					events = append(events, "resize complete")
				}
			},
			io: resizeTestIO{write: func(data []byte) { events = append(events, string(data)) }},
		})
		go shell.writeLoop()
		defer close(shell.input)
		go shell.resizeLoop()
		defer close(shell.resizeWake)
		shell.Resize(90, 24)
		<-entered
		shell.Resize(100, 30)
		shell.Resize(110, 40)
		if !shell.Write([]byte("input")) {
			t.Fatal("Write refused input while resize was in flight")
		}
		// A writer waiting on resizeMu is not durably blocked for synctest.
		// Release the backend before Wait; its completion event still checks
		// that the latest resize and input follow the in-flight resize.
		close(release)
		synctest.Wait()
		want := []string{"resize 90 24", "resize complete", "resize 110 40", "input"}
		if !reflect.DeepEqual(events, want) {
			t.Fatalf("backend calls = %v, want %v", events, want)
		}
	})
}

func TestPendingResizeIsDroppedWhenShellEnds(t *testing.T) {
	for _, finished := range []bool{false, true} {
		t.Run(fmt.Sprintf("finished=%v", finished), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				calls := 0
				shell := resizeTestShell(backend{resize: func(int, int) { calls++ }})
				go shell.resizeLoop()
				defer close(shell.resizeWake)
				shell.Resize(90, 24)
				synctest.Wait()
				shell.mu.Lock()
				shell.closed, shell.finished = !finished, finished
				shell.mu.Unlock()
				shell.Resize(100, 30)
				if shell.Write([]byte("input")) {
					t.Fatal("ended shell accepted input")
				}
				time.Sleep(2 * resizeInterval)
				synctest.Wait()
				if calls != 0 {
					t.Fatalf("ended shell received %d resize calls", calls)
				}
			})
		})
	}
}

func TestResizeBackToCurrentSizeDoesNotRedrawTheProgram(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		calls := 0
		shell := resizeTestShell(backend{resize: func(int, int) { calls++ }})
		go shell.resizeLoop()
		defer close(shell.resizeWake)
		shell.Resize(90, 24)
		shell.Resize(80, 24)
		synctest.Wait()
		time.Sleep(2 * resizeInterval)
		synctest.Wait()
		if calls != 0 {
			t.Fatalf("unchanged size redrew the program %d times", calls)
		}
	})
}

func TestResizeKeepsUpdatingWhileInputIsBackpressured(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		entered, release := make(chan struct{}), make(chan struct{})
		var sizes [][2]int
		shell := resizeTestShell(backend{
			resize: func(cols, rows int) { sizes = append(sizes, [2]int{cols, rows}) },
			io: resizeTestIO{write: func([]byte) {
				close(entered)
				<-release
			}},
		})
		go shell.writeLoop()
		defer close(shell.input)
		go shell.resizeLoop()
		defer close(shell.resizeWake)
		defer close(release)
		if !shell.Write([]byte("paste")) {
			t.Fatal("Write refused input")
		}
		<-entered
		shell.Resize(100, 30)
		synctest.Wait()
		time.Sleep(resizeInterval)
		synctest.Wait()
		shell.Resize(120, 40)
		synctest.Wait()
		time.Sleep(resizeInterval)
		synctest.Wait()
		if want := [][2]int{{100, 30}, {120, 40}}; !reflect.DeepEqual(sizes, want) {
			t.Fatalf("resizes during a blocked input write = %v, want %v", sizes, want)
		}
	})
}
