import AppKit
// Curtain's app icon: a velvet stage curtain drawn back from a strip of menu bar.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS icon grid: 824pt body inside 1024, centred, corner radius ~185
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let clip = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
// soft drop shadow under the body
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.14, alpha: 1).setFill(); clip.fill()
NSGraphicsContext.restoreGraphicsState()
clip.addClip()
// backdrop: deep stage, lit from the centre
NSGradient(colors: [NSColor(calibratedRed: 0.30, green: 0.24, blue: 0.40, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.12, alpha: 1)])!
    .draw(in: NSBezierPath(rect: body), relativeCenterPosition: NSPoint(x: 0, y: 0.1))
// the menu bar strip revealed between the drapes
let barY: CGFloat = 560
let bar = NSBezierPath(roundedRect: CGRect(x: 330, y: barY, width: 364, height: 84), xRadius: 22, yRadius: 22)
NSColor(calibratedWhite: 0.97, alpha: 0.95).setFill(); bar.fill()
let dotColors: [NSColor] = [.systemTeal, .systemYellow, .systemPink]
for (i, c) in dotColors.enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: CGRect(x: 400 + CGFloat(i) * 84, y: barY + 22, width: 40, height: 40)).fill()
}
// one drape; mirrored for the other side
func drape(left: Bool) {
    let top: CGFloat = 820, bottom: CGFloat = 100
    let outer: CGFloat = left ? 100 : 924
    let innerTop: CGFloat = left ? 470 : 554        // where the drape meets the rod
    let waist: CGFloat = left ? 250 : 774           // gathered by the tie-back
    let hem: CGFloat = left ? 330 : 694
    let p = NSBezierPath()
    p.move(to: NSPoint(x: outer, y: top))
    p.line(to: NSPoint(x: innerTop, y: top))
    p.curve(to: NSPoint(x: waist, y: 420), controlPoint1: NSPoint(x: innerTop, y: 640), controlPoint2: NSPoint(x: waist + (left ? 40 : -40), y: 480))
    p.curve(to: NSPoint(x: hem, y: bottom), controlPoint1: NSPoint(x: waist - (left ? 10 : -10), y: 330), controlPoint2: NSPoint(x: hem, y: 200))
    p.line(to: NSPoint(x: outer, y: bottom))
    p.close()
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.04, blue: 0.10, alpha: 1),
                        NSColor(calibratedRed: 0.86, green: 0.14, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.60, green: 0.05, blue: 0.12, alpha: 1)])!
        .draw(in: p.bounds, angle: left ? 0 : 180)
    // folds: soft dark and light vertical bands
    for k in 0..<5 {
        let fx = left ? outer + CGFloat(k) * 70 + 20 : outer - CGFloat(k) * 70 - 50
        let fold = NSBezierPath(rect: CGRect(x: fx, y: bottom, width: 30, height: top - bottom))
        NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)])!
            .draw(in: fold, angle: 0)
        let hi = NSBezierPath(rect: CGRect(x: fx + 32, y: bottom, width: 18, height: top - bottom))
        NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(in: hi, angle: 0)
    }
    NSGraphicsContext.restoreGraphicsState()
    // gold tie-back
    let tie = NSBezierPath(roundedRect: CGRect(x: (left ? 100 : waist - 30), y: 395, width: (left ? waist + 30 - 100 : 924 - waist + 30), height: 34), xRadius: 17, yRadius: 17)
    NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.83, blue: 0.42, alpha: 1), NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.16, alpha: 1)])!.draw(in: tie, angle: -90)
}
drape(left: true); drape(left: false)
// valance across the top
let val = NSBezierPath()
val.move(to: NSPoint(x: 100, y: 924)); val.line(to: NSPoint(x: 924, y: 924)); val.line(to: NSPoint(x: 924, y: 800))
for i in stride(from: 4, through: 0, by: -1) {
    let x0 = 100 + CGFloat(i) * 164.8
    val.curve(to: NSPoint(x: x0, y: 800), controlPoint1: NSPoint(x: x0 + 140, y: 740), controlPoint2: NSPoint(x: x0 + 25, y: 740))
}
val.close()
NSGradient(colors: [NSColor(calibratedRed: 0.72, green: 0.08, blue: 0.14, alpha: 1), NSColor(calibratedRed: 0.45, green: 0.03, blue: 0.08, alpha: 1)])!.draw(in: val, angle: -90)
let rod = NSBezierPath(rect: CGRect(x: 100, y: 890, width: 824, height: 14))
NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.83, blue: 0.42, alpha: 1), NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.16, alpha: 1)])!.draw(in: rod, angle: -90)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
