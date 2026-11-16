import Combine
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import GameController
import QuartzCore

/// Routes key events to the guest before AppKit's key-equivalent/menu machinery (which would
/// otherwise swallow Cmd-combos and their keyUps).
final class SteamacApplication: NSApplication {
    weak var router: WindowController?

    override func sendEvent(_ event: NSEvent) {
        if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(event.type) { router?.cancelDeferredMetaTaps() }
        if let router, router.handleKeyEvent(event) { return }
        super.sendEvent(event)
    }
}

final class WindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: VMView
    private let inputs: VMInputs?
    private let mouseMode: MouseMode
    private let baseTitle: String
    var onCloseRequest: (() -> Void)?
    /// Launcher settings (live values: overlay, follow window size, mouse auto-capture).
    let settings: LauncherSettings
    private var subscriptions: [AnyCancellable] = []
    /// FX boot/shutdown overlay, layered over the Metal view.
    let overlay: OverlayView
    /// "Loading…" card shown when the guest GPU goes idle (StallMonitor), above the overlay.
    let stallView: StallIndicatorView
    private var stall: StallMonitor?
    /// Game-runtime setup status (`setup <code> [text]`) over the Steam UI, in the GPU-idle card's style.
    let setupView: StallIndicatorView
    private var setupStatus: (code: String, text: String)?
    /// "Restart Steam" on the setup card: host -> guest `restart-steam`.
    var onRestartSteam: (() -> Void)?
    /// Compact boot / shutdown progress while the full overlay is not up before `ready`, and the
    /// no-picture guard's report after it (bottom centre, above the GPU-idle card).
    let pill: ProgressPillView
    private var noPicture: NoPictureGuard?
    private var noPictureReport: NoPictureGuard.Report?
    /// "Game paused" (GamePause confirmed a frozen game), above everything else.
    let pauseView: PauseOverlayView
    /// App id shown as paused (nil = not paused).
    private(set) var pausedGame: Int? { didSet { window.invalidateCursorRects(for: view) } }
    /// "SteamOS is sleeping" (the guest went to sleep, SuspendController paused the VM).
    let sleepView: PauseOverlayView
    /// The guest sleeps: nothing reaches it; the first click, key or controller button wakes it.
    private(set) var guestAsleep = false { didSet { window.invalidateCursorRects(for: view) } }
    /// A click / key while the guest sleeps (argument: what it was, for the log).
    var onWakeRequest: ((String) -> Void)?
    /// "Resuming…" chip after a suspend, until the guest's next frame.
    let resumeChip: ResumeChipView
    /// Buttons whose press was swallowed (it resumed a paused game or woke the guest): their
    /// release is too.
    private var swallowedButtons = Set<UInt16>()
    /// Same for keys (macOS key codes) that woke the guest.
    private var swallowedKeys = Set<UInt16>()
    private var progress: BootProgress?
    /// The boot / shutdown overlay is collapsed into the pill (click / key, menu, 15 min); a new
    /// shutdown, the pill or the menu expands it again.
    private var overlayCollapsed = false
    /// Collapsed by View → Show Boot Progress or the 15-minute timeout: download-type stages do
    /// not re-expand it (a click / key collapse is undone when one starts).
    private var collapseIsSticky = false

    private var pressedKeys = Set<UInt16>()
    private var heldModifiers = Set<UInt16>()
    private var deferredMetaTaps = Set<UInt16>()
    private let keyBindings = GuestKeyBindings()
    private var tabletButtons = Set<UInt16>()
    private var mouseButtons = Set<UInt16>()
    private var lastAbs: (Int32, Int32) = (-1, -1)
    private var captured = false { didSet { window.invalidateCursorRects(for: view) } }
    /// Last reported presentation state; log changes, not every mouse motion / wmtr present.
    private var lastCursorPresentation: (captured: Bool, covered: Bool, hidden: Bool, overlay: Bool)?
    private var relRemainder = (0.0, 0.0)
    private var rawMouse = false
    private var mouseConnectObserver: NSObjectProtocol?
    /// Auto mode: where the guest cursor is (guest pixels); nil = unknown, re-anchor first.
    private var guestCursor: (Int, Int)?
    private var lastPointerMotion = Date.distantPast
    /// The surface gamescope moves the cursor on, in its pixels, as the agent reports it with
    /// each focus line (nil = not reported: the display).
    private var guestSurface: (Int, Int)?
    /// What the guest says has focus (progress agent `focus …`); Steam until told otherwise.
    private(set) var guestFocus: GuestFocus = .steam { didSet { window.invalidateCursorRects(for: view) } }
    private var wheelHiRemainder = (0.0, 0.0)   // (vertical, horizontal) in 1/120 notch units
    private var wheelLoAccum: (Int32, Int32) = (0, 0)
    private var scanoutSize: (Int, Int)
    /// Guest display should become (width, height) px: the window's content size in points times
    /// `pixelScale`.
    var onGuestSizeRequest: ((Int, Int) -> Void)?
    private var requestedGuestSize: (Int, Int)
    /// Guest display size at boot: the target while the guest does not follow the window.
    private let bootGuestSize: (Int, Int)
    /// The focused game's window size in guest pixels (`game-size`, progress agent); nil outside game focus.
    private var focusedGameSize: (Int, Int)?
    /// MetalFX factor limit per axis while a lower game resolution is shown (above it: bilinear).
    static let lowResMetalFXMaxRatio = 1.5
    private var preStreamGuestSize: (Int, Int)
    private var guestResizeWork: DispatchWorkItem?
    private var inFullScreenTransition = false
    static let minGuestSize = NSSize(width: 800, height: 500)
    /// Guest pixels per window point for this session (Settings > Display > Retina resolution:
    /// the screen's backing scale at boot, else 1) times the render scale (Settings > Display >
    /// "Render scale", below 1 to render fewer guest pixels for MetalFX to upscale).
    let pixelScale: Double
    /// This boot renders fewer guest pixels than the window (renderScale < 1): MetalFX super
    /// resolution is forced on so those pixels are upscaled with it instead of a plain blur.
    private let renderScaled: Bool
    /// Settle time after the last size change before the guest is asked to switch modes.
    static let guestResizeDebounce: TimeInterval = 0.25

    /// `width` x `height`: initial content size in points; the guest display is that times `pixelScale`.
    init(title: String, width: Int, height: Int, pixelScale: Double = 1, renderer: Renderer, inputs: VMInputs?,
         mouseMode: MouseMode) {
        self.inputs = inputs
        self.mouseMode = mouseMode
        self.baseTitle = title
        self.pixelScale = pixelScale
        self.renderScaled = pixelScale < 1
        let guest = WindowController.guestSize(points: CGSize(width: width, height: height), scale: pixelScale)
        self.scanoutSize = guest
        self.requestedGuestSize = guest
        self.bootGuestSize = guest
        self.preStreamGuestSize = guest
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let screen = WindowController.targetScreen()
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false, screen: screen)
        view = VMView(frame: rect, renderer: renderer, contentPixelSize: CGSize(width: guest.0, height: guest.1))
        overlay = OverlayView(frame: rect)
        stallView = StallIndicatorView(frame: rect)
        setupView = StallIndicatorView(frame: rect)
        pill = ProgressPillView(frame: rect)
        pauseView = PauseOverlayView(frame: rect)
        sleepView = PauseOverlayView(frame: rect, style: .sleeping)
        resumeChip = ResumeChipView(frame: rect)
        settings = LauncherSettings.shared
        super.init()
        window.title = title
        window.contentView = view
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentMinSize = WindowController.minGuestSize
        fitToScreen(width: width, height: height)
        window.center()
        view.controller = self
        overlay.frame = view.bounds
        view.addSubview(overlay)
        stallView.frame = view.bounds
        view.addSubview(stallView)
        setupView.frame = view.bounds
        view.addSubview(setupView)
        pill.frame = view.bounds
        view.addSubview(pill)
        pill.onClick = { [weak self] in self?.expandPill() }
        pill.clickable = { [weak self] in self.map { $0.bootOrShutdown && !$0.captured } ?? false }
        overlay.onVisibilityChange = { [weak self] _ in
            guard let self else { return }
            self.updateStallGate()
            self.updatePill()
            self.updateSetupCard()
            self.window.invalidateCursorRects(for: self.view)
        }
        stallView.onVisibilityChange = { [weak self] in self?.refreshHostCursor() }
        setupView.onVisibilityChange = { [weak self] in self?.refreshHostCursor() }
        pauseView.frame = view.bounds
        view.addSubview(pauseView)
        sleepView.frame = view.bounds
        view.addSubview(sleepView)
        resumeChip.frame = view.bounds
        view.addSubview(resumeChip)
        updateTitle()
        // @Published fires before the change: evaluate on the next main-queue turn.
        subscriptions.append(settings.$followWindowSize.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in
            log("display: follow window size \(on ? "on" : "off")")
            if on { self?.scheduleGuestResize() }
        })
        subscriptions.append(settings.$showOverlay.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in
            guard let self else { return }
            if !on { self.overlay.hide() }
            else if self.bootOrShutdown, !self.overlayCollapsed { self.overlay.show() }
        })
        subscriptions.append(settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if self.captured && self.mouseMode == .auto && !self.clickCaptures { self.releasePointer() }
            self.updateTitle()
        })
        // Only injected when enabled at boot; hiding an injected HUD cannot unload its handlers.
        applyMetalHUD(settings.metalHUD)
        subscriptions.append(settings.$metalHUD.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.applyMetalHUD(on)
        })
        applySuperResolution(settings.superResolution)
        subscriptions.append(settings.$superResolution.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.applySuperResolution(on)
        })
        subscriptions.append(settings.$upscaleLowerResolutions.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshLowerResolution()
        })
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self.view)
        NSApp.activate()
    }

    /// The screen the window opens on: the one of the previous boot's window (guest reboot),
    /// else the one under the mouse pointer, else the main screen.
    static func targetScreen() -> NSScreen? {
        if let f = Supervisor.windowFrame, !f.isEmpty {
            let r = NSRectFromString(f)
            if let s = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: r.midX, y: r.midY), $0.frame, false) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Initial content size: the requested size in points (Retina: 2x2 physical pixels each), shrunk
    /// to fit the screen's visible area below the title bar. Also the basis of the default EDID size.
    static func initialContentSize(width: Int, height: Int, screen: NSScreen?) -> NSSize {
        var size = NSSize(width: width, height: height)
        if let vf = screen?.visibleFrame {
            let chrome = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size),
                                            styleMask: [.titled, .closable, .miniaturizable, .resizable]).height - size.height
            let s = min(1, vf.width / size.width, (vf.height - chrome) / size.height)
            size = NSSize(width: (size.width * s).rounded(.down), height: (size.height * s).rounded(.down))
        }
        return size
    }

    private func fitToScreen(width: Int, height: Int) {
        window.setContentSize(WindowController.initialContentSize(width: width, height: height,
                                                                  screen: window.screen ?? NSScreen.main))
    }

    /// The guest switched its scanout size. The window does not follow (the guest follows the
    /// window); frames of any size are scaled to fit, so old-size frames bridge the switch.
    func scanoutResized(width: Int, height: Int) {
        view.contentPixelSize = CGSize(width: width, height: height)
        scanoutSize = (width, height)
        updateUpscaleCap()
        view.redraw()
        refreshHostCursor()   // the black bars moved
    }

    /// Lower game resolution (Settings > Display > "Upscale lower game resolutions"): the guest
    /// game's own window size as reported by the progress agent. Nil = unknown / not in game focus.
    func guestGameSize(width: Int, height: Int) {
        focusedGameSize = (width & ~1, height & ~1)
        log("display: focused game renders \(width)x\(height)")
        refreshLowerResolution()
    }

    /// The guest display size wanted now: the window's (the boot size when it does not follow the
    /// window), or the focused game's own size while that is smaller than it on both axes and the
    /// setting is on. The window never changes for it: the Mac upscales the smaller picture.
    func desiredGuestSize() -> (Int, Int) {
        let base = settings.followWindowSize ? guestSizeForWindow() : bootGuestSize
        guard settings.upscaleLowerResolutions, focusedGame != nil, let g = focusedGameSize,
              g != base, g.0 >= 320, g.1 >= 200, g.0 <= base.0, g.1 <= base.1 else { return base }
        return g
    }

    /// Re-evaluate the lower-resolution mode after a focus, game size or setting change.
    private func refreshLowerResolution() {
        updateUpscaleCap()
        scheduleGuestResize()
    }

    /// MetalFX up to `lowResMetalFXMaxRatio` per axis only while the shown scanout is the focused
    /// game's own size with the setting on; nil otherwise (the renderer's existing path, unchanged).
    private func updateUpscaleCap() {
        let lower = settings.upscaleLowerResolutions && focusedGame != nil
            && focusedGameSize.map { $0 == scanoutSize } == true
        let cap: Double? = lower ? WindowController.lowResMetalFXMaxRatio : nil
        guard view.renderer.upscaleCap != cap else { return }
        view.renderer.upscaleCap = cap
        view.redraw()
        refreshHostCursor()   // the black bars moved
    }

    /// Guest size for the current window: content size in points times `pixelScale`.
    func guestSizeForWindow() -> (Int, Int) {
        WindowController.guestSize(points: view.bounds.size, scale: pixelScale)
    }

    /// Guest display size for a content size in points at `scale` guest pixels per point: rounded
    /// down to even, at least `minGuestSize`, at most VM.maxDisplaySide per side (a scale above 1
    /// is lowered, keeping the aspect, until the longer side fits). Below 1 (`renderScale`) the
    /// guest renders fewer pixels than the window for MetalFX super resolution to upscale.
    static func guestSize(points: CGSize, scale: Double) -> (Int, Int) {
        let maxSide = VM.maxDisplaySide & ~1
        let pw = max(minGuestSize.width, points.width), ph = max(minGuestSize.height, points.height)
        let s = min(max(0.25, scale), Double(maxSide) / Double(max(pw, ph)))
        return (min(maxSide, Int(Double(pw) * s) & ~1), min(maxSide, Int(Double(ph) * s) & ~1))
    }

    /// Set while the VM is paused (suspended, guest asleep): window size changes (leaving full
    /// screen before the window hides, resizes while it sleeps) do not resize the guest until it
    /// runs again.
    var holdGuestSize = false {
        didSet {
            if oldValue && !holdGuestSize {
                if restoreStreamDisplay { endStreamDisplay() } else { scheduleGuestResize() }
            }
        }
    }
    /// Separate from the suspend hold: ending a stream must not release a paused VM's hold.
    private var streamHoldsGuestSize = false
    private var restoreStreamDisplay = false

    func beginStreamDisplay(width: Int, height: Int) {
        if !streamHoldsGuestSize && !restoreStreamDisplay { preStreamGuestSize = requestedGuestSize }
        streamHoldsGuestSize = true
        restoreStreamDisplay = false
        guestResizeWork?.cancel()
        requestedGuestSize = (width, height)
        onGuestSizeRequest?(width, height)
    }

    func endStreamDisplay() {
        guard streamHoldsGuestSize || restoreStreamDisplay else { return }
        streamHoldsGuestSize = false
        restoreStreamDisplay = holdGuestSize
        guard !holdGuestSize else { return }
        let size = settings.followWindowSize ? desiredGuestSize() : preStreamGuestSize
        requestedGuestSize = size
        onGuestSizeRequest?(size.0, size.1)
    }
    /// One-shot: the window has left full screen.
    var onDidExitFullScreen: (() -> Void)?

    /// Debounced: never during a live drag or a fullscreen transition (the last frame is scaled
    /// meanwhile); fires once the size has been stable for `guestResizeDebounce`.
    private func scheduleGuestResize() {
        guestResizeWork?.cancel()
        // Also while a lower game size is shown: turning the option off must send the boot size back.
        guard settings.followWindowSize || settings.upscaleLowerResolutions || requestedGuestSize != bootGuestSize
        else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.window.inLiveResize, !self.inFullScreenTransition,
                  !self.holdGuestSize, !self.streamHoldsGuestSize else { return }
            let size = self.desiredGuestSize()
            guard size != self.requestedGuestSize else { return }
            self.requestedGuestSize = size
            self.onGuestSizeRequest?(size.0, size.1)
        }
        guestResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowController.guestResizeDebounce, execute: work)
    }

    func windowDidEndLiveResize(_ notification: Notification) { scheduleGuestResize() }

    /// Programmatic / zoom-button resizes (no live resize session).
    func windowDidResize(_ notification: Notification) {
        if !window.inLiveResize && !inFullScreenTransition { scheduleGuestResize() }
        refreshHostCursor()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        scheduleGuestResize()
        refreshHostCursor()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        scheduleGuestResize()
        refreshHostCursor()
        if let done = onDidExitFullScreen {
            onDidExitFullScreen = nil
            done()
        }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { inFullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { inFullScreenTransition = false }

    func setStatus(_ status: String?) {
        let title = status.map { String(localized: "\(baseTitle) — \($0)", comment: "Window title: app name and current status") } ?? baseTitle
        if window.title != title { window.title = title }
    }

    /// Before `ready` and during shutdown / reboot the title mirrors the progress
    /// ("Downloading Steam update 70%", "Starting Steam…", "Shutting down…").
    private func updateTitle() {
        if guestAsleep {
            setStatus(String(localized: "sleeping — click to wake"))
        } else if pausedGame != nil {
            setStatus(String(localized: "paused", comment: "Window status: the game is paused"))
        } else if let s = progress.flatMap({ WindowController.progressStatus($0.state) }) {
            setStatus(captured ? String(localized: "\(s) — mouse captured, Ctrl+Option releases") : s)
        } else if captured {
            setStatus(String(localized: "mouse captured — Ctrl+Option releases"))
        } else if inputs != nil && clickCaptures {
            setStatus(String(localized: "click to capture the mouse"))
        } else {
            setStatus(nil)
        }
    }

    /// Window-title status for a boot / shutdown progress state; nil once Steam is ready.
    static func progressStatus(_ s: ProgressState) -> String? {
        let ellipsized = s.title.hasSuffix("…") || s.title.hasSuffix(".") ? s.title : s.title + "…"
        switch s.phase {
        case .running: return nil
        case .shutdown: return ellipsized
        case .boot:
            guard !s.indeterminate, s.fraction > 0 else { return ellipsized }
            let t = s.title.hasSuffix("…") ? String(s.title.dropLast()) : s.title
            return String(localized: "\(t) \(Int((s.fraction * 100).rounded(.down)))%")
        }
    }

    /// GamePause: the guest confirmed `appid` frozen (nil: running again). The card stays off
    /// while the boot/shutdown overlay is up or the guest sleeps.
    func gamePaused(_ appid: Int?) {
        pausedGame = appid
        if let appid, !overlay.shown, !guestAsleep {
            pauseView.show(gameName: settings.gameName(appid))
        } else {
            pauseView.hide()
            captureIfGameActive()
        }
        updateTitle()
        updateNoPictureGate()
        refreshHostCursor()
    }

    /// SuspendController: the guest went to sleep (VM paused) / woke up. "Game paused" gives way
    /// to "SteamOS is sleeping" (GamePause freezes the game again after the wake if it still should).
    func guestSleeping(_ asleep: Bool) {
        guestAsleep = asleep
        if asleep {
            pauseView.hide(animated: false)
            sleepView.show(gameName: nil)
        } else {
            sleepView.hide()
            captureIfGameActive()
        }
        refreshHostCursor()
        updateTitle()
        updateNoPictureGate()
    }

    /// First click / key while the guest sleeps: wake it (the event itself is swallowed).
    private func wakeGuest(_ what: String) {
        log("input: \(what) wakes SteamOS (not sent to the guest)")
        onWakeRequest?(what)
    }

    // MARK: overlay

    /// Boot / shutdown progress always stays on screen until `ready`: the full overlay, or the
    /// compact pill once the user clicked / pressed a key in the window (or after 15 minutes, or
    /// with Settings > General's overlay off). Clicking the pill or View > Show Boot Progress
    /// expands it again; a shutdown / reboot starts with the full overlay again. Provisioning and
    /// the Steam client download / install keep the full overlay up (`keepOverlayStages`).
    func attach(progress: BootProgress) {
        self.progress = progress
        overlay.update(progress.state)
        let previous = progress.onChange
        progress.onChange = { [weak self] s in previous?(s); self?.progressChanged(s) }
        let previousFocus = progress.onFocus
        progress.onFocus = { [weak self] f in previousFocus?(f); self?.guestFocusChanged(f) }
        progress.onGameSize = { [weak self] w, h in self?.guestGameSize(width: w, height: h) }
        progress.onFocusSurface = { [weak self] s in self?.guestSurfaceChanged(s) }
        let previousCursor = progress.onCursorVisible
        progress.onCursorVisible = { [weak self] v in previousCursor?(v); self?.view.guestCursorVisibility(v) }
        let previousCursorImage = progress.onCursorImage
        progress.onCursorImage = { [weak self] w, h, xhot, yhot, bgra in
            previousCursorImage?(w, h, xhot, yhot, bgra)
            self?.view.guestCursorImage(width: w, height: h, xhot: xhot, yhot: yhot, bgra: bgra)
        }
        let previousCursorPosition = progress.onCursorPosition
        progress.onCursorPosition = { [weak self] x, y, w, h in
            previousCursorPosition?(x, y, w, h)
            self?.view.guestCursorPosition(x: x, y: y, windowWidth: w, windowHeight: h)
        }
        progress.onSetup = { [weak self] code, text in self?.setupChanged(code: code, text: text) }
        let previousReady = progress.onReady
        progress.onReady = { [weak self] in previousReady?(); self?.overlay.hide() }
        let previousShutdown = progress.onShutdown
        progress.onShutdown = { [weak self] reboot in
            previousShutdown?(reboot)
            guard let self else { return }
            self.overlayCollapsed = false
            self.collapseIsSticky = false
            if self.settings.showOverlay { self.overlay.show() }
            self.pauseView.hide(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60) { [weak self] in
            guard let self, let p = self.progress, p.state.phase == .boot, self.overlay.shown else { return }
            self.collapseOverlay("still booting after 15 min", sticky: true)
        }
        updatePill()
        updateTitle()
    }

    private func progressChanged(_ s: ProgressState) {
        overlay.update(s)
        // Entering a download-type stage after a click / key collapsed the overlay: full overlay again.
        if s.phase == .boot, Self.keepOverlayStages.contains(s.stageId), overlayCollapsed, !collapseIsSticky,
           settings.showOverlay, !overlay.shown {
            overlayCollapsed = false
            log("overlay: expanded for \(s.stageId)")
            overlay.show()
        }
        updatePill()
        updateTitle()
        updateNoPictureGate()
        updateSetupCard()
    }

    /// Booting or shutting down (not `ready` yet, or no longer).
    private var bootOrShutdown: Bool { progress.map { $0.state.phase != .running } ?? false }

    /// The pill shows the boot / shutdown progress whenever the full overlay is not up, else the
    /// no-picture guard's report (after `ready`); hidden (fading) otherwise.
    private func updatePill() {
        let content: ProgressPillView.Content?
        if overlay.shown {
            content = nil
        } else if let p = progress?.state, p.phase != .running {
            content = ProgressPillView.Content(p)
        } else if let r = noPictureReport, !r.game {
            content = ProgressPillView.Content(title: r.title, detail: r.detail, fraction: nil)
        } else {
            content = nil
        }
        if let content {
            pill.update(content)
            pill.show()
        } else {
            pill.hide()
        }
        refreshHostCursor()
    }

    /// `setup <code> [text]` from the guest agent; unknown codes are ignored.
    private func setupChanged(code: String, text: String) {
        guard ["preparing", "installed", "need-tools", "need-restart", "failed", "off"].contains(code) else {
            log("setup: ignoring unknown status \(code)")
            return
        }
        log("setup: \(code)" + (text.isEmpty ? "" : " \(text)"))
        setupStatus = (code, text)
        updateSetupCard()
    }

    /// The setup card shows over the Steam UI after `ready` (never over a game, the desktop or the overlay).
    private func updateSetupCard() {
        let shown = progress?.state.phase == .running && !overlay.shown && guestFocus == .steam
        var title: String?
        var restart = false
        switch shown ? setupStatus?.code : nil {
        case "preparing": title = String(localized: "Setting up game support…")
        case "need-tools":
            let tools = ListFormatter.localizedString(byJoining: setupStatus!.text.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            title = String(localized: "Install \(tools) in Steam to play games with anti-cheat", comment: "Card over the Steam UI: Steam tool names")
        case "need-restart":
            title = String(localized: "Restart Steam to finish setting up")
            restart = true
        case "failed": title = String(localized: "Game support could not be set up")
        default: break
        }
        guard let title else {
            setupView.actions = []
            setupView.showsReportLink = false
            return setupView.hide()
        }
        setupView.showsSpinner = setupStatus?.code == "preparing"
        setupView.showsReportLink = setupStatus?.code == "failed"
        setupView.actions = restart ? [(String(localized: "Restart Steam", comment: "Button: restart the Steam client in SteamOS"), { [weak self] in
            self?.setupStatus = nil
            self?.updateSetupCard()
            self?.onRestartSteam?()
        })] : []
        setupView.update(title: title, detail: "")
        setupView.show()
    }

    /// Full overlay → pill (the progress stays on screen; input goes through). `sticky`: the menu
    /// or the timeout, which download-type stages respect until `ready`.
    private func collapseOverlay(_ why: String, sticky: Bool = false) {
        guard overlay.shown else { return }
        if bootOrShutdown {
            overlayCollapsed = true
            collapseIsSticky = sticky
            log("overlay: collapsed to pill (\(why))")
        }
        overlay.hide()
    }

    /// Click on the pill: back to the full overlay.
    private func expandPill() {
        guard bootOrShutdown, !overlay.shown else { return }
        overlayCollapsed = false
        collapseIsSticky = false
        log("overlay: expanded from pill (click)")
        overlay.show()
    }

    /// Menu "Show Boot Progress": expand the pill / collapse the overlay (after `ready`: show / hide
    /// the overlay).
    func toggleOverlay() {
        if overlay.shown {
            collapseOverlay("menu", sticky: true)
        } else {
            if bootOrShutdown { log("overlay: expanded from pill (menu)") }
            overlayCollapsed = false
            collapseIsSticky = false
            overlay.show()
        }
    }

    /// Menu "Show Metal Performance HUD" / Ctrl+Cmd+P: flips the setting (persisted, Settings > Display).
    func toggleMetalHUD() {
        // Both callers are AppKit's main-thread menu/event dispatch, even though this
        // controller predates actor annotations.
        MainActor.assumeIsolated {
            guard settings.metalHUD || MetalHUD.confirmEnable(current: settings.metalHUD, nextDriver: settings.vulkanDriver) else { return }
            settings.metalHUD.toggle()
        }
    }

    private func applyMetalHUD(_ on: Bool) {
        let shown = MetalHUD.visible(requested: on)
        view.metalHUD = shown
        CrashReporting.metalHUDChanged()
        log("display: Metal Performance HUD \(shown ? "on" : "off") (library \(MetalHUD.loaded ? "loaded" : "not loaded"))")
        if on && MetalHUD.driver == .kosmickrisp { log("display: \(MetalHUD.kosmicKrispNote)") }
        if on && !shown { log("display: enabling the Metal Performance HUD requires a VM restart") }
        view.redraw()   // the HUD changes with the next present; an idle guest sends none
    }

    private func applySuperResolution(_ on: Bool) {
        let effective = on || renderScaled   // renderScale < 1 needs the upscaler to be useful
        view.renderer.superResolution = effective
        log("display: MetalFX super resolution \(effective ? "on" : "off")"
            + (effective && !Renderer.superResolutionSupported ? " (not supported on this GPU)" : "")
            + (renderScaled ? " (forced by render scale < 1)" : ""))
        view.redraw()   // an idle guest sends no new frame
    }

    /// The GPU-idle indicator follows `ready`, the overlay (never while it is up or the guest shuts
    /// down), game focus, the guest heartbeat and Settings > General.
    func attach(stall: StallMonitor) {
        self.stall = stall
        stall.enabled = settings.showStallIndicator
        stall.game = focusedGame
        stall.onAsk = { [weak self] in self?.releasePointer() }
        stall.gameName = { [weak self] in self?.focusedGame.flatMap { self?.settings.gameName($0) } }
        if let progress {
            let previous = progress.onChange
            progress.onChange = { [weak self] s in previous?(s); self?.updateStallGate() }
            let previousAlive = progress.onAlive
            progress.onAlive = { [weak stall] ms, load, cpu in previousAlive?(ms, load, cpu); stall?.alive(uptimeMs: ms, load: load, gameCPU: cpu) }
        }
        subscriptions.append(settings.$showStallIndicator.dropFirst().receive(on: DispatchQueue.main).sink { [weak stall] on in
            log("stall: indicator \(on ? "on" : "off")")
            stall?.enabled = on
        })
        updateStallGate()
        stall.start()
    }

    private func updateStallGate() {
        guard let stall else { return }
        stall.suppressed = overlay.shown || bootOrShutdown
    }

    /// "Waiting for SteamOS to draw…" in the pill after `ready` (never during sleep, a paused game
    /// or a paused VM; `vmPaused` is set by the owner). A focused game's black picture goes to the
    /// GPU-idle card instead.
    func attach(noPicture: NoPictureGuard) {
        self.noPicture = noPicture
        if let progress {
            let previousAlive = progress.onAlive
            progress.onAlive = { [weak noPicture] ms, load, cpu in previousAlive?(ms, load, cpu); noPicture?.alive() }
            noPicture.lastKnown = { [weak progress] in
                progress.flatMap { $0.state.phase == .running ? $0.state.detail : nil }
            }
        }
        noPicture.onChange = { [weak self] report in
            self?.noPictureReport = report
            self?.stall?.gameDark = report?.game == true
            self?.updatePill()
        }
        updateNoPictureGate()
        noPicture.start()
    }

    private func updateNoPictureGate() {
        guard let noPicture else { return }
        noPicture.ready = progress.map { $0.state.phase == .running } ?? false
        noPicture.game = focusedGame
        noPicture.gamePaused = pausedGame != nil
        noPicture.asleep = guestAsleep
    }

    /// The user interacted with the guest: a visible overlay gets out of the way (input still goes
    /// through); before `ready` the progress stays on screen as the pill. While the guest downloads
    /// or installs the Steam client or provisions a new disk the overlay stays up: the guest shows
    /// nothing to interact with then (View → Show Boot Progress still collapses it).
    private func userInput(_ what: String) {
        guard overlay.shown else { return }
        if let p = progress?.state, p.phase == .boot, Self.keepOverlayStages.contains(p.stageId) { return }
        collapseOverlay(what)
    }

    /// Boot stages during which input does not collapse the overlay.
    private static let keepOverlayStages: Set<String> = ["provision", "steam-download", "steam-install"]

    /// Read back the next presented drawable; `composite` = drawable with the overlay, the
    /// GPU-idle indicator, the progress pill, the "Game paused" / "SteamOS is sleeping" cards and
    /// the "Resuming…" chip on top, at 2x.
    func captureWindow(_ done: @escaping (_ drawable: CGImage?, _ composite: CGImage?) -> Void) {
        let wasFramebufferOnly = view.metalLayer.framebufferOnly
        view.renderer.captureNextDraw = { [weak self] bytes, w, h in
            DispatchQueue.main.async {
                // Restore on the main thread: this callback runs on a Metal completion thread, and
                // the setting is the app's (the self-tests deliberately turn it off), not always true.
                self?.view.metalLayer.framebufferOnly = wasFramebufferOnly
                let drawable = PNG.image(bgra: bytes, width: w, height: h)
                guard let self else { return done(drawable, nil) }
                var composite = self.overlay.renderImage(scale: 2, under: drawable)
                composite = self.stallView.renderImage(scale: 2, under: composite)
                composite = self.setupView.renderImage(scale: 2, under: composite)
                composite = self.pill.renderLayerImage(scale: 2, under: composite)
                for v in [self.pauseView, self.sleepView, self.resumeChip] as [NSView] {
                    composite = v.renderLayerImage(scale: 2, under: composite)
                }
                done(drawable, composite)
            }
        }
        view.metalLayer.framebufferOnly = false   // readable drawable for this one capture
        view.redraw()
    }

    /// The window as the window server composites it, Metal HUD included (the HUD is not part of
    /// the drawable). CGWindowListCreateImage is unavailable in the macOS 15 SDK but still captures
    /// the process's own windows without Screen Recording permission; looked up at run time.
    func windowServerImage() -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }   // RTLD_DEFAULT
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest?()
        return false
    }

    /// The window's screen changed: the guest gets that screen's refresh rate (set when it follows the screen).
    var onScreenRefreshRate: ((Int) -> Void)?
    /// The window became visible (true) or hidden: minimized, fully covered, on another Space.
    /// Hiding is reported after `hideDelay`, so a Space swipe or Mission Control does not count.
    var onVisibleChange: ((Bool) -> Void)?
    private var hideWork: DispatchWorkItem?
    static let hideDelay: TimeInterval = 2
    func windowDidChangeOcclusionState(_ notification: Notification) {
        hideWork?.cancel()
        hideWork = nil
        guard window.occlusionState.contains(.visible) else {
            let work = DispatchWorkItem { [weak self] in self?.onVisibleChange?(false) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + WindowController.hideDelay, execute: work)
            return
        }
        onVisibleChange?(true)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let s = window.screen else { return }
        log("display: window on \"\(s.localizedName)\" (\(s.maximumFramesPerSecond) Hz, \(s.backingScaleFactor)x)")
        onScreenRefreshRate?(LauncherSettings.refreshRate(of: s))
    }
    func windowDidBecomeKey(_ notification: Notification) {
        refreshHostCursor()
        // Activated by a click: a click in the picture captures through pointerButton (not sent to the
        // game); one on the title bar may start a window drag, which a capture would freeze.
        let byClick = NSApp.currentEvent.map { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) } ?? false
        if !byClick { captureIfGameActive() }
    }
    func windowDidResignKey(_ notification: Notification) { releaseAll() }
    func windowDidMiniaturize(_ notification: Notification) { releaseAll() }

    // MARK: keyboard

    /// Returns true if the event was consumed (only while our window is key).
    func handleKeyEvent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp || e.type == .flagsChanged,
              e.window === window || (e.window == nil && window.isKeyWindow), window.isKeyWindow, window.firstResponder === view else { return false }
        return processKey(e)
    }

    /// Key/flags event -> host shortcut or guest evdev key.
    func processKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch e.type {
        case .keyDown:
            userInput("key")
            if MainMenu.performKeyEquivalent(with: e, editing: nativeEditing) { return true }
            if nativeTextBindings, !mods.contains(.control), !mods.intersection([.command, .option]).isEmpty,
               let commands = keyBindings.resolve(e) {
                sendGuestCommands(commands)
                return true
            }
            if e.isARepeat { return true }   // guest does autorepeat
            if guestAsleep {
                swallowedKeys.insert(e.keyCode)
                wakeGuest("key")
                return true
            }
            sendHeldModifiers()
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.insert(code).inserted { sendKey(code, true) }
            return true
        case .keyUp:
            if swallowedKeys.remove(e.keyCode) != nil || guestAsleep { return true }
            guard let code = Keymap.linuxKey(e.keyCode) else { return true }
            if pressedKeys.remove(code) != nil { sendKey(code, false) }
            return true
        default: // flagsChanged
            if guestAsleep { return true }   // modifiers alone do not wake it
            if Int(e.keyCode) == kVK_CapsLock {
                // macOS reports the lock *state*; evdev wants a key press each time.
                sendKey(KEY.CAPSLOCK, true)
                sendKey(KEY.CAPSLOCK, false)
            } else if let mask = Keymap.modifierMask(e.keyCode), let code = Keymap.linuxKey(e.keyCode) {
                let down = (UInt(e.modifierFlags.rawValue) & mask) != 0
                if down {
                    let meta = code == KEY.LEFTMETA || code == KEY.RIGHTMETA
                    let tap = meta && nativeEditing && !nativeTextBindings && heldModifiers.isEmpty
                    cancelDeferredMetaTaps()
                    heldModifiers.insert(code)
                    if tap { deferredMetaTaps.insert(code) }
                    if (!nativeTextBindings || mods.contains(.control)) && !(meta && nativeEditing) {
                        if pressedKeys.insert(code).inserted { sendKey(code, true) }
                    }
                } else {
                    heldModifiers.remove(code)
                    if pressedKeys.remove(code) != nil { sendKey(code, false) }
                    if deferredMetaTaps.remove(code) != nil {
                        sendKey(code, true)
                        sendKey(code, false)
                    }
                }
            }
            if captured && mods.contains([.control, .option]) { releasePointer() }
            return true
        }
    }

    var nativeEditing: Bool {
        inputs != nil && !captured && focusedGame == nil && !guestAsleep && pausedGame == nil
    }

    private var nativeTextBindings: Bool { nativeEditing && guestFocus == .steam }

    func performGuestEdit(_ selector: Selector) {
        guard nativeEditing, let commands = GuestEditCommand.keys(for: selector) else { return }
        sendGuestCommands(commands)
    }

    func cancelDeferredMetaTaps() { deferredMetaTaps.removeAll() }

    private func sendGuestCommands(_ commands: [[UInt16]]) {
        cancelDeferredMetaTaps()
        for modifier in heldModifiers.sorted() where pressedKeys.remove(modifier) != nil { sendKey(modifier, false) }
        for keys in commands {
            for code in keys { sendKey(code, true) }
            for code in keys.reversed() { sendKey(code, false) }
        }
    }

    private func sendHeldModifiers() {
        cancelDeferredMetaTaps()
        for modifier in heldModifiers.sorted() where pressedKeys.insert(modifier).inserted { sendKey(modifier, true) }
    }

    private func sendKey(_ code: UInt16, _ down: Bool) {
        inputs?.keyboard.send([(EV.KEY, code, down ? 1 : 0)])
    }

    // MARK: pointer
    //
    // gamescope (SteamOS gaming mode) ignores absolute pointer motion: wlserver only handles
    // wlr_pointer `motion` (relative), never `motion_absolute`, so a virtio tablet's ABS_X/ABS_Y
    // never moves its cursor. It applies relative motion *unaccelerated* (unaccel_dx/dy) in the
    // focused surface's pixels and clamps the cursor to that surface. So in `auto` mode the host
    // pointer is mirrored with exact relative deltas through the virtio mouse, after anchoring the
    // guest cursor at the top-left corner with one large negative delta whenever its position is
    // unknown (pointer entered the picture, idle, after a capture), mapped onto the focused
    // surface as gamescope shows it (PointerMap): the agent reports its size with every focus
    // line (`focus steam 1920x1200`: Steam's window when its Display > Resolution is not native;
    // Desktop Mode's Plasma window, `focus desktop <w>x<h>`). The absolute tablet is used only in
    // `tablet` mode.

    /// Idle time after which the guest cursor may have been moved by the guest (warps, a game's
    /// smaller surface clamping); the next motion re-anchors.
    static let reanchorAfterIdle: TimeInterval = 1.5

    private var usesTablet: Bool {
        mouseMode == .tablet
    }

    var hostCursorRect: NSRect? {
        guard inputs != nil, !captured, Self.hostCursorShouldBeHidden(mouseMode: mouseMode, captured: false),
              !bootOrShutdown, !overlay.shown, pausedGame == nil, !guestAsleep else { return nil }
        return pointerMap.surfaceRect
    }

    /// Current host view -> guest cursor mapping (the picture as drawn, the current scanout, the
    /// focused surface).
    var pointerMap: PointerMap {
        PointerMap(picture: view.fitRect, display: scanoutSize, surface: guestSurface ?? scanoutSize)
    }

    func guestSurfaceChanged(_ s: (Int, Int)?) {
        guard s.map({ [$0.0, $0.1] }) != guestSurface.map({ [$0.0, $0.1] }) else { return }
        guestSurface = s
        log("input: guest pointer surface " + (s.map { "\($0.0)x\($0.1)" } ?? "= display"))
        guestCursor = nil
        refreshHostCursor()   // auto mode: the picture is this surface's rectangle
    }

    /// "Name (appid)" when the guest told us the game's name. IDs are interpolated as text: an
    /// Int would be grouped like a quantity ("1 091 500").
    private func gameLabel(_ id: Int) -> String {
        settings.gameName(id).map { String(localized: "\($0) (\(String(id)))", comment: "Game name and Steam app ID") }
            ?? String(localized: "game \(String(id))")
    }

    private var focusedGame: Int? {
        if case .game(let id) = guestFocus { return id } else { return nil }
    }

    /// A click in the picture captures the mouse instead of being forwarded.
    private var clickCaptures: Bool {
        switch mouseMode {
        case .capture: return true
        case .tablet: return false
        case .auto: return focusedGame.map { settings.autoCapture(for: $0) } ?? false
        }
    }

    func guestFocusChanged(_ f: GuestFocus) {
        // The agent ended with the gamescope session: no heartbeats until the next session's agent.
        if f == .sessionEnded {
            stall?.heartbeatsEnded()
            noPicture?.heartbeatsEnded()
        }
        guard f != guestFocus else { return }
        cancelDeferredMetaTaps()
        guestFocus = f
        // The agent sends the new game's `game-size` right after `focus game`; until then none is known.
        focusedGameSize = nil
        view.gameLayersVisible = focusedGame != nil
        stall?.game = focusedGame
        updateNoPictureGate()
        updateSetupCard()
        log("input: guest focus \(f)")
        refreshLowerResolution()
        guestCursor = nil
        // Back in Steam / desktop (or a game without auto-capture): give the pointer back.
        if captured && mouseMode == .auto && !clickCaptures { releasePointer() }
        captureIfGameActive()
        updateTitle()
        if let id = focusedGame, mouseMode == .auto, !settings.autoCapture(for: id) {
            flashStatus(String(localized: "auto-capture off for \(gameLabel(id))"))
        }
    }

    private func captureIfGameActive() {
        guard !captured, focusedGame != nil, clickCaptures, NSApp.isActive, window.isKeyWindow,
              !pauseView.shown, !guestAsleep, !overlay.shown else { return }
        // A pointer outside the picture (another screen) would stay there hidden and send clicks to other windows.
        if !view.bounds.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            let c = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            CGWarpMouseCursorPosition(CGPoint(x: c.x, y: NSScreen.screens[0].frame.maxY - c.y))
        }
        grabPointer()
    }

    /// Window-title hint for a few seconds, then back to the regular status.
    private var statusFlashWork: DispatchWorkItem?
    private func flashStatus(_ text: String) {
        statusFlashWork?.cancel()
        setStatus(text)
        let work = DispatchWorkItem { [weak self] in self?.updateTitle() }
        statusFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // Mouse menu actions.
    @objc func toggleGameAutoCapture(_ sender: Any?) {
        guard let id = focusedGame else { return }
        let on = !settings.autoCapture(for: id)
        settings.setAutoCapture(on, for: id)
        if !on && captured { releasePointer() }
        updateTitle()
        flashStatus(on ? String(localized: "auto-capture on for \(gameLabel(id))")
                       : String(localized: "auto-capture off for \(gameLabel(id))"))
    }

    @objc func toggleGlobalAutoCapture(_ sender: Any?) {
        let on = !settings.globalAutoCapture
        settings.autoCaptureGames = on
        log("input: auto-capture in games \(on ? "on" : "off") (saved)"
            + (settings.autoCaptureOverride != nil ? "; --auto-capture still applies to this run" : ""))
        if captured && !clickCaptures { releasePointer() }
        updateTitle()
        flashStatus(settings.globalAutoCapture ? String(localized: "auto-capture in games on")
                                               : String(localized: "auto-capture in games off"))
    }

    @objc func toggleCaptureNow(_ sender: Any?) { captured ? releasePointer() : grabPointer() }

    /// Adds the "Mouse" menu (validated against the current focus each time it opens).
    func installMouseMenu() {
        guard let main = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Mouse", comment: "Menu for mouse capture controls"))
        menu.autoenablesItems = true
        let entries: [(LocalizedStringResource, Selector)] = [
            ("Capture Mouse in This Game", #selector(toggleGameAutoCapture(_:))),
            ("Auto-Capture Mouse in Games", #selector(toggleGlobalAutoCapture(_:))),
            ("Capture / Release Mouse Now", #selector(toggleCaptureNow(_:))),
        ]
        for (title, action) in entries {
            let i = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        item.submenu = menu
        main.addItem(item)
    }
}

extension WindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleGameAutoCapture(_:)):
            if let id = focusedGame {
                item.title = String(localized: "Capture Mouse in This Game (\(gameLabel(id)))")
                item.state = settings.autoCapture(for: id) ? .on : .off
                return mouseMode == .auto
            }
            item.title = String(localized: "Capture Mouse in This Game")
            item.state = .off
            return false
        case #selector(toggleGlobalAutoCapture(_:)):
            item.state = settings.globalAutoCapture ? .on : .off
            return mouseMode == .auto
        default:
            return inputs != nil
        }
    }
}

