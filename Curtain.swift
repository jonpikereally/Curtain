import AppKit
import SwiftUI
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

// Curtain: a menu bar hider.
//
// The mechanism is one divider status item. Its width is normally 10,000 points, which pushes every
// item to its left off the bar. Nothing decides what to hide; whatever sits left of the divider is
// hidden, whatever sits right of it stays. The item list comes from the Accessibility API, an item is
// moved with a synthetic cmd-drag (the same gesture as by hand, with the cursor hidden and put back),
// and the popout renders hidden items from ScreenCaptureKit captures when Screen Recording is granted,
// falling back to the owning app's icon when it is not.

let debugLog = UserDefaults.standard.bool(forKey: "DebugLog")
func log(_ s: String) {
    guard debugLog else { return }
    let line = "\(Date()) \(s)\n"
    // Not ~/Documents: that is TCC-protected, and a background app with no way to show the prompt has
    // its writes denied in silence. The log going quiet is exactly when it is needed most.
    let path = NSString(string: "~/Library/Logs/Curtain.log").expandingTildeInPath
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

// MARK: - Menu bar items

struct BarItem: Identifiable {
    let app: String
    let detail: String
    let pid: pid_t
    let element: AXUIElement
    var frame: CGRect            // AX coordinates: top-left origin, in points
    var windowID: CGWindowID?
    var hostPid: pid_t = 0       // the process that owns the window, which is Control Center, not the app
    var onScreen: Bool = false   // whether its window is currently on the visible bar
    var key: String              // what settings remember: the app name, or Control Center's module identifier

    var id: String { key }
    var label: String {
        if app == "Control Center" { return detail.split(separator: ",").first.map(String.init) ?? key }
        return detail.isEmpty || detail == "-" ? app : "\(app) \u{2013} \(detail)"
    }
    var midX: CGFloat { frame.midX }
}

enum Bar {
    static let ownName = "Curtain"
    /// Processes never listed, and the two Control Center modules pinned to the right end.
    static let skippedApps: Set<String> = ["SystemUIServer", "Clock"]
    static let pinnedModules: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]

    /// Every third-party menu bar item, sorted left to right. Off the main thread only.
    static func scan(onlyPids: Set<pid_t>? = nil) -> [BarItem] {
        // Each app is a separate round trip to a separate process, so asking them one at a time costs
        // the SUM of every app's answer: forty apps against a 1s timeout is a forty-second scan, and a
        // scan that slow is indistinguishable from a freeze. Asked all at once it costs the slowest one.
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            if let onlyPids, !onlyPids.contains(app.processIdentifier) { return false }
            guard let name = app.localizedName, !skippedApps.contains(name), name != ownName else { return false }
            return true
        }
        var buckets = [[BarItem]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = itemsIn(apps[i])
            lock.lock(); buckets[i] = found; lock.unlock()
        }
        var out = buckets.flatMap { $0 }
        return finish(&out)
    }

    /// One app's menu bar extras. Called concurrently, one thread per app, so it touches nothing shared.
    private static func itemsIn(_ app: NSRunningApplication) -> [BarItem] {
        var out: [BarItem] = []
        let name = app.localizedName ?? ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // A timeout set on one element does NOT reach elements copied out of it, so the menu bar and
        // its children below are given their own, on top of the process default set on the system-wide
        // element at launch. Without a timeout a single wedged app blocks this call forever.
        AXUIElementSetMessagingTimeout(ax, 1.0)
        var extras: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        AXUIElementSetMessagingTimeout(bar as! AXUIElement, 1.0)
        var kids: AnyObject?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return [] }
        for child in children {
            AXUIElementSetMessagingTimeout(child, 1.0)
            var posv: AnyObject?, sizev: AnyObject?, descv: AnyObject?, identv: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posv)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizev)
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descv)
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identv)
            var p = CGPoint.zero, s = CGSize.zero
            if let posv, CFGetTypeID(posv) == AXValueGetTypeID() { AXValueGetValue(posv as! AXValue, .cgPoint, &p) }
            if let sizev, CFGetTypeID(sizev) == AXValueGetTypeID() { AXValueGetValue(sizev as! AXValue, .cgSize, &s) }
            guard s.width > 0 else { continue }
            let ident = (identv as? String) ?? ""
            var key = name
            if name == "Control Center" {
                // Control Center's modules (Wi-Fi, Battery, Bluetooth...) are real, movable items;
                // only the Clock and the Control Center menu itself are fixed
                guard !ident.isEmpty, !pinnedModules.contains(ident) else { continue }
                key = ident
            }
            out.append(BarItem(app: name, detail: (descv as? String) ?? "", pid: app.processIdentifier,
                               element: child, frame: CGRect(origin: p, size: s), windowID: nil, key: key))
        }
        return out
    }

    /// Everything that needs the whole bar at once: window ids, left-to-right order, unique keys.
    private static func finish(_ out: inout [BarItem]) -> [BarItem] {
        // Window ids, matched by horizontal position, are what ScreenCaptureKit captures by.
        let windows = statusWindows()
        // First pass: the window that contains the item. The AX frame is often just the button inside the
        // window (PasteStack, ClickCast, Stream Deck, AlDente: a 24pt button in a 38pt window), which the
        // width test below rejects, and with two displays every item has a window on each menu bar, so the
        // one-window-per-app fallback further down never fires either. Same-pid windows win ties.
        var taken = Set<CGWindowID>()
        for i in out.indices {
            let mid = out[i].frame.midX, pid = out[i].pid
            let holding = windows.filter { !taken.contains($0.id) && $0.x - 2 <= mid && mid <= $0.x + $0.width + 2
                && $0.width <= out[i].frame.width + 30 }
            guard let w = holding.first(where: { $0.pid == pid })
                    ?? holding.min(by: { abs($0.x + $0.width / 2 - mid) < abs($1.x + $1.width / 2 - mid) }) else { continue }
            taken.insert(w.id)
            out[i].windowID = w.id
            out[i].hostPid = w.pid
            out[i].onScreen = w.onScreen
        }
        for i in out.indices where out[i].windowID == nil {
            let candidates = windows.filter { abs($0.width - out[i].frame.width) <= 12 }
            if let w = candidates.min(by: { abs($0.x - out[i].frame.minX) < abs($1.x - out[i].frame.minX) }),
               abs(w.x - out[i].frame.minX) <= 30 {
                out[i].windowID = w.id
                out[i].hostPid = w.pid
                out[i].onScreen = w.onScreen
            }
        }
        // AlDente's AXPosition never resolves (reads back as x=0, hence the bogus "@30" that never
        // moves): kAXPositionAttribute fails on its menu extra, so the position match above never has
        // a real coordinate to compare against. Fall back to matching by owning pid: if this app has
        // exactly one status window nobody has claimed yet, it must be this item, wrong AX position
        // or not. Also correct the frame from that window's real bounds so drag/compare math (which
        // reads frame.midX) works from here on instead of from the bogus position.
        let claimed = Set(out.compactMap(\.windowID))
        for i in out.indices where out[i].windowID == nil {
            let byPid = windows.filter { $0.pid == out[i].pid && !claimed.contains($0.id) }
            guard byPid.count == 1, let w = byPid.first else { continue }
            out[i].windowID = w.id
            out[i].hostPid = w.pid
            out[i].onScreen = w.onScreen
            out[i].frame = CGRect(x: w.x, y: out[i].frame.minY, width: w.width, height: out[i].frame.height)
            log("matched \(out[i].label) to window \(w.id) by pid only (AX position was unreadable)")
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        // Some apps (CleanMyMac, Google Drive) show several items under one name. Keying by name
        // alone makes them collide: enforce moves one, the others stay, and the loop ping-pongs.
        // Give each item after the first of a key a stable ordinal, so every item is distinct.
        var seen: [String: Int] = [:]
        for i in out.indices {
            let n = seen[out[i].key, default: 0]
            seen[out[i].key] = n + 1
            if n > 0 { out[i].key += "#\(n)" }
        }
        return out
    }

    private struct StatusWindow { let id: CGWindowID; let x: CGFloat; let width: CGFloat; let pid: pid_t; let onScreen: Bool }

    private static func statusWindows() -> [StatusWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (b["Height"] ?? 0) < 60 else { return nil }
            return StatusWindow(id: id, x: b["X"] ?? 0, width: b["Width"] ?? 0, pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                                onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    /// Cmd-drags an item to `toX`. The events carry the item's window id, so they reach the item
    /// even when the app menus are drawn over it (a plain click there would hit the menu instead).
    /// The cursor is hidden for the duration and put back where it was.
    static func drag(_ item: BarItem, toX: CGFloat) {
        let fromX = item.midX, y: CGFloat = 12
        let saved = currentCursor()
        Cursor.hide()
        defer { CGWarpMouseCursorPosition(saved); Cursor.show() }
        func post(_ type: CGEventType, _ x: CGFloat) {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
            e.flags = .maskCommand
            if let wid = item.windowID {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
                e.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: Int64(wid))   // kCGEventWindowID, undocumented
                if item.hostPid > 0 { e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(item.hostPid)) }
            }
            e.post(tap: .cgSessionEventTap)
        }
        post(.mouseMoved, fromX); usleep(80_000)
        post(.leftMouseDown, fromX); usleep(150_000)
        var x = fromX
        let step = (toX - fromX) / 16
        for _ in 0..<16 { x += step; post(.leftMouseDragged, x); usleep(12_000) }
        usleep(120_000)
        post(.leftMouseUp, toX); usleep(250_000)
    }

    /// Opens an item the way a click would, without a mouse event where possible.
    static func press(_ item: BarItem, allowClick: Bool = true) {
        if AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success { return }
        guard allowClick else { log("press \(item.label): AXPress failed and mouse clicks are off"); return }
        let saved = currentCursor()
        Cursor.hide()
        defer { CGWarpMouseCursorPosition(saved); Cursor.show() }
        let p = CGPoint(x: item.midX, y: 12)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
        }
    }

    static func currentCursor() -> CGPoint {
        // NSEvent is bottom-left origin; CG is top-left on the main display.
        let loc = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: loc.x, y: h - loc.y)
    }
}

