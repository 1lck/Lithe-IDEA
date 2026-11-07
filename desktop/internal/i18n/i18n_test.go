package i18n

import (
	"reflect"
	"testing"
)

// TestCatalogsAreComplete walks every catalog and fails on an empty string or a missing
// function, so a field added to Messages cannot ship untranslated.
func TestCatalogsAreComplete(t *testing.T) {
	for _, language := range Languages {
		checkComplete(t, language.Code(), reflect.ValueOf(*For(language)))
	}
}

func checkComplete(t *testing.T, path string, value reflect.Value) {
	t.Helper()
	switch value.Kind() {
	case reflect.Struct:
		for index := range value.NumField() {
			checkComplete(t, path+"."+value.Type().Field(index).Name, value.Field(index))
		}
	case reflect.String:
		if value.String() == "" {
			t.Errorf("%s is empty", path)
		}
	case reflect.Func:
		if value.IsNil() {
			t.Errorf("%s is nil", path)
			return
		}
		args := make([]reflect.Value, value.Type().NumIn())
		for index := range args {
			switch value.Type().In(index).Kind() {
			case reflect.String:
				args[index] = reflect.ValueOf("x")
			case reflect.Int:
				args[index] = reflect.ValueOf(2)
			default:
				t.Fatalf("%s takes an unsupported parameter type", path)
			}
		}
		if out := value.Call(args); out[0].String() == "" {
			t.Errorf("%s returns an empty string", path)
		}
	default:
		t.Fatalf("%s has unsupported kind %s", path, value.Kind())
	}
}

func TestDetect(t *testing.T) {
	cases := []struct {
		preferred []string
		want      Language
	}{
		{nil, English},
		{[]string{"zh-Hans-CN", "en-US"}, Chinese},
		{[]string{"en-GB", "zh-Hans"}, English},
		{[]string{"fr-FR", "zh-Hant-TW"}, Chinese},
		{[]string{"ZH"}, Chinese},
		{[]string{"fr", "de"}, English},
	}
	for _, c := range cases {
		if got := Detect(c.preferred); got != c.want {
			t.Errorf("Detect(%v) = %v, want %v", c.preferred, got, c.want)
		}
	}
}

func TestParseRoundTrips(t *testing.T) {
	for _, language := range Languages {
		got, ok := Parse(language.Code())
		if !ok || got != language {
			t.Errorf("Parse(%q) = %v, %v", language.Code(), got, ok)
		}
	}
	if _, ok := Parse(""); ok {
		t.Error("Parse accepts an empty code")
	}
	if _, ok := Parse("fr"); ok {
		t.Error("Parse accepts an unsupported code")
	}
}
