package core

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
)

// The watch's events reach their callbacks in order: started, a batch of changes, a batch that
// only lost changes, and the host's watch limit. An empty batch, the root's removal (which ends
// the request instead) and events that are not the watch's are not delivered. A batch that cannot
// be read is an error, since its changes would be missed.
func TestRemoteWatchEventsReachTheirCallbacks(t *testing.T) {
	var got []string
	events := RemoteWatchEvents{
		Started: func() { got = append(got, "started") },
		Changed: func(changes []RemoteWatchChange, overflow bool) {
			entry := "changed"
			for _, change := range changes {
				entry += " " + change.Kind + ":" + change.Path
			}
			if overflow {
				entry += " overflow"
			}
			got = append(got, entry)
		},
		LimitReached: func() { got = append(got, "limit") },
	}
	for _, raw := range []string{
		`{"type":"progress","message":"remote"}`,
		`{"type":"remote","event":"watch.started","params":{"watchId":3,"pid":null}}`,
		`{"type":"remote","event":"watch.changed","params":{"watchId":3,"changes":[{"path":"/srv/repo/a.go","kind":"modified"},{"path":"/srv/repo/b","kind":"deleted"}],"overflow":false}}`,
		`{"type":"remote","event":"watch.changed","params":{"watchId":3,"changes":[],"overflow":false}}`,
		`{"type":"remote","event":"watch.changed","params":{"watchId":3,"changes":[],"overflow":true}}`,
		`{"type":"remote","event":"watch.error","params":{"watchId":3,"code":"LIMIT_REACHED","message":"inotify limit"}}`,
		`{"type":"remote","event":"watch.error","params":{"watchId":3,"code":"ROOT_REMOVED","message":"gone"}}`,
		`{"type":"remote","event":"terminal.output","params":{"terminalId":1,"data":"aGk="}}`,
	} {
		if err := deliverRemoteWatchEvent(json.RawMessage(raw), events); err != nil {
			t.Fatalf("event %s: %v", raw, err)
		}
	}
	want := []string{"started", "changed modified:/srv/repo/a.go deleted:/srv/repo/b", "changed overflow", "limit"}
	if !slices.Equal(got, want) {
		t.Fatalf("delivered %q, want %q", got, want)
	}
	for _, bad := range []string{
		`{"type":"remote","event":"watch.changed","params":{"watchId":3,"changes":"not a list"}}`,
		`{"type":"remote","event":"watch.error","params":{"watchId":3,"code":7}}`,
	} {
		if err := deliverRemoteWatchEvent(json.RawMessage(bad), events); !errors.Is(err, errRemoteWatchEvent) {
			t.Fatalf("unreadable event %s = %v, want errRemoteWatchEvent", bad, err)
		}
	}
}

// With the real kernel, a watch over a session Core does not know fails with connection_closed
// and never reports a start.
func TestRemoteWatchOfAnUnknownSession(t *testing.T) {
	client := NewClient()
	started := false
	err := client.RemoteRunWatch(testContext(t), "no-such-session", "/srv/repo", []string{"target"}, RemoteWatchEvents{
		Started: func() { started = true },
	})
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed || started {
		t.Fatalf("runWatch = %v, started %v, want connection_closed", err, started)
	}
}

// The tree filters the host watch's changes in Core without the session: a remote workspace's
// context, connected or not, gets the folders Core hides dropped by name.
func TestRemoteWorkspaceFiltersChangesWithoutTheHost(t *testing.T) {
	client := NewClient()
	binding := NewRemoteWorkspace("/cache/remote/1/abc/repo", "/srv/repo", nil)
	ctx := WithRemoteWorkspace(testContext(t), binding)
	for _, attached := range []bool{false, true} {
		if attached {
			binding.Attach("no-such-session")
		}
		filtered, err := client.FilterWorkspaceChanges(ctx, []string{".git/index", "src/main.go"})
		if err != nil || strings.Join(filtered, ",") != "src/main.go" {
			t.Fatalf("filterChanges (attached %v) = %q, %v, want src/main.go", attached, filtered, err)
		}
	}
	// A command that reads the workspace still goes to the host.
	if _, err := client.ListDirectories(ctx, "/cache/remote/1/abc/repo", []string{""}); err == nil {
		t.Fatal("listing the remote workspace without its host succeeded")
	}
}