enum Cursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let allowedInBackground: Bool = {
        guard let cidSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let setSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(cidSym, to: MainConnection.self)()
        let ok = unsafeBitCast(setSym, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
        log("cursor-in-background property set: \(ok)")
        return ok
    }()
    static func hide() { _ = allowedInBackground; CGDisplayHideCursor(CGMainDisplayID()) }
    static func show() { CGDisplayShowCursor(CGMainDisplayID()) }
}

// MARK: - Icons for the popout

final class IconCache {
    static let shared = IconCache()
    private var images: [String: NSImage] = [:]
    private let q = DispatchQueue(label: "curtain.icons")
    private var capturing = false
    private var capturePausedUntil = Date.distantPast

    func imageAndKind(for item: BarItem) -> (NSImage, Bool) {
        if let img = q.sync(execute: { images[item.key] }) { return (img, true) }
        return (image(for: item), false)
    }

    func image(for item: BarItem) -> NSImage {
        if let img = q.sync(execute: { images[item.key] }) { return img }
        return appIcon(for: item)
    }

    /// The owning app's Dock icon, never a captured glyph. Used for items whose glyph is too wide.
    func appIcon(for item: BarItem) -> NSImage {
        let icon = item.app == "Control Center"
            ? NSImage(systemSymbolName: "switch.2", accessibilityDescription: item.label)!
            : (NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
        // The same height as a normalised glyph. It used to be 18 against glyphs that drew at whatever
        // size their app chose, which is why the app-icon fallbacks stood out as the big colourful ones.
        icon.size = NSSize(width: IconCache.iconHeight, height: IconCache.iconHeight)
        return icon
    }

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures the real menu bar glyphs. Works for items covered by the app menus; whether it
    /// works for items pushed fully off-screen is checked live, and a blank result is discarded.
    func refresh(_ items: [BarItem], completion: @escaping () -> Void) {
        guard IconCache.canCapture else { completion(); return }
        var wanted: [CGWindowID: String] = [:]
        for i in items { if let w = i.windowID { wanted[w] = i.key } }
        guard !wanted.isEmpty else { completion(); return }
        // One capture at a time, and none for a while after one fails. On macOS 15 every ScreenCaptureKit
        // call from an app not yet approved puts up its own "bypass the private window picker" prompt, and
        // the popout, its rescan and each arrange all ask, so without this gate they stacked up on screen.
        let go: Bool = q.sync {
            guard !capturing, Date() >= capturePausedUntil else { return false }
            capturing = true
            return true
        }
        guard go else { completion(); return }
        Task {
            defer { q.sync { capturing = false }; DispatchQueue.main.async(execute: completion) }
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            catch {
                log("capture unavailable, pausing for 10 min: \(error.localizedDescription)")
                q.sync { capturePausedUntil = Date().addingTimeInterval(600) }
                return
            }
            for window in content.windows where wanted[window.windowID] != nil {
                let cfg = SCStreamConfiguration()
                cfg.width = Int(window.frame.width * 2)
                cfg.height = Int(window.frame.height * 2)
                cfg.showsCursor = false
                guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: cfg),
                      IconCache.hasInk(cg) else { continue }
                // Capturing the whole status window keeps whatever padding that app chose, and the
                // glyphs inside are genuinely different sizes: measured live, the ink ranges from
                // 3x3pt to 21x12pt inside identical 30pt-tall windows. Drawing the raw window meant
                // those differences went straight into the popout. Crop to the ink, then scale every
                // icon to one size, so a grid of them reads as a grid.
                guard let trimmed = IconCache.cropToInk(cg) else { continue }
                let img = IconCache.normalised(trimmed)
                let key = wanted[window.windowID]!
                q.sync { images[key] = img }
                log("captured glyph for \(key)")
            }
        }
    }

