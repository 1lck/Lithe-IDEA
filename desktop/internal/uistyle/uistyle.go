// Package uistyle holds the few shared metrics the client's windows paint with, so one
// number describes the same surface everywhere instead of each window choosing its own.
package uistyle

import "github.com/vivaui/viva/components"

// Bars is the geometry every scrollbar of the client draws with: IDEA's eleven point track
// with a five point thumb, a one point gap from the track's edge, and a twenty point least
// thumb. A window hands it to ui.PageConfig.BarStyle, so its lists, trees and areas agree
// without each one asking for it.
var Bars = components.ScrollBarStyle{Size: 11, HoverSize: 5, Inset: 1, MinThumb: 20}
