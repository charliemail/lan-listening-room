import AppKit

// Usage: make-dmg-background <out.png> <scale>
// 640x400 pt DMG window background: arrow from the app icon (160,180) to Applications (480,180) and a hint line.
// Coordinates must match the --icon / --app-drop-link positions in scripts/package.sh.
let args = CommandLine.arguments
let scale = CGFloat(Double(args[2])!)
let size = NSSize(width: 640, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Finder's y grows downward; AppKit's grows upward.
let y = size.height - 180
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 250, y: y))
arrow.line(to: NSPoint(x: 380, y: y))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
let head = NSBezierPath()
head.move(to: NSPoint(x: 368, y: y + 16))
head.line(to: NSPoint(x: 392, y: y))
head.line(to: NSPoint(x: 368, y: y - 16))
head.lineWidth = 6
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor(white: 0.55, alpha: 1).setStroke()
arrow.stroke()
head.stroke()

let text = "把左邊的 App 拖到右邊的 Applications 資料夾即可安裝" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                            .foregroundColor: NSColor(white: 0.35, alpha: 1)]
let w = text.size(withAttributes: attrs).width
text.draw(at: NSPoint(x: (size.width - w) / 2, y: 70), withAttributes: attrs)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
