package marketplace

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	cacheTestFirstArchive  = "one"
	cacheTestSecondArchive = "two"
)

func TestArchiveCacheKeepsBudgetAcrossProcesses(t *testing.T) {
	for _, scenario := range []struct {
		name  string
		count int
		size  int64
	}{
		{"entries", archiveCacheEntries - 1, 1},
		{"bytes", 4, archiveCacheBudget/4 - 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			cache := ArchiveCache{directory: t.TempDir()}
			for index := range scenario.count {
				path := filepath.Join(cache.directory, fmt.Sprintf("%064x.zip", index+1))
				file, err := os.Create(path)
				if err != nil {
					t.Fatal(err)
				}
				if err := errors.Join(file.Truncate(scenario.size), file.Close()); err != nil {
					t.Fatal(err)
				}
			}
			source := filepath.Join(t.TempDir(), "archive.zip")
			if err := os.WriteFile(source, []byte(cacheTestSecondArchive), 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
			defer cancel()
			executable, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			writer := func(role string) *exec.Cmd {
				cmd := exec.CommandContext(ctx, executable, "-test.run=^TestArchiveCacheWriterProcess$", "-test.timeout=7s")
				cmd.Env = append(os.Environ(), "LITHE_TEST_ARCHIVE_CACHE_ROLE="+role,
					"LITHE_TEST_ARCHIVE_CACHE_DIRECTORY="+cache.directory, "LITHE_TEST_ARCHIVE_CACHE_SOURCE="+source)
				cmd.WaitDelay = time.Second
				return cmd
			}
			first := writer("hold")
			release, err := first.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			output, err := first.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			var stderr bytes.Buffer
			first.Stderr = &stderr
			if err := first.Start(); err != nil {
				t.Fatal(err)
			}
			waited := false
			defer func() {
				if !waited {
					cancel()
					_ = first.Wait()
				}
			}()
			reader := bufio.NewReader(output)
			// The first writer has finished pruning and is paused inside the copy.
			if line, err := reader.ReadString('\n'); line != "copying\n" || err != nil {
				t.Fatalf("first writer ready signal = %q, %v", line, err)
			}
			second, err := writer("write").CombinedOutput()
			if err != nil {
				t.Fatalf("second writer: %v\n%s", err, second)
			}
			if err := release.Close(); err != nil {
				t.Fatal(err)
			}
			remaining, readErr := io.ReadAll(reader)
			waitErr := first.Wait()
			waited = true
			if err := errors.Join(readErr, waitErr); err != nil {
				t.Fatalf("first writer: %v\n%s\n%s", err, remaining, stderr.String())
			}
			// A writer that could not get the lock can retry after publication.
			if bytes.HasPrefix(second, []byte("unavailable\n")) {
				second, err = writer("write").CombinedOutput()
				if err != nil {
					t.Fatalf("second writer retry: %v\n%s", err, second)
				}
			}
			if !bytes.HasPrefix(second, []byte("published\n")) {
				t.Fatalf("second writer result = %q", second)
			}
			for _, body := range []string{cacheTestFirstArchive, cacheTestSecondArchive} {
				path, err := cache.base(deltaDigest([]byte(body)))
				if err != nil || path == "" {
					t.Fatalf("published archive %q missing: %v", body, err)
				}
			}
			entries, err := os.ReadDir(cache.directory)
			if err != nil {
				t.Fatal(err)
			}
			var count int
			var size int64
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), ".incoming-") {
					t.Fatalf("temporary archive left behind: %q", entry.Name())
				}
				if filepath.Ext(entry.Name()) != ".zip" {
					continue
				}
				info, err := entry.Info()
				if err != nil {
					t.Fatal(err)
				}
				count++
				size += info.Size()
			}
			if count > archiveCacheEntries || size > archiveCacheBudget {
				t.Fatalf("cache contains %d archives and %d bytes, limits are %d and %d", count, size, archiveCacheEntries, archiveCacheBudget)
			}
		})
	}
}

func TestArchiveCacheWriterProcess(t *testing.T) {
	role := os.Getenv("LITHE_TEST_ARCHIVE_CACHE_ROLE")
	if role == "" {
		t.Skip("archive cache subprocess")
	}
	cache := ArchiveCache{directory: os.Getenv("LITHE_TEST_ARCHIVE_CACHE_DIRECTORY")}
	switch role {
	case "hold":
		target, err := cache.path(deltaDigest([]byte(cacheTestFirstArchive)))
		if err != nil {
			t.Fatal(err)
		}
		reader := &pausedArchiveCopy{Reader: strings.NewReader(cacheTestFirstArchive)}
		if err := cache.publish(t.Context(), reader, int64(len(cacheTestFirstArchive)), target); err != nil {
			t.Fatal(err)
		}
	case "write":
		archive := &DownloadedArchive{file: &archiveFile{path: os.Getenv("LITHE_TEST_ARCHIVE_CACHE_SOURCE")}}
		err := cache.remember(t.Context(), deltaDigest([]byte(cacheTestSecondArchive)), archive)
		if errors.Is(err, context.DeadlineExceeded) {
			fmt.Println("unavailable")
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		fmt.Println("published")
	default:
		t.Fatalf("unknown archive cache subprocess role %q", role)
	}
}

type pausedArchiveCopy struct {
	io.Reader
	released bool
}

func (c *pausedArchiveCopy) Read(p []byte) (int, error) {
	if !c.released {
		if _, err := fmt.Fprintln(os.Stdout, "copying"); err != nil {
			return 0, err
		}
		if _, err := io.Copy(io.Discard, os.Stdin); err != nil {
			return 0, err
		}
		c.released = true
	}
	return c.Reader.Read(p)
}
