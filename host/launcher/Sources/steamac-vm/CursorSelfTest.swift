import AppKit

enum CursorSelfTest {
    static func run() -> Never {
        if let value = ProcessInfo.processInfo.environment["STEAMAC_CURSOR_TEST_PARENT"], let pid = pid_t(value),
           let parent = NSRunningApplication(processIdentifier: pid),
           let token = ProcessInfo.processInfo.environment["STEAMAC_CURSOR_TEST_ID"] {
            runHelper(parent: parent, token: token)
        }
        let failures = check()
        failures.forEach { log("cursor selftest: FAIL \($0)") }
        log(failures.isEmpty ? "cursor selftest: PASS" : "cursor selftest: \(failures.count) FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func runHelper(parent: NSRunningApplication, token: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 180, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Cursor test helper"
        window.center()
        window.makeKeyAndOrderFront(nil)
        let center = DistributedNotificationCenter.default()
        let cursorObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: app, queue: .main) { _ in NSCursor.arrow.set() }
        let observer = center.addObserver(forName: .init("steamac.cursor-test.command"), object: token, queue: .main) { note in
            if note.userInfo?["action"] as? String == "activate" {
                window.makeKeyAndOrderFront(nil)
                app.activate()
            } else {
                window.orderOut(nil)
                app.yieldActivation(to: parent)
                parent.activate()
            }
        }
        center.postNotificationName(.init("steamac.cursor-test.ready"), object: token, userInfo: nil, deliverImmediately: true)
        withExtendedLifetime((observer, cursorObserver)) { app.run() }
        exit(0)
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
        func expect(_ shown: Bool, _ name: String, stable: Bool = false) {
            guard InputSelfTest.wait({ visible() == shown }) else { failures.append(name); return }
            if stable {
                let deadline = Date().addingTimeInterval(1)
                _ = InputSelfTest.wait({ visible() != shown || Date() >= deadline })
                if visible() != shown { failures.append(name) }
            }
        }
        func move(in window: NSWindow, _ point: NSPoint) {
            let p = window.convertPoint(toScreen: point)
            let screen = CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
            CGWarpMouseCursorPosition(screen)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: screen, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        wc.show()
        guard InputSelfTest.wait({ wc.window.isKeyWindow && app.isActive }) else { return ["test window did not become active"] }
        let center = NSPoint(x: wc.view.bounds.midX, y: wc.view.bounds.midY)
        move(in: wc.window, center)
        expect(false, "Steam picture still shows the Mac cursor")
        let token = UUID().uuidString
        let notifications = DistributedNotificationCenter.default()
        var helper: NSRunningApplication?
        var ready = false
        let observer = notifications.addObserver(forName: .init("steamac.cursor-test.ready"), object: token, queue: .main) { _ in ready = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steamac-cursor-" + token)
        let helperURL = directory.appendingPathComponent("CursorHelper.app")
        defer {
            notifications.removeObserver(observer)
            helper?.terminate()
            if InputSelfTest.wait({ helper?.isTerminated != false }) { try? FileManager.default.removeItem(at: directory) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: helperURL)
            let info = helperURL.appendingPathComponent("Contents/Info.plist")
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as! [String: Any]
            plist["CFBundleIdentifier"] = "es.fxgam.steamac.cursor-helper." + token
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--deep", "--sign", "-", helperURL.path]
            try sign.run()
            sign.waitUntilExit()
            guard sign.terminationStatus == 0 else { return ["cursor test helper could not be signed"] }
        } catch { return ["cursor test helper could not be prepared: \(error)"] }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--selftest-cursor", "--no-crash-reports"]
        configuration.environment = ["STEAMAC_CURSOR_TEST_PARENT": String(ProcessInfo.processInfo.processIdentifier),
                                     "STEAMAC_CURSOR_TEST_ID": token, "STEAMAC_SENTRY": "0",
                                     "STEAMAC_DEFAULTS_DOMAIN": "steamac.cursor-test." + token]
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { running, _ in helper = running }
        guard InputSelfTest.wait({ helper != nil && ready }), let helper else { return ["cursor test helper did not start"] }
        for attempt in 1...3 {
            if attempt == 2 {
                wc.grabPointer()
                if !wc.pointerCaptured { return ["app-switch capture fixture failed"] }
            }
            app.yieldActivation(to: helper)
            notifications.postNotificationName(.init("steamac.cursor-test.command"), object: token, userInfo: ["action": "activate"], deliverImmediately: true)
            guard InputSelfTest.wait({ helper.isActive && !app.isActive }) else { return failures + ["app-switch \(attempt) did not leave the test app, active=\(app.isActive), helper=\(helper.isActive)"] }
            expect(true, "native helper did not restore the Mac cursor", stable: true)
            notifications.postNotificationName(.init("steamac.cursor-test.command"), object: token, userInfo: ["action": "return"], deliverImmediately: true)
            guard InputSelfTest.wait({ app.isActive && wc.window.isKeyWindow }) else { return failures + ["app-switch \(attempt) did not return to the test app, active=\(app.isActive), key=\(wc.window.isKeyWindow)"] }
            wc.window.orderFront(nil)
            guard InputSelfTest.wait({ NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == wc.window.windowNumber }) else { return failures + ["app-switch test did not uncover the guest picture: point=\(NSEvent.mouseLocation), frame=\(wc.window.frame), top=\(NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)), expected=\(wc.window.windowNumber)"] }
            expect(false, "app switch \(attempt) restores the extra cursor without mouse movement", stable: true)
            var clicks = 0
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in
                if event.window === wc.window { clicks += 1 }
                return event
            }) else { return ["click monitor could not start"] }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return ["click event could not be created"] }
                app.postEvent(event, atStart: false)
            }
            let delivered = InputSelfTest.wait({ clicks == 2 })
            NSEvent.removeMonitor(monitor)
            if !delivered { failures.append("clicks did not reach the test window") }
            expect(false, "click \(attempt) restores the extra cursor", stable: true)
        }
        native.makeKeyAndOrderFront(nil)
        guard InputSelfTest.wait({ native.isKeyWindow }) else { return failures + ["native focus fixture failed"] }
        wc.window.makeKeyAndOrderFront(nil)
        NSCursor.arrow.set()
        expect(false, "returning focus does not restore the guest cursor after a system cursor reset", stable: true)
        let menu = NSMenu()
        menu.addItem(withTitle: "Cursor test", action: nil, keyEquivalent: "")
        let tracking = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { _ in
            DispatchQueue.main.async { menu.cancelTracking() }
        }
        menu.popUp(positioning: nil, at: center, in: wc.view)
        NotificationCenter.default.removeObserver(tracking)
        expect(false, "closing a native menu restores the extra cursor", stable: true)
        NSCursor.arrow.set()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            app.sendEvent(event)
        }
        expect(false, "a click does not restore the guest cursor after a system cursor reset", stable: true)
        let panel = NSPanel(contentRect: wc.window.convertToScreen(NSRect(x: center.x - 50, y: center.y - 30, width: 100, height: 60)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSButton(title: "Native", target: nil, action: nil)
        panel.orderFront(nil)
        guard InputSelfTest.wait({ wc.window.isKeyWindow && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == panel.windowNumber }) else { return failures + ["native panel fixture is not over the pointer"] }
        NSCursor.arrow.set()
        wc.view.refreshHostCursor()
        expect(true, "cursor refresh hides the pointer over a native panel", stable: true)
        panel.orderOut(nil)
        wc.view.refreshHostCursor()
        expect(false, "closing a native panel leaves the extra cursor", stable: true)
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
