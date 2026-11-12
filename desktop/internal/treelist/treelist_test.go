package treelist

import "testing"

func TestGeometry(t *testing.T) {
	if got, want := Width(0, 100), float32(2*Gutter+Disclosure+Gap+100+Trailing); got != want {
		t.Fatalf("Width(0, 100) = %v, want %v", got, want)
	}
	if got, want := Width(2, 100)-Width(0, 100), float32(2*Indent); got != want {
		t.Fatalf("two levels add %v, want %v", got, want)
	}
}