    /// One size for every icon in the popout. Glyphs are scaled to this height, and anything unusually
    /// wide (a short text item) is scaled down to fit the width instead, so nothing overflows its cell.
    static let iconHeight: CGFloat = 16
    static let iconMaxWidth: CGFloat = 30

    /// Trims the transparent padding around a captured status item, leaving only the glyph itself.
    static func cropToInk(_ cg: CGImage) -> CGImage? {
        let rep = NSBitmapImageRep(cgImage: cg)
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Gives a cropped glyph the shared point size. The pixels are untouched; only the point size the
    /// image reports changes, so a 2x capture still draws at full resolution.
    static func normalised(_ cg: CGImage) -> NSImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return NSImage(cgImage: cg, size: .zero) }
        let scale = min(iconHeight / h, iconMaxWidth / w)
        return NSImage(cgImage: cg, size: NSSize(width: w * scale, height: h * scale))
    }

    private static func hasInk(_ cg: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cg)
        var hits = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { hits += 1 }
        }
        return hits > 4
    }
}

// MARK: - Settings

final class Store: ObservableObject {
    static let shared = Store()
    private let d = UserDefaults.standard

    @Published var visibleApps: Set<String> { didSet { d.set(Array(visibleApps), forKey: "VisibleApps") } }
    @Published var hideNewItems: Bool { didSet { d.set(hideNewItems, forKey: "HideNewItems") } }
    /// Never drag or click with the mouse unprompted: no arrange at launch or when new items appear, and
    /// no synthetic click when an item won't open by accessibility. Drags still run when the user asks
    /// for them (a switch in Settings, Arrange now, the Stream Deck's Keep on Bar), since macOS has no
    /// other way to move another app's menu bar item.
    @Published var handsOff: Bool { didSet { d.set(handsOff, forKey: "HandsOff") } }
    /// What a plain click on the arrow does: false opens the popout, true shows everything on the bar.
    /// Option-click always does the other one.
    @Published var clickExpands: Bool { didSet { d.set(clickExpands, forKey: "ClickExpands") } }
    @Published var rehideSeconds: Double { didSet { d.set(rehideSeconds, forKey: "RehideSeconds") } }
    /// The popout's order, as item keys, set by dragging icons around in it. Keys not listed (new items)
    /// follow the listed ones in their menu bar order. Empty means plain menu bar order.
    @Published var order: [String] { didSet { d.set(order, forKey: "ItemOrder") } }
    @Published var items: [BarItem] = []
    @Published var scanning = false
    @Published var status = ""
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = IconCache.canCapture

    private init() {
        visibleApps = Set(d.stringArray(forKey: "VisibleApps") ?? [])
        hideNewItems = d.object(forKey: "HideNewItems") as? Bool ?? true
        handsOff = d.object(forKey: "HandsOff") as? Bool ?? true
        clickExpands = d.bool(forKey: "ClickExpands")
        rehideSeconds = d.object(forKey: "RehideSeconds") as? Double ?? 10
        order = d.stringArray(forKey: "ItemOrder") ?? []
    }

    var hidden: [BarItem] { ordered(items.filter { !visibleApps.contains($0.key) }) }

    func ordered(_ list: [BarItem]) -> [BarItem] {
        var rank: [String: Int] = [:]
        for (i, k) in order.enumerated() where rank[k] == nil { rank[k] = i }
        return list.enumerated().sorted { a, b in
            switch (rank[a.element.key], rank[b.element.key]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Saves a new popout order. Items not in it keep their remembered place behind it, so an item that
    /// is visible right now gets its popout position back if it is hidden again later.
    func setOrder(_ keys: [String]) {
        let moved = Set(keys)
        order = keys + order.filter { !moved.contains($0) }
    }

    func isVisible(_ item: BarItem) -> Bool { visibleApps.contains(item.key) }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let toggle = NSStatusBar.system.statusItem(withLength: 24)
    private let divider = NSStatusBar.system.statusItem(withLength: 10_000)
    private let store = Store.shared
    private let work = DispatchQueue(label: "curtain.work")   // one drag at a time, ever
    private var expanded = false
    private var rehideTimer: Timer?
    private var settingsWindow: NSWindow?
    private var popout: Popout?
    private var watcher: Timer?
    private var knownApps: Set<String> = []
    private var clickAwayMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The process-wide default for every accessibility element we ever touch. Elements copied out
        // of another element do not inherit that element's timeout, only this one, so this line is the
        // only thing standing between one wedged app and a permanently frozen Curtain.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        divider.autosaveName = "CurtainDivider"
        toggle.autosaveName = "CurtainToggle"
        divider.button?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "divider")
        divider.button?.imagePosition = .imageOnly
        divider.button?.target = self
        divider.button?.action = #selector(openSettings)
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render()

        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        // the login item is tied to the bundle path; re-register after a move so the choice survives
        if UserDefaults.standard.bool(forKey: "LoginItem"), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        rescan { [weak self] in
            guard let self else { return }
            self.knownApps = Set(self.store.items.map(\.key))
            // launch: arrange for real, don't let the pre-check race the collapse
            if !self.store.handsOff { self.forceEnforce() }
        }
        // New items land visible by default; catch them and put them where the settings say.
        watcher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.watch() }
    }