extension WindowController {

    /// The mouse is captured (relative mode, cursor hidden).
    var pointerCaptured: Bool { captured }

    func grabPointer() {
        guard inputs != nil, !captured else { return }
        releaseButtons()
        captured = true
        relRemainder = (0, 0)
        rawMouse = false
        if settings.rawMouse {
            GCMouse.mice().forEach(attachRawMouse)
            mouseConnectObserver = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) {
                [weak self] in ($0.object as? GCMouse).map { self?.attachRawMouse($0) }
            }
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        refreshHostCursor()
        log("input: mouse captured")
        updateTitle()
        window.invalidateCursorRects(for: pill)
    }

    func releasePointer() {
        guard captured else { return }
        releaseButtons()
        captured = false
        mouseConnectObserver.map(NotificationCenter.default.removeObserver)
        mouseConnectObserver = nil
        GCMouse.mice().forEach { $0.mouseInput?.mouseMovedHandler = nil }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        lastAbs = (-1, -1)
        guestCursor = nil
        log("input: mouse released")
        updateTitle()
        window.invalidateCursorRects(for: pill)
        refreshHostCursor()
    }

    private func attachRawMouse(_ mouse: GCMouse) {
        mouse.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, self.captured, !self.pauseView.shown, !self.guestAsleep else { return }
            self.rawMouse = true
            self.moveRelative(dx: Double(dx), dy: -Double(dy))
        }
    }

    private func releaseButtons() {
        for b in tabletButtons { inputs?.tablet.send([(EV.KEY, b, 0)]) }
        for b in mouseButtons { inputs?.mouse.send([(EV.KEY, b, 0)]) }
        tabletButtons.removeAll()
        mouseButtons.removeAll()
    }

    func releaseAll() {
        for k in pressedKeys { sendKey(k, false) }
        pressedKeys.removeAll()
        heldModifiers.removeAll()
        cancelDeferredMetaTaps()
        releasePointer()
        releaseButtons()
        reportCursorPresentation(at: window.mouseLocationOutsideOfEventStream)
        guestCursor = nil
    }

    /// gamescope draws the SteamOS cursor into scanout; auto mode hides the Mac cursor over the
    /// picture (hostCursorRect, a transparent cursor rect in VMView) to avoid duplicates. On DXMT the
    /// opaque wmtr picture covers scanout, so VMView draws the game's XFixes cursor above it, using
    /// the guest's visibility, shape and position. Never infer a replacement Mac arrow from layer
    /// coverage: the game may intentionally hide its cursor. Report both coverage and overlay
    /// visibility to distinguish those cases.
    /// Pure policy, also checked by --selftest-pointer. Captured hiding is owned by grabPointer.
    static func hostCursorShouldBeHidden(mouseMode: MouseMode, captured: Bool) -> Bool {
        captured || mouseMode == .auto
    }

    /// `point` is in the scanout layer's coordinates. Detect scanout occlusion, not guest cursor
    /// visibility: only wmtr's opaque Metal sublayers replace scanout, not ordinary launcher layers.
    static func guestCursorCovered(at point: CGPoint, in picture: CAMetalLayer) -> Bool {
        for case let layer as CAMetalLayer in picture.sublayers ?? [] {
            if !layer.isHidden && layer.isOpaque && layer.opacity == 1,
               layer.contains(layer.convert(point, from: picture)) { return true }
        }
        return false
    }

    func guestCursorCovered(at location: NSPoint) -> Bool {
        Self.guestCursorCovered(at: view.convert(location, from: nil), in: view.metalLayer)
    }

    /// `location` in window coordinates.
    private func reportCursorPresentation(at location: NSPoint) {
        let covered = guestCursorCovered(at: location)
        let hidden = captured || (window.isKeyWindow && hostCursorRect?.contains(view.convert(location, from: nil)) == true)
        let overlay = view.cursorOverlayVisible
        guard lastCursorPresentation?.captured != captured || lastCursorPresentation?.covered != covered
                || lastCursorPresentation?.hidden != hidden || lastCursorPresentation?.overlay != overlay else { return }
        lastCursorPresentation = (captured, covered, hidden, overlay)
        log("input: cursor presentation mode=\(mouseMode.rawValue) captured=\(captured) scanout-cursor-covered=\(covered) host-hidden=\(hidden) overlay-visible=\(overlay) focus=\(guestFocus) overlay={\(view.cursorOverlayDiagnostic)}")
    }

    /// What decides the cursor changed without the mouse moving: the progress phase, the pause
    /// card, sleep, the pill, the overlay or the stall card and its "Report…" link coming or
    /// going, the window becoming key or changing size, the scanout or the focused surface
    /// changing (the picture's rectangle), a wmtr layer attaching/hiding/detaching, a capture ending.
    /// Decided from where the pointer is now.
    func refreshHostCursor() {
        window.invalidateCursorRects(for: view)
        view.refreshHostCursor()
        reportCursorPresentation(at: window.mouseLocationOutsideOfEventStream)
    }

    private func button(for e: NSEvent) -> UInt16 {
        switch e.type {
        case .leftMouseDown, .leftMouseUp: return BTN.LEFT
        case .rightMouseDown, .rightMouseUp: return BTN.RIGHT
        default:
            switch e.buttonNumber {
            case 2: return BTN.MIDDLE
            case 3: return BTN.SIDE
            default: return BTN.EXTRA
            }
        }
    }

    private func inPicture(_ e: NSEvent) -> Bool { inPicture(at: e.locationInWindow) }

    /// `location` in window coordinates.
    private func inPicture(at location: NSPoint) -> Bool {
        (usesTablet ? view.fitRect : pointerMap.surfaceRect).contains(view.convert(location, from: nil))
    }

    /// Host pointer position in pixels of the focused surface, clamped to it.
    private func guestPoint(_ e: NSEvent) -> (Int, Int) {
        pointerMap.surfacePoint(view.convert(e.locationInWindow, from: nil))
    }

    private func moveTablet(_ e: NSEvent) {
        guard let inputs else { return }
        let (ux, uy) = view.unitPoint(for: e)
        let x = Int32((ux * Double(InputDevices.absMax)).rounded())
        let y = Int32((uy * Double(InputDevices.absMax)).rounded())
        guard (x, y) != lastAbs else { return }
        lastAbs = (x, y)
        inputs.tablet.send([(EV.ABS, ABS.X, x), (EV.ABS, ABS.Y, y)])
    }

    /// Auto mode: steer the guest cursor onto the host pointer with relative motion.
    private func moveEmulated(_ e: NSEvent) {
        guard let inputs else { return }
        let target = guestPoint(e)
        let now = Date()
        if guestCursor == nil || now.timeIntervalSince(lastPointerMotion) > WindowController.reanchorAfterIdle {
            let (sw, sh) = pointerMap.surface
            let far = -Int32(4 * (max(sw, scanoutSize.0) + max(sh, scanoutSize.1)))
            inputs.mouse.send([(EV.REL, REL.X, far), (EV.REL, REL.Y, far)])
            guestCursor = (0, 0)
        }
        lastPointerMotion = now
        let (cx, cy) = guestCursor!
        let dx = Int32(target.0 - cx), dy = Int32(target.1 - cy)
        guard dx != 0 || dy != 0 else { return }
        var ev: [(UInt16, UInt16, Int32)] = []
        if dx != 0 { ev.append((EV.REL, REL.X, dx)) }
        if dy != 0 { ev.append((EV.REL, REL.Y, dy)) }
        inputs.mouse.send(ev)
        guestCursor = target
    }

    /// Captured: raw relative motion, one count per host point (also with Retina resolution: games
    /// keep their mouse sensitivity; no acceleration in gamescope).
    func moveRelative(dx: Double, dy: Double) {
        guard let inputs else { return }
        let fx = dx + relRemainder.0
        let fy = dy + relRemainder.1
        let ix = Int32(fx.rounded(.towardZero)), iy = Int32(fy.rounded(.towardZero))
        relRemainder = (fx - Double(ix), fy - Double(iy))
        var ev: [(UInt16, UInt16, Int32)] = []
        if ix != 0 { ev.append((EV.REL, REL.X, ix)) }
        if iy != 0 { ev.append((EV.REL, REL.Y, iy)) }
        inputs.mouse.send(ev)
    }

    func pointerMoved(_ e: NSEvent) {
        reportCursorPresentation(at: e.locationInWindow)
        if pauseView.shown || guestAsleep { return }   // nothing reaches a frozen game / sleeping guest
        if captured {
            if !rawMouse { moveRelative(dx: Double(e.deltaX), dy: Double(e.deltaY)) }
        } else if inPicture(e) || NSEvent.pressedMouseButtons != 0 {
            if usesTablet { moveTablet(e) } else { moveEmulated(e) }
        } else {
            guestCursor = nil   // left the picture: re-anchor on the way back in
        }
    }

    func pointerButton(_ e: NSEvent, down: Bool) {
        guard let inputs else { return }
        let b = button(for: e)
        // "Game paused": the click resumes (activates the app → GamePause thaws); it must not
        // also click into the game. Its release is swallowed too.
        if down && pauseView.shown {
            swallowedButtons.insert(b)
            log("input: click resumes the paused game (not sent to the guest)")
            NSApp.activate()
            return
        }
        if down && guestAsleep {
            swallowedButtons.insert(b)
            wakeGuest("click")
            return
        }
        if !down && swallowedButtons.remove(b) != nil { return }
        if down { userInput("click") }
        if captured {
            if down { sendHeldModifiers() }
            if down ? mouseButtons.insert(b).inserted : mouseButtons.remove(b) != nil {
                inputs.mouse.send([(EV.KEY, b, down ? 1 : 0)])
            }
            return
        }
        if down {
            guard inPicture(e) else { return }
            if clickCaptures {
                grabPointer()   // the capturing click itself is not forwarded
                return
            }
        }
        // The tablet only advertises LEFT/RIGHT/MIDDLE (see InputDevices); other buttons and the
        // auto mode use the relative mouse.
        if down { sendHeldModifiers() }
        if usesTablet && InputDevices.tabletButtons.contains(b) {
            if down {
                moveTablet(e)
                if tabletButtons.insert(b).inserted { inputs.tablet.send([(EV.KEY, b, 1)]) }
            } else if tabletButtons.remove(b) != nil {
                inputs.tablet.send([(EV.KEY, b, 0)])
            }
            return
        }
        if down {
            if !usesTablet { moveEmulated(e) }
            if mouseButtons.insert(b).inserted { inputs.mouse.send([(EV.KEY, b, 1)]) }
        } else if mouseButtons.remove(b) != nil {
            inputs.mouse.send([(EV.KEY, b, 0)])
        }
    }

    func scroll(_ e: NSEvent) {
        guard inputs != nil, !pauseView.shown, !guestAsleep else { return }
        if !captured {
            guard inPicture(e) else { return }
            if usesTablet { moveTablet(e) } else { moveEmulated(e) }
        }
        sendHeldModifiers()
        // 120 = one wheel notch. Precise (trackpad) deltas are points: ~30 pt per notch.
        let scale = e.hasPreciseScrollingDeltas ? 4.0 : 120.0
        sendWheel(hiResY: Double(e.scrollingDeltaY) * scale, hiResX: -Double(e.scrollingDeltaX) * scale)
    }

    /// Wheel motion in 1/120-notch units (positive y = up, positive x = right), emitted as
    /// REL_*_HI_RES plus whole REL_WHEEL/REL_HWHEEL notches.
    func sendWheel(hiResY: Double, hiResX: Double) {
        guard let inputs else { return }
        let vy = hiResY + wheelHiRemainder.0
        let vx = hiResX + wheelHiRemainder.1
        let hy = Int32(vy.rounded(.towardZero)), hx = Int32(vx.rounded(.towardZero))
        wheelHiRemainder = (vy - Double(hy), vx - Double(hx))
        wheelLoAccum.0 += hy
        wheelLoAccum.1 += hx
        let ly = wheelLoAccum.0 / 120, lx = wheelLoAccum.1 / 120
        wheelLoAccum.0 -= ly * 120
        wheelLoAccum.1 -= lx * 120
        var ev: [(UInt16, UInt16, Int32)] = []
        if hy != 0 { ev.append((EV.REL, REL.WHEEL_HI_RES, hy)) }
        if hx != 0 { ev.append((EV.REL, REL.HWHEEL_HI_RES, hx)) }
        if ly != 0 { ev.append((EV.REL, REL.WHEEL, ly)) }
        if lx != 0 { ev.append((EV.REL, REL.HWHEEL, lx)) }
        (!captured && usesTablet ? inputs.tablet : inputs.mouse).send(ev)
    }
}

