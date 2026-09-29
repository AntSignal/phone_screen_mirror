// iMirror — mirror a USB-connected iPhone to a macOS window, take screenshots,
// and control it from the Mac via WebDriverAgent — while the phone stays
// physically usable (unlike Apple's "iPhone Mirroring").
//
// Dependency-free: AppKit + Foundation. The mirror itself is decoded WDA-MJPEG
// frames (plain CGImages), not a local capture session.
//
// UI: a native unified NSToolbar (Liquid Glass on macOS 26) with SF Symbol
// controls and an NSSwitch for control; status shown in the window subtitle.
//
// SECURITY: control talks to WDA over loopback only (no auth on WDA's wire), and
// is OFF by default — you must explicitly connect and flip the Control switch.

import AppKit
import iMirrorCore
import os

/// Unified-logging channel. NSLog output was not reaching `log show`, which made
/// field reports (black mirror on a user's Mac) undiagnosable without a debugger.
let mirrorLog = Logger(subsystem: "com.local.imirror", category: "capture")

// MARK: - Preview view (hosts preview layer + captures mouse/keyboard)

final class PreviewView: NSView {
    /// Displays decoded WDA-MJPEG frames (plain CGImages).
    private let imageLayer = CALayer()

    /// Pixel size of the most recently displayed frame (set by `setFrame`).
    /// AppDelegate uses this to compute the aspect-fit video rect for coordinate
    /// mapping, the same role AVCaptureVideoPreviewLayer's own rect conversion
    /// used to play.
    private(set) var lastFrameSize: CGSize?

    // View-space callbacks (AppDelegate transforms to device coordinates).
    var onTap: ((CGPoint) -> Void)?
    var onDrag: (([CGPoint], _ flick: Bool) -> Void)?   // path + fast-release flag
    var onScroll: ((_ at: CGPoint, _ delta: CGVector) -> Void)?  // trackpad scroll
    var onType: ((String) -> Void)?

    private var downPoint: CGPoint?
    private var dragSamples: [(p: CGPoint, t: TimeInterval)] = []
    private var wheelAccum = CGVector(dx: 0, dy: 0)
    private let kFlickWindowSec: TimeInterval = 0.08    // trailing window for flick velocity

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// Displays a freshly decoded MJPEG frame. Main-thread only: the MJPEG
    /// client delivers frames on its own queue, so callers must hop to main
    /// before calling this.
    func setFrame(_ image: CGImage) {
        imageLayer.contents = image
        lastFrameSize = CGSize(width: image.width, height: image.height)
    }