    // MARK: state

    private func render() {
        divider.length = expanded ? 12 : 10_000
        let symbol = expanded ? "chevron.right" : "chevron.left"
        toggle.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: expanded ? "hide" : "show")
        divider.button?.image = expanded ? NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "divider") : nil
    }

    func setExpanded(_ on: Bool, rehideAfter: Double? = nil) {
        expanded = on
        render()
        rehideTimer?.invalidate()
        if on, let secs = rehideAfter, secs > 0 {
            rehideTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                // not while ⌘ or a mouse button is down: that is someone mid-drag rearranging the bar
                if NSEvent.modifierFlags.contains(.command) || NSEvent.pressedMouseButtons != 0 {
                    self?.setExpanded(true, rehideAfter: 2)
                } else {
                    self?.setExpanded(false)
                }
            }
        }
    }

    /// Runs `body` with the bar expanded (items must be on the bar to be measured or dragged),
    /// then restores whatever state it was in. Body runs on the work queue.
    private func whileExpanded(_ body: @escaping () -> Void, then: @escaping () -> Void = {}) {
        let wasExpanded = expanded
        DispatchQueue.main.async {
            if !wasExpanded { self.setExpanded(true) }
        }
        work.async {
            // wait until the divider is genuinely expanded and on screen; 250ms was not always enough
            for _ in 0..<20 {
                if let f = self.dividerFrame(), f.width < 100, f.minX > 0 { break }
                usleep(50_000)
            }
            usleep(150_000)
            body()
            DispatchQueue.main.async {
                if !wasExpanded { self.setExpanded(false) }
                then()
            }
        }
    }

    // MARK: scanning and layout

    func rescan(_ then: @escaping () -> Void = {}) {
        store.scanning = true
        work.async {
            let found = Bar.scan()
            log("scan: \(found.count) items, trusted=\(AXIsProcessTrusted())")
            DispatchQueue.main.async {
                self.store.items = found
                self.followBar()
                self.store.scanning = false
                self.store.accessibility = AXIsProcessTrusted()
                self.store.screenRecording = IconCache.canCapture
                then()
            }
        }
    }

    /// Puts every item on the side of the divider the settings say, one drag at a time,
    /// re-reading the bar between drags because each one shifts everything else.
    private var enforcing = false

    func enforce() {
        guard AXIsProcessTrusted() else { store.status = "Needs Accessibility"; return }
        guard !enforcing, !checking else { return }
        checking = true
        let wanted = store.visibleApps
        // Pre-check WITHOUT expanding: an item's window is on-screen exactly when it is visible.
        // If every item is already on the side the settings want, do nothing at all, so the bar
        // does not flash open and shut on every 5s watch tick when there is nothing to move.
        work.async {
            let pre = Bar.scan()
            let edge = self.toggleFrame()?.minX ?? 0
            let mismatch = pre.contains { $0.windowID != nil && wanted.contains($0.key) != $0.onScreen }
                // a shown item sitting left of the arrow: the arrow is meant to be the leftmost icon
                || pre.contains { $0.windowID != nil && wanted.contains($0.key) && $0.onScreen && $0.midX < edge }
            DispatchQueue.main.async {
                self.checking = false
                self.store.items = pre
                guard mismatch else {
                    self.store.status = ""
                    // Same reasoning as the "futile arrange" case below: whatever asked for this
                    // found nothing to do, so let it stop asking.
                    self.futileTriggers.formUnion(self.pendingTrigger)
                    self.pendingTrigger = []
                    return
                }
                self.runEnforce(wanted)
            }
        }
    }

    private var checking = false

    /// Arrange now, skipping the on-screen pre-check. Used at launch and when the user changes
    /// settings, where the bar is mid-transition and the pre-check can misread what is visible.
    /// With the mouse setting on, the bar is the truth: whatever sits right of the divider stays, the rest
    /// is hidden, and the settings follow wherever the user has \u{2318}-dragged things. The divider's right
    /// edge doesn't move when the bar expands (hidden items slide in from the left of it), so this reads
    /// the same whether the bar is out or not.
    func followBar() {
        guard store.handsOff, !enforcing, let edge = divider.button?.window?.frame.maxX else { return }
        var visible = store.visibleApps
        for item in store.items where item.windowID != nil {
            if item.midX > edge { visible.insert(item.key) } else { visible.remove(item.key) }
        }
        if visible != store.visibleApps { store.visibleApps = visible }
    }

    func forceEnforce() { futileTriggers = []; runEnforce(store.visibleApps) }

    /// Belt and braces for the freeze above: whatever goes wrong inside an arrange, `enforcing` and the
    /// expanded bar are released after this long. Without it a single stuck call leaves the arrow dead
    /// and the bar open until the user notices and quits the app.
    private var enforceWatchdog: Timer?

    private func runEnforce(_ wanted: Set<String>) {
        guard !enforcing else { return }
        // Every drag goes through here. With the mouse setting on, nothing is dragged, ever.
        guard !store.handsOff else { store.status = "Mouse is off: \u{2318}-drag icons yourself"; return }
        enforcing = true
        enforceWatchdog?.invalidate()
        enforceWatchdog = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, self.enforcing else { return }
            log("enforce watchdog fired: releasing a stuck arrange")
            self.enforcing = false
            self.setExpanded(false)
            self.store.status = "Arrange timed out"
        }
        store.status = "Arranging\u{2026}"
        whileExpanded({
            var moved = 0
            var attempts: [String: Int] = [:]
            var skipped: Set<String> = []
            let full = Bar.scan()
            let pids = Set(full.map(\.pid))
            var items = full
            if let d0 = self.dividerFrame() {
                log("runEnforce: dividerFrame w=\(Int(d0.width)) minX=\(Int(d0.minX)) midX=\(Int(d0.midX)); wanted items: " +
                    full.filter { wanted.contains($0.key) }.map { "\($0.label)@\(Int($0.midX))win=\($0.windowID != nil)" }.joined(separator: " "))
            }
            for _ in 0..<40 {
                // the bar must be out for any of this to mean anything; if it is not, stop rather than
                // drag things around at off-screen coordinates
                guard let d = self.dividerFrame(), d.width < 100, d.minX > 0 else { log("enforce aborted: bar is not expanded"); break }
                let dividerX = d.midX
                // Shown items belong right of the arrow, not just right of the divider, so the arrow stays
                // the leftmost icon on the bar. If the arrow has somehow ended up left of the divider, fall
                // back to the divider alone rather than drag shown items into the hidden section.
                let arrowEdge = self.toggleFrame().map { $0.midX > dividerX ? $0.maxX : dividerX } ?? dividerX
                guard let wrong = items.first(where: { item in
                    !skipped.contains(item.key) && (attempts[item.key] ?? 0) < 2
                        && (wanted.contains(item.key) ? item.midX < arrowEdge : item.midX > dividerX)
                }) else { break }
                guard wrong.windowID != nil else {
                    // an accessibility entry with no window behind it (AlDente does this) cannot be dragged;
                    // but positions settle a beat after the bar expands, so look once more before giving up
                    usleep(300_000)
                    items = Bar.scan(onlyPids: pids)
                    if items.first(where: { $0.key == wrong.key })?.windowID != nil { continue }
                    log("skip \(wrong.label): no window")
                    skipped.insert(wrong.key)
                    continue
                }
                attempts[wrong.key, default: 0] += 1
                let toVisible = wanted.contains(wrong.key)
                log("drag \(wrong.label) from \(Int(wrong.midX)) to \(toVisible ? "visible" : "hidden") side of divider at \(Int(dividerX))")
                Bar.drag(wrong, toX: toVisible ? arrowEdge + 4 : dividerX - 10)
                items = Bar.scan(onlyPids: pids)
                if let now = items.first(where: { $0.key == wrong.key }), let d2 = self.dividerFrame(),
                   toVisible ? now.midX > (self.toggleFrame()?.maxX ?? d2.midX) : now.midX < d2.midX {
                    moved += 1
                } else {
                    log("\(wrong.label) did not land where expected")
                }
            }
            let stuck = attempts.filter { $0.value >= 2 }.keys.sorted()
            let final = Bar.scan()
            log("enforce done: moved \(moved), stuck \(stuck); order now: \(final.map { "\($0.label)@\(Int($0.midX))" }.joined(separator: " "))")
            // glyphs capture cleanly only while the items are on the bar, i.e. right now
            let group = DispatchGroup(); group.enter()
            IconCache.shared.refresh(final.filter { !wanted.contains($0.key) }) { group.leave() }
            _ = group.wait(timeout: .now() + 4)
            DispatchQueue.main.async {
                self.store.items = final
                self.store.status = stuck.isEmpty ? (moved == 0 ? "" : "Moved \(moved)") : "Could not move \(stuck.joined(separator: ", "))"
                // Nothing moved and nothing was stuck means the bar was already correct: whatever
                // asked for this arrange did not need one, so stop letting it ask again.
                if moved == 0, stuck.isEmpty, !self.pendingTrigger.isEmpty {
                    log("futile arrange, muting triggers: \(self.pendingTrigger.sorted())")
                    self.futileTriggers.formUnion(self.pendingTrigger)
                }
                self.pendingTrigger = []
            }
        }, then: { self.enforceWatchdog?.invalidate(); self.enforcing = false })
    }

    /// The arrow's frame, in the same x space as dividerFrame().
    private func toggleFrame() -> CGRect? {
        var frame: CGRect?
        DispatchQueue.main.sync { frame = toggle.button?.window?.frame }
        return frame.map { CGRect(x: $0.minX, y: 0, width: $0.width, height: $0.height) }
    }

    private func dividerFrame() -> CGRect? {
        var frame: CGRect?
        DispatchQueue.main.sync { frame = divider.button?.window?.frame }
        guard let f = frame else { return nil }
        // convert the bottom-left window frame to the top-left AX space (same x, which is all we use)
        return CGRect(x: f.minX, y: 0, width: f.width, height: f.height)
    }

    private var watching = false
    /// Keys whose arrival triggered an arrange that turned out to have nothing to do. macOS destroys
    /// and recreates the Now Playing window every few seconds (a new window id each time) while its
    /// accessibility entry stays put on the hidden side, so it reads as a brand new item over and
    /// over and expanded the bar for nothing roughly once a minute. One futile arrange each is enough.
    private var futileTriggers: Set<String> = []
    private var pendingTrigger: Set<String> = []

    private func watch() {
        // The work queue is serial, so a watch tick that outlives its 5s interval must not queue the
        // next one behind it: that is how one slow scan turns into a backlog nothing can drain.
        guard !store.scanning, !watching, !enforcing, AXIsProcessTrusted() else { return }
        watching = true
        work.async {
            let found = Bar.scan()
            let apps = Set(found.map(\.key))
            let apps2 = apps
            DispatchQueue.main.async {
                self.watching = false
                let fresh = apps2.subtracting(self.knownApps).subtracting(self.futileTriggers)
                self.knownApps = apps2
                self.store.items = found
                self.followBar()
                // Only a genuinely new item triggers an arrange. Sweeping for "anything on the wrong
                // side" was tried and reverted: while the bar is collapsed a hidden item's window is
                // still reported on-screen (the app menus cover it, they do not unmap it), so the
                // check fired constantly on items that were already correct and flashed the bar open
                // every thirty seconds for nothing. Every arrange it triggered reported "moved 0".
                guard !fresh.isEmpty, self.store.hideNewItems, !self.store.handsOff, !self.expanded else { return }
                self.pendingTrigger = fresh
                self.enforce()
            }
        }
    }

    // MARK: clicks

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        log("toggle clicked type=\(String(describing: event?.type.rawValue)) expanded=\(expanded) popoutVisible=\(popout?.isVisible ?? false) enforcing=\(enforcing)")
        if event?.type == .rightMouseUp { showMenu(); return }
        if let popout, popout.isVisible { popout.close(); return }
        // A click on the arrow ALWAYS does something. It used to return silently whenever an arrange
        // was in flight, which meant any stuck arrange read to the user as a dead arrow. Collapsing
        // mid-arrange is safe: the drag loop aborts as soon as it sees the bar is no longer expanded.
        if expanded { setExpanded(false); return }
        // A plain click does whichever the settings chose; option-click does the other.
        let option = event?.modifierFlags.contains(.option) == true
        if store.clickExpands != option { setExpanded(true, rehideAfter: store.rehideSeconds) }
        else { showPopout() }
    }

    private func showPopout() {
        guard let button = toggle.button, let screenFrame = button.window?.frame else { return }
        if store.items.isEmpty && !store.scanning { rescan { self.showPopout() }; return }
        let items = store.hidden
        let panel = Popout(items: items, anchorRight: screenFrame.maxX, top: screenFrame.minY - 6) { [weak self] item in
            self?.activate(item)
        } showAll: { [weak self] in
            guard let self else { return }
            self.setExpanded(true, rehideAfter: self.store.rehideSeconds)
        } settings: { [weak self] in
            self?.openSettings()
        } reorder: { [weak self] keys in
            self?.store.setOrder(keys)
            log("popout reordered: \(keys)")
        }
        popout = panel
        panel.orderFrontRegardless()
        log("popout shown frame=\(panel.frame) items=\(items.count)")
        IconCache.shared.refresh(items) { [weak panel] in panel?.reloadIcons() }
        rescan { [weak panel, weak self] in
            guard let self, let panel else { return }
            panel.update(items: self.store.hidden)
            IconCache.shared.refresh(self.store.hidden) { [weak panel] in panel?.reloadIcons() }
        }
    }

    /// Opens a hidden item's menu: bring the bar out, press the item, put the bar back once the
    /// user has clicked anywhere else (which is what closes the menu), or after 25 seconds.
    private func activate(_ item: BarItem) {
        let allowClick = !store.handsOff
        popout?.close()
        setExpanded(true)
        work.async {
            usleep(300_000)
            // the element handle survives, but re-read for a fresh position in case the press has to fall back to a click
            let fresh = Bar.scan().first { $0.key == item.key } ?? item
            Bar.press(fresh, allowClick: allowClick)
            DispatchQueue.main.async { self.collapseAfterNextClick() }
        }
    }

    private func collapseAfterNextClick() {
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m) }
        var fired = false
        let finish = { [weak self] in
            guard !fired else { return }; fired = true
            if let m = self?.clickAwayMonitor { NSEvent.removeMonitor(m); self?.clickAwayMonitor = nil }
            self?.setExpanded(false)
        }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: finish)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: finish)
    }

    private func showMenu() {
        let menu = NSMenu()
        let show = NSMenuItem(title: expanded ? "Hide items" : "Show all items", action: #selector(menuToggleBar), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Curtain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        if let button = toggle.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func menuToggleBar() {
        setExpanded(!expanded, rehideAfter: store.rehideSeconds)
    }

    // MARK: settings window

    @objc func openSettings() {
        popout?.close()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Curtain"
            w.contentView = NSHostingView(rootView: SettingsView(delegate: self))
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            w.isReleasedWhenClosed = false
            w.delegate = self
            settingsWindow = w
        }
        // Stays an accessory app: switching to .regular put Curtain in the Dock and the Cmd-Tab switcher
        // for as long as Settings was open, which is not wanted. The floating level plus
        // orderFrontRegardless brings the window forward without it.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.level = .floating            // guaranteed on top when opened
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        rescan()
    }

    /// Coming back from System Settings: pick up permissions granted there without needing a rescan.
    func windowDidBecomeKey(_ notification: Notification) {
        store.accessibility = AXIsProcessTrusted()
        store.screenRecording = IconCache.canCapture
    }

    func windowDidResignKey(_ notification: Notification) {
        settingsWindow?.level = .normal              // not glued over everything once you click away
    }

}

