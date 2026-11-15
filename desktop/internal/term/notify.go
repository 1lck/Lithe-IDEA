package term

import (
	"bytes"
	"encoding/base64"
	"slices"
	"strings"
	"unicode/utf8"
)

// Desktop notifications a program asks for: OSC 9 (iTerm2, a message), OSC 777
// (urxvt's notify extension, a title and a message) and OSC 99 (kitty's, a title
// and body in any number of chunks). The terminal only reports a complete
// notification; whether and how to show it is the owner's.

const (
	// maxNotifyTitle and maxNotifyBody are what a notification keeps, in bytes.
	maxNotifyTitle = 200
	maxNotifyBody  = 1000
	// maxKittyPending bounds how many unfinished OSC 99 notifications are held.
	maxKittyPending = 4
)

// Notification is one desktop notification a program asked for.
type Notification struct {
	Title string
	Body  string
}

// SetNotify installs the receiver of notifications. The callback runs during
// Write and must not block.
func (t *Terminal) SetNotify(notify func(Notification)) { t.notifyFn = notify }

// SetBell installs the receiver of the bell, BEL (0x07) outside a control
// string, where it ends the string instead. The callback runs during Write
// and must not block; a program that rings in a loop calls it for every BEL,
// so the owner limits how often it sounds.
func (t *Terminal) SetBell(bell func()) { t.bellFn = bell }

// kittyPending is an OSC 99 notification whose chunks have not all arrived.
type kittyPending struct {
	id          string
	title, body []byte
}

func (t *Terminal) notify(title, body string) {
	title, body = cleanNotifyText(title, maxNotifyTitle), cleanNotifyText(body, maxNotifyBody)
	if t.notifyFn == nil || title == "" && body == "" {
		return
	}
	t.notifyFn(Notification{Title: title, Body: body})
}

// cleanNotifyText makes a notification's text safe to show: no control
// characters (a program could otherwise smuggle escape sequences into a native
// notification), valid UTF-8, a bounded length.
func cleanNotifyText(value string, limit int) string {
	value = strings.ToValidUTF8(value, "")
	value = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\t':
			return ' '
		case r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0:
			return -1
		}
		return r
	}, value)
	value = strings.TrimSpace(value)
	if len(value) > limit {
		value = strings.ToValidUTF8(value[:limit], "")
	}
	return value
}

// osc9 is iTerm2's growl message. ConEmu reuses OSC 9 for its own commands, which
// start with a number and a semicolon (9;4 sets a progress bar, 9;9 the working
// directory): those are not messages.
func (t *Terminal) osc9(text []byte) {
	if bytes.HasPrefix(text, []byte("9;")) {
		t.oscWindowsDirectory(string(text[2:]))
		return
	}
	if i := bytes.IndexByte(text, ';'); i > 0 && allDigits(text[:i]) {
		return
	}
	if len(text) == 1 && text[0] >= '0' && text[0] <= '9' {
		return
	}
	t.notify("", string(text))
}

func allDigits(value []byte) bool {
	for _, b := range value {
		if b < '0' || b > '9' {
			return false
		}
	}
	return len(value) > 0
}

// osc777 is urxvt's extension: 777;notify;title;body. Other 777 commands are
// ignored.
func (t *Terminal) osc777(text []byte) {
	parts := bytes.SplitN(text, []byte{';'}, 3)
	if len(parts) < 2 || string(parts[0]) != "notify" {
		return
	}
	title, body := string(parts[1]), ""
	if len(parts) == 3 {
		body = string(parts[2])
	}
	t.notify(title, body)
}

// osc99 is kitty's desktop notification protocol, the part that carries text:
// 99;key=value:key=value;payload. i names the notification, d=0 says more chunks
// follow, p says whether the payload is the title (the default) or the body, and
// e=1 says it is base64. Actions, urgency, icons and the rest are ignored.
func (t *Terminal) osc99(text []byte) {
	separator := bytes.IndexByte(text, ';')
	if separator < 0 {
		return
	}
	var (
		id      string
		done    = true
		isBody  bool
		encoded bool
	)
	for _, field := range bytes.Split(text[:separator], []byte{':'}) {
		key, value, ok := bytes.Cut(field, []byte{'='})
		if !ok || len(key) != 1 {
			continue
		}
		switch key[0] {
		case 'i':
			id = string(value)
		case 'd':
			done = string(value) != "0"
		case 'p':
			isBody = string(value) == "body"
			if v := string(value); v != "title" && v != "body" {
				return // icons, close requests, queries: not ours
			}
		case 'e':
			encoded = string(value) == "1"
		}
	}
	payload := text[separator+1:]
	if encoded {
		decoded, err := base64.StdEncoding.DecodeString(string(payload))
		if err != nil || !utf8.Valid(decoded) {
			return
		}
		payload = decoded
	}
	var pending *kittyPending
	for index := range t.kittyNotes {
		if t.kittyNotes[index].id == id {
			pending = &t.kittyNotes[index]
		}
	}
	if pending == nil {
		if len(t.kittyNotes) == maxKittyPending {
			t.kittyNotes = slices.Delete(t.kittyNotes, 0, 1)
		}
		t.kittyNotes = append(t.kittyNotes, kittyPending{id: id})
		pending = &t.kittyNotes[len(t.kittyNotes)-1]
	}
	target := &pending.title
	limit := maxNotifyTitle
	if isBody {
		target, limit = &pending.body, maxNotifyBody
	}
	if room := limit*2 - len(*target); room > 0 {
		*target = append(*target, payload[:min(len(payload), room)]...)
	}
	if !done {
		return
	}
	title, body := string(pending.title), string(pending.body)
	for index := range t.kittyNotes {
		if t.kittyNotes[index].id == id {
			t.kittyNotes = slices.Delete(t.kittyNotes, index, index+1)
			break
		}
	}
	if title == "" && body != "" {
		title, body = body, "" // a lone body is the message
	}
	t.notify(title, body)
}
