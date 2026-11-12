package plugintrust

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// approvedRequest is a marketplace request with one program and one permission.
func approvedRequest() Request {
	return Request{
		Source:        Marketplace,
		ArchiveSHA256: "aa11",
		ContentDigest: "bb22",
		Review: Review{
			Permissions: []string{"workspace.read"},
			Programs:    []json.RawMessage{json.RawMessage(`{"kind":"runtime","command":"java"}`)},
		},
	}
}

// storedRecord is the record an approval of approvedRequest would store.
func storedRecord() Record {
	return RecordFor("io.github.lithe-idea.java-support", "1.0.0", approvedRequest())
}

func TestDecideReusesUnchangedMarketplaceApproval(t *testing.T) {
	decision := Decide(storedRecord(), true, approvedRequest())
	if !decision.Reuse {
		t.Fatalf("decision = %+v", decision)
	}
	if decision.Reason != "" {
		t.Fatalf("reason = %q", decision.Reason)
	}
}

func TestDecideRefusesEveryChange(t *testing.T) {
	cases := map[string]func(*Request){
		"disk source": func(req *Request) {
			req.Source = Disk
		},
		"archive digest": func(req *Request) {
			req.ArchiveSHA256 = "cc33"
		},
		"content digest": func(req *Request) {
			req.ContentDigest = "dd44"
		},
		"new programs": func(req *Request) {
			req.Review.NewPrograms = []json.RawMessage{json.RawMessage(`{"kind":"run"}`)}
		},
		"extra permission": func(req *Request) {
			req.Review.Permissions = []string{"workspace.read", "workspace.write"}
		},
		"changed program": func(req *Request) {
			req.Review.Programs = []json.RawMessage{json.RawMessage(`{"kind":"runtime","command":"javaw"}`)}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			req := approvedRequest()
			mutate(&req)
			decision := Decide(storedRecord(), true, req)
			if decision.Reuse {
				t.Fatalf("decision reused an approval: %+v", decision)
			}
			if decision.Reason == "" {
				t.Fatal("a refusal has no reason")
			}
		})
	}
}

