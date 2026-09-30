import AppKit
// Tiles every 144px PNG in a folder onto a dark sheet for a quick visual check.
let dir = CommandLine.arguments[1], out = CommandLine.arguments[2]
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") && !$0.contains("@2x") }.sorted()
let cols = 4, cell = 160, rows = (files.count + cols - 1) / cols
let img = NSImage(size: NSSize(width: cols * cell, height: rows * cell))
img.lockFocus()
NSColor.black.setFill(); NSRect(x: 0, y: 0, width: cols * cell, height: rows * cell).fill()
for (i, f) in files.enumerated() {
    let x = (i % cols) * cell, y = (rows - 1 - i / cols) * cell
    NSImage(contentsOfFile: "\(dir)/\(f)")!.draw(in: NSRect(x: x + 8, y: y + 20, width: 136, height: 136))
    (f.replacingOccurrences(of: ".png", with: "") as NSString).draw(at: NSPoint(x: x + 8, y: y + 2), withAttributes: [.foregroundColor: NSColor.lightGray, .font: NSFont.systemFont(ofSize: 11)])
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