    /// Blank the picture (switching phones: the old phone's last frame must
    /// not linger under the new phone's taps).
    func clearFrame() {
        imageLayer.contents = nil
        lastFrameSize = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True while Control is armed. Drives the cursor (a pointing hand signals the
    /// mirror is interactive) so a click while Control is off isn't a silent no-op.
    var controlActive = false {
        didSet {
            guard controlActive != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        if controlActive { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// Brief local ripple at a tap point — acknowledges the tap the instant it's
    /// dispatched, independent of WDA's network round-trip, so a slow response
    /// reads differently from a dropped one.
    func flashTap(at point: CGPoint) {
        let d: CGFloat = 46
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        ripple.position = point
        ripple.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        ripple.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        ripple.lineWidth = 2
        ripple.opacity = 0
        layer?.addSublayer(ripple)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "tapFlash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak ripple] in
            ripple?.removeFromSuperlayer()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        dragSamples = [(p, event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        dragSamples.append((convert(event.locationInWindow, from: nil), event.timestamp))
    }

    override func mouseUp(with event: NSEvent) {
        let up = convert(event.locationInWindow, from: nil)
        guard let down = downPoint else { return }
        downPoint = nil
        dragSamples.append((up, event.timestamp))           // release point in the window + path
        let dx = up.x - down.x, dy = up.y - down.y
        if (dx * dx + dy * dy).squareRoot() > 6 {
            let flick = releaseIsFlick()
            onDrag?(gesturePath(flick: flick), flick)
        } else {
            onTap?(up)
        }
        dragSamples = []
    }

    /// True when the trailing ~80ms of travel is fast enough to read as a flick — so
    /// the gesture is sent as one quick swipe (snappy scroll jump) rather than a
    /// faithful 1:1 path replay (precise drag). The 80ms window survives a single
    /// coalesced (~16ms) event. (WDA can't produce inertial momentum — see
    /// WDAClient.drag — so a flick just scrolls fast, it doesn't coast.)
    private func releaseIsFlick() -> Bool {
        guard let b = dragSamples.last, dragSamples.count >= 2 else { return false }
        var i = dragSamples.count - 1
        while i > 0 && b.t - dragSamples[i - 1].t < kFlickWindowSec { i -= 1 }
        guard dragSamples.count - i >= 3 else { return false }   // too few samples → velocity unreliable
        let a = dragSamples[i]
        let dt = Swift.max(b.t - a.t, 1.0 / 240)            // guard against /0
        let dist = ((b.p.x - a.p.x) * (b.p.x - a.p.x)
                  + (b.p.y - a.p.y) * (b.p.y - a.p.y)).squareRoot()
        return dist > 25 && dist / dt > 800                // view points/sec (tune)
    }

    /// Points to send for the gesture. For a flick, only the last ~100ms of travel,
    /// so the swipe's origin is where the flick actually started — not an earlier
    /// slow wander, which would encode the wrong angle and distance.
    private func gesturePath(flick: Bool) -> [CGPoint] {
        guard flick, let b = dragSamples.last else { return dragSamples.map { $0.p } }
        var start = 0
        for i in stride(from: dragSamples.count - 1, through: 0, by: -1)
        where b.t - dragSamples[i].t >= kFlickWindowSec { start = i; break }
        return dragSamples[start...].map { $0.p }
    }

    /// Two-finger trackpad scroll. Accumulate the finger distance and emit one quick
    /// swipe when the user lifts (phase .ended); the Mac's own inertial frames are
    /// ignored (the phone can't reproduce momentum, so a coasting tail would just be
    /// extra 1:1 swipes). A legacy mouse wheel (no precise deltas, no phase) instead
    /// emits an immediate nudge per tick. Direction is normalised via
    /// isDirectionInvertedFromDevice (the authoritative Natural-Scroll flag): dy > 0
    /// means the finger moved up, dx > 0 means it moved right.
    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase != [] { return }                       // iOS supplies the tail
        if event.phase.contains(.cancelled) { wheelAccum = .zero; return }
        if event.phase.contains(.began) { wheelAccum = .zero }        // drop any stale partial gesture
        let at = convert(event.locationInWindow, from: nil)
        let inv = event.isDirectionInvertedFromDevice
        let dx = inv ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inv ? event.scrollingDeltaY : -event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Legacy wheel: discrete ticks, no phase. Emit an immediate nudge.
            let nudge = CGVector(dx: dx * 30, dy: dy * 30)
            if (nudge.dx * nudge.dx + nudge.dy * nudge.dy).squareRoot() >= 8 { onScroll?(at, nudge) }
            return
        }
        wheelAccum.dx += dx
        wheelAccum.dy += dy
        if event.phase.contains(.ended) {
            var d = wheelAccum
            wheelAccum = .zero
            // Dominant-axis dead zone: a near-vertical scroll shouldn't smear the
            // content sideways (and vice-versa). Drop the minor axis when it's < 30%
            // of the major; true diagonals (both axes comparable) pass through.
            if abs(d.dx) < abs(d.dy) * 0.3 { d.dx = 0 }
            else if abs(d.dy) < abs(d.dx) * 0.3 { d.dy = 0 }
            if (d.dx * d.dx + d.dy * d.dy).squareRoot() > 4 { onScroll?(at, d) }
        }
    }

    /// Clear any buffered trackpad delta — call when control is disarmed so a stale
    /// partial gesture can't fire a phantom swipe on re-enable.
    func resetScroll() { wheelAccum = .zero }

    override func keyDown(with event: NSEvent) {
        // Map special keys to the characters XCUITest's typeText understands.
        switch event.keyCode {
        case 51:        onType?("\u{8}")   // delete / backspace
        case 117:       onType?("\u{7F}")  // forward delete
        case 36, 76:    onType?("\n")      // return / enter
        case 48:        onType?("\t")      // tab
        default:
            if let chars = event.characters, !chars.isEmpty { onType?(chars) }
        }
    }
}

// MARK: - Click-through glass strip (status HUD that doesn't block the preview)

final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Toolbar item identifiers

private extension NSToolbarItem.Identifier {
    static let device     = NSToolbarItem.Identifier("device")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let health     = NSToolbarItem.Identifier("health")
    static let control    = NSToolbarItem.Identifier("control")
    static let settings   = NSToolbarItem.Identifier("settings")
    static let home       = NSToolbarItem.Identifier("home")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var window: NSWindow!
    private var previewView: PreviewView!
    private var emptyStateView: NSView!
    private var statusLabel: NSTextField!

    // Toolbar controls
    private let controlSwitch = NSSwitch()
    private let automationSwitch = NSSwitch()
    private let settingsButton = NSButton()
    private let settingsPopover = NSPopover()
    private var settingsBuilt = false
    private let deviceMCP = MCPSectionUI(profile: .device, noun: "")
    private let simMCP = MCPSectionUI(profile: .simulator, noun: " (sim)")
    private let simController = SimulatorController()
    private var simDevices: [SimDevice] = []
    private let simPicker = NSPopUpButton()
    private let simEnableButton = NSButton()
    private let simStatusLabel = NSTextField(labelWithString: "")
    private var simEnabled = false
    /// The Simulator Settings enabled, for its entry in the device file.
    private var simEnabledDevice: SimDevice?
    private let healthButton = NSButton()
    /// Which phone the window shows (and the toolbar's buttons act on).
    private let devicePopUp = NSPopUpButton()
    private var deviceItem: NSToolbarItem!
    /// Settings → iPhones: one row per attached phone, rebuilt as they change.
    private let devicesStack = NSStackView()
    private var screenshotItem: NSToolbarItem!
    private var controlItem: NSToolbarItem!
    private var homeItem: NSToolbarItem!

    private var mjpeg: MJPEGClient?
    /// True once WDA-MJPEG frames are actually flowing. Distinct from `health`,
    /// which only reflects the WDA HTTP session — the MJPEG socket can connect,
    /// drop, and reconnect independently of that session.
    private var mirroring = false
    /// Latest decoded WDA-MJPEG frame (updated on main by the mjpeg.onFrame handler).
    /// Screenshot now saves this instead of the (now-unused) capture pixel buffer.
    private var lastFrame: CGImage?

    // Control + health. Every attached phone has its own chain, 3s probe and
    // recovery ladder (DeviceController, run by ChainManager) whether or not
    // it's on screen, so an agent driving phone2 doesn't depend on this window.
    // The window renders the selected phone; `wda`/`health` below are its.
    private let manager = ChainManager()
    private var selectedUDID: String? = UserDefaults.standard.string(forKey: "imirror.selectedDevice")
    private var selected: DeviceController? { manager.controller(selectedUDID) }
    private var wda: WDAClient? { selected?.wda }
    private var health: DeviceController.Health { selected?.health ?? .down }
    private var controlEnabled = false
    private var automationEnabled = false

    // MJPEG partial-wedge watchdog (see nextMjpegRecoveryAction in
    // iMirrorCore): WDA's /status can stay healthy while the MJPEG stream has
    // silently died, so `health == .connected` alone isn't proof frames are
    // still arriving.
    private var mjpegLastFrameAt: TimeInterval?
    private var mjpegBounced = false
    private let mjpegNoFrameThresholdSec: TimeInterval = 20
    /// Counts `.escalate` outcomes for the current connected session, reset
    /// ONLY when a real frame arrives (not on every `setHealth(.connected)`,
    /// which fires on every probe tick once connected). Past 2, a chain
    /// restart clearly isn't bringing the stream back — stop looping and
    /// surface a terminal state instead of restarting forever.
    private var mjpegEscalationCount = 0

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        // The phones' controllers report here; only the selected phone drives
        // the window, but any phone's change refreshes the picker and Settings.
        manager.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        manager.onControllerChange = { [weak self] c in
            guard let self else { return }
            self.refreshDevicePicker()
            self.rebuildDeviceRows()
            if c.udid == self.selectedUDID { self.updateHealthDot() }
        }
        manager.onControllerHealth = { [weak self] c, old, new in
            guard let self, c.udid == self.selectedUDID else { return }
            self.applyHealth(old: old, new: new)
            self.checkMjpegWatchdog()
        }
        manager.onControllerStatus = { [weak self] c, text in
            guard let self, c.udid == self.selectedUDID else { return }
            // A specific message beats the generic debounced "Starting…" line.
            self.downStatusWorkItem?.cancel(); self.downStatusWorkItem = nil
            self.setStatus(text)
        }
        manager.onBlocked = { [weak self] text in self?.setStatus(text) }
        updateHealthDot()        // grey — automation off
        // Automation now drives the entire mirror (WDA-MJPEG frames replace camera
        // capture), so it always starts on launch instead of waiting for an opt-in.
        automationSwitch.state = .on
        setAutomation(true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()           // every phone's chain + the tunnel; deletes the device file
        mjpeg?.stop()
    }

    // MARK: UI

    /// A plain SPM executable ships no MainMenu nib, so build one: the standard App
    /// and Window menus (Quit/Hide/Minimize a Mac user expects) plus a Controls
    /// menu that gives the toolbar actions real keyboard shortcuts.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About iMirror",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iMirror",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iMirror",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let ctrlItem = NSMenuItem()
        mainMenu.addItem(ctrlItem)
        let ctrlMenu = NSMenu(title: "Controls")
        ctrlItem.submenu = ctrlMenu
        let shot = ctrlMenu.addItem(withTitle: "Screenshot", action: #selector(takeScreenshot), keyEquivalent: "s")
        shot.target = self
        let home = ctrlMenu.addItem(withTitle: "Home", action: #selector(pressHome), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        home.target = self
        ctrlMenu.addItem(.separator())
        let next = ctrlMenu.addItem(withTitle: "Next iPhone", action: #selector(selectNextDevice), keyEquivalent: "]")
        next.target = self
        let prev = ctrlMenu.addItem(withTitle: "Previous iPhone", action: #selector(selectPreviousDevice), keyEquivalent: "[")
        prev.target = self

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iMirror"
        window.titleVisibility = .hidden   // free the unified toolbar for the controls
        window.center()
        window.setFrameAutosaveName("iMirrorMain")
        // Stop the window shrinking into a degenerate size that clips the toolbar;
        // the content aspect ratio is locked to the phone once its size is known.
        window.contentMinSize = NSSize(width: 260, height: 480)

        // Container: preview fills it; a click-through glass HUD shows status at
        // the bottom so the toolbar stays clean.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 880))

        previewView = PreviewView(frame: container.bounds)
        previewView.autoresizingMask = [.width, .height]
        wireInput()
        container.addSubview(previewView)

        // Minimal empty state over the (black) preview when no iPhone is connected.
        emptyStateView = makeEmptyStateView()
        container.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -24),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        let hud = PassthroughEffectView()
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)

        statusLabel = NSTextField(labelWithString: "Looking for iPhone…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: hud.topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -5),
        ])

        window.contentView = container

        // Control switch (iOS-style toggle) — arms sending taps; needs WDA connected.
        controlSwitch.target = self
        controlSwitch.action = #selector(toggleControl)
        controlSwitch.isEnabled = false
        controlSwitch.setAccessibilityLabel("Control — drive the phone from the preview")

        // Automation switch — starts/stops WebDriverAgent (and iOS's on-phone
        // "Automation Running" overlay). Off by default: view-only until you opt in.
        automationSwitch.target = self
        automationSwitch.action = #selector(toggleAutomation)
        automationSwitch.state = .off
        automationSwitch.setAccessibilityLabel("Automation — start or stop WebDriverAgent")

        // Health dot — colored status, click to force a re-check
        healthButton.isBordered = false
        healthButton.bezelStyle = .toolbar
        healthButton.imagePosition = .imageOnly
        healthButton.wantsLayer = true   // for the tint cross-fade + connecting pulse
        healthButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "WDA status")
        healthButton.contentTintColor = .systemGray
        healthButton.target = self
        healthButton.action = #selector(forceProbe)
        healthButton.toolTip = "WDA status — click to re-check"

        // Phone picker — which attached iPhone the window mirrors and controls.
        // Every phone stays driveable from the MCP server either way.
        devicePopUp.target = self
        devicePopUp.action = #selector(devicePicked)
        devicePopUp.controlSize = .small
        devicePopUp.setAccessibilityLabel("iPhone shown in this window")
        refreshDevicePicker()

        // Settings gear — opens the settings popover (automation, scroll speed, …).
        settingsButton.isBordered = true
        settingsButton.bezelStyle = .toolbar
        settingsButton.imagePosition = .imageOnly
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.toolTip = "iMirror settings"

        let toolbar = NSToolbar(identifier: "iMirrorToolbar")
        toolbar.delegate = self
        // Icon-only keeps the bar compact for the narrow (portrait) window;
        // each item carries a tooltip for discoverability.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(previewView)
    }

    // SF Symbol helper
    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    /// Quiet, centered empty state shown over the black preview when no iPhone is
    /// connected. A thin phone glyph + a title + a one-line hint — nothing loud.
    private func makeEmptyStateView() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "No iPhone")?
            .withSymbolConfiguration(.init(pointSize: 52, weight: .ultraLight))
        icon.contentTintColor = .tertiaryLabelColor

        // Wrapping labels so longer copy (e.g. the camera-permission guidance)
        // wraps to multiple centered lines instead of clipping.
        let title = NSTextField(wrappingLabelWithString: "No iPhone connected")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.isSelectable = false
        title.preferredMaxLayoutWidth = 300

        let hint = NSTextField(wrappingLabelWithString: "Plug in via USB, unlock, and tap “Trust.”")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = 300

        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(14, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true                    // layer-backed so alphaValue animates
        return stack
    }

    /// Cross-fade the empty state instead of snapping it — the first mirror frame
    /// otherwise pops in abruptly the instant a device binds.
    private func setEmptyState(hidden: Bool) {
        guard let v = emptyStateView else { return }
        if hidden {
            guard !v.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                v.animator().alphaValue = 0
            }, completionHandler: { v.isHidden = true })
        } else {
            v.isHidden = false
            v.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                v.animator().alphaValue = 1
            }
        }
    }

