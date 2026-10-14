import AppKit
import Foundation
import ImageIO

let size = NSSize(width: 256, height: 256)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(
  roundedRect: NSRect(x: 8, y: 8, width: 240, height: 240),
  xRadius: 54,
  yRadius: 54
)
NSGradient(
  starting: NSColor(calibratedRed: 0.11, green: 0.52, blue: 0.98, alpha: 1),
  ending: NSColor(calibratedRed: 0.18, green: 0.26, blue: 0.86, alpha: 1)
)!.draw(in: background, angle: -55)

NSColor.white.withAlphaComponent(0.98).setStroke()
let display = NSBezierPath(
  roundedRect: NSRect(x: 49, y: 67, width: 158, height: 121),
  xRadius: 19,
  yRadius: 19
)
display.lineWidth = 13
display.stroke()

let stand = NSBezierPath()
stand.move(to: NSPoint(x: 128, y: 67))
stand.line(to: NSPoint(x: 128, y: 45))
stand.move(to: NSPoint(x: 96, y: 44))
stand.line(to: NSPoint(x: 160, y: 44))
stand.lineCapStyle = .round
stand.lineWidth = 13
stand.stroke()

let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 100, y: 174))
cursor.line(to: NSPoint(x: 112, y: 105))
cursor.line(to: NSPoint(x: 128, y: 126))
cursor.line(to: NSPoint(x: 154, y: 100))
cursor.line(to: NSPoint(x: 166, y: 112))
cursor.line(to: NSPoint(x: 140, y: 138))
cursor.line(to: NSPoint(x: 161, y: 154))
cursor.close()
NSColor.white.setFill()
cursor.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiff),
  let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.9]),
  let source = CGImageSourceCreateWithData(png as CFData, nil),
  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
    source,
    0,
    [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 128,
    ] as CFDictionary
  ),
  let finalPNG = NSBitmapImageRep(cgImage: thumbnail).representation(
    using: .png,
    properties: [.compressionFactor: 0.9]
  )
else {
  fatalError("Could not render Computer Use icon")
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
  at: output.deletingLastPathComponent(),
  withIntermediateDirectories: true
)
try finalPNG.write(to: output, options: .atomic)
