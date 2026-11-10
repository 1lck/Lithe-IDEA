package core

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestFileEncodingSharedFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/editor/file-encoding-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name                 string
			Encoding             string
			Text                 string
			BytesHex             string
			HasBom               bool
			AutoDetectedEncoding *string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			want, err := hex.DecodeString(c.BytesHex)
			if err != nil {
				t.Fatal(err)
			}
			encoded, err := client.EncodeFileText(testContext(t), c.Text, c.Encoding, nil)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(encoded.Bytes, want) || encoded.Encoding != c.Encoding || encoded.HasBOM != c.HasBom {
				t.Fatalf("encoded = %x %s %v, want %x", encoded.Bytes, encoded.Encoding, encoded.HasBOM, want)
			}
			decoded, err := client.DecodeFileBytes(testContext(t), want, c.Encoding)
			if err != nil {
				t.Fatal(err)
			}
			if decoded.Text != c.Text || decoded.HasBOM != c.HasBom || decoded.Lossy {
				t.Fatalf("decoded = %+v", decoded)
			}
			if c.AutoDetectedEncoding != nil {
				detected, err := client.DecodeFileBytes(testContext(t), want, "")
				if err != nil {
					t.Fatal(err)
				}
				if detected.Encoding != *c.AutoDetectedEncoding || detected.Text != c.Text {
					t.Fatalf("detected = %+v, want %s", detected, *c.AutoDetectedEncoding)
				}
			}
		})
	}
}

func TestEncodeFileTextReportsUnmappableCharacter(t *testing.T) {
	_, err := NewClient().EncodeFileText(testContext(t), "A😀", "gbk", nil)
	details, ok := IsEncodingUnmappable(err)
	if !ok || details == "" {
		t.Fatalf("err = %v, details = %q", err, details)
	}
}