    private func actionItem(_ id: NSToolbarItem.Identifier, _ label: String,
                            _ symbolName: String, _ action: Selector,
                            enabled: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = symbol(symbolName, label)
        item.target = self
        item.action = action
        item.isBordered = true
        item.isEnabled = enabled
        return item
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.device, .screenshot, .flexibleSpace, .health, .control, .settings, .home]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.device, .screenshot, .health, .control, .settings, .home, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .device:
            deviceItem = NSToolbarItem(itemIdentifier: .device)
            deviceItem.label = "iPhone"
            deviceItem.toolTip = "Which iPhone this window shows (⌘] / ⌘[ to switch)"
            deviceItem.view = devicePopUp
            deviceItem.menuFormRepresentation = deviceMenuForm()
            return deviceItem

        case .screenshot:
            // enabled starts false and flips on via setHealth's .connected/.down
            // branches now that there's no device-bind step to gate it on.
            screenshotItem = actionItem(.screenshot, "Screenshot", "camera.viewfinder",
                                        #selector(takeScreenshot), enabled: false)
            return screenshotItem

        case .health:
            let item = NSToolbarItem(itemIdentifier: .health)
            item.label = "WDA"
            item.toolTip = "WDA connection status"
            item.view = healthButton
            return item

        case .control:
            controlItem = NSToolbarItem(itemIdentifier: .control)
            controlItem.label = "Control"
            controlItem.toolTip = "Drive the phone from the preview (taps, swipes, typing)"
            controlItem.view = controlSwitch
            // A custom-view toolbar item is dead in the narrow-window overflow menu;
            // this menu form makes Control work there too.
            let cmenu = NSMenuItem(title: "Control", action: #selector(toggleControlFromMenu), keyEquivalent: "")
            cmenu.target = self
            controlItem.menuFormRepresentation = cmenu
            return controlItem

        case .settings:
            let item = NSToolbarItem(itemIdentifier: .settings)
            item.label = "Settings"
            item.toolTip = "iMirror settings — automation (WDA), scroll speed, …"
            item.view = settingsButton
            let smenu = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
            smenu.target = self
            item.menuFormRepresentation = smenu
            return item

        case .home:
            homeItem = actionItem(.home, "Home", "house",
                                  #selector(pressHome), enabled: false)
            return homeItem

        default:
            return nil
        }
    }

    // MARK: Screenshot

    @objc private func takeScreenshot() {
        guard let cgImage = lastFrame else {
            setStatus("No frame yet — wait for the mirror to start.")
            return
        }
        let name = "iMirror_\(selected?.alias ?? "iphone")_\(timestamp()).png"
        let url = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        // PNG-encode + write off the main thread: a blocking file write (to a possibly
        // iCloud-synced ~/Pictures) would otherwise hitch the UI on a click that should
        // feel instant. Only the status update hops back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async { self.setStatus("Screenshot failed (could not encode PNG).") }
                return
            }
            do {
                try png.write(to: url)
                DispatchQueue.main.async { self.setStatus("Saved \(url.lastPathComponent) → ~/Pictures") }
            } catch {
                DispatchQueue.main.async { self.setStatus("Screenshot save failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Control (WDA)

    private func wireInput() {
        previewView.onTap = { [weak self] viewPoint in
            guard let self, self.controlEnabled, let p = self.devicePoint(fromViewPoint: viewPoint) else { return }
            self.wda?.tap(at: p)
            self.previewView.flashTap(at: viewPoint)   // local acknowledgment
        }
        previewView.onDrag = { [weak self] viewPath, flick in
            guard let self, self.controlEnabled else { return }
            let devicePath = downsample(viewPath, max: 24)
                .compactMap { self.devicePoint(fromViewPoint: $0) }
            guard devicePath.count >= 2 else { return }
            self.wda?.drag(path: devicePath, flick: flick)
        }
        previewView.onScroll = { [weak self] viewPoint, viewDelta in
            guard let self, self.controlEnabled,
                  let size = self.wda?.deviceSize,
                  let start = self.devicePoint(fromViewPoint: viewPoint) else { return }
            guard let frameSize = self.previewView.lastFrameSize else { return }
            let videoRect = self.displayedImageRect(in: self.previewView.bounds, imageSize: frameSize)
            guard videoRect.width > 1, videoRect.height > 1 else { return }
            // Scale view-space scroll distance into device points and send one fast
            // swipe. Since the phone can't add inertia, `gain` amplifies the swipe
            // length so a small trackpad push still travels a useful distance — it
            // stacks on the view→device scale (~2.4x) and is live-tunable via the
            // UserDefaults key "imirror.scrollGain".
            let gain = Swift.max(0.2, UserDefaults.standard.object(forKey: "imirror.scrollGain") as? Double ?? 3.5)
            // viewDelta normalised: dy>0 = finger up = device pointer moves up (y down).
            var end = CGPoint(x: start.x + viewDelta.dx * gain * (size.width / videoRect.width),
                              y: start.y - viewDelta.dy * gain * (size.height / videoRect.height))
            end.x = Swift.min(Swift.max(end.x, 0), size.width)
            end.y = Swift.min(Swift.max(end.y, 0), size.height)
            let moved = ((end.x - start.x) * (end.x - start.x)
                       + (end.y - start.y) * (end.y - start.y)).squareRoot()
            guard moved >= 20 else { return }          // skip imperceptible swipes
            self.wda?.drag(path: [start, end], flick: true)
        }
        previewView.onType = { [weak self] text in
            guard let self, self.controlEnabled else { return }
            self.wda?.typeText(text)
        }
    }

    /// Aspect-fit rect of `imageSize` centered within `bounds` (both in the view's
    /// own y-up coordinate space) — the CALayer analogue of what
    /// AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:) used
    /// to compute automatically when the preview was capture-backed.
    private func displayedImageRect(in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let x = bounds.minX + (bounds.width - w) / 2
        let y = bounds.minY + (bounds.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Map a click in the preview to a device point. The aspect-fit rect of the
    /// latest MJPEG frame within the view handles letterboxing + orientation;
    /// mapToDevice (in iMirrorCore) does the normalize + y-flip and is unit-tested.
    private func devicePoint(fromViewPoint p: CGPoint) -> CGPoint? {
        guard let size = wda?.deviceSize, let frameSize = previewView.lastFrameSize else { return nil }
        let videoRect = displayedImageRect(in: previewView.bounds, imageSize: frameSize)
        return mapToDevice(viewPoint: p, videoRect: videoRect, deviceSize: size)
    }

    // MARK: Which phone the window shows

    /// The set of phones changed: refresh the picker and Settings, and keep a
    /// valid selection (the saved one if it's attached, else the lowest slot).
    private func devicesChanged() {
        refreshDevicePicker()
        rebuildDeviceRows()
        if selected == nil {
            if let first = manager.controllers.first {
                selectDevice(first.udid)
            } else {
                showNoPhone()
            }
        }
    }

    @objc private func devicePicked() {
        let i = devicePopUp.indexOfSelectedItem
        guard i >= 0, i < manager.controllers.count else { return }
        selectDevice(manager.controllers[i].udid)
    }

    @objc private func selectNextDevice() { stepSelection(by: 1) }
    @objc private func selectPreviousDevice() { stepSelection(by: -1) }

    private func stepSelection(by delta: Int) {
        let list = manager.controllers
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.udid == selectedUDID } ?? 0
        selectDevice(list[(i + delta + list.count) % list.count].udid)
    }

    @objc private func deviceMenuPicked(_ sender: NSMenuItem) {
        if let udid = sender.representedObject as? String { selectDevice(udid) }
    }

    /// Show `udid`'s phone: tear down the old phone's video and controls, then
    /// render the new phone's current health (which starts its video).
    private func selectDevice(_ udid: String) {
        guard udid != selectedUDID || mjpeg == nil else { return }
        disarmControl()
        mjpeg?.stop()
        mjpeg = nil
        mirroring = false
        lastFrame = nil
        previewView.clearFrame()
        resetMjpegWatchdog()
        downStatusWorkItem?.cancel(); downStatusWorkItem = nil
        selectedUDID = udid
        UserDefaults.standard.set(udid, forKey: "imirror.selectedDevice")
        refreshDevicePicker()
        guard let c = selected else { showNoPhone(); return }
        setEmptyState(hidden: false)
        setStatus("\(c.alias) — \(c.attached.productType ?? "iPhone")")
        applyHealth(old: .down, new: c.health)
    }

    private func showNoPhone() {
        disarmControl()
        mjpeg?.stop()
        mjpeg = nil
        mirroring = false
        previewView.clearFrame()
        setEmptyState(hidden: false)
        updateHealthDot()
        if automationEnabled {
            let blocked = manager.problems.first.map { "An iPhone is attached but can't be used: \($0.value)." }
            setStatus(blocked ?? "Looking for iPhone… plug one in by USB, unlock it, and tap “Trust.”")
        }
    }

    private func refreshDevicePicker() {
        let list = manager.controllers
        devicePopUp.removeAllItems()
        for c in list {
            devicePopUp.addItem(withTitle: "\(c.alias) · \(c.attached.productType ?? "iPhone")")
            devicePopUp.lastItem?.image = healthGlyph(c.health, installing: c.installingRunner)
        }
        if list.isEmpty {
            devicePopUp.addItem(withTitle: "No iPhone")
            devicePopUp.isEnabled = false
        } else {
            devicePopUp.isEnabled = true
            if let i = list.firstIndex(where: { $0.udid == selectedUDID }) { devicePopUp.selectItem(at: i) }
        }
        devicePopUp.sizeToFit()
        deviceItem?.menuFormRepresentation = deviceMenuForm()
    }

    /// The picker as a submenu, for when the toolbar overflows into `»`.
    private func deviceMenuForm() -> NSMenuItem {
        let item = NSMenuItem(title: "iPhone", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for c in manager.controllers {
            let mi = NSMenuItem(title: "\(c.alias) · \(c.attached.productType ?? "iPhone")",
                                action: #selector(deviceMenuPicked(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = c.udid
            mi.state = c.udid == selectedUDID ? .on : .off
            menu.addItem(mi)
        }
        item.submenu = menu
        return item
    }

    private func healthGlyph(_ h: DeviceController.Health, installing: Bool) -> NSImage? {
        let color: NSColor = installing ? .systemYellow
            : (h == .connected ? .systemGreen : (h == .connecting ? .systemYellow : .systemRed))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
    }

    // MARK: WDA health (the selected phone)

    /// The WDA toolbar dot's click handler: a re-check, or after a give-up the
    /// user explicitly asking the selected phone to retry.
    @objc private func forceProbe() {
        guard let c = selected else { return }
        if c.ladder.hardStopped {
            // Give the user's retry its own two-strike video allowance.
            mjpegEscalationCount = 0
            mjpegBounced = false
        }
        c.userRetry()
    }

    private func resetMjpegWatchdog() {
        mjpegLastFrameAt = nil
        mjpegBounced = false
        mjpegEscalationCount = 0
    }

    /// MJPEG partial-wedge watchdog, for the phone on screen (only its stream is
    /// open): WDA's HTTP session can be healthy while the video underneath has
    /// silently died. Cheapest fix first (bounce that phone's MJPEG forward);
    /// escalate to restarting that phone's chain only if frames don't return.
    private func checkMjpegWatchdog() {
        guard let c = selected, health == .connected, mjpeg != nil, let lastFrame = mjpegLastFrameAt else { return }
        // With an external WDA there's no chain to bounce; once hard-stopped,
        // this watchdog goes quiet until the user retries.
        guard c.chain != nil, !c.ladder.hardStopped else { return }
        let noFrameFor = ProcessInfo.processInfo.systemUptime - lastFrame
        switch nextMjpegRecoveryAction(noFrameForSec: noFrameFor, alreadyBounced: mjpegBounced, thresholdSec: mjpegNoFrameThresholdSec) {
        case .wait:
            break
        case .bounceForward:
            mjpegBounced = true
            NSLog("iMirror: no MJPEG frames from \(c.alias) for \(Int(noFrameFor))s — bouncing its MJPEG forward")
            c.bounceMJPEGForward()
        case .escalate:
            mjpegEscalationCount += 1
            if mjpegEscalationCount >= 2 {
                // Two restarts with no real frame in between: restarting isn't
                // fixing this. Stop looping and surface a terminal state.
                NSLog("iMirror: MJPEG from \(c.alias) still stalled after \(mjpegEscalationCount) restarts — giving up")
                c.hardStopForStalledVideo()
                return
            }
            // Restart the no-frame clock so this doesn't fire again on the next
            // tick before health actually flips to .down.
            mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
            mjpegBounced = false
            c.restartForStalledVideo()
        }
    }

    private var downStatusWorkItem: DispatchWorkItem?

    private func disarmControl() {
        if controlEnabled {
            controlEnabled = false
            controlSwitch.state = .off
            previewView.controlActive = false
            previewView.resetScroll()
        }
        controlSwitch.isEnabled = false
        homeItem?.isEnabled = false
        screenshotItem?.isEnabled = false
    }

    /// Render the selected phone's health in the window. Called on every probe
    /// of that phone (changed or not), so everything here is idempotent.
    private func applyHealth(old: DeviceController.Health, new: DeviceController.Health) {
        guard let c = selected else { return }
        let changed = (new != old)
        updateHealthDot()                       // dot colour is always instant

        switch new {
        case .connected:
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            controlSwitch.isEnabled = true
            homeItem?.isEnabled = true
            screenshotItem?.isEnabled = true
            if changed {
                let s = c.wda.deviceSize ?? .zero
                // Lock resizing to the phone's proportions so the mirror fills the
                // window without letterboxing (portrait points; landscape just
                // shows bars until the next connect).
                if s.width > 0, s.height > 0 {
                    window.contentAspectRatio = NSSize(width: s.width, height: s.height)
                }
                setStatus("\(c.alias) connected — \(Int(s.width))×\(Int(s.height)) pts. Flip Control to drive.")
            }
            // Start the MJPEG mirror the moment WDA is healthy. Guarded against
            // double-start: this runs on every probe tick once connected.
            if mjpeg == nil { startMirror(for: c) }
        case .connecting:
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            if changed { setStatus("Connecting to WDA on \(c.alias)…") }
        case .down:
            // Lost the connection — disarm control so stray clicks can't fire.
            disarmControl()
            mjpeg?.stop()
            mjpeg = nil
            mirroring = false
            setEmptyState(hidden: false)
            // Debounce the *status text* by 6s: a brief probe blip during heavy
            // scrolling flips health to .down for one cycle, and flashing
            // "Starting WebDriverAgent…" on every scroll is alarming and wrong.
            // The red dot already shows instantly above; only the text waits.
            if changed {
                downStatusWorkItem?.cancel()
                let canManage = manager.canSelfManage
                let reconnecting = c.ladder.hadSuccessfulConnection
                let alias = c.alias
                let udid = c.udid
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.automationEnabled, self.selected?.udid == udid,
                          self.health == .down else { return }
                    self.setStatus(reconnecting ? "WDA on \(alias) reconnecting…"
                        : (canManage ? "Starting WebDriverAgent on \(alias)… (first launch can take ~20s)"
                                     : "WDA unreachable — run ./scripts/wda-up.sh"))
                }
                downStatusWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
            }
        }
    }

    /// Open the selected phone's MJPEG stream (its slot's forwarded port to the
    /// phone's WDA mjpegServerPort 9100).
    private func startMirror(for c: DeviceController) {
        let udid = c.udid
        let client = MJPEGClient(port: c.slot.mjpegPort)
        client.onFrame = { [weak self] cg in
            DispatchQueue.main.async {
                guard let self, self.selectedUDID == udid else { return }
                self.mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
                // A real frame arrived — earlier escalations no longer count
                // toward the two-strike give-up.
                self.mjpegEscalationCount = 0
                self.lastFrame = cg
                self.previewView.setFrame(cg)
                if !self.mirroring {
                    self.mirroring = true
                    self.setEmptyState(hidden: true)
                    self.setStatus("Mirroring \(c.alias) — phone stays usable.")
                }
            }
        }
        client.onStateChange = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self, self.selectedUDID == udid, !connected else { return }
                // MJPEG socket dropped independently of the WDA HTTP session — show
                // the waiting state until frames resume.
                self.mirroring = false
                self.setEmptyState(hidden: false)
                self.setStatus("Waiting for video from \(c.alias)…")
            }
        }
        mjpeg = client
        // Seed the no-frame clock at start so the watchdog measures from
        // "stream just opened," not from an already-ancient nil baseline.
        mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
        mjpegBounced = false
        client.start()
    }

    private var healthDotColor: NSColor?

    private func updateHealthDot() {
        guard automationEnabled else {
            setHealthDot(.systemGray, tip: "Automation off — flip Automation on to control the phone",
                         a11y: "automation off", pulsing: false)
            return
        }
        guard let c = selected else {
            setHealthDot(.systemGray, tip: "No iPhone attached", a11y: "no iPhone", pulsing: false)
            return
        }
        if c.installingRunner {
            setHealthDot(.systemYellow, tip: "Installing WebDriverAgent on \(c.alias)…",
                         a11y: "installing runner", pulsing: true)
            return
        }
        switch health {
        case .connected:
            setHealthDot(.systemGreen, tip: "WDA connected — click to re-check",
                         a11y: "connected", pulsing: false)
        case .connecting:
            setHealthDot(.systemYellow, tip: "Connecting to WDA…",
                         a11y: "connecting", pulsing: true)
        case .down:
            setHealthDot(.systemRed, tip: "WDA unreachable — click to re-check",
                         a11y: "unreachable", pulsing: false)
        }
    }

    /// Apply the health dot's colour/tooltip/label. Cross-fades the tint only when
    /// it actually changes (so a steady state doesn't flicker every probe), and
    /// runs a gentle opacity pulse while connecting so "in progress" reads
    /// differently from a stuck yellow. Also updates the VoiceOver label so status
    /// isn't communicated by hue alone.
    private func setHealthDot(_ color: NSColor, tip: String, a11y: String, pulsing: Bool) {
        healthButton.toolTip = tip
        healthButton.setAccessibilityLabel("WDA status: \(a11y)")
        if color != healthDotColor {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            healthButton.layer?.add(fade, forKey: "tint")
            healthButton.contentTintColor = color
            healthDotColor = color
        }
        let key = "connectingPulse"
        if pulsing {
            if healthButton.layer?.animation(forKey: key) == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = 0.7
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                healthButton.layer?.add(pulse, forKey: key)
            }
        } else {
            healthButton.layer?.removeAnimation(forKey: key)
        }
    }

    @objc private func toggleControl() {
        // Only allow arming control when actually connected.
        guard health == .connected else {
            controlSwitch.state = .off
            controlEnabled = false
            previewView.controlActive = false
            setStatus("Can't enable control — WDA not connected (dot is not green).")
            return
        }
        controlEnabled = (controlSwitch.state == .on)
        previewView.controlActive = controlEnabled
        if !controlEnabled { previewView.resetScroll() }
        setStatus(controlEnabled
            ? "Control ON — clicks/keys drive the phone."
            : "Control off — mirror only.")
    }

    /// Start or stop WebDriverAgent on demand. Off (default) = pure view-only
    /// mirroring: no go-ios children, no XCUITest session, and no iOS "Automation
    /// Running" overlay on the phone. On = bring the control channel up.
    @objc private func toggleAutomation() { setAutomation(automationSwitch.state == .on) }

    /// Enable/disable the WDA control channel (every attached phone's) and
    /// remember the choice across launches.
    private func setAutomation(_ on: Bool) {
        automationEnabled = on
        UserDefaults.standard.set(on, forKey: "imirror.automationEnabled")
        resetMjpegWatchdog()
        if on {
            setStatus("Automation ON — starting WebDriverAgent… "
                    + "(iOS shows an \"Automation Running\" overlay on each phone).")
            // Each phone's ladder clock starts when its runwda does, not now:
            // tunnel bring-up and the runner install mustn't eat WDA's boot grace.
            manager.start()          // tunnel, then a chain per USB phone as it's found
        } else {
            // Tear everything down so nothing runs on the phones (the overlay clears).
            disarmControl()
            manager.stop()
            mjpeg?.stop()
            mjpeg = nil
            mirroring = false
            updateHealthDot()        // grey — automation off
            setStatus("Automation off — no control, no on-phone overlay.")
        }
    }

    /// Drive the Control switch from its overflow-menu form (custom-view toolbar
    /// items are non-interactive in the narrow-window `»` menu on their own).
    @objc private func toggleControlFromMenu() {
        controlSwitch.state = (controlSwitch.state == .on) ? .off : .on
        toggleControl()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleControlFromMenu) {
            menuItem.state = controlEnabled ? .on : .off
            return controlSwitch.isEnabled          // only armable once WDA is connected
        }
        return true
    }

    // MARK: Settings popover

    @objc private func showSettings() {
        if !settingsBuilt { buildSettingsPopover(); settingsBuilt = true }
        rebuildDeviceRows()         // refresh each phone's status each time it opens
        if settingsPopover.isShown { settingsPopover.close(); return }
        // Anchor to the gear when it's on screen; if it overflowed into the `»` menu
        // its view is detached (no window), so fall back to the window content view.
        let anchor: NSView = settingsButton.window != nil ? settingsButton : (window.contentView ?? settingsButton)
        let edge: NSRectEdge = anchor === settingsButton ? .maxY : .minY
        settingsPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    private func buildSettingsPopover() {
        let pad: CGFloat = 16
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "iMirror Settings")
        title.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(title)

        let autoRow = NSStackView()
        autoRow.orientation = .horizontal
        autoRow.spacing = 8
        autoRow.addArrangedSubview(NSTextField(labelWithString: "Automation (WebDriverAgent)"))
        autoRow.addArrangedSubview(automationSwitch)
        stack.addArrangedSubview(autoRow)

        let cap = NSTextField(wrappingLabelWithString:
            "On starts the control channel; iOS shows an “Automation Running” overlay on the phone. Off = view-only mirroring.")
        cap.font = .systemFont(ofSize: 11)
        cap.textColor = .secondaryLabelColor
        cap.preferredMaxLayoutWidth = 260
        stack.addArrangedSubview(cap)

        let scrollRow = NSStackView()
        scrollRow.orientation = .horizontal
        scrollRow.spacing = 8
        scrollRow.addArrangedSubview(NSTextField(labelWithString: "Scroll speed"))
        let slider = NSSlider(value: UserDefaults.standard.object(forKey: "imirror.scrollGain") as? Double ?? 3.5,
                              minValue: 0.5, maxValue: 6.0, target: self, action: #selector(scrollGainChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        scrollRow.addArrangedSubview(slider)
        stack.addArrangedSubview(scrollRow)

        // iPhones section — every attached phone, its port and runner state, a
        // rename field (the alias agents pass as `device=`) and a Restart.
        let devSep = NSBox(); devSep.boxType = .separator
        devSep.translatesAutoresizingMaskIntoConstraints = false
        devSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(devSep)

        let devTitle = NSTextField(labelWithString: "iPhones")
        devTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(devTitle)

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8
        stack.addArrangedSubview(devicesStack)

        let tunnelButton = NSButton(title: "Restart USB tunnel (all phones)", target: self,
                                    action: #selector(restartTunnel))
        tunnelButton.bezelStyle = .rounded
        tunnelButton.controlSize = .small
        tunnelButton.toolTip = "Every phone rides one go-ios tunnel; this restarts it and every phone's WebDriverAgent."
        stack.addArrangedSubview(tunnelButton)
        rebuildDeviceRows()

        // MCP server section — one-click register with Claude Code / Claude Desktop.
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(sep)

        let mcpTitle = NSTextField(labelWithString: "MCP server (drive from Claude)")
        mcpTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(mcpTitle)

        let mcpCap = NSTextField(wrappingLabelWithString:
            "Register the iMirror MCP server with Claude Code and Claude Desktop so an "
          + "agent can drive the phone. (Turn Automation on for it to connect.)")
        mcpCap.font = .systemFont(ofSize: 11)
        mcpCap.textColor = .secondaryLabelColor
        mcpCap.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(mcpCap)

        for v in deviceMCP.views() { stack.addArrangedSubview(v) }
        deviceMCP.refresh(updateLabel: true)

        // iOS Simulator section — pick a sim, bring up WDA on :8201, install imirror-sim.
        let simSep = NSBox(); simSep.boxType = .separator
        simSep.translatesAutoresizingMaskIntoConstraints = false
        simSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(simSep)

        let simTitle = NSTextField(labelWithString: "iOS Simulator")
        simTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(simTitle)

        let simCap = NSTextField(wrappingLabelWithString:
            "Boot a Simulator and drive it from Claude. Enable brings up WebDriverAgent "
          + "on it (port 8201); view the sim in Apple's Simulator app. Requires Xcode.")
        simCap.font = .systemFont(ofSize: 11)
        simCap.textColor = .secondaryLabelColor
        simCap.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(simCap)

        simPicker.target = self
        simPicker.action = #selector(simPicked)
        stack.addArrangedSubview(simPicker)

        simEnableButton.bezelStyle = .rounded
        simEnableButton.title = "Enable"
        simEnableButton.target = self
        simEnableButton.action = #selector(toggleSimEnable)
        stack.addArrangedSubview(simEnableButton)

        simStatusLabel.font = .systemFont(ofSize: 11)
        simStatusLabel.textColor = .secondaryLabelColor
        simStatusLabel.preferredMaxLayoutWidth = 268
        simStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(simStatusLabel)

        for v in simMCP.views() { stack.addArrangedSubview(v) }

        simController.onState = { [weak self] state in self?.renderSimState(state) }
        refreshSimulators()
        simMCP.refresh(updateLabel: true)

        // Version footer.
        let verSep = NSBox(); verSep.boxType = .separator
        verSep.translatesAutoresizingMaskIntoConstraints = false
        verSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(verSep)

        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "iMirror \(ver) (build \(build))")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 300),
        ])
        let vc = NSViewController()
        vc.view = container
        settingsPopover.contentViewController = vc
        settingsPopover.behavior = .transient
    }

