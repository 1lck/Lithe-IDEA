package remoteconn

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A window closed with "Keep on Host" leaves its programs running in the host session, and the
// next connection to the same target resumes that session (#2231, §9.2). What resumes it is the
// session's key and token, which this file remembers in the platform secret store, one item per
// connection: the token is a secret, so it never goes into a preference file or the log.
//
// The item's account is a digest of the connection's id, so the store's list of items names no
// host or WSL distribution. Its secret is a JSON list of the connection's kept sessions, newest
// last. Both entry count and actual serialized bytes are capped to fit Windows Credential
// Manager. Eviction forgets the oldest record. Core compares the newest record's verified binding
// before sending it to the host; only a consumed record is forgotten. A mismatch or legacy record
// remains available for its original target. Giving a resumed session back without opening a
// workspace stores it again (workbench, remote_close.go).

// KeptNamespace is the secret-store namespace of the kept sessions; "@host/" namespaces are the
// application's own and cannot clash with a plugin's id.
const KeptNamespace = "@host/remote-sessions"

// keptLimit is how many kept sessions one connection remembers.
const keptLimit = 8

// Credential Manager limits the actual UTF-8 secret blob to 2560 bytes.
const keptBytes = 2560

// Secrets is the secret store the kept sessions and the remembered answers (answers.go) are
// kept in, credentials.Store in the application. Get reports found false for an item that is not
// there.
type Secrets interface {
	Get(ctx context.Context, namespace, key string) (string, bool, error)
	Set(ctx context.Context, namespace, key, secret string) error
	Delete(ctx context.Context, namespace, key string) error
}

// keptLock makes each change of a connection's list one read and one write, so two windows of the
// application closing at once do not drop each other's session.
var keptLock sync.Mutex

// keptAccount is the store's key of connectionID's item: "kept." and the first 128 bits of the
// id's SHA-256, which the store's key alphabet allows.
func keptAccount(connectionID string) string {
	sum := sha256.Sum256([]byte(connectionID))
	return "kept." + hex.EncodeToString(sum[:16])
}

// readKept is connectionID's list, oldest first. A secret that does not decode holds no session
// that can be resumed, so it reads as an empty list, which the next change replaces.
func readKept(ctx context.Context, secrets Secrets, connectionID string) ([]core.RemoteResume, error) {
	secret, found, err := secrets.Get(ctx, KeptNamespace, keptAccount(connectionID))
	if err != nil || !found {
		return nil, err
	}
	var kept []core.RemoteResume
	if json.Unmarshal([]byte(secret), &kept) != nil {
		return nil, nil
	}
	return slices.DeleteFunc(kept, func(resume core.RemoteResume) bool { return resume.Key == "" || resume.Token == "" }), nil
}

// writeKept stores kept as connectionID's list, removing the item when it is empty.
func writeKept(ctx context.Context, secrets Secrets, connectionID string, kept []core.RemoteResume) error {
	account := keptAccount(connectionID)
	if len(kept) == 0 {
		return secrets.Delete(ctx, KeptNamespace, account)
	}
	secret, err := json.Marshal(kept)
	if err != nil {
		return err
	}
	for len(secret) > keptBytes && len(kept) > 1 {
		kept = kept[1:]
		secret, err = json.Marshal(kept)
		if err != nil {
			return err
		}
	}
	if len(secret) > keptBytes {
		return errors.New("remote session credential exceeds storage capacity")
	}
	return secrets.Set(ctx, KeptNamespace, account, string(secret))
}

// NewestKept is the session connectionID kept last, nil when it keeps none.
func NewestKept(ctx context.Context, secrets Secrets, connectionID string) (*core.RemoteResume, error) {
	keptLock.Lock()
	defer keptLock.Unlock()
	kept, err := readKept(ctx, secrets, connectionID)
	if err != nil || len(kept) == 0 {
		return nil, err
	}
	newest := kept[len(kept)-1]
	return &newest, nil
}

// RememberKept adds resume as connectionID's newest kept session, replacing an entry of the same
// key and forgetting the oldest beyond keptLimit.
func RememberKept(ctx context.Context, secrets Secrets, connectionID string, resume core.RemoteResume) error {
	keptLock.Lock()
	defer keptLock.Unlock()
	kept, err := readKept(ctx, secrets, connectionID)
	if err != nil {
		return err
	}
	kept = slices.DeleteFunc(kept, func(entry core.RemoteResume) bool { return entry.Key == resume.Key })
	kept = append(kept, resume)
	if len(kept) > keptLimit {
		kept = kept[len(kept)-keptLimit:]
	}
	return writeKept(ctx, secrets, connectionID, kept)
}

// ForgetKept removes the session key from connectionID's list; forgetting one that is not there
// succeeds.
func ForgetKept(ctx context.Context, secrets Secrets, connectionID, key string) error {
	keptLock.Lock()
	defer keptLock.Unlock()
	kept, err := readKept(ctx, secrets, connectionID)
	if err != nil {
		return err
	}
	left := slices.DeleteFunc(slices.Clone(kept), func(entry core.RemoteResume) bool { return entry.Key == key })
	if len(left) == len(kept) {
		return nil
	}
	return writeKept(ctx, secrets, connectionID, left)
}
