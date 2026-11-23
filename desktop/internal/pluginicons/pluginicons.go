// Package pluginicons draws SVG icons from the marketplace and plugin packages: the
// {"path", "darkPath", "mode"} form of the contract's UI icons. Core checks the
// declaration and the shape of each path; the contract leaves decoding the bytes
// to the platform adapter, which is this package.
//
// Installed packages are read-only at runtime. Icons are read through
// pluginpkg.ReadFile, compiled to gfx.Icon values and kept in memory only: no
// cache file, rasterization or converted copy is written anywhere, so nothing
// here touches a package's bytes, its code signature or an update's baseline.
//
// SVG is compiled with Viva's iconcompile, the compiler of the host's own icons.
// It draws filled shapes in their own colors and tinted strokes; a stroke color
// is drawn in the tint. Content the compiler cannot draw is reported as
// ErrUnsupported, and so is PNG, because the icon slots of this host draw
// vectors only. Callers fall back to their own icon on any error.
package pluginicons

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/tools/iconcompile"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// Limits from the plugin contract's UI icons.
const (
	// MaxFileBytes bounds one icon resource.
	MaxFileBytes int64 = 256 << 10
	// MaxDimension bounds an icon's width and height, in image units.
	MaxDimension = 1024
	// MaxPackageBytes bounds the unique icon bytes one package may use.
	MaxPackageBytes int64 = 8 << 20
	// MaxPackagePixels bounds the image area of one package's unique icons.
	MaxPackagePixels = 4_194_304
)

const (
	// ModeTemplate icons are drawn in the tint of the control that holds them.
	ModeTemplate = "template"
	// ModeOriginal icons keep their own colors.
	ModeOriginal = "original"
)

var (
	// ErrUnreadable is an icon the package does not hold as a regular file.
	ErrUnreadable = errors.New("plugin icon is not readable from its package")
	// ErrUnsupported is an icon in a format, or using SVG this host cannot draw.
	ErrUnsupported = errors.New("plugin icon format is not supported")
	// ErrRefused is an icon the contract refuses: active or external SVG
	// content, or a resource over its size limits.
	ErrRefused = errors.New("plugin icon is refused")
)

// Reason is the log reason of an icon error.
func Reason(err error) string {
	switch {
	case errors.Is(err, ErrRefused):
		return "refused"
	case errors.Is(err, ErrUnsupported):
		return "unsupported_format"
	default:
		return "unreadable"
	}
}

// Declaration is a package icon a manifest names.
type Declaration struct {
	Path     string
	DarkPath string
	Mode     string
}

// Icon is a compiled package icon.
type Icon struct {
	light, dark gfx.Icon
}

// For is the icon for a theme: the dark variant in a dark theme when there is one.
func (icon Icon) For(dark bool) gfx.Icon {
	if dark {
		return icon.dark
	}
	return icon.light
}

// Cache holds the icons read so far, by plugin and declaration. Reads happen off
// the UI thread; lookups are cheap and safe from any goroutine.
type Cache struct {
	mu       sync.Mutex
	icons    map[key]entry
	packages map[string]*budget // by package directory
}

type key struct {
	pluginID    string
	declaration Declaration
}

// entry is one read: the package it came from, and its icon or failure.
type entry struct {
	directory string
	icon      Icon
	err       error
}

// budget is what one package's unique icon files have used.
type budget struct {
	files  map[string]bool
	bytes  int64
	pixels float64
}

// Read reads and compiles the icon the plugin installed at directory declares,
// unless it was already read from that directory. It returns only a failure of
// this read, so the caller reports each broken icon once; later reads of the
// same icon return nil and Lookup keeps answering false.
func (cache *Cache) Read(pluginID, directory string, declaration Declaration) error {
	k := key{pluginID, declaration}
	cache.mu.Lock()
	if current, ok := cache.icons[k]; ok && current.directory == directory {
		cache.mu.Unlock()
		return nil
	}
	cache.mu.Unlock()

	icon, files, err := read(directory, declaration)
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if current, ok := cache.icons[k]; ok && current.directory == directory {
		return nil // a concurrent read stored it first
	}
	if err == nil {
		err = cache.charge(directory, files)
	}
	if cache.icons == nil {
		cache.icons = map[key]entry{}
	}
	cache.icons[k] = entry{directory: directory, icon: icon, err: err}
	return err
}

// Lookup is the icon Read stored for the plugin's declaration.
func (cache *Cache) Lookup(pluginID string, declaration Declaration) (Icon, bool) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	current, ok := cache.icons[key{pluginID, declaration}]
	if !ok || current.err != nil {
		return Icon{}, false
	}
	return current.icon, true
}

