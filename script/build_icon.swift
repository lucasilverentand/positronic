import AppKit
import SwiftUI
import ImageIO

@MainActor
func buildIcon() throws {

// Normalize AI artwork into the monolithic macOS icon geometry measured from
// Calculator, Notes and Contacts: 824 px artwork, 100 px margins, 1024 px canvas.
let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Usage: swift build_icon.swift artwork.png AppIcon.png")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
// Find the solid tile, ignoring scattered alpha/fringe pixels outside its edge.
let sampleX = (width / 4)..<(width * 3 / 4)
let sampleY = (height / 4)..<(height * 3 / 4)
let columns = (0..<width).filter { x in sampleY.filter { pixels[$0 * width * 4 + x * 4 + 3] >= 240 }.count > sampleY.count * 9 / 10 }
let rows = (0..<height).filter { y in sampleX.filter { pixels[y * width * 4 + $0 * 4 + 3] >= 240 }.count > sampleX.count * 9 / 10 }
guard let left = columns.first, let right = columns.last, let bottom = rows.first, let top = rows.last else { fatalError("No solid icon tile found.") }
// Pixel sampling above is bottom-up; CGImage cropping uses the top-left origin.
let sourceRect = CGRect(x: left, y: height - 1 - top, width: right - left + 1, height: top - bottom + 1)
guard let cropped = image.cropping(to: sourceRect) else { fatalError("Invalid artwork crop.") }
let artwork = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
let tile = ZStack {
    LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.65, green: 0.67, blue: 0.96)], startPoint: .top, endPoint: .bottom)
    Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
}
.frame(width: 824, height: 824)
.clipped()
.clipShape(RoundedRectangle(cornerRadius: 185.4, style: .continuous))
.overlay {
    // A narrow lighting edge, rather than a gray frame around the artwork.
    RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        .strokeBorder(LinearGradient(stops: [
            .init(color: .white.opacity(0.52), location: 0),
            .init(color: .white.opacity(0.12), location: 0.45),
            .init(color: .black.opacity(0.16), location: 1)
        ], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
}
// Keep the native 824 px tile footprint; cast its shadow into the clear margin.
.shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 9)
.shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
.padding(100)
.frame(width: 1024, height: 1024)
let renderer = ImageRenderer(content: tile)
renderer.scale = 1
renderer.proposedSize = ProposedViewSize(width: 1024, height: 1024)
guard let result = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { fatalError("Could not render icon.") }
try png.write(to: URL(fileURLWithPath: arguments[2]))
print("Source tile: \(sourceRect); output: 1024 canvas / 824 artwork / 100 margin")

}
try MainActor.assumeIsolated { try buildIcon() }