// MARK: - Popout (the Bartender-style bar)

/// A popout icon that is clicked to open its item, or dragged to a new place in the popout. The drag
/// is tracked by hand inside mouseDown, because the panel never becomes key and never activates.
final class IconButton: NSButton {
    var onDragBegin: (() -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        // the button is rebuilt while the drag runs, so the loop holds the window, not self.window
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = e.locationInWindow
            if e.type == .leftMouseUp {
                if dragging { onDragEnd?() } else if let action { NSApp.sendAction(action, to: target, from: self) }
                return
            }
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true; onDragBegin?() }
            if dragging { onDragMove?(p) }
        }
    }
}

final class Popout: NSPanel {
    private var items: [BarItem]
    private let onPick: (BarItem) -> Void
    private let onShowAll: () -> Void
    private let onSettings: () -> Void
    private let onReorder: ([String]) -> Void
    private var buttons: [IconButton] = []
    private var draggingKey: String?
    /// A column of rows, each row a horizontal strip of icons. Wrapping keeps the popout roughly the
    /// width of a normal menu bar section no matter how many items are hidden, instead of one long
    /// strip that gets wider the more you hide - which is what made it look broken with 20+ items.
    private let column = NSStackView()
    private static let maxRowWidth: CGFloat = 420
    private let anchorRight: CGFloat
    private let top: CGFloat
    private var monitors: [Any] = []