enum MainMenu {
    private static weak var editMenu: NSMenu?

    static func performKeyEquivalent(with event: NSEvent, editing: Bool) -> Bool {
        for item in NSApp.mainMenu?.items ?? [] {
            guard let menu = item.submenu, editing || menu !== editMenu else { continue }
            if menu.performKeyEquivalent(with: event) { return true }
        }
        return false
    }

    static func install(target: AnyObject, settings: Selector, report: Selector, checkForUpdates: Selector, restart: Selector,
                        suspend: Selector, shutdown: Selector, forceQuit: Selector, fullscreen: Selector, grab: Selector,
                        overlay: Selector, metalHUD: Selector) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        // Titled by the target's validateMenuItem ("Update Available: X.Y…" once one was found).
        appMenu.addItem(item("Check for Updates…", checkForUpdates, target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", settings, target, key: ","))
        appMenu.addItem(item("Report a Problem…", report, target))
        appMenu.addItem(.separator())
        let suspendItem = item(LocalizedStringResource("Suspend", comment: "App menu: freeze the VM in memory"), suspend, target, key: "s")
        suspendItem.keyEquivalentModifierMask = [.command, .control]
        appMenu.addItem(suspendItem)
        appMenu.addItem(item("Restart VM", restart, target))
        appMenu.addItem(item("Shut Down SteamOS", shutdown, target))
        appMenu.addItem(item("Force Quit", forceQuit, target))
        appMenu.addItem(.separator())
        // Lifecycle.applicationShouldTerminate decides (shut down; asks first while suspended).
        appMenu.addItem(NSMenuItem(title: String(localized: "Quit FX Steam Launcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addEditAndWindowMenus(main)
        let viewItem = NSMenuItem()
        main.insertItem(viewItem, at: 2)
        let viewMenu = NSMenu(title: String(localized: "View", comment: "Menu for display controls"))
        viewItem.submenu = viewMenu
        let fullscreenItem = item("Toggle Full Screen", fullscreen, target, key: "f")
        fullscreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullscreenItem)
        let grabItem = item("Grab Pointer", grab, target, key: "g")
        grabItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(grabItem)
        viewMenu.addItem(item("Show Boot Progress", overlay, target))
        // Ticked by the target's validateMenuItem (follows Settings > Display and Ctrl+Cmd+P).
        let hudItem = item("Show Metal Performance HUD", metalHUD, target, key: "p")
        hudItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(hudItem)
        adoptHUDMenuItems(target: target, metalHUD: metalHUD)
        let help = NSMenu(title: String(localized: "Help", comment: "Application help menu"))
        help.addItem(item("Report a Problem…", report, target))
        let helpItem = NSMenuItem()
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.helpMenu = help
    }

    /// App menu with Settings… and Quit only (first-run sheet, --selftest-settings).
    static func installMinimal(settings: (Selector, AnyObject)? = nil) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        if let (action, target) = settings { appMenu.addItem(item("Settings…", action, target, key: ",")) }
        appMenu.addItem(NSMenuItem(title: String(localized: "Quit FX Steam Launcher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addEditAndWindowMenus(main)
        NSApp.mainMenu = main
    }

    /// Standard Edit (text fields in Settings) and Window (Cmd+W closes Settings) menus.
    private static func addEditAndWindowMenus(_ main: NSMenu) {
        let edit = NSMenu(title: String(localized: "Edit", comment: "Standard text editing menu"))
        editMenu = edit
        let entries: [(LocalizedStringResource, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in entries {
            edit.addItem(NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key))
        }
        let find = NSMenuItem(title: String(localized: "Find…"), action: Selector(("performFindPanelAction:")), keyEquivalent: "f")
        find.tag = 1
        edit.addItem(.separator())
        edit.addItem(find)
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        let window = NSMenu(title: String(localized: "Window", comment: "Standard window management menu"))
        window.addItem(NSMenuItem(title: String(localized: "Close", comment: "Menu command: close the window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
    }

    /// libMTLHud (loaded by MTL_HUD_ENABLED=1, main.swift) adds a menu of its own once the HUD
    /// attaches, with "Enable HUD": that item flips the library's global switch, which the HUD
    /// mode the launcher sets on each layer (VMView.applyHUD) overrides, so it did nothing. It
    /// drives the launcher's setting instead (one HUD, one state, ticked and titled by
    /// validateMenuItem like the View menu item; the library's own "Enable"/"Hide HUD" title
    /// would contradict the tick). Its Cmd-F9 never worked: AppKit drops the function-key
    /// modifier the library asks for (the warning it logs at every start, before the item
    /// reaches a menu), so the key equivalent goes too.
    ///
    /// The library adds the item before it sets its target, then adds the rest of its submenu
    /// and finally the submenu's item to the main menu: every addition re-scans the menu it went
    /// into with its submenus, now and once more after the library's current call returns, so
    /// the item is adopted whatever order the library builds the menu in.
    static let adoptedHUDItemTag = 0x4855
    private static var hudMenuObserver: NSObjectProtocol?
    private static func adoptHUDMenuItems(target: AnyObject, metalHUD: Selector) {
        let toggle = NSSelectorFromString("toggleEnabled:")
        func adopt(in menu: NSMenu) {
            for i in menu.items {
                if let sub = i.submenu { adopt(in: sub) }
                guard i.action == toggle, let handler = NSClassFromString("HUDKeyboardEventHandler"),
                      (i.target as AnyObject?)?.isKind(of: handler) == true else { continue }
                i.target = target
                i.action = metalHUD
                i.tag = adoptedHUDItemTag
                i.keyEquivalent = ""
                i.keyEquivalentModifierMask = []
                log("menu: libMTLHud's \"\(i.title)\" drives the Metal Performance HUD setting")
            }
        }
        hudMenuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { n in
            guard let menu = n.object as? NSMenu else { return }
            adopt(in: menu)
            DispatchQueue.main.async { adopt(in: menu) }
        }
    }

    private static func item(_ title: LocalizedStringResource, _ action: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        i.target = target
        return i
    }
}
