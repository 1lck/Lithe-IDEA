package store

import (
	"bytes"
	"encoding"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
)

// A file can hold settings this version of the client cannot read: a newer version wrote keys
// this one has no field for, or gave a known key a value of another shape. The stable channel
// and AutoBuild share one settings directory, so an install that moves between them meets both.
// Load finds them by walking the file against the type it decodes into, and Save writes them back
// beside what the value holds, so that running an older version and saving does not erase what
// the newer one stored.
//
// What a save writes back is only what this version cannot have changed:
//   - a key no field reads, wherever its parent object is still written;
//   - a known key whose stored value this version could not decode, as long as the value still
//     encodes as it did right after the load. Once this version sets the field, its value wins
//     and the stored one is dropped.
//
// A known key this version clears is gone from the next save, as before: the walk never keeps a
// key it can read. Arrays are kept or replaced whole; the walk does not look inside them.

// keptObject is what one JSON object in a file holds that the value it decoded into cannot.
type keptObject struct {
	// unknown are the keys no field reads, with their stored values.
	unknown map[string]json.RawMessage
	// foreign are the known keys whose stored value would not decode, by the name this
	// version writes.
	foreign map[string]*foreignValue
	// inner are the known keys holding objects that keep something themselves, by the name this
	// version writes.
	inner map[string]*keptObject
}

// foreignValue is a stored value the field could not take, and how the field encoded right after
// the load, nil when it was left out.
type foreignValue struct {
	stored, loaded json.RawMessage
}

func (object *keptObject) empty() bool {
	return len(object.unknown) == 0 && len(object.foreign) == 0 && len(object.inner) == 0
}

// paths appends the dotted path of every key object keeps, under prefix.
func (object *keptObject) paths(prefix string, into []string) []string {
	for key := range object.unknown {
		into = append(into, prefix+key)
	}
	for key := range object.foreign {
		into = append(into, prefix+key)
	}
	for key, inner := range object.inner {
		into = inner.paths(prefix+key+".", into)
	}
	return into
}

var (
	jsonUnmarshaler = reflect.TypeFor[json.Unmarshaler]()
	textUnmarshaler = reflect.TypeFor[encoding.TextUnmarshaler]()
)

// opaque reports whether values of t decode themselves, so their insides are not fields to walk.
func opaque(t reflect.Type) bool {
	if t.Kind() == reflect.Interface {
		return true
	}
	pointer := reflect.PointerTo(t)
	return t.Implements(jsonUnmarshaler) || pointer.Implements(jsonUnmarshaler) ||
		t.Implements(textUnmarshaler) || pointer.Implements(textUnmarshaler)
}

// walk compares the stored JSON value with the type it decodes into and returns what that type
// cannot hold, or nil when it holds everything.
func walk(stored json.RawMessage, t reflect.Type) *keptObject {
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if opaque(t) {
		return nil
	}
	var object map[string]json.RawMessage
	switch t.Kind() {
	case reflect.Struct:
		if json.Unmarshal(stored, &object) != nil || object == nil {
			return nil
		}
		fields := fieldsOf(t)
		kept := &keptObject{}
		for _, key := range sortedKeys(object) {
			value := object[key]
			field, ok := fields.match(key)
			switch {
			case !ok:
				kept.keepUnknown(key, value)
			case !field.decodes(value):
				kept.keepForeign(field.name, value)
			default:
				if inner := walk(value, field.typ); inner != nil {
					kept.keepInner(field.name, inner)
				}
			}
		}
		if kept.empty() {
			return nil
		}
		return kept
	case reflect.Map:
		if t.Key().Kind() != reflect.String || json.Unmarshal(stored, &object) != nil || object == nil {
			return nil
		}
		element := field{typ: t.Elem()}
		kept := &keptObject{}
		for _, key := range sortedKeys(object) {
			value := object[key]
			if !element.decodes(value) {
				kept.keepForeign(key, value)
			} else if inner := walk(value, t.Elem()); inner != nil {
				kept.keepInner(key, inner)
			}
		}
		if kept.empty() {
			return nil
		}
		return kept
	}
	return nil
}

func (object *keptObject) keepUnknown(key string, value json.RawMessage) {
	if object.unknown == nil {
		object.unknown = map[string]json.RawMessage{}
	}
	object.unknown[key] = value
}

func (object *keptObject) keepForeign(name string, value json.RawMessage) {
	if object.foreign == nil {
		object.foreign = map[string]*foreignValue{}
	}
	object.foreign[name] = &foreignValue{stored: value}
}