    init(items: [BarItem], anchorRight: CGFloat, top: CGFloat,
         onPick: @escaping (BarItem) -> Void, showAll: @escaping () -> Void, settings: @escaping () -> Void,
         reorder: @escaping ([String]) -> Void) {
        self.items = items; self.onPick = onPick; self.onShowAll = showAll; self.onSettings = settings
        self.onReorder = reorder
        self.anchorRight = anchorRight; self.top = top
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        contentView = blur

        column.orientation = .vertical
        column.spacing = 2
        column.alignment = .trailing   // rows right-align, matching the anchor to the toggle above
        column.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            column.topAnchor.constraint(equalTo: blur.topAnchor),
            column.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        build()

        // Any click outside closes it, like a menu.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        } as Any)
    }

    override var canBecomeKey: Bool { false }

    /// A rescan landing mid-drag would snap the icons back to the saved order, so it waits for the drop.
    func update(items: [BarItem]) { guard draggingKey == nil else { return }; self.items = items; build() }
    func reloadIcons() { build() }

    private func iconButton(for item: BarItem, tag: Int) -> (NSButton, CGFloat) {
        var (image, isGlyph) = IconCache.shared.imageAndKind(for: item)
        // A very wide glyph (CleanMyMac's graph, a menu bar item holding a whole sentence) squashes to
        // a smear once it is scaled down to one cell's width, so those show the app icon instead.
        if isGlyph, item.frame.width > 72 { image = IconCache.shared.appIcon(for: item) }
        let b = IconButton(image: image, target: self, action: #selector(pick(_:)))
        b.tag = tag
        b.isBordered = false
        b.imageScaling = .scaleNone       // the image is already at its final size; let it be
        b.toolTip = "\(item.label)\nDrag to rearrange"
        b.alphaValue = item.key == draggingKey ? 0.35 : 1
        b.onDragBegin = { [weak self] in self?.draggingKey = item.key; self?.build() }
        b.onDragMove = { [weak self] p in self?.dragMoved(to: p) }
        b.onDragEnd = { [weak self] in
            guard let self else { return }
            self.draggingKey = nil
            self.build()
            self.onReorder(self.items.map(\.key))
        }
        buttons.append(b)
        // Every cell is identical. Cells used to be sized from the item's width on the real menu bar,
        // which put a 22pt cell next to a 72pt one and made a grid look ragged even before the glyphs
        // inside it differed. The icon is centred in the cell, whatever its aspect ratio.
        let width = IconCache.iconMaxWidth + 6
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return (b, width)
    }

    private func newRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        column.addArrangedSubview(row)
        return row
    }