// charge adds the files not yet counted to their package's budget, or refuses
// the icon when they would exceed it. The cache lock is held.
func (cache *Cache) charge(directory string, files []resource) error {
	if cache.packages == nil {
		cache.packages = map[string]*budget{}
	}
	used := cache.packages[directory]
	if used == nil {
		used = &budget{files: map[string]bool{}}
		cache.packages[directory] = used
	}
	bytes, pixels := used.bytes, used.pixels
	for _, file := range files {
		if !used.files[file.path] {
			bytes += file.bytes
			pixels += file.pixels
		}
	}
	if bytes > MaxPackageBytes {
		return fmt.Errorf("%w: the package's icons exceed %d bytes", ErrRefused, MaxPackageBytes)
	}
	if pixels > MaxPackagePixels {
		return fmt.Errorf("%w: the package's icons exceed %d pixels", ErrRefused, MaxPackagePixels)
	}
	for _, file := range files {
		used.files[file.path] = true
	}
	used.bytes, used.pixels = bytes, pixels
	return nil
}

// resource is one icon file a read used, for the package budget.
type resource struct {
	path   string
	bytes  int64
	pixels float64
}

func read(directory string, declaration Declaration) (Icon, []resource, error) {
	mode := declaration.Mode
	if mode == "" {
		mode = ModeTemplate
	}
	if mode != ModeTemplate && mode != ModeOriginal {
		return Icon{}, nil, fmt.Errorf("%w: mode %q", ErrUnsupported, declaration.Mode)
	}
	light, file, err := readResource(directory, declaration.Path, mode)
	if err != nil {
		return Icon{}, nil, err
	}
	files := []resource{file}
	dark := light
	if declaration.DarkPath != "" {
		dark, file, err = readResource(directory, declaration.DarkPath, mode)
		if err != nil {
			return Icon{}, nil, err
		}
		files = append(files, file)
	}
	return Icon{light: light, dark: dark}, files, nil
}

// readResource reads and compiles one package-relative icon file.
func readResource(directory, name, mode string) (gfx.Icon, resource, error) {
	clean, err := pluginpkg.ValidatePath(name)
	if err != nil {
		return gfx.Icon{}, resource{}, fmt.Errorf("%w: %v", ErrUnreadable, err)
	}
	switch strings.ToLower(path.Ext(clean)) {
	case ".svg":
	case ".png":
		return gfx.Icon{}, resource{}, fmt.Errorf("%w: %s: this host draws vector icons only", ErrUnsupported, clean)
	default:
		return gfx.Icon{}, resource{}, fmt.Errorf("%w: %s", ErrUnsupported, clean)
	}
	data, err := pluginpkg.ReadFile(directory, strings.Split(clean, "/"), MaxFileBytes)
	if errors.Is(err, pluginpkg.ErrReadTooLarge) {
		return gfx.Icon{}, resource{}, fmt.Errorf("%w: %s exceeds %d bytes", ErrRefused, clean, MaxFileBytes)
	}
	if err != nil {
		// Messages name the package-relative path only, never where the package
		// is installed.
		detail := "cannot be read"
		switch {
		case errors.Is(err, os.ErrNotExist):
			detail = "is missing"
		case errors.Is(err, pluginpkg.ErrNotPackageFile):
			detail = "is not a regular file without symbolic links"
		}
		return gfx.Icon{}, resource{}, fmt.Errorf("%w: %s %s", ErrUnreadable, clean, detail)
	}
	icon, err := CompileSVG(clean, data)
	if err != nil {
		return gfx.Icon{}, resource{}, err
	}
	if mode == ModeTemplate {
		if icon, err = silhouette(icon); err != nil {
			return gfx.Icon{}, resource{}, fmt.Errorf("%s: %w", clean, err)
		}
	}
	height := icon.ViewHeight
	if height == 0 {
		height = icon.ViewBox
	}
	return icon, resource{path: clean, bytes: int64(len(data)), pixels: float64(icon.ViewBox) * float64(height)}, nil
}