func TestDecideRefusesMissingRecord(t *testing.T) {
	decision := Decide(Record{}, false, approvedRequest())
	if decision.Reuse || decision.Reason == "" {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestDecideRefusesApprovalGivenForDisk(t *testing.T) {
	disk := approvedRequest()
	disk.Source = Disk
	record := RecordFor("io.github.lithe-idea.java-support", "1.0.0", disk)
	decision := Decide(record, true, approvedRequest())
	if decision.Reuse {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestDecideIgnoresProgramKeyOrder(t *testing.T) {
	record := storedRecord()
	record.ApprovedPrograms = []json.RawMessage{json.RawMessage(`{"kind":"runtime","command":"java"}`)}
	req := approvedRequest()
	req.Review.Programs = []json.RawMessage{json.RawMessage(`{"command":"java","kind":"runtime"}`)}
	if decision := Decide(record, true, req); !decision.Reuse {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestDecideIgnoresPermissionOrder(t *testing.T) {
	record := storedRecord()
	record.Permissions = []string{"workspace.read", "terminal.exec"}
	req := approvedRequest()
	req.Review.Permissions = []string{"terminal.exec", "workspace.read"}
	if decision := Decide(record, true, req); !decision.Reuse {
		t.Fatalf("decision = %+v", decision)
	}
}

func TestRecordForCopiesTheRequest(t *testing.T) {
	req := approvedRequest()
	record := RecordFor("example", "1.0.0", req)
	req.Review.Permissions[0] = "changed"
	req.Review.Programs[0][0] = 'x'
	if record.Permissions[0] != "workspace.read" {
		t.Fatalf("permissions = %v", record.Permissions)
	}
	if string(record.ApprovedPrograms[0]) != `{"kind":"runtime","command":"java"}` {
		t.Fatalf("programs = %s", record.ApprovedPrograms[0])
	}
}

func TestRecordValidate(t *testing.T) {
	valid := storedRecord()
	if err := valid.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	cases := map[string]func(*Record){
		"empty ID":      func(r *Record) { r.PluginID = "" },
		"empty version": func(r *Record) { r.Version = "" },
		"unknown source": func(r *Record) {
			r.Source = "network"
		},
		"broken program": func(r *Record) {
			r.ApprovedPrograms = []json.RawMessage{json.RawMessage(`{`)}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			record := storedRecord()
			mutate(&record)
			if err := record.Validate(); !errors.Is(err, ErrInvalidRecord) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestStoreRoundTrip(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	record := storedRecord()
	if err := approvals.Approve(record); err != nil {
		t.Fatalf("approve: %v", err)
	}
	loaded, found, err := approvals.Record(record.PluginID, record.Version)
	if err != nil || !found {
		t.Fatalf("record: %v, found = %v", err, found)
	}
	if loaded.ArchiveSHA256 != record.ArchiveSHA256 || loaded.ContentDigest != record.ContentDigest {
		t.Fatalf("loaded = %+v", loaded)
	}
	if !Decide(loaded, found, approvedRequest()).Reuse {
		t.Fatal("a reloaded approval no longer covers its own request")
	}
}

func TestStoreRecordMissingFile(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	if _, found, err := approvals.Record("example", "1.0.0"); err != nil || found {
		t.Fatalf("found = %v, err = %v", found, err)
	}
	records, err := approvals.List()
	if err != nil || len(records) != 0 {
		t.Fatalf("records = %+v, err = %v", records, err)
	}
}

func TestStoreApproveReplacesEarlierApproval(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	if err := approvals.Approve(storedRecord()); err != nil {
		t.Fatal(err)
	}
	updated := storedRecord()
	updated.ContentDigest = "ee55"
	if err := approvals.Approve(updated); err != nil {
		t.Fatal(err)
	}
	loaded, found, err := approvals.Record(updated.PluginID, updated.Version)
	if err != nil || !found {
		t.Fatalf("record: %v, found = %v", err, found)
	}
	if loaded.ContentDigest != "ee55" {
		t.Fatalf("loaded = %+v", loaded)
	}
}

func TestStoreForget(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	if err := approvals.Approve(storedRecord()); err != nil {
		t.Fatal(err)
	}
	if err := approvals.Forget("io.github.lithe-idea.java-support", "1.0.0"); err != nil {
		t.Fatalf("forget: %v", err)
	}
	if _, found, err := approvals.Record("io.github.lithe-idea.java-support", "1.0.0"); err != nil || found {
		t.Fatalf("found = %v, err = %v", found, err)
	}
	// Forgetting a version that was never approved is not an error.
	if err := approvals.Forget("absent", "0.0.0"); err != nil {
		t.Fatalf("forget absent: %v", err)
	}
}

func TestStoreRefusesInvalidRecord(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	record := storedRecord()
	record.PluginID = ""
	if err := approvals.Approve(record); !errors.Is(err, ErrInvalidRecord) {
		t.Fatalf("err = %v", err)
	}
}

func TestStoreListIsSorted(t *testing.T) {
	approvals := New(store.At(t.TempDir()))
	for _, item := range []struct{ id, version string }{
		{"zeta", "2.0.0"},
		{"alpha", "1.1.0"},
		{"alpha", "1.0.0"},
	} {
		record := storedRecord()
		record.PluginID = item.id
		record.Version = item.version
		if err := approvals.Approve(record); err != nil {
			t.Fatal(err)
		}
	}
	records, err := approvals.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	want := []string{"alpha 1.0.0", "alpha 1.1.0", "zeta 2.0.0"}
	if len(records) != len(want) {
		t.Fatalf("records = %+v", records)
	}
	for i, record := range records {
		if record.PluginID+" "+record.Version != want[i] {
			t.Fatalf("record %d = %q %q", i, record.PluginID, record.Version)
		}
	}
}
