package term

// cubeLevels are the six intensities of each channel in the 6x6x6 color cube.
var cubeLevels = [6]uint8{0, 95, 135, 175, 215, 255}

// Resolve returns the RGB of palette index i: the first sixteen come from
// ansi, 16-231 are the color cube and 232-255 the grayscale ramp.
func Resolve(index uint8, ansi *[16][3]uint8) (red, green, blue uint8) {
	switch {
	case index < 16:
		c := ansi[index]
		return c[0], c[1], c[2]
	case index < 232:
		i := int(index) - 16
		return cubeLevels[i/36], cubeLevels[(i/6)%6], cubeLevels[i%6]
	default:
		level := uint8(8 + 10*(int(index)-232))
		return level, level, level
	}
}
