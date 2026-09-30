import AppKit
let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let src = URL(fileURLWithPath: args[1])
let outBase = args[2]
guard let image = NSImage(contentsOf: src) else {
    FileHandle.standardError.write(Data("NSImage could not load \(src.lastPathComponent)\n".utf8)); exit(1)
}
for (suffix, size) in [("", 144), ("@2x", 288)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outBase)\(suffix).png"))
}
