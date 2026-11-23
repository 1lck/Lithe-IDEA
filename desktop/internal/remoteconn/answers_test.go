package remoteconn

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
)

// cappedStore is a keptStore that refuses a secret longer than limit as the Windows store does.
type cappedStore struct {
	keptStore
	limit int
}

func (s cappedStore) Set(ctx context.Context, namespace, key, secret string) error {
	if len(secret) > s.limit {
		return credentials.ErrTooLarge
	}
	return s.keptStore.Set(ctx, namespace, key, secret)
}

var devbox = core.SSHConnection{Host: "devbox", Port: 2222, User: "dev"}

// Only a password or a passphrase is remembered; a code, a host key or another question never.
func TestOnlyPasswordsAndPassphrasesAreRememberable(t *testing.T) {
	for kind, want := range map[core.RemoteQuestionKind]bool{
		core.RemoteQuestionPassword: true, core.RemoteQuestionPassphrase: true,
		core.RemoteQuestionCode: false, core.RemoteQuestionHostKey: false, core.RemoteQuestionOther: false, "": false,
	} {
		if got := Rememberable(kind); got != want {
			t.Errorf("Rememberable(%q) = %v, want %v", kind, got, want)
		}
	}
}

// A question's digest changes with its kind, its wording and every field of the login, so an
// answer is never offered to another host, port, user or jump host, and names none of them.
func TestAnswerQuestionNamesOneQuestionOfOneLogin(t *testing.T) {
	question := AnswerQuestion(core.RemoteQuestionPassword, devbox, "dev@devbox's password: ")
	if got := AnswerQuestion(core.RemoteQuestionPassword, devbox, "  dev@devbox's password:"); got != question {
		t.Fatal("the digest depends on the space around the wording")
	}
	if !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(question) || strings.Contains(question, "devbox") {
		t.Fatalf("digest %q", question)
	}
	jump := devbox
	jump.ProxyJump = "bastion"
	others := map[string]string{
		"kind":   AnswerQuestion(core.RemoteQuestionPassphrase, devbox, "dev@devbox's password: "),
		"prompt": AnswerQuestion(core.RemoteQuestionPassword, devbox, "Password: "),
		"host":   AnswerQuestion(core.RemoteQuestionPassword, core.SSHConnection{Host: "other", Port: 2222, User: "dev"}, "dev@devbox's password: "),
		"port":   AnswerQuestion(core.RemoteQuestionPassword, core.SSHConnection{Host: "devbox", Port: 22, User: "dev"}, "dev@devbox's password: "),
		"user":   AnswerQuestion(core.RemoteQuestionPassword, core.SSHConnection{Host: "devbox", Port: 2222, User: "root"}, "dev@devbox's password: "),
		"jump":   AnswerQuestion(core.RemoteQuestionPassword, jump, "dev@devbox's password: "),
	}
	for field, other := range others {
		if other == question {
			t.Errorf("changing the %s keeps the digest", field)
		}
	}
}

