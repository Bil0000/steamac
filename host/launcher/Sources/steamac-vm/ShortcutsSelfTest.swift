import AppKit
import Carbon.HIToolbox
import CKrun

enum ShortcutsSelfTest {
    static func run() -> Never {
        let failures = check()
        failures.forEach { log("shortcuts selftest: FAIL \($0)") }
        log(failures.isEmpty ? "shortcuts selftest: PASS" : "shortcuts selftest: \(failures.count) FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func check() -> [String] {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = saved
        arguments["NSUserKeyEquivalents"] = [String(localized: "Paste"): "@~p", String(localized: "Copy"): "@~k"]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let app = SteamacApplication.shared as! SteamacApplication
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let previous = NSWorkspace.shared.frontmostApplication
        MainMenu.installMinimal()
        let keyboard = InputDevices.keyboard()
        let provider = keyboard.makeEventProvider()
        var instance: UnsafeMutableRawPointer?
        precondition(provider.create!(&instance, provider.create_userdata, nil) == 0)
        let wc = WindowController(title: "Shortcut test", width: 800, height: 500, renderer: Renderer(),
                                  inputs: VMInputs(keyboard: keyboard, tablet: InputDevices.tablet(), mouse: InputDevices.mouse()),
                                  mouseMode: .auto)
        app.router = wc
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let native = NSWindow(contentRect: field.frame, styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = field
        defer {
            wc.releaseAll()
            app.router = nil
            wc.window.orderOut(nil)
            native.orderOut(nil)
            defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        func key(_ type: NSEvent.EventType, _ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, window: NSWindow? = nil) {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: (window ?? wc.window).windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: repeatKey, keyCode: UInt16(code))!
            app.sendEvent(e)
        }
        func drain() -> [(UInt16, UInt32)] {
            var events: [(UInt16, UInt32)] = []
            var e = krun_input_event()
            while provider.vtable.next_event!(instance, &e) == 1 { if e.type == EV.KEY { events.append((e.code, e.value)) } }
            return events
        }
        func held(_ events: [(UInt16, UInt32)]) -> Set<UInt16> {
            var keys = Set<UInt16>()
            for (code, value) in events { if value == 1 { keys.insert(code) } else { keys.remove(code) } }
            return keys
        }
        func activeAt(_ events: [(UInt16, UInt32)], _ code: UInt16) -> Set<UInt16>? {
            var held = Set<UInt16>()
            for (key, value) in events {
                if value == 1 { held.insert(key) } else { held.remove(key) }
                if key == code && value == 1 { return held }
            }
            return nil
        }
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        let commandOption = NSEvent.ModifierFlags(rawValue: command.rawValue | NSEvent.ModifierFlags.option.rawValue | 0x20)
        let option = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        wc.show()
        guard InputSelfTest.wait({ app.isActive && wc.window.isKeyWindow }) else { return ["test window did not become active"] }
        _ = drain()
        key(.flagsChanged, kVK_Command, "", command)
        key(.flagsChanged, kVK_Option, "", commandOption)
        key(.keyDown, kVK_ANSI_P, "p", commandOption)
        key(.keyUp, kVK_ANSI_P, "p", commandOption)
        key(.flagsChanged, kVK_Option, "", command)
        key(.flagsChanged, kVK_Command, "")
        var paste = drain()
        _ = InputSelfTest.wait { paste += drain(); return activeAt(paste, KEY.V) != nil }
        expect(activeAt(paste, KEY.V) == [KEY.LEFTCTRL, KEY.V], "custom Mac Paste did not send a clean guest Paste: \(paste)")
        expect(!paste.contains { $0.0 == KEY.P && $0.1 == 1 }, "custom Paste leaked its physical key")
        expect(held(paste).isEmpty, "custom Paste left keys held")
        key(.keyDown, kVK_ANSI_K, "k", commandOption)
        key(.keyUp, kVK_ANSI_K, "k", commandOption)
        var copied = drain()
        _ = InputSelfTest.wait { copied += drain(); return activeAt(copied, KEY.C) != nil }
        expect(activeAt(copied, KEY.C) == [KEY.LEFTCTRL, KEY.C], "custom Mac Copy was ignored: \(copied)")
        for (code, chars, flags, expected) in [
            (kVK_ANSI_F, "f", command, [KEY.LEFTCTRL, KEY.F]),
            (kVK_ANSI_X, "x", command, [KEY.LEFTCTRL, KEY.X]),
            (kVK_ANSI_A, "a", command, [KEY.LEFTCTRL, KEY.A]),
            (kVK_ANSI_Z, "z", command, [KEY.LEFTCTRL, KEY.Z]),
            (kVK_ANSI_Z, "Z", command.union(.shift), [KEY.LEFTCTRL, KEY.LEFTSHIFT, KEY.Z]),
        ] {
            key(.keyDown, code, chars, flags)
            key(.keyUp, code, chars, flags)
            var events = drain()
            _ = InputSelfTest.wait { events += drain(); return activeAt(events, expected.last!) != nil }
            expect(activeAt(events, expected.last!) == Set(expected), "native edit action failed: \(chars)")
        }
        for (code, text) in [(kVK_ANSI_V, "v"), (kVK_ANSI_F, "f"), (kVK_ANSI_A, "a"), (kVK_ANSI_D, "d")] {
            let control = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)
            key(.flagsChanged, kVK_Control, "", control)
            key(.keyDown, code, text, control)
            key(.keyUp, code, text, control)
            key(.flagsChanged, kVK_Control, "")
            expect(activeAt(drain(), Keymap.linuxKey(UInt16(code))!) == [KEY.LEFTCTRL, Keymap.linuxKey(UInt16(code))!], "Control shortcut changed: \(text)")
        }
        key(.flagsChanged, kVK_Command, "", command)
        key(.keyDown, kVK_ANSI_9, "9", command)
        key(.keyUp, kVK_ANSI_9, "9", command)
        key(.flagsChanged, kVK_Command, "")
        expect(activeAt(drain(), KEY._9) == [KEY.LEFTMETA, KEY._9], "unbound Command key was lost")
        for (code, text) in [(kVK_LeftArrow, "\u{f702}"), (kVK_Return, "\r"), (kVK_Tab, "\t"), (kVK_Escape, "\u{1b}"), (kVK_Delete, "\u{7f}")] {
            key(.keyDown, code, text)
            expect(drain().map { "\($0.0):\($0.1)" } == ["\(Keymap.linuxKey(UInt16(code))!):1"], "plain key no longer stays held: \(code)")
            key(.keyUp, code, text)
            expect(drain().map { "\($0.0):\($0.1)" } == ["\(Keymap.linuxKey(UInt16(code))!):0"], "plain key release changed: \(code)")
        }
        wc.guestFocusChanged(.desktop(width: 1280, height: 800))
        key(.flagsChanged, kVK_Command, "", command)
        key(.keyDown, kVK_ANSI_X, "x", command)
        key(.keyUp, kVK_ANSI_X, "x", command)
        key(.flagsChanged, kVK_Command, "")
        var desktopCut = drain()
        _ = InputSelfTest.wait { desktopCut += drain(); return activeAt(desktopCut, KEY.X) != nil }
        expect(activeAt(desktopCut, KEY.X) == [KEY.LEFTCTRL, KEY.X], "Desktop native Cut failed")
        expect(!desktopCut.contains { $0.0 == KEY.LEFTMETA }, "Desktop native Cut emits a Meta tap")
        key(.flagsChanged, kVK_Command, "", command)
        wc.performGuestEdit(Selector(("cut:")))
        key(.flagsChanged, kVK_Command, "")
        let directCut = drain()
        expect(activeAt(directCut, KEY.X) == [KEY.LEFTCTRL, KEY.X] && !directCut.contains { $0.0 == KEY.LEFTMETA }, "direct Desktop menu action emits a Meta tap")
        key(.flagsChanged, kVK_Command, "", command)
        key(.keyDown, kVK_ANSI_9, "9", command)
        key(.keyUp, kVK_ANSI_9, "9", command)
        key(.flagsChanged, kVK_Command, "")
        let desktopRaw = drain()
        expect(activeAt(desktopRaw, KEY._9) == [KEY.LEFTMETA, KEY._9], "unmapped Desktop Meta chord changed")
        expect(desktopRaw.filter { $0.0 == KEY.LEFTMETA }.count == 2 && held(desktopRaw).isEmpty, "unmapped Desktop Meta chord leaves extra events")
        key(.flagsChanged, kVK_Command, "", command)
        key(.flagsChanged, kVK_Command, "")
        expect(drain().map { "\($0.0):\($0.1)" } == ["\(KEY.LEFTMETA):1", "\(KEY.LEFTMETA):0"], "Desktop Super tap was lost")
        key(.flagsChanged, kVK_Command, "", command)
        wc.releaseAll()
        key(.flagsChanged, kVK_Command, "")
        expect(drain().isEmpty, "focus cleanup emits a deferred Meta tap")
        key(.flagsChanged, kVK_Command, "", command)
        wc.guestFocusChanged(.steam)
        key(.flagsChanged, kVK_Command, "")
        expect(drain().isEmpty, "focus change emits a deferred Meta tap")
        wc.guestFocusChanged(.desktop(width: 1280, height: 800))
        key(.flagsChanged, kVK_Option, "", option)
        key(.keyDown, kVK_LeftArrow, "\u{f702}", option)
        key(.keyUp, kVK_LeftArrow, "\u{f702}", option)
        key(.flagsChanged, kVK_Option, "")
        expect(activeAt(drain(), KEY.LEFT) == [KEY.LEFTALT, KEY.LEFT], "Desktop game controls were translated")
        wc.guestFocusChanged(.steam)
        key(.flagsChanged, kVK_Option, "", option)
        key(.keyDown, kVK_LeftArrow, "\u{f702}", option)
        key(.keyUp, kVK_LeftArrow, "\u{f702}", option)
        key(.flagsChanged, kVK_Option, "")
        expect(activeAt(drain(), KEY.LEFT) == [KEY.LEFTCTRL, KEY.LEFT], "Mac word navigation was ignored")
        key(.flagsChanged, kVK_Command, "", command)
        key(.keyDown, kVK_LeftArrow, "\u{f702}", command)
        key(.keyUp, kVK_LeftArrow, "\u{f702}", command)
        key(.flagsChanged, kVK_Command, "")
        expect(activeAt(drain(), KEY.HOME) == [KEY.HOME], "Mac line navigation was ignored")
        key(.keyDown, kVK_ANSI_A, "a")
        key(.keyDown, kVK_ANSI_A, "a", repeatKey: true)
        key(.keyUp, kVK_ANSI_A, "a")
        expect(drain().map { "\($0.0):\($0.1)" } == ["\(KEY.A):1", "\(KEY.A):0"], "plain typing or guest autorepeat changed")
        let shift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
        key(.flagsChanged, kVK_Shift, "", shift)
        let center = NSPoint(x: wc.view.bounds.midX, y: wc.view.bounds.midY)
        for (type, down) in [(NSEvent.EventType.leftMouseDown, true), (.leftMouseUp, false)] {
            let click = NSEvent.mouseEvent(with: type, location: center, modifierFlags: shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: wc.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            wc.pointerButton(click, down: down)
        }
        key(.flagsChanged, kVK_Shift, "")
        expect(drain().map { "\($0.0):\($0.1)" } == ["\(KEY.LEFTSHIFT):1", "\(KEY.LEFTSHIFT):0"], "Shift-click lost its modifier")
        let control = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)
        key(.flagsChanged, kVK_Control, "", control)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)!
        scroll.location = CGPoint(x: center.x, y: NSScreen.screens[0].frame.maxY - center.y)
        let scrollEvent = NSEvent(cgEvent: scroll)!
        expect(wc.view.fitRect.contains(scrollEvent.locationInWindow), "scroll fixture is outside the picture")
        wc.scroll(scrollEvent)
        key(.flagsChanged, kVK_Control, "")
        expect(drain().map { "\($0.0):\($0.1)" } == ["\(KEY.LEFTCTRL):1", "\(KEY.LEFTCTRL):0"], "Control-scroll lost its modifier")
        wc.guestFocusChanged(.game(4242))
        key(.flagsChanged, kVK_Command, "", command)
        key(.flagsChanged, kVK_Option, "", commandOption)
        key(.keyDown, kVK_ANSI_P, "p", commandOption)
        key(.keyUp, kVK_ANSI_P, "p", commandOption)
        key(.flagsChanged, kVK_Option, "", command)
        key(.flagsChanged, kVK_Command, "")
        expect(activeAt(drain(), KEY.P) == [KEY.LEFTMETA, KEY.LEFTALT, KEY.P], "game shortcut was intercepted by Edit menu")
        key(.flagsChanged, kVK_Option, "", option)
        key(.keyDown, kVK_LeftArrow, "\u{f702}", option)
        key(.keyUp, kVK_LeftArrow, "\u{f702}", option)
        key(.flagsChanged, kVK_Option, "")
        expect(activeAt(drain(), KEY.LEFT) == [KEY.LEFTALT, KEY.LEFT], "game controls were translated")
        wc.guestFocusChanged(.steam)
        wc.grabPointer()
        key(.flagsChanged, kVK_Option, "", option)
        key(.keyDown, kVK_LeftArrow, "\u{f702}", option)
        key(.keyUp, kVK_LeftArrow, "\u{f702}", option)
        key(.flagsChanged, kVK_Option, "")
        expect(activeAt(drain(), KEY.LEFT) == [KEY.LEFTALT, KEY.LEFT], "captured controls were translated")
        wc.releaseAll()
        _ = drain()
        native.makeKeyAndOrderFront(nil)
        native.makeFirstResponder(field)
        expect(InputSelfTest.wait({ native.isKeyWindow }), "native text window did not become key")
        field.string = "native text"
        field.setSelectedRange(NSRange(location: 0, length: 0))
        key(.keyDown, kVK_ANSI_A, "a", command, window: native)
        key(.keyUp, kVK_ANSI_A, "a", command, window: native)
        expect(field.selectedRange() == NSRange(location: 0, length: field.string.utf16.count), "native text editing was intercepted")
        expect(drain().isEmpty, "native text editing sent guest keys")
        wc.show()
        _ = InputSelfTest.wait({ wc.window.isKeyWindow })
        key(.flagsChanged, kVK_Command, "", command)
        key(.keyDown, kVK_ANSI_A, "a", command)
        wc.releaseAll()
        let cleanup = drain()
        expect(held(cleanup).isEmpty, "focus cleanup left keys held")
        let pointer = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(CGPoint(x: 1, y: 1))
        wc.guestFocusChanged(.game(4242))
        expect(wc.pointerCaptured, "game focus did not capture the mouse")
        expect(wc.view.bounds.contains(wc.view.convert(wc.window.mouseLocationOutsideOfEventStream, from: nil)),
               "auto-capture left the pointer outside the picture")
        native.makeKeyAndOrderFront(nil)
        expect(InputSelfTest.wait({ native.isKeyWindow }) && !wc.pointerCaptured, "another window did not release the mouse")
        wc.show()
        expect(InputSelfTest.wait({ wc.window.isKeyWindow }) && wc.pointerCaptured, "returning to the game window did not capture the mouse")
        wc.guestFocusChanged(.steam)
        expect(!wc.pointerCaptured, "leaving the game did not release the mouse")
        CGWarpMouseCursorPosition(CGPoint(x: pointer.x, y: NSScreen.screens[0].frame.maxY - pointer.y))
        return failures
    }
}