func (object *keptObject) keepInner(name string, inner *keptObject) {
	if object.inner == nil {
		object.inner = map[string]*keptObject{}
	}
	object.inner[name] = inner
}

// noteLoaded records how each foreign value's field encoded right after the load, from the value
// encoded as a whole.
func (object *keptObject) noteLoaded(encoded json.RawMessage) {
	var current map[string]json.RawMessage
	_ = json.Unmarshal(encoded, &current)
	for name, foreign := range object.foreign {
		foreign.loaded = compacted(current[name])
	}
	for name, inner := range object.inner {
		inner.noteLoaded(current[name])
	}
}

// merge writes what object keeps into encoded, the object as this version encodes it now. An
// object this version no longer writes at all, such as a cleared pointer, gets nothing back.
// A foreign value whose field has changed since the load is dropped for good.
func (object *keptObject) merge(encoded json.RawMessage) json.RawMessage {
	var current map[string]json.RawMessage
	if json.Unmarshal(encoded, &current) != nil || current == nil {
		return encoded
	}
	for key, value := range object.unknown {
		if _, written := current[key]; !written {
			current[key] = value
		}
	}
	for name, foreign := range object.foreign {
		now, written := current[name]
		unchanged := (!written && foreign.loaded == nil) ||
			(written && foreign.loaded != nil && bytes.Equal(compacted(now), foreign.loaded))
		if !unchanged {
			delete(object.foreign, name)
			continue
		}
		current[name] = foreign.stored
	}
	for name, inner := range object.inner {
		if now, written := current[name]; written {
			current[name] = inner.merge(now)
		}
	}
	merged, err := json.Marshal(current)
	if err != nil {
		return encoded
	}
	return merged
}

// field is one key a struct reads: the name it writes and the type it decodes into.
type field struct {
	name string
	typ  reflect.Type
	// quoted is the ",string" option: the value is a JSON string holding the field's.
	quoted bool
}

// decodes reports whether value has a shape the field can take. A struct or map only has to be
// an object, because walk looks inside it; anything else has to decode whole.
func (f field) decodes(value json.RawMessage) bool {
	t := f.typ
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	trimmed := bytes.TrimSpace(value)
	if bytes.Equal(trimmed, []byte("null")) || f.quoted {
		return true
	}
	if !opaque(t) && (t.Kind() == reflect.Struct || t.Kind() == reflect.Map) {
		return len(trimmed) > 0 && trimmed[0] == '{'
	}
	return json.Unmarshal(value, reflect.New(f.typ).Interface()) == nil
}

type fields []field

// match finds the field encoding/json would decode key into: the exact name first, then one that
// differs only in case.
func (list fields) match(key string) (field, bool) {
	for _, candidate := range list {
		if candidate.name == key {
			return candidate, true
		}
	}
	for _, candidate := range list {
		if strings.EqualFold(candidate.name, key) {
			return candidate, true
		}
	}
	return field{}, false
}

// fieldsOf lists the keys a struct type reads, as encoding/json names them: the tag name or the
// field name, skipping "-" and unexported fields, with the fields of an untagged embedded struct
// promoted.
func fieldsOf(t reflect.Type) fields {
	var list fields
	for index := range t.NumField() {
		structField := t.Field(index)
		tag := structField.Tag.Get("json")
		if tag == "-" {
			continue
		}
		name, options, _ := strings.Cut(tag, ",")
		fieldType := structField.Type
		if structField.Anonymous && name == "" {
			embedded := fieldType
			for embedded.Kind() == reflect.Pointer {
				embedded = embedded.Elem()
			}
			if embedded.Kind() == reflect.Struct {
				list = append(list, fieldsOf(embedded)...)
				continue
			}
		}
		if !structField.IsExported() {
			continue
		}
		if name == "" {
			name = structField.Name
		}
		quoted := false
		for option := range strings.SplitSeq(options, ",") {
			quoted = quoted || option == "string"
		}
		list = append(list, field{name: name, typ: fieldType, quoted: quoted})
	}
	return list
}

func sortedKeys(object map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(object))
	for key := range object {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// compacted is value without insignificant space, nil for no value.
func compacted(value json.RawMessage) json.RawMessage {
	if value == nil {
		return nil
	}
	var buffer bytes.Buffer
	if json.Compact(&buffer, value) != nil {
		return value
	}
	return buffer.Bytes()
}
