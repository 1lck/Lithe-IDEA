package configfile

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestNativeConfigPublicationPreservesWindowsSecurity(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "settings.json")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	setWindowsConfigDACL(t, path, "A;;FA")
	assertWindowsConfigReplacement(t, root, path)
}

func TestNativeConfigPublicationWithWindowsModifyAccess(t *testing.T) {
	root := t.TempDir()
	// Inherit Modify access for files, without granting WRITE_OWNER.
	setWindowsConfigDACL(t, root, "A;OICI;0x1301bf")
	path := filepath.Join(root, "settings.json")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertWindowsConfigReplacement(t, root, path)
}

func setWindowsConfigDACL(t *testing.T, path, accessRule string) {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := windows.SecurityDescriptorFromString("D:P(" + accessRule + ";;;" + user.User.Sid.String() + ")")
	if err != nil {
		t.Fatal(err)
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil); err != nil {
		t.Fatal(err)
	}
}

func assertWindowsConfigReplacement(t *testing.T, root, path string) {
	t.Helper()
	security := func() string {
		t.Helper()
		value, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.GROUP_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		return value.String()
	}
	before := security()
	snapshot, err := Capture(t.Context(), root, "settings.json", 4096)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := snapshot.Replace(t.Context(), []byte("changed"), nil); err != nil {
		t.Fatal(err)
	}
	if after := security(); after != before {
		t.Fatalf("security changed: before %s, after %s", before, after)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "changed" {
		t.Fatalf("unexpected content: %q", content)
	}
	assertNoTemporaryFiles(t, root)
}
