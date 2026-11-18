package fileapps

import (
	"reflect"
	"testing"
)

func TestMarkDefaultMovesTheDefaultFirstAndKeepsTheShellsOrder(t *testing.T) {
	for _, tc := range []struct {
		name              string
		executable, label string
		want              []App
	}{
		{
			name:       "by executable, case folded",
			executable: `c:\program files\viewer\viewer.exe`,
			want: []App{
				{ID: `C:\Program Files\Viewer\viewer.exe`, Name: "Viewer", Default: true},
				{ID: `C:\Windows\notepad.exe`, Name: "Notepad"},
				{ID: "Microsoft.Photos", Name: "Photos"},
			},
		},
		{
			name:  "by name, for a packaged app",
			label: "Photos",
			want: []App{
				{ID: "Microsoft.Photos", Name: "Photos", Default: true},
				{ID: `C:\Windows\notepad.exe`, Name: "Notepad"},
				{ID: `C:\Program Files\Viewer\viewer.exe`, Name: "Viewer"},
			},
		},
		{
			name:       "no match leaves the list",
			executable: `C:\Other\other.exe`,
			label:      "Other",
			want: []App{
				{ID: `C:\Windows\notepad.exe`, Name: "Notepad"},
				{ID: `C:\Program Files\Viewer\viewer.exe`, Name: "Viewer"},
				{ID: "Microsoft.Photos", Name: "Photos"},
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			apps := []App{
				{ID: `C:\Windows\notepad.exe`, Name: "Notepad"},
				{ID: `C:\Program Files\Viewer\viewer.exe`, Name: "Viewer"},
				{ID: "Microsoft.Photos", Name: "Photos"},
			}
			markDefault(apps, tc.executable, tc.label)
			if !reflect.DeepEqual(apps, tc.want) {
				t.Fatalf("markDefault = %+v, want %+v", apps, tc.want)
			}
		})
	}
}
