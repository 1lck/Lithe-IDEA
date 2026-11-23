package remoteconn

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
)

// A password or key passphrase OpenSSH asks a saved connection for is remembered only when the
// user ticks Remember under the question (#2231, S12), and only in the platform secret store:
// never in a preference file, Core's state or the log. One-time codes, host keys and any other
// question are never remembered.
//
// Each saved connection has one item. Its account is a digest of the connection's id, so the
// store's list of items names no host. Its secret is a JSON list of the remembered answers,
// newest last, each filed under a digest of its question: the kind, the host, port, user and jump
// host the question was asked for, and OpenSSH's wording. An answer is therefore offered only to
// the same question of the same login, never to the host a connection was edited to before it is
// saved. answersLimit caps the list so the item fits Windows Credential Manager's 2560 bytes; a
// list the store still cannot hold keeps only its newest answer.

// AnswersNamespace is the secret-store namespace of the remembered answers.
const AnswersNamespace = "@host/remote-answers"

// answersLimit is how many answers one saved connection remembers.
const answersLimit = 8

// answerEntry is one remembered answer.
type answerEntry struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

// answersLock makes each change of a connection's list one read and one write, so two windows
// connecting at once do not drop each other's answer.
var answersLock sync.Mutex

// Rememberable reports whether the answer to a question of kind may be remembered: a password or
// a key's passphrase.
func Rememberable(kind core.RemoteQuestionKind) bool {
	return kind == core.RemoteQuestionPassword || kind == core.RemoteQuestionPassphrase
}

// AnswerQuestion is the digest an answer to OpenSSH's question prompt, of kind, asked while
// logging in as login, is filed under: the first 128 bits of the SHA-256 of the fields, each
// ended by a NUL, which no field holds.
func AnswerQuestion(kind core.RemoteQuestionKind, login core.SSHConnection, prompt string) string {
	digest := sha256.New()
	for _, field := range []string{string(kind), login.Host, strconv.Itoa(int(login.Port)), login.User, login.ProxyJump, strings.TrimSpace(prompt)} {
		digest.Write([]byte(field))
		digest.Write([]byte{0})
	}
	return hex.EncodeToString(digest.Sum(nil)[:16])
}

// answersAccount is the store's key of connectionID's item: "answers." and the first 128 bits of
// the id's SHA-256, which the store's key alphabet allows.
func answersAccount(connectionID string) string {
	sum := sha256.Sum256([]byte(connectionID))
	return "answers." + hex.EncodeToString(sum[:16])
}

// readAnswers is connectionID's list, oldest first. A secret that does not decode holds no answer
// that can be sent, so it reads as an empty list, which the next change replaces.
func readAnswers(ctx context.Context, secrets Secrets, connectionID string) ([]answerEntry, error) {
	secret, found, err := secrets.Get(ctx, AnswersNamespace, answersAccount(connectionID))
	if err != nil || !found {
		return nil, err
	}
	var answers []answerEntry
	if json.Unmarshal([]byte(secret), &answers) != nil {
		return nil, nil
	}
	return slices.DeleteFunc(answers, func(entry answerEntry) bool { return entry.Question == "" || entry.Answer == "" }), nil
}

// writeAnswers stores answers as connectionID's list, removing the item when it is empty. A list
// too large for the store keeps only its newest answer.
func writeAnswers(ctx context.Context, secrets Secrets, connectionID string, answers []answerEntry) error {
	account := answersAccount(connectionID)
	if len(answers) == 0 {
		return secrets.Delete(ctx, AnswersNamespace, account)
	}
	secret, err := json.Marshal(answers)
	if err != nil {
		return err
	}
	err = secrets.Set(ctx, AnswersNamespace, account, string(secret))
	if errors.Is(err, credentials.ErrTooLarge) && len(answers) > 1 {
		return writeAnswers(ctx, secrets, connectionID, answers[len(answers)-1:])
	}
	return err
}

// RememberedAnswer is the answer connectionID remembers for question, an AnswerQuestion digest;
// found is false when it remembers none.
func RememberedAnswer(ctx context.Context, secrets Secrets, connectionID, question string) (answer string, found bool, err error) {
	answersLock.Lock()
	defer answersLock.Unlock()
	answers, err := readAnswers(ctx, secrets, connectionID)
	if err != nil {
		return "", false, err
	}
	for _, entry := range answers {
		if entry.Question == question {
			return entry.Answer, true, nil
		}
	}
	return "", false, nil
}

// AnswerChange remembers Answer for Question, an AnswerQuestion digest, or, with Forget set,
// forgets the answer remembered for it.
type AnswerChange struct {
	Question string
	Answer   string
	Forget   bool
}

// ChangeAnswers applies changes to connectionID's list in order, in one write: a remembered answer
// replaces the question's earlier one and becomes the newest, and the oldest beyond answersLimit
// are forgotten. Changes that leave the list as it was write nothing.
func ChangeAnswers(ctx context.Context, secrets Secrets, connectionID string, changes []AnswerChange) error {
	if len(changes) == 0 {
		return nil
	}
	answersLock.Lock()
	defer answersLock.Unlock()
	answers, err := readAnswers(ctx, secrets, connectionID)
	if err != nil {
		return err
	}
	changed := slices.Clone(answers)
	for _, change := range changes {
		changed = slices.DeleteFunc(changed, func(entry answerEntry) bool { return entry.Question == change.Question })
		if !change.Forget && change.Answer != "" {
			changed = append(changed, answerEntry{Question: change.Question, Answer: change.Answer})
		}
	}
	if len(changed) > answersLimit {
		changed = changed[len(changed)-answersLimit:]
	}
	if slices.Equal(changed, answers) {
		return nil
	}
	return writeAnswers(ctx, secrets, connectionID, changed)
}

// ForgetAnswers forgets every answer connectionID remembers; forgetting none succeeds.
func ForgetAnswers(ctx context.Context, secrets Secrets, connectionID string) error {
	answersLock.Lock()
	defer answersLock.Unlock()
	return secrets.Delete(ctx, AnswersNamespace, answersAccount(connectionID))
}
