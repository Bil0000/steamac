import AppKit

enum CursorSelfTest {
    static func run() -> Never {
        let failures = check()
        failures.forEach { log("cursor selftest: FAIL \($0)") }
        log(failures.isEmpty ? "cursor selftest: PASS" : "cursor selftest: \(failures.count) FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func check() -> [String] {
        let app = SteamacApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let previous = NSWorkspace.shared.frontmostApplication
        let original = NSEvent.mouseLocation
        let inputs = VMInputs(keyboard: InputDevices.keyboard(), tablet: InputDevices.tablet(), mouse: InputDevices.mouse())
        let wc = WindowController(title: "Cursor test", width: 800, height: 500,
                                  renderer: Renderer(), inputs: inputs, mouseMode: .auto)
        let native = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 200, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = NSButton(title: "Native control", target: nil, action: nil)
        defer {
            wc.releaseAll()
            wc.window.orderOut(nil)
            native.orderOut(nil)
            CGWarpMouseCursorPosition(CGPoint(x: original.x, y: NSScreen.screens[0].frame.maxY - original.y))
            if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
        }
        var failures: [String] = []
        let tablet = WindowController(title: "Tablet cursor test", width: 800, height: 500,
                                      renderer: wc.view.renderer, inputs: inputs, mouseMode: .tablet)
        if tablet.hostCursorRect != nil { failures.append("tablet mode hides its only usable cursor") }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if condition() { return true }
                if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    app.sendEvent(e)
                }
                app.updateWindows()
            } while Date() < deadline
            return condition()
        }
        func visible() -> Bool? {
            guard let data = NSCursor.currentSystem?.image.tiffRepresentation,
                  let pixels = NSBitmapImageRep(data: data) else { return nil }
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                    return true
                }
            }
            return false
        }
        func expect(_ shown: Bool, _ name: String) {
            if !wait({ visible() == shown }) { failures.append(name) }
        }
        func move(in window: NSWindow, _ point: NSPoint) {
            let p = window.convertPoint(toScreen: point)
            let screen = CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
            CGWarpMouseCursorPosition(screen)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: screen, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        wc.show()
        guard wait({ wc.window.isKeyWindow && app.isActive }) else { return ["test window did not become active"] }
        let center = NSPoint(x: wc.view.bounds.midX, y: wc.view.bounds.midY)
        move(in: wc.window, center)
        expect(false, "Steam picture still shows the Mac cursor")
        wc.overlay.show(animated: false)
        expect(true, "boot overlay hides the Mac cursor")
        wc.overlay.hide(animated: false)
        expect(false, "closing the overlay leaves the extra cursor")
        wc.guestSleeping(true)
        expect(true, "sleep overlay hides the Mac cursor")
        wc.guestSleeping(false)
        expect(false, "waking leaves the extra cursor")
        wc.gamePaused(4242)
        expect(true, "pause overlay hides the Mac cursor")
        wc.gamePaused(nil)
        expect(false, "resuming leaves the extra cursor")
        wc.scanoutResized(width: 1600, height: 800)
        move(in: wc.window, NSPoint(x: 20, y: wc.view.bounds.height - 10))
        expect(true, "letterbox hides the Mac cursor")
        move(in: wc.window, center)
        expect(false, "entering the picture leaves the extra cursor")
        move(in: wc.window, NSPoint(x: center.x, y: wc.view.bounds.height + 10))
        expect(true, "title bar hides the Mac cursor")
        native.makeKeyAndOrderFront(nil)
        move(in: native, NSPoint(x: 100, y: 60))
        expect(true, "native controls hide the Mac cursor")
        wc.show()
        move(in: wc.window, center)
        expect(false, "returning to Steam leaves the extra cursor")
        wc.grabPointer()
        if !wc.pointerCaptured { failures.append("capture failed") }
        wc.releasePointer()
        expect(false, "release leaves the extra cursor")
        move(in: wc.window, NSPoint(x: center.x, y: wc.view.bounds.height + 10))
        expect(true, "capture/release left the cursor hidden outside the picture")
        let progress = BootProgress()
        wc.attach(progress: progress)
        wc.overlay.hide(animated: false)
        let card = wc.pill.cardFrame
        move(in: wc.window, wc.pill.convert(NSPoint(x: card.midX, y: card.midY), to: nil))
        expect(true, "clickable progress pill hides the Mac cursor")
        progress.guestLine("ready")
        move(in: wc.window, center)
        expect(false, "closing the progress pill leaves the extra cursor")
        return failures
    }
}