// CompileSVG compiles bounded, passive SVG bytes in their original fill colors.
// It runs off the UI thread and shares the package icon decoder's safety and
// dimension checks. Callers own the resulting in-memory icon; no file is written.
func CompileSVG(name string, data []byte) (gfx.Icon, error) {
	if int64(len(data)) > MaxFileBytes {
		return gfx.Icon{}, fmt.Errorf("%w: %s exceeds %d bytes", ErrRefused, name, MaxFileBytes)
	}
	paint, err := checkSVG(data)
	if err != nil {
		return gfx.Icon{}, fmt.Errorf("%s: %w", name, err)
	}
	icon, err := iconcompile.Compile(name, data)
	if err != nil {
		return gfx.Icon{}, fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	width, height := float64(icon.ViewBox), float64(icon.ViewHeight)
	if height == 0 {
		height = width
	}
	if width > MaxDimension || height > MaxDimension || paint.width > MaxDimension || paint.height > MaxDimension {
		return gfx.Icon{}, fmt.Errorf("%w: %s is larger than %d×%d", ErrRefused, name, MaxDimension, MaxDimension)
	}
	if !paint.stroked {
		// SVG fills a shape that names no paint; the compiler's icon dialect
		// strokes it unless told otherwise. A document that strokes nothing
		// therefore fills its tinted shapes, as SVG draws them.
		icon.Stroke = 0
	}
	return icon, nil
}

// silhouette is a template icon: every shape drawn in the tint. Colored fills
// become tinted fills; the shapes must then share one way of being drawn.
func silhouette(icon gfx.Icon) (gfx.Icon, error) {
	if len(icon.Layers) == 0 {
		return icon, nil
	}
	if len(icon.Commands) > 0 && icon.Stroke > 0 {
		return gfx.Icon{}, fmt.Errorf("%w: a template icon mixes stroked and filled shapes", ErrUnsupported)
	}
	for _, layer := range icon.Layers {
		if layer.FillRule == gfx.PathFillEvenOdd {
			return gfx.Icon{}, fmt.Errorf("%w: a template icon fills with the evenodd rule", ErrUnsupported)
		}
		icon.Commands = append(icon.Commands, layer.Commands...)
	}
	icon.Stroke, icon.Layers = 0, nil
	return icon, nil
}

// svgPaint is what the safety pass learned about a document.
type svgPaint struct {
	// stroked says some element names a stroke paint.
	stroked bool
	// width and height are the root's sizes in user units, 0 when unset.
	width, height float64
}

// refusedElements are SVG elements the contract refuses: scripts, styles,
// embedded or linked content, and animation.
var refusedElements = map[string]bool{
	"script": true, "style": true, "image": true, "foreignObject": true,
	"iframe": true, "a": true, "feImage": true, "animate": true,
	"animateMotion": true, "animateTransform": true, "animateColor": true,
	"set": true, "audio": true, "video": true, "canvas": true,
}

// checkSVG refuses the SVG content the contract does not accept: DOCTYPEs and
// entities, processing instructions, scripts and event handlers, style elements
// and attributes, embedded images and references outside the document.
func checkSVG(data []byte) (svgPaint, error) {
	var paint svgPaint
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = true
	root := true
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return paint, nil
		}
		if err != nil {
			return paint, fmt.Errorf("%w: %v", ErrRefused, err)
		}
		switch token := token.(type) {
		case xml.Directive:
			return paint, fmt.Errorf("%w: DOCTYPEs and entities are not allowed", ErrRefused)
		case xml.ProcInst:
			if token.Target != "xml" {
				return paint, fmt.Errorf("%w: processing instruction %q", ErrRefused, token.Target)
			}
		case xml.StartElement:
			if refusedElements[token.Name.Local] {
				return paint, fmt.Errorf("%w: <%s> is not allowed", ErrRefused, token.Name.Local)
			}
			for _, attribute := range token.Attr {
				if err := checkAttribute(attribute); err != nil {
					return paint, err
				}
				if attribute.Name.Local == "stroke" {
					if value := strings.TrimSpace(attribute.Value); value != "" && value != "none" {
						paint.stroked = true
					}
				}
				if root && (attribute.Name.Local == "width" || attribute.Name.Local == "height") {
					size, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(attribute.Value), "px"), 64)
					if attribute.Name.Local == "width" {
						paint.width = size
					} else {
						paint.height = size
					}
				}
			}
			root = false
		}
	}
}

func checkAttribute(attribute xml.Attr) error {
	name := attribute.Name.Local
	value := strings.TrimSpace(attribute.Value)
	switch {
	case strings.HasPrefix(strings.ToLower(name), "on"):
		return fmt.Errorf("%w: event handler %q", ErrRefused, name)
	case name == "style":
		return fmt.Errorf("%w: style attributes are not allowed; use presentation attributes", ErrRefused)
	case name == "href" && !strings.HasPrefix(value, "#"):
		return fmt.Errorf("%w: reference %q is outside the document", ErrRefused, value)
	}
	for rest := value; ; {
		index := strings.Index(strings.ToLower(rest), "url(")
		if index < 0 {
			return nil
		}
		rest = strings.TrimSpace(rest[index+len("url("):])
		rest = strings.TrimLeft(rest, `"'`)
		if !strings.HasPrefix(rest, "#") {
			return fmt.Errorf("%w: reference in %q is outside the document", ErrRefused, name)
		}
	}
}
