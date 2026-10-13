import AppKit
import Testing

/// Fix the drawing destination before capture. A display-dependent native
/// bitmap can contain Display P3 samples under a Generic RGB tag; converting
/// that tag afterwards does not recover the source palette values.
@MainActor
func nativeSRGBCapture(_ view: NSView, scale: CGFloat = 2) throws -> NSBitmapImageRep {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: Int(ceil(view.bounds.width * scale)),
        height: Int(ceil(view.bounds.height * scale)),
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

/// colorAt wraps raw channels in a calibrated color. Decode those channels
/// using the bitmap's actual profile before comparing sRGB palette values.
@MainActor
func nativeSRGBPixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
    let pixel = try #require(bitmap.colorAt(x: x, y: y))
    return try #require(NSColor(colorSpace: bitmap.colorSpace,
        components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
        count: 4).usingColorSpace(.sRGB))
}
