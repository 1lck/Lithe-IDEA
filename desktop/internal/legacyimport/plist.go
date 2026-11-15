package legacyimport

import (
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// maxPlistDepth bounds the nesting a preference document may have; the earlier client
// stores flat keys whose values are at most a few levels deep.
const maxPlistDepth = 32

// parsePlist decodes an XML property list, as `defaults export` writes it, into Go
// values: map[string]any for dict, []any for array, string, int64, float64, bool and
// []byte for data. A date is kept as its text, since nothing imported reads one.
func parsePlist(r io.Reader) (map[string]any, error) {
	decoder := xml.NewDecoder(r)
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("property list: %w", err)
		}
		start, ok := token.(xml.StartElement)
		if !ok || start.Name.Local == "plist" {
			continue
		}
		value, err := plistValue(decoder, start, 0)
		if err != nil {
			return nil, err
		}
		root, ok := value.(map[string]any)
		if !ok {
			return nil, errors.New("property list: the root is not a dictionary")
		}
		return root, nil
	}
}

func plistValue(decoder *xml.Decoder, start xml.StartElement, depth int) (any, error) {
	if depth > maxPlistDepth {
		return nil, errors.New("property list: nested too deeply")
	}
	switch start.Name.Local {
	case "dict":
		values := map[string]any{}
		key, hasKey := "", false
		for {
			token, err := decoder.Token()
			if err != nil {
				return nil, fmt.Errorf("property list: %w", err)
			}
			switch t := token.(type) {
			case xml.StartElement:
				if t.Name.Local == "key" {
					text, err := plistText(decoder)
					if err != nil {
						return nil, err
					}
					key, hasKey = text, true
					continue
				}
				if !hasKey {
					return nil, errors.New("property list: a dictionary value has no key")
				}
				value, err := plistValue(decoder, t, depth+1)
				if err != nil {
					return nil, err
				}
				values[key], hasKey = value, false
			case xml.EndElement:
				return values, nil
			}
		}
	case "array":
		values := []any{}
		for {
			token, err := decoder.Token()
			if err != nil {
				return nil, fmt.Errorf("property list: %w", err)
			}
			switch t := token.(type) {
			case xml.StartElement:
				value, err := plistValue(decoder, t, depth+1)
				if err != nil {
					return nil, err
				}
				values = append(values, value)
			case xml.EndElement:
				return values, nil
			}
		}
	case "true", "false":
		if err := decoder.Skip(); err != nil {
			return nil, fmt.Errorf("property list: %w", err)
		}
		return start.Name.Local == "true", nil
	}
	text, err := plistText(decoder)
	if err != nil {
		return nil, err
	}
	switch start.Name.Local {
	case "string", "date":
		return text, nil
	case "integer":
		return strconv.ParseInt(strings.TrimSpace(text), 10, 64)
	case "real":
		return strconv.ParseFloat(strings.TrimSpace(text), 64)
	case "data":
		return base64.StdEncoding.DecodeString(strings.Join(strings.Fields(text), ""))
	}
	return nil, fmt.Errorf("property list: unknown element %q", start.Name.Local)
}

// plistText is the character data up to the end of the element just opened.
func plistText(decoder *xml.Decoder) (string, error) {
	var text strings.Builder
	for {
		token, err := decoder.Token()
		if err != nil {
			return "", fmt.Errorf("property list: %w", err)
		}
		switch t := token.(type) {
		case xml.CharData:
			text.Write(t)
		case xml.EndElement:
			return text.String(), nil
		case xml.StartElement:
			return "", fmt.Errorf("property list: unexpected element %q in text", t.Name.Local)
		}
	}
}