    /// Live reorder: whichever icon the cursor is over, the dragged one takes its place.
    private func dragMoved(to p: NSPoint) {
        guard let key = draggingKey, let from = items.firstIndex(where: { $0.key == key }),
              let to = buttons.firstIndex(where: { $0.convert($0.bounds, to: nil).contains(p) }),
              to != from, items.indices.contains(to) else { return }
        items.insert(items.remove(at: from), at: to)
        build()
    }

    private func build() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        if items.isEmpty {
            let row = newRow()
            let label = NSTextField(labelWithString: "Nothing hidden")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(label)
        }
        // Wrap icons into rows capped at maxRowWidth, so the popout stays roughly the width of a
        // normal menu bar section no matter how many items are hidden (was one long strip that grew
        // with every hidden item - unusable past a dozen or so).
        var row = newRow()
        var rowWidth: CGFloat = 0
        for (i, item) in items.enumerated() {
            let (button, width) = iconButton(for: item, tag: i)
            if rowWidth > 0, rowWidth + 2 + width > Popout.maxRowWidth {
                row = newRow()
                rowWidth = 0
            }
            row.addArrangedSubview(button)
            rowWidth += width + 2
        }
        // controls always get their own final row; column.alignment = .trailing right-aligns it
        // flush with every icon row above, same as the rest.
        let controls = newRow()
        let sep = NSBox(); sep.boxType = .separator
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        controls.addArrangedSubview(sep)
        let all = NSButton(image: NSImage(systemSymbolName: "rectangle.expand.vertical", accessibilityDescription: "show all")!, target: self, action: #selector(showAll))
        all.isBordered = false; all.toolTip = "Show everything on the bar for a moment"
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "settings")!, target: self, action: #selector(settings))
        gear.isBordered = false; gear.toolTip = "Settings"
        for b in [all, gear] {
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            controls.addArrangedSubview(b)
        }
        column.layoutSubtreeIfNeeded()
        let size = column.fittingSize
        let x = max(8, min(anchorRight - size.width, (NSScreen.main?.frame.maxX ?? anchorRight) - size.width - 8))
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    @objc private func pick(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onPick(items[sender.tag])
    }
    @objc private func showAll() { close(); onShowAll() }
    @objc private func settings() { close(); onSettings() }