// A remembered answer is found for its question only; remembering the question again replaces
// it; forgetting removes it and the item once the list is empty. Each connection has its own
// item, under an account that names no connection, and its secret names no host.
func TestRememberedAnswersReplaceAndForget(t *testing.T) {
	ctx, store := testContext(t), keptStore{}
	password := AnswerQuestion(core.RemoteQuestionPassword, devbox, "Password: ")
	passphrase := AnswerQuestion(core.RemoteQuestionPassphrase, devbox, "Enter passphrase for key 'id': ")
	if _, found, err := RememberedAnswer(ctx, store, "build", password); err != nil || found {
		t.Fatalf("a connection that remembers nothing found an answer, %v", err)
	}
	if err := ChangeAnswers(ctx, store, "build", []AnswerChange{
		{Question: password, Answer: "first"}, {Question: passphrase, Answer: "phrase"}, {Question: password, Answer: "s3cret"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := ChangeAnswers(ctx, store, "other", []AnswerChange{{Question: password, Answer: "elsewhere"}}); err != nil {
		t.Fatal(err)
	}
	if answer, found, _ := RememberedAnswer(ctx, store, "build", password); !found || answer != "s3cret" {
		t.Fatalf("answer %q, %v; want the one remembered last", answer, found)
	}
	if answer, _, _ := RememberedAnswer(ctx, store, "other", password); answer != "elsewhere" {
		t.Fatalf("the other connection's answer is %q", answer)
	}
	if len(store) != 2 {
		t.Fatalf("the store holds %d items, want one per connection", len(store))
	}
	account := regexp.MustCompile(`^` + regexp.QuoteMeta(AnswersNamespace) + `/answers\.[0-9a-f]{32}$`)
	for item, secret := range store {
		if !account.MatchString(item) || strings.Contains(item, "build") || strings.Contains(item, "other") {
			t.Fatal("an item's account is not a digest of the connection")
		}
		if strings.Contains(secret, "devbox") || strings.Contains(secret, "Password") {
			t.Fatal("an item's secret names the host or the question")
		}
	}

	if err := ChangeAnswers(ctx, store, "build", []AnswerChange{{Question: password, Forget: true}}); err != nil {
		t.Fatal(err)
	}
	if _, found, _ := RememberedAnswer(ctx, store, "build", password); found {
		t.Fatal("a forgotten answer is still found")
	}
	if answer, _, _ := RememberedAnswer(ctx, store, "build", passphrase); answer != "phrase" {
		t.Fatalf("forgetting the password lost the passphrase: %q", answer)
	}
	if err := ChangeAnswers(ctx, store, "build", []AnswerChange{{Question: passphrase, Forget: true}}); err != nil {
		t.Fatal(err)
	}
	if err := ForgetAnswers(ctx, store, "other"); err != nil {
		t.Fatal(err)
	}
	if len(store) != 0 {
		t.Fatalf("empty lists left %d items", len(store))
	}
	if err := ForgetAnswers(ctx, store, "other"); err != nil {
		t.Fatalf("forgetting a connection that remembers nothing failed: %v", err)
	}
}

// Changes that leave the list as it was write nothing, so a connection whose answers did not
// change does not touch the store.
func TestUnchangedAnswersWriteNothing(t *testing.T) {
	ctx := testContext(t)
	question := AnswerQuestion(core.RemoteQuestionPassword, devbox, "Password: ")
	store := cappedStore{keptStore: keptStore{}, limit: 1 << 20}
	if err := ChangeAnswers(ctx, store, "build", []AnswerChange{{Question: question, Answer: "s3cret"}}); err != nil {
		t.Fatal(err)
	}
	// A store that refuses every write shows whether one is attempted.
	store.limit = 0
	for _, changes := range [][]AnswerChange{
		nil,
		{{Question: question, Answer: "s3cret"}},
		{{Question: "not-remembered", Forget: true}},
	} {
		if err := ChangeAnswers(ctx, store, "build", changes); err != nil {
			t.Fatalf("%+v wrote to the store: %v", changes, err)
		}
	}
}

// A list beyond the limit forgets its oldest answers; a list the store cannot hold keeps only the
// newest; a secret that does not decode reads as no answer and is replaced by the next change.
func TestRememberedAnswersStayWithinTheStore(t *testing.T) {
	ctx, store := testContext(t), keptStore{}
	for n := 1; n <= answersLimit+2; n++ {
		if err := ChangeAnswers(ctx, store, "build", []AnswerChange{{Question: fmt.Sprintf("q%d", n), Answer: fmt.Sprintf("a%d", n)}}); err != nil {
			t.Fatal(err)
		}
	}
	for n := 1; n <= answersLimit+2; n++ {
		_, found, _ := RememberedAnswer(ctx, store, "build", fmt.Sprintf("q%d", n))
		if want := n > 2; found != want {
			t.Errorf("answer %d found %v, want %v", n, found, want)
		}
	}

	capped := cappedStore{keptStore: keptStore{}, limit: 120}
	for _, n := range []int{1, 2, 3} {
		if err := ChangeAnswers(ctx, capped, "build", []AnswerChange{{Question: fmt.Sprintf("q%d", n), Answer: strings.Repeat("x", 30)}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, found, _ := RememberedAnswer(ctx, capped, "build", "q3"); !found {
		t.Fatal("the newest answer was not kept when the list was too large")
	}
	if _, found, _ := RememberedAnswer(ctx, capped, "build", "q1"); found {
		t.Fatal("a list too large for the store kept its oldest answer")
	}
	if err := ChangeAnswers(ctx, capped, "build", []AnswerChange{{Question: "q4", Answer: strings.Repeat("x", 200)}}); err == nil {
		t.Fatal("an answer the store cannot hold on its own was reported remembered")
	}

	store[AnswersNamespace+"/"+answersAccount("broken")] = "not json"
	if _, found, err := RememberedAnswer(ctx, store, "broken", "q1"); err != nil || found {
		t.Fatalf("an undecodable secret found an answer, %v", err)
	}
	if err := ChangeAnswers(ctx, store, "broken", []AnswerChange{{Question: "q1", Answer: "a1"}}); err != nil {
		t.Fatal(err)
	}
	if answer, _, _ := RememberedAnswer(ctx, store, "broken", "q1"); answer != "a1" {
		t.Fatalf("the undecodable secret was not replaced: %q", answer)
	}
}