    @objc private func scrollGainChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "imirror.scrollGain")
    }

    /// One row per attached phone (plus any phone that couldn't get a chain).
    private func rebuildDeviceRows() {
        guard settingsBuilt || devicesStack.superview != nil else { return }
        // A phone changing state mid-rename must not wipe the field being typed in.
        if let editor = devicesStack.window?.firstResponder as? NSTextView,
           let field = editor.delegate as? NSView, field.isDescendant(of: devicesStack) { return }
        for v in devicesStack.arrangedSubviews { devicesStack.removeArrangedSubview(v); v.removeFromSuperview() }
        if !automationEnabled {
            devicesStack.addArrangedSubview(smallLabel("Turn Automation on to find attached iPhones."))
            return
        }
        if manager.controllers.isEmpty && manager.problems.isEmpty {
            devicesStack.addArrangedSubview(smallLabel("No iPhone attached by USB."))
        }
        for c in manager.controllers {
            let name = NSTextField(string: c.alias)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.placeholderString = "alias"
            name.toolTip = "The name agents pass as device= (lower-case, starts with a letter)"
            name.identifier = NSUserInterfaceItemIdentifier(c.udid)
            name.target = self
            name.action = #selector(aliasEdited(_:))
            name.widthAnchor.constraint(equalToConstant: 96).isActive = true

            let restart = NSButton(title: "Restart", target: self, action: #selector(restartDeviceRow(_:)))
            restart.bezelStyle = .rounded
            restart.controlSize = .small
            restart.identifier = NSUserInterfaceItemIdentifier(c.udid)
            restart.toolTip = "Restart this phone's WebDriverAgent only"

            let glyph = NSImageView(image: healthGlyph(c.health, installing: c.installingRunner) ?? NSImage())
            let top = NSStackView(views: [glyph, name, restart])
            top.orientation = .horizontal
            top.spacing = 6

            let model = [c.attached.productType, c.attached.productVersion.map { "iOS \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            let port = c.slot.index == 0 ? ":\(c.slot.relayPort) (default)" : ":\(c.slot.relayPort)"
            let info = smallLabel("\(model.isEmpty ? "iPhone" : model) · \(shortUDID(c.udid)) · WDA \(port)\n\(c.runnerText)")
            let row = NSStackView(views: [top, info])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            devicesStack.addArrangedSubview(row)
        }
        for (udid, why) in manager.problems.sorted(by: { $0.key < $1.key }) {
            devicesStack.addArrangedSubview(smallLabel("\(shortUDID(udid)): not started — \(why)."))
        }
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 268
        l.isSelectable = true
        return l
    }

    private func shortUDID(_ udid: String) -> String {
        udid.count <= 14 ? udid : "\(udid.prefix(8))…\(udid.suffix(5))"
    }

    @objc private func aliasEdited(_ sender: NSTextField) {
        guard let udid = sender.identifier?.rawValue, let c = manager.controller(udid) else { return }
        let wanted = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard wanted != c.alias else { return }
        if let problem = manager.rename(c, to: wanted) {
            sender.stringValue = c.alias
            switch problem {
            case .badFormat: setStatus("“\(wanted)”: use lower-case letters, digits, - or _, starting with a letter.")
            case .looksLikeUDID: setStatus("“\(wanted)” looks like part of a UDID — pick a name.")
            case .taken: setStatus("“\(wanted)” already names another iPhone.")
            }
        } else {
            setStatus("Renamed to \(wanted) — agents now pass device=\"\(wanted)\".")
        }
    }

    @objc private func restartDeviceRow(_ sender: NSButton) {
        guard let udid = sender.identifier?.rawValue, let c = manager.controller(udid) else { return }
        c.restartChain()
    }

    @objc private func restartTunnel() {
        setStatus("Restarting the USB tunnel and every phone's WebDriverAgent…")
        manager.requestTunnelRestart(coalesce: false)
    }

    /// Check installed state / version / staleness off the main thread (it shells
    /// out) and reflect it in the buttons — and the status line when `updateLabel`.

    private func refreshSimulators() {
        DispatchQueue.global(qos: .userInitiated).async {
            let hasXcode = self.simController.xcodeAvailable()
            let sims = hasXcode ? self.simController.listSimulators() : []
            DispatchQueue.main.async {
                self.simPicker.isEnabled = hasXcode
                self.simEnableButton.isEnabled = hasXcode
                guard hasXcode else { self.simStatusLabel.stringValue = "Requires Xcode."; return }
                self.simDevices = sims
                self.simPicker.removeAllItems()
                for s in sims {
                    self.simPicker.addItem(withTitle: "\(s.name) — \(s.runtime)"
                                           + (s.isBooted ? " (booted)" : ""))
                }
                if sims.isEmpty { self.simStatusLabel.stringValue = "No simulators found." }
            }
        }
    }

    @objc private func simPicked() { /* selection stored implicitly via indexOfSelectedItem */ }

    @objc private func toggleSimEnable() {
        if simEnabled {
            simController.disable()
            return
        }
        let idx = simPicker.indexOfSelectedItem
        guard idx >= 0, idx < simDevices.count else {
            simStatusLabel.stringValue = "Pick a simulator first."; return
        }
        simEnabledDevice = simDevices[idx]
        simController.enable(udid: simDevices[idx].udid)
    }

    private func renderSimState(_ state: SimState) {
        publishSimulator(state)
        switch state {
        case .idle:
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Off."
        case .booting:  simEnabled = true; simEnableButton.title = "Disable"; simStatusLabel.stringValue = "Booting simulator…"
        case .building: simStatusLabel.stringValue = "Building WebDriverAgent (first run ~2–3 min)…"
        case .starting: simStatusLabel.stringValue = "Starting WebDriverAgent…"
        case .ready:    simStatusLabel.stringValue = "WebDriverAgent ready on :8201 ✓"
        case .failed(let m):
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Failed: \(m)"
        }
    }

    /// List the enabled Simulator in the device file, so the one MCP server
    /// can drive it too (device="sim") alongside the phones.
    private func publishSimulator(_ state: SimState) {
        guard let sim = simEnabledDevice else { manager.simulatorEntry = nil; return }
        let registryState: RegisteredDevice.State
        switch state {
        case .idle: manager.simulatorEntry = nil; simEnabledDevice = nil; return
        case .failed: registryState = .failed
        case .ready: registryState = .ready
        case .booting, .building, .starting: registryState = .starting
        }
        let version = sim.runtime.split(separator: " ").last.map(String.init)
        manager.simulatorEntry = RegisteredDevice(
            udid: sim.udid, alias: "sim", kind: .simulator, productType: sim.name,
            iosVersion: version, wdaURL: "http://127.0.0.1:\(SimulatorController.port)",
            state: registryState)
    }

    @objc private func pressHome() {
        wda?.home()
    }

    // MARK: Helpers

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        NSLog("iMirror: \(text)")
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
