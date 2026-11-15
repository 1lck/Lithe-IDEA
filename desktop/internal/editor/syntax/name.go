package syntax

import (
	"sync"
	"sync/atomic"
)

// Name is an interned token name, such as "keyword.java" or "method.declaration.static". Tokens
// hold Names instead of styles, so a theme change restyles them without tokenizing again, and
// a Name is a plain integer, so the token arrays that hold them have no pointers for the garbage
// collector to scan. The zero Name is "", the token with no role.
type Name uint32

// names is every Name made so far. Names are never removed: there are few distinct token names
// and they are shared by every document. It is set by its declaration rather than by an init
// function, so that package variables that intern names, such as semanticNames, are
// initialized after it.
var names = newNameTable()

type nameTable struct {
	mu   sync.Mutex
	ids  map[string]Name
	list atomic.Pointer[[]string]
}

func newNameTable() *nameTable {
	t := &nameTable{ids: map[string]Name{"": 0}}
	list := []string{""}
	t.list.Store(&list)
	return t
}

// Intern returns the Name of token, making it on first use.
func Intern(token string) Name {
	names.mu.Lock()
	defer names.mu.Unlock()
	if n, ok := names.ids[token]; ok {
		return n
	}
	// Appending may write past the end of the slice readers hold, never inside it, and they see
	// the new element only through the new header, so readers need no lock.
	list := *names.list.Load()
	n := Name(len(list))
	list = append(list, token)
	names.ids[token] = n
	names.list.Store(&list)
	return n
}

// String is the token name.
func (n Name) String() string {
	list := *names.list.Load()
	if int(n) < len(list) {
		return list[n]
	}
	return ""
}

// nameCount is the number of Names made so far.
func nameCount() int { return len(*names.list.Load()) }