    override func close() {
        log("popout closed")
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        super.close()
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    weak var delegate: AppDelegate?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ticked items stay on the bar. Everything else lives behind the chevron.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if !store.accessibility {
                permissionRow("Accessibility is off, so items cannot be read or moved.", "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }

            List {
                if store.scanning && store.items.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading the menu bar\u{2026}").foregroundStyle(.secondary) }
                }
                ForEach(store.items) { item in
                    if item.windowID == nil {
                        HStack(spacing: 8) {
                            Image(nsImage: NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage())
                                .resizable().frame(width: 16, height: 16)
                            Text(item.label).lineLimit(1)
                            Spacer()
                            Text("no menu bar window, cannot be moved").font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                    Toggle(isOn: Binding(
                        get: { store.isVisible(item) },
                        set: { on in
                            if on { store.visibleApps.insert(item.key) } else { store.visibleApps.remove(item.key) }
                            delegate?.forceEnforce()
                        }
                    )) {
                        HStack(spacing: 8) {
                            Image(nsImage: NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage())
                                .resizable().frame(width: 16, height: 16)
                            Text(item.label).lineLimit(1)
                        }
                    }
                    // the switch only, not the List: a disabled List stops scrolling too
                    .disabled(store.handsOff)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Clicking the arrow", selection: $store.clickExpands) {
                    Text("Opens the popout").tag(false)
                    Text("Shows icons in the menu bar").tag(true)
                }
                Text(store.clickExpands ? "Option-click opens the popout instead." : "Option-click shows the icons in the menu bar instead.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Toggle("Never move the mouse", isOn: $store.handsOff)
                    .onChange(of: store.handsOff) { _, on in if on { delegate?.followBar() } }
                Text(store.handsOff
                     ? "You arrange the bar: show all icons, then hold \u{2318} and drag an icon left of the \u{2261} divider to hide it, or right of it to keep it on the bar. The switches above follow what you do."
                     : "Curtain drags icons into place itself when you change a switch above or press Arrange now, and briefly takes over the mouse to do it.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Toggle("Hide new items automatically", isOn: $store.hideNewItems).disabled(store.handsOff)
                HStack {
                    Text("Show all, then hide again after")
                    Slider(value: $store.rehideSeconds, in: 3...60, step: 1).frame(width: 140)
                    Text("\(Int(store.rehideSeconds))s").monospacedDigit().frame(width: 32, alignment: .trailing)
                }
                Toggle("Open Curtain at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: "LoginItem")
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { store.status = "Login item: \(error.localizedDescription)" }
                    }
                ))
                if !store.screenRecording {
                    permissionRow("Screen Recording is off, so the popout shows app icons instead of the real glyphs. After allowing it, quit and reopen Curtain.", "Open Settings") {
                        // The system prompt only ever appears once, so after that the button would do
                        // nothing. Registering still adds Curtain to the list; the pane is where it's switched on.
                        CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                HStack {
                    Button("Rescan") { delegate?.rescan() }
                    Button("Arrange now") { delegate?.forceEnforce() }.disabled(store.handsOff)
                    Button("Reset popout order") { store.order = [] }.disabled(store.order.isEmpty)
                    Spacer()
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Tip: drag icons in the popout to rearrange them. Hold \u{2318} and drag icons on the bar itself to reorder it.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 460, height: 760)
    }

    private func permissionRow(_ text: String, _ button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

// MARK: - Stream Deck control server
//
// Loopback HTTP API for the Curtain Deck Stream Deck plugin. Bound to 127.0.0.1 only; not reachable
// from the network. Plain BSD sockets + GCD (same shape as ClickCast's). Every response is the state.
//
//  GET  /state
//  POST /expand    {toggle:true} | {on:Bool}, optional {stay:true} to skip the auto re-hide
//  POST /popout    toggles the popout of hidden items
//  POST /open      {key}          opens that item's menu, the same as clicking it in the popout
//  POST /visible   {key, on?:Bool} keeps an item on the bar (on) or behind the arrow (off); toggles without `on`
//  POST /arrange   arrange now
//  POST /rescan
//  POST /settings  opens the Settings window

final class ControlServer {
    static let port: UInt16 = 8767

    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "curtain.control", qos: .userInitiated)
    private unowned let app: AppDelegate

    init(app: AppDelegate) { self.app = app }

    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { log("control server: socket() failed"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            log("control server: bind/listen on 127.0.0.1:\(Self.port) failed (errno \(errno))")
            close(fd)
            return
        }
        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
        log("control server listening on 127.0.0.1:\(Self.port)")
    }

    private func acceptOne() {
        let client = accept(socketFD, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var parsed: (head: String, body: Data, complete: Bool)?
        while buf.count < 1 << 20 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(chunk, count: n)
            if let p = Self.parse(buf) {
                parsed = p
                if p.complete { break }
            }
        }
        guard let req = parsed, req.complete else { return }
        let startLine = req.head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = startLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]

        // Store and AppKit state live on the main thread.
        var payload: [String: Any] = [:]
        DispatchQueue.main.sync { payload = self.app.handleControl(route: route, json: json) }

        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private static func parse(_ data: Data) -> (head: String, body: Data, complete: Bool)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let body = data[sep.upperBound...]
        var expected = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            expected = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return (head, Data(body), body.count >= expected)
    }
}

// In the same file as AppDelegate, so it can reach the private state and actions without changing them.
extension AppDelegate {
    func handleControl(route: String, json: [String: Any]) -> [String: Any] {
        let store = Store.shared
        let key = json["key"] as? String
        switch route {
        case "/", "/state":
            break
        case "/expand":
            let on = json["toggle"] as? Bool == true ? !expanded : (json["on"] as? Bool ?? !expanded)
            popout?.close()
            setExpanded(on, rehideAfter: json["stay"] as? Bool == true ? nil : store.rehideSeconds)
        case "/popout":
            if let popout, popout.isVisible { popout.close() }
            else {
                if expanded { setExpanded(false) }
                showPopout()
            }
        case "/open":
            guard let key, let item = store.items.first(where: { $0.key == key }) else { return state(error: "unknown item") }
            activate(item)
        case "/visible" where store.handsOff, "/arrange" where store.handsOff:
            return state(error: "Never move the mouse is on in Curtain's settings")
        case "/visible":
            guard let key, store.items.contains(where: { $0.key == key }) || store.visibleApps.contains(key) else {
                return state(error: "unknown item")
            }
            let on = json["on"] as? Bool ?? !store.visibleApps.contains(key)
            if on { store.visibleApps.insert(key) } else { store.visibleApps.remove(key) }
            forceEnforce()
        case "/arrange":
            forceEnforce()
        case "/rescan":
            rescan()
        case "/settings":
            openSettings()
        default:
            return state(error: "unknown route \(route)")
        }
        return state()
    }

    private func state(error: String? = nil) -> [String: Any] {
        let store = Store.shared
        var s: [String: Any] = [
            "running": true,
            "expanded": expanded,
            "popout": popout?.isVisible ?? false,
            "trusted": AXIsProcessTrusted(),
            "screenRecording": store.screenRecording,
            "hiddenCount": store.hidden.count,
            "status": store.status,
            "items": store.items.map { ["key": $0.key, "label": $0.label, "visible": store.isVisible($0), "movable": $0.windowID != nil] },
        ]
        if let error { s["error"] = error }
        return s
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
let control = ControlServer(app: delegate)
control.start()
app.run()
