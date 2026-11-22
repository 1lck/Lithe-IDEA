package remoteconn

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// keptStore is a secret store held in a map, keyed by namespace and key.
type keptStore map[string]string

func (s keptStore) Get(_ context.Context, namespace, key string) (string, bool, error) {
	secret, found := s[namespace+"/"+key]
	return secret, found, nil
}

func (s keptStore) Set(_ context.Context, namespace, key, secret string) error {
	s[namespace+"/"+key] = secret
	return nil
}

func (s keptStore) Delete(_ context.Context, namespace, key string) error {
	delete(s, namespace+"/"+key)
	return nil
}

func resumeOf(n int) core.RemoteResume {
	return core.RemoteResume{Key: fmt.Sprintf("key-%d", n), Token: fmt.Sprintf("token-%d", n)}
}

// The newest kept session is the one a connection resumes; keeping one of the same key again
// moves it to the newest; forgetting removes it and the item once the list is empty. Each
// connection has its own list, under an account that names no connection.
func TestKeptSessionsNewestReplaceAndForget(t *testing.T) {
	ctx, store := testContext(t), keptStore{}
	if got, err := NewestKept(ctx, store, "build"); err != nil || got != nil {
		t.Fatalf("a connection that kept nothing has %+v, %v", got, err)
	}
	for _, n := range []int{1, 2, 1} {
		if err := RememberKept(ctx, store, "build", resumeOf(n)); err != nil {
			t.Fatal(err)
		}
	}
	if err := RememberKept(ctx, store, "other", resumeOf(9)); err != nil {
		t.Fatal(err)
	}
	if got, _ := NewestKept(ctx, store, "build"); got == nil || *got != resumeOf(1) {
		t.Fatalf("newest %+v, want the session kept again last", got)
	}
	if len(store) != 2 {
		t.Fatalf("the store holds %d items, want one per connection", len(store))
	}
	account := regexp.MustCompile(`^` + regexp.QuoteMeta(KeptNamespace) + `/kept\.[0-9a-f]{32}$`)
	for item := range store {
		if !account.MatchString(item) || strings.Contains(item, "build") || strings.Contains(item, "other") {
			t.Fatal("an item's account is not a digest of the connection")
		}
	}

	if err := ForgetKept(ctx, store, "build", "key-1"); err != nil {
		t.Fatal(err)
	}
	if got, _ := NewestKept(ctx, store, "build"); got == nil || *got != resumeOf(2) {
		t.Fatalf("after forgetting the newest, newest %+v, want the one before", got)
	}
	if err := ForgetKept(ctx, store, "build", "key-absent"); err != nil {
		t.Fatalf("forgetting a session that is not kept: %v", err)
	}
	if err := ForgetKept(ctx, store, "build", "key-2"); err != nil {
		t.Fatal(err)
	}
	if got, _ := NewestKept(ctx, store, "build"); got != nil || len(store) != 1 {
		t.Fatal("forgetting the last session did not remove the connection's item")
	}
}

// A connection remembers keptLimit sessions, forgetting the oldest beyond them.
func TestKeptSessionsForgetTheOldestBeyondTheLimit(t *testing.T) {
	ctx, store := testContext(t), keptStore{}
	for n := 1; n <= keptLimit+2; n++ {
		if err := RememberKept(ctx, store, "build", resumeOf(n)); err != nil {
			t.Fatal(err)
		}
	}
	kept, err := readKept(ctx, store, "build")
	if err != nil {
		t.Fatal(err)
	}
	if len(kept) != keptLimit || kept[0] != resumeOf(3) || kept[len(kept)-1] != resumeOf(keptLimit+2) {
		t.Fatalf("kept %d sessions from %+v, want the newest %d", len(kept), kept[0], keptLimit)
	}
	// The whole list fits Windows Credential Manager's 2560 bytes with keys and tokens of the size
	// Core issues (32 and 43 characters).
	long := make([]core.RemoteResume, keptLimit)
	for i := range long {
		long[i] = core.RemoteResume{Key: strings.Repeat("k", 32), Token: strings.Repeat("t", 43)}
		long[i].Key = fmt.Sprintf("%d%s", i, long[i].Key[1:])
	}
	if err := writeKept(ctx, store, "long", long); err != nil {
		t.Fatal(err)
	}
	if secret, _, _ := store.Get(ctx, KeptNamespace, keptAccount("long")); len(secret) > 2560 {
		t.Fatalf("a full list takes %d bytes", len(secret))
	}
}

// A secret that does not decode, or holds entries without a key or a token, reads as no session,
// and the next keep replaces it.
func TestKeptSessionsIgnoreWhatDoesNotDecode(t *testing.T) {
	ctx, store := testContext(t), keptStore{}
	account := keptAccount("build")
	for _, secret := range []string{"not json", `[{"key":"","token":"t"},{"key":"k","token":""}]`} {
		_ = store.Set(ctx, KeptNamespace, account, secret)
		if got, err := NewestKept(ctx, store, "build"); err != nil || got != nil {
			t.Fatalf("%q reads as %+v, %v", secret, got, err)
		}
	}
	if err := RememberKept(ctx, store, "build", resumeOf(1)); err != nil {
		t.Fatal(err)
	}
	if got, _ := NewestKept(ctx, store, "build"); got == nil || *got != resumeOf(1) {
		t.Fatalf("after a keep, newest %+v", got)
	}
}
