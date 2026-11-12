// Package assets holds the files the desktop client embeds from desktop/assets.
package assets

import _ "embed"

// Icon is the image also referenced by icon in viva.toml. Viva uses it to create
// the packaged .icns file, while a running executable uses it for its window icon
// when it is outside an .app bundle.
//
//go:embed icon.png
var Icon []byte
