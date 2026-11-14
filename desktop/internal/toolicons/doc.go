// Package toolicons holds the IntelliJ New UI tool window icons the tool stripes of the Lithe
// desktop client draw, compiled into gfx.Icon values by
// scripts/desktop/generate-desktop-file-icons.sh.
//
// Each icon is one filled shape in a 20 point view box with no color of its own, so the
// stripe tints it like a Lucide icon: grey at rest, the text color under the pointer and the
// primary foreground on an open window's button. icons.go is generated: do not edit it. To add
// or change an icon, put the unmodified IntelliJ SVG in svg/, record its source in NOTICE and
// run the script again.
package toolicons
