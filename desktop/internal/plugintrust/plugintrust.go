// Package plugintrust remembers which programs a user approved for a plugin
// version, so a marketplace update can proceed without asking again while a
// package the user picked off disk is confirmed every time.
//
// Core's install review is a pure description and comparison, not an approval
// grant. The decision to reuse an earlier approval therefore lives here, and it
// is deliberately conservative: any change to the archive digest, the package
// content digest, the permission set or the program set asks the user again.
//
// Records are stored without timestamps and without any clock, so a decision is
// reproducible from the file alone.
package plugintrust

import (
	"encoding/json"
	"fmt"
	"sort"
)

// Source says where a package came from.
type Source string

const (
	// Marketplace is a package downloaded from an index the user subscribed to.
	// A matching earlier approval may be reused.
	Marketplace Source = "marketplace"
	// Disk is a package the user picked themselves. It is confirmed every time,
	// including when it replaces the same version with identical bytes.
	Disk Source = "disk"
)

// Review is the part of Core's install review this package decides on. It is a
// local shape rather than core.MarketplaceReview so that the trust rules stay
// testable without the kernel bridge.
type Review struct {
	// Permissions are the capability names the package asks for.
	Permissions []string
	// Programs are every program declaration in the package, as Core returned
	// them.
	Programs []json.RawMessage
	// NewPrograms are the declarations that no earlier approval covers.
	NewPrograms []json.RawMessage
}

// Record is the provenance of one approved plugin version.
type Record struct {
	PluginID         string            `json:"pluginID"`
	Version          string            `json:"version"`
	Source           Source            `json:"source"`
	ArchiveSHA256    string            `json:"archiveSHA256,omitempty"`
	ContentDigest    string            `json:"contentDigest,omitempty"`
	Permissions      []string          `json:"permissions"`
	ApprovedPrograms []json.RawMessage `json:"approvedPrograms"`
}

// Request is what the host knows about the package it is about to install.
type Request struct {
	// Source is where the package came from.
	Source Source
	// ArchiveSHA256 is the digest of the archive the package was extracted from.
	ArchiveSHA256 string
	// ContentDigest is the digest of the extracted package tree.
	ContentDigest string
	// Review is Core's install review for this package.
	Review Review
}

// Decision reports whether an earlier approval still covers a request.
type Decision struct {
	// Reuse reports that the stored approval covers this request, so the user
	// does not have to confirm the same programs again.
	Reuse bool
	// Reason explains a refusal to reuse. It is empty when Reuse is true, and it
	// is a stable English phrase rather than a user-facing sentence.
	Reason string
}

// Decide reports whether the stored approval covers req.
//
// record and found are what Store.Record returned. A marketplace package may
// reuse an approval only when every fact the user saw is unchanged; anything
// else falls back to asking.
func Decide(record Record, found bool, req Request) Decision {
	if req.Source == Disk {
		return Decision{Reason: "a package chosen on disk is confirmed every time"}
	}
	if !found {
		return Decision{Reason: "no earlier approval for this version"}
	}
	if record.Source == Disk {
		// An approval given for a disk package says nothing about the same
		// version arriving from an index.
		return Decision{Reason: "the earlier approval covered a package from disk"}
	}
	if record.ArchiveSHA256 != req.ArchiveSHA256 {
		return Decision{Reason: "the archive digest changed"}
	}
	if record.ContentDigest != req.ContentDigest {
		return Decision{Reason: "the package content digest changed"}
	}
	if len(req.Review.NewPrograms) != 0 {
		return Decision{Reason: "the package declares programs that were never approved"}
	}
	if !sameStrings(record.Permissions, req.Review.Permissions) {
		return Decision{Reason: "the permission set changed"}
	}
	same, err := samePrograms(record.ApprovedPrograms, req.Review.Programs)
	if err != nil {
		return Decision{Reason: "the program declarations could not be compared"}
	}
	if !same {
		return Decision{Reason: "the program declarations changed"}
	}
	return Decision{Reuse: true}
}

// RecordFor builds the record that approves req for one plugin version.
func RecordFor(id, version string, req Request) Record {
	return Record{
		PluginID:         id,
		Version:          version,
		Source:           req.Source,
		ArchiveSHA256:    req.ArchiveSHA256,
		ContentDigest:    req.ContentDigest,
		Permissions:      append([]string(nil), req.Review.Permissions...),
		ApprovedPrograms: clonePrograms(req.Review.Programs),
	}
}

// Validate reports whether a record can be stored.
func (r Record) Validate() error {
	if r.PluginID == "" {
		return fmt.Errorf("%w: the plugin ID is empty", ErrInvalidRecord)
	}
	if r.Version == "" {
		return fmt.Errorf("%w: the plugin version is empty", ErrInvalidRecord)
	}
	switch r.Source {
	case Marketplace, Disk:
	default:
		return fmt.Errorf("%w: unknown source %q", ErrInvalidRecord, r.Source)
	}
	for _, program := range r.ApprovedPrograms {
		if !json.Valid(program) {
			return fmt.Errorf("%w: an approved program is not valid JSON", ErrInvalidRecord)
		}
	}
	return nil
}

// samePrograms compares two program lists as sets of canonical JSON, so key
// order in a declaration does not count as a change.
func samePrograms(left, right []json.RawMessage) (bool, error) {
	leftKeys, err := canonicalPrograms(left)
	if err != nil {
		return false, err
	}
	rightKeys, err := canonicalPrograms(right)
	if err != nil {
		return false, err
	}
	if len(leftKeys) != len(rightKeys) {
		return false, nil
	}
	for i := range leftKeys {
		if leftKeys[i] != rightKeys[i] {
			return false, nil
		}
	}
	return true, nil
}

// canonicalPrograms returns one sorted canonical spelling per declaration.
func canonicalPrograms(programs []json.RawMessage) ([]string, error) {
	keys := make([]string, 0, len(programs))
	for _, program := range programs {
		var value any
		if err := json.Unmarshal(program, &value); err != nil {
			return nil, err
		}
		// encoding/json sorts object keys, which is what makes this canonical.
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		keys = append(keys, string(encoded))
	}
	sort.Strings(keys)
	return keys, nil
}

func clonePrograms(programs []json.RawMessage) []json.RawMessage {
	if len(programs) == 0 {
		return nil
	}
	cloned := make([]json.RawMessage, len(programs))
	for i, program := range programs {
		cloned[i] = append(json.RawMessage(nil), program...)
	}
	return cloned
}

// sameStrings compares two string lists as sets.
func sameStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	leftCopy := append([]string(nil), left...)
	rightCopy := append([]string(nil), right...)
	sort.Strings(leftCopy)
	sort.Strings(rightCopy)
	for i := range leftCopy {
		if leftCopy[i] != rightCopy[i] {
			return false
		}
	}
	return true
}
