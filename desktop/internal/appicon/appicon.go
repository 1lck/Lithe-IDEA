// Package appicon is the Lithe icon of the client's windows. A client started outside an .app
// bundle, as make run starts it, has no icon of its own, and macOS shows a generic one in the
// Dock; giving every window this icon shows Lithe's instead. A packaged client has the same
// image in its bundle.
package appicon

import (
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/assets"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/app/iconpng"
	"github.com/vivaui/viva/gfx"
)

// windowIcon decodes once because every native window uses the same image.
var windowIcon = sync.OnceValue(func() app.WindowIcon {
	icon, err := iconpng.Decode(assets.Icon)
	if err != nil {
		panic("appicon: could not decode the embedded desktop icon: " + err.Error())
	}
	return icon
})

// Window returns the decoded application icon shared by every native window.
func Window() app.WindowIcon { return windowIcon() }

// welcomeIcon is a small premultiplied BGRA copy for the welcome page. Decoding
// it once avoids keeping another full-size texture or allocating on every frame.
var welcomeIcon = sync.OnceValue(func() gfx.Bitmap {
	icon, err := iconpng.DecodeFit(assets.Icon, 64)
	if err != nil {
		panic("appicon: could not decode the embedded desktop icon: " + err.Error())
	}
	pix := make([]byte, len(icon.RGBA))
	for i := 0; i < len(pix); i += 4 {
		index := i / 4
		coverage := welcomeIconCoverage(index%icon.Size, index/icon.Size, icon.Size)
		alpha := (uint16(icon.RGBA[i+3])*coverage + 8) / 16
		pix[i] = byte((uint16(icon.RGBA[i+2])*alpha + 127) / 255)
		pix[i+1] = byte((uint16(icon.RGBA[i+1])*alpha + 127) / 255)
		pix[i+2] = byte((uint16(icon.RGBA[i])*alpha + 127) / 255)
		pix[i+3] = byte(alpha)
	}
	return gfx.Bitmap{Pix: pix, Width: icon.Size, Height: icon.Size, Stride: icon.Size * 4, ID: 0x4c6974686549636f, Version: 1}
})

// welcomeIconCoverage antialiases the 0.24-side corner radius used by the
// native welcome logo. It runs only when the retained icon is first decoded.
func welcomeIconCoverage(x, y, side int) uint16 {
	radius := float64(side) * 0.24
	var count uint16
	for sy := 0; sy < 4; sy++ {
		for sx := 0; sx < 4; sx++ {
			px := float64(x) + (float64(sx)+0.5)/4
			py := float64(y) + (float64(sy)+0.5)/4
			cx := max(radius, min(px, float64(side)-radius))
			cy := max(radius, min(py, float64(side)-radius))
			dx, dy := px-cx, py-cy
			if dx*dx+dy*dy <= radius*radius {
				count++
			}
		}
	}
	return count
}

// Welcome returns the immutable image used in the welcome sidebar.
func Welcome() gfx.Bitmap { return welcomeIcon() }
