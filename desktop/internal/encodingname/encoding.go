// Package encodingname supplies presentation names shared by the file and console encoding selectors.
package encodingname

// labels are the names shown for Core's encoding ids; they are the encodings' own
// names, not translations.
var labels = map[string]string{
	"utf-8": "UTF-8", "utf-8-bom": "UTF-8 BOM", "utf-16le-bom": "UTF-16 LE BOM", "utf-16be-bom": "UTF-16 BE BOM",
	"utf-16le": "UTF-16 LE", "utf-16be": "UTF-16 BE", "gbk": "GBK", "gb18030": "GB18030", "big5": "Big5",
	"shift-jis": "Shift JIS", "euc-jp": "EUC-JP", "euc-kr": "EUC-KR", "windows-874": "Windows-874",
	"windows-1250": "Windows-1250", "windows-1251": "Windows-1251", "windows-1252": "Windows-1252",
	"windows-1253": "Windows-1253", "windows-1254": "Windows-1254", "windows-1255": "Windows-1255",
	"windows-1256": "Windows-1256", "windows-1257": "Windows-1257", "windows-1258": "Windows-1258",
	"koi8-r": "KOI8-R",
}

// DisplayName returns the display name of a Core encoding ID, preserving unknown IDs.
func DisplayName(id string) string {
	if label, ok := labels[id]; ok {
		return label
	}
	return id
}
