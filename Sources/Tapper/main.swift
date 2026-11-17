// Tapper — turns the mouse pointer into a cartoon glove on a long stick that
// pokes on every click. Made for demos, screen recordings and calls.
//
// How it works:
//   * One transparent, click-through window per display at screen-saver level.
//     The pointer "rig" (glove + stick) is a CALayer tree that lives in the
//     window of whichever display the pointer is on.
//   * The stick hangs toward the bottom-right. Its far end is a point mass on a
//     damped spring, so the stick swings and lags behind when you move.
//   * The real system cursor is hidden on ALL displays while the glove shows.
//     Background apps normally can't hide the cursor, so we set the WindowServer
//     connection property "SetsCursorInBackground" (private but long-stable).
//   * Clicks are observed with a global NSEvent monitor (no permission needed):
//     the glove jabs forward and a comic burst pops at the fingertip. Rapid
//     clicks build a combo that makes bursts bigger and wilder.
//   * Presentation Mode swallows mouse clicks with a CGEventTap so clicks only
//     poke; the keyboard stays live. Needs Accessibility permission.
//   * Windows keep the default sharingType, so they appear in full-screen
//     shares and recordings (Zoom, Meet, OBS, Loom).

import AppKit
import Carbon
import ServiceManagement

// MARK: - Private cursor API

@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Legacy CG call (still exported): is the cursor visible system-wide right now?
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Int32

enum Cursor {
    private(set) static var hidden = false
    static func setHidden(_ h: Bool) {
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        // kCGNullDirectDisplay = every display. (Hiding only the main display was
        // the v1 bug: the arrow stayed visible on secondary screens.)
        if h {
            if CGCursorIsVisible() != 0 { CGDisplayHideCursor(kCGNullDirectDisplay) }
        } else {
            // Unwind any hide count we stacked, but never loop forever.
            for _ in 0..<8 where CGCursorIsVisible() == 0 { CGDisplayShowCursor(kCGNullDirectDisplay) }
        }
        hidden = h
    }

    /// Other apps undo our hide (app switches, "hide until mouse moves" while
    /// typing, cursor-rect changes). Called on a timer: re-hide if it came back.
    static func enforce() {
        if hidden && CGCursorIsVisible() != 0 { setHidden(true) }
    }
}

// MARK: - Settings

/// Stick colours offered in the Color submenu.
let stickColors: [(String, NSColor)] = [
    ("Black", .black), ("White", .white), ("Orange", .systemOrange), ("Red", .systemRed),
    ("Pink", .systemPink), ("Purple", .systemPurple), ("Blue", .systemBlue), ("Green", .systemGreen),
]

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private func get<T>(_ k: String, _ def: T) -> T { d.object(forKey: k) as? T ?? def }

    var enabled: Bool { get { get("enabled", false) } set { d.set(newValue, forKey: "enabled") } }
    /// Pointer mood 0…4: Shy finger → In your face.
    var mood: Int { get { get("mood", 1) } set { d.set(newValue, forKey: "mood") } }
    var style: HandStyle {
        get { HandStyle(rawValue: get("style", 0)) ?? .tinyHand }
        set { d.set(newValue.rawValue, forKey: "style") }
    }
    var colorIndex: Int { get { get("color", 0) } set { d.set(newValue, forKey: "color") } }
    var animateOnClick: Bool { get { get("animate", true) } set { d.set(newValue, forKey: "animate") } }
    var soundOn: Bool { get { get("sound", true) } set { d.set(newValue, forKey: "sound") } }
    var volume: Double { get { get("volume", 0.6) } set { d.set(newValue, forKey: "volume") } }

    var stickColor: NSColor { stickColors[min(max(colorIndex, 0), stickColors.count - 1)].1 }
}

/// Per-mood tuning: how big, how long and how loud each mood is.
struct MoodSpec {
    let handScale: CGFloat   // points per hand unit
    let stickLength: CGFloat // points
    let stickWidth: CGFloat  // points at the hand end
    let jab: CGFloat         // jab distance in points
    let burst: CGFloat       // burst radius in points
    static let all: [MoodSpec] = [
        MoodSpec(handScale: 0.34, stickLength: 170, stickWidth: 4.0, jab: 4, burst: 18),
        MoodSpec(handScale: 0.42, stickLength: 280, stickWidth: 5.0, jab: 7, burst: 26),
        MoodSpec(handScale: 0.52, stickLength: 400, stickWidth: 6.0, jab: 10, burst: 36),
        MoodSpec(handScale: 0.66, stickLength: 520, stickWidth: 7.5, jab: 14, burst: 50),
        MoodSpec(handScale: 0.84, stickLength: 680, stickWidth: 9.5, jab: 20, burst: 70),
    ]
    static var current: MoodSpec { all[min(max(Settings.shared.mood, 0), all.count - 1)] }
}

// MARK: - Overlay windows

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        contentView = v
    }
    var root: CALayer { contentView!.layer! }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Pointer rig

/// The glove + stick. `rig` sits on the hotspot and is rotated by the stick
/// angle; `body` inside it is what jabs forward on a click.
final class PointerRig {
    let rig = CALayer()
    let body = CALayer()
    let hand = CALayer()
    let stick = CAShapeLayer()
    let stickFade = CAGradientLayer()

    // Spring state for the far end of the stick (screen coordinates).
    private var tip = CGPoint.zero           // hotspot (pointer position)
    private var end = CGPoint.zero           // far end of the stick
    private var endVel = CGVector.zero
    private var lastStep = CACurrentMediaTime()
    private var initialised = false
    static let restAngle: CGFloat = 0.42     // radians from straight-down, toward the right

    init() {
        rig.name = "rig"
        rig.addSublayer(body)
        body.addSublayer(stick)
        body.addSublayer(hand)
        stick.mask = stickFade
        hand.shadowColor = NSColor.black.cgColor
        hand.shadowOpacity = 0.25
        hand.shadowRadius = 3
        hand.shadowOffset = CGSize(width: 0, height: -2)
        stickFade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        stickFade.locations = [0, 0.5, 1]
        stickFade.startPoint = CGPoint(x: 0.5, y: 1)   // y-up: 1 = hand end
        stickFade.endPoint = CGPoint(x: 0.5, y: 0)
        apply()
    }

    /// Rebuild artwork from Settings (style, mood, colour).
    func apply() {
        let m = MoodSpec.current, s = Settings.shared
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = Art.bounds
        hand.contents = Art.image(s.style, scale: m.handScale, backing: 2)
        hand.contentsGravity = .resize
        hand.frame = CGRect(x: b.minX * m.handScale, y: b.minY * m.handScale,
                            width: b.width * m.handScale, height: b.height * m.handScale)

        // Stick: a slightly tapering bar from the cuff downward, outlined so a
        // white stick still reads on a white background.
        let top = -Art.handLength * m.handScale + 2
        let x = Art.stickX * m.handScale
        let w0 = m.stickWidth, w1 = m.stickWidth * 1.7, L = m.stickLength
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x - w0 / 2, y: top))
        p.addLine(to: CGPoint(x: x + w0 / 2, y: top))
        p.addLine(to: CGPoint(x: x + w1 / 2, y: top - L))
        p.addLine(to: CGPoint(x: x - w1 / 2, y: top - L))
        p.closeSubpath()
        stick.path = p
        stick.fillColor = s.stickColor.cgColor
        stick.strokeColor = (s.stickColor == .black ? NSColor.black : NSColor.black.withAlphaComponent(0.8)).cgColor
        stick.lineWidth = 1
        stick.frame = .zero
        stickFade.frame = CGRect(x: x - w1, y: top - L, width: w1 * 2, height: L)
        CATransaction.commit()
        initialised = false
    }

    /// Advance the spring and place the rig at `p` (window coordinates).
    func step(to p: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastStep, 1.0 / 240), 1.0 / 20))
        lastStep = now
        let L = MoodSpec.current.stickLength
        let rest = CGVector(dx: sin(Self.restAngle) * L, dy: -cos(Self.restAngle) * L)
        if !initialised {
            end = CGPoint(x: p.x + rest.dx, y: p.y + rest.dy); endVel = .zero; initialised = true
        }
        tip = p
        // Damped spring pulling the far end toward its rest position.
        let k: CGFloat = 90, c: CGFloat = 13
        let target = CGPoint(x: p.x + rest.dx, y: p.y + rest.dy)
        endVel.dx += ((target.x - end.x) * k - endVel.dx * c) * dt
        endVel.dy += ((target.y - end.y) * k - endVel.dy * c) * dt
        end.x += endVel.dx * dt
        end.y += endVel.dy * dt
        // Stick angle from the hotspot to the far end (0 = straight down).
        var a = atan2(end.x - tip.x, -(end.y - tip.y))
        a = min(max(a, -0.35), 1.25)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.position = p
        rig.setAffineTransform(CGAffineTransform(rotationAngle: a))
        CATransaction.commit()
    }

    /// Jab the glove forward along the stick.
    func jab(power: CGFloat) {
        let d = MoodSpec.current.jab * min(power, 3)
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, -d * 0.4, d, 0]        // wind up slightly, then poke
        a.keyTimes = [0, 0.25, 0.5, 1]
        a.duration = 0.22
        body.add(a, forKey: "jab")
        let sq = CAKeyframeAnimation(keyPath: "transform.scale")
        sq.values = [1, 0.92, 1.08, 1]
        sq.duration = 0.22
        hand.add(sq, forKey: "squash")
        // Kick the spring so the stick wobbles after a hard poke.
        endVel.dx += 220 * power
    }
}

// MARK: - Comic burst

enum Burst {
    /// Add below the pointer rig (if present) so the glove stays on top of the burst.
    private static func insert(_ l: CALayer, into layer: CALayer) {
        if let rig = layer.sublayers?.first(where: { $0.name == "rig" }) { layer.insertSublayer(l, below: rig) }
        else { layer.addSublayer(l) }
    }
    /// Radial "impact" lines around `p`; at higher power also a spiky star.
    static func pop(in layer: CALayer, at p: CGPoint, power: CGFloat, color: NSColor) {
        let m = MoodSpec.current
        let R = m.burst * (0.8 + 0.35 * min(power, 4))
        let ink = (color == .white ? NSColor.black : color).cgColor
        let n = 10 + Int(min(power, 4)) * 2
        for i in 0..<n {
            let ang = CGFloat(i) / CGFloat(n) * 2 * .pi + CGFloat.random(in: -0.15...0.15)
            let len = R * CGFloat.random(in: 0.35...0.7)
            let line = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: .zero); path.addLine(to: CGPoint(x: len, y: 0))
            line.path = path
            line.strokeColor = ink
            line.lineWidth = CGFloat.random(in: 1.6...2.8) * (0.8 + 0.12 * CGFloat(Settings.shared.mood))
            line.lineCap = .round
            line.position = p
            line.setAffineTransform(CGAffineTransform(rotationAngle: ang))
            line.opacity = 0
            insert(line, into: layer)
            // Lines shoot outward from the centre while shrinking from the inside.
            let out = CABasicAnimation(keyPath: "transform.translation.x")
            out.fromValue = R * 0.25; out.toValue = R * 0.75
            let tail = CABasicAnimation(keyPath: "strokeStart")
            tail.fromValue = 0; tail.toValue = 1
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [out, tail, fade]
            g.duration = 0.32
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.add(g, forKey: nil)
        }
        if power >= 2 || Settings.shared.mood >= 4 {
            let star = CAShapeLayer()
            let spikes = 11
            let path = CGMutablePath()
            for i in 0..<(spikes * 2) {
                let r = i % 2 == 0 ? R * 0.55 : R * CGFloat.random(in: 0.22...0.32)
                let ang = CGFloat(i) / CGFloat(spikes * 2) * 2 * .pi
                let pt = CGPoint(x: cos(ang) * r, y: sin(ang) * r)
                i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            path.closeSubpath()
            star.path = path
            star.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
            star.strokeColor = ink
            star.lineWidth = 2.2
            star.lineJoin = .miter
            star.position = p
            star.opacity = 0
            insert(star, into: layer)
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.3, 1.15, 1.0]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.toValue = CGFloat.random(in: -0.4...0.4)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.55, 1]
            let g = CAAnimationGroup(); g.animations = [grow, spin, fade]; g.duration = 0.34
            star.add(g, forKey: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { star.removeFromSuperlayer() }
        }
        // Clean up the lines.
        let lines = layer.sublayers?.filter { $0 is CAShapeLayer && $0.opacity == 0 } ?? []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { lines.forEach { $0.removeFromSuperlayer() } }
    }
}

// MARK: - Knock sound (synthesised so we ship no audio assets)

enum Knock {
    /// A short damped low "thud", like a knuckle on wood.
    static let sound: NSSound? = {
        let rate = 44_100.0, dur = 0.09
        let n = Int(rate * dur)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let env = exp(-t * 55)
            let s = (sin(2 * .pi * 180 * t) * 0.7 + sin(2 * .pi * 420 * t) * 0.3) * env
            let noise = Double.random(in: -1...1) * exp(-t * 400) * 0.35
            samples[i] = Int16(max(-1, min(1, s + noise)) * 30_000)
        }
        var data = Data()  // minimal 16-bit mono WAV container
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2))
        data.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(n * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return NSSound(data: data)
    }()

    static func play() {
        let s = Settings.shared
        guard s.soundOn, let snd = sound?.copy() as? NSSound else { return }
        snd.volume = Float(s.volume)
        snd.play()
    }
}

// MARK: - Toast (shown when Presentation Mode toggles)

final class Toast {
    private var window: NSWindow?
    func show(_ text: String, on screen: NSScreen) {
        window?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 32)
        let w = NSWindow(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 48,
                                             width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.level = .screenSaver; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: size)); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemOrange.cgColor
        v.layer?.cornerRadius = 16
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        v.addSubview(label)
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak w] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; w?.animator().alphaValue = 0 },
                                                 completionHandler: { w?.orderOut(nil); if self?.window === w { self?.window = nil } })
        }
    }
}

// MARK: - Global hotkeys (Carbon)

enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    static var refs: [EventHotKeyRef?] = []
    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
    static func register(_ id: UInt32, key: Int, mods: Int, _ h: @escaping () -> Void) {
        handlers[id] = h
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: 0x5441_5050, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Menu views

/// "Pointer mood" slider with five detents and end labels, like the original.
func moodItem(value: Int, target: AnyObject, action: Selector) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 62))
    let title = NSTextField(labelWithString: "Pointer mood")
    title.font = .menuFont(ofSize: 13); title.textColor = .secondaryLabelColor
    title.frame = NSRect(x: 14, y: 42, width: 200, height: 17)
    let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 4, target: target, action: action)
    slider.numberOfTickMarks = 5
    slider.allowsTickMarkValuesOnly = true
    slider.frame = NSRect(x: 14, y: 16, width: 222, height: 24)
    let l = NSTextField(labelWithString: "Shy finger"), r = NSTextField(labelWithString: "In your face")
    for f in [l, r] { f.font = .systemFont(ofSize: 10); f.textColor = .secondaryLabelColor }
    l.frame = NSRect(x: 14, y: 0, width: 100, height: 14)
    r.alignment = .right; r.frame = NSRect(x: 136, y: 0, width: 100, height: 14)
    [title, slider, l, r].forEach(view.addSubview)
    let item = NSMenuItem(); item.view = view
    return item
}

func sliderItem(_ title: String, value: Double, target: AnyObject, action: Selector) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 44))
    let label = NSTextField(labelWithString: title)
    label.font = .menuFont(ofSize: 13); label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 14, y: 24, width: 200, height: 17)
    let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: target, action: action)
    slider.frame = NSRect(x: 14, y: 2, width: 222, height: 22)
    view.addSubview(label); view.addSubview(slider)
    let item = NSMenuItem(); item.view = view
    return item
}

func swatch(_ c: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        c.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); p.lineWidth = 1; p.stroke()
        return true
    }
}

// MARK: - App

/// Event-tap callback for Presentation Mode: swallow clicks, but still poke.
private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let app = Unmanaged<AppDelegate>.fromOpaque(info!).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = app.eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown {
        DispatchQueue.main.async { app.didClick() }
    }
    return nil // swallowed: the app underneath never sees the click
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [OverlayWindow] = []
    private let rig = PointerRig()
    private let toast = Toast()
    private var clickTimes: [TimeInterval] = []
    private(set) var presentation = false
    fileprivate var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var displayTimer: Timer?
    private let s = Settings.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        buildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(buildOverlays),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Re-assert the hidden cursor after sleep / screen lock.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reassertCursor),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reassertCursor),
                                                          name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        let click: (NSEvent) -> Void = { [weak self] _ in
            guard let self, !self.presentation else { return } // the event tap handles presentation mode
            self.didClick()
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { click($0); return $0 }

        HotKeys.install()
        HotKeys.register(1, key: kVK_ANSI_P, mods: controlKey | optionKey) { [weak self] in self?.toggleEnabled() }
        HotKeys.register(2, key: kVK_ANSI_T, mods: controlKey | optionKey) { [weak self] in self?.togglePresentation() }

        // URL scheme for automation: tapper://show, hide, toggle, poke, presentation, set?…
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        apply()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let host = URL(string: str)?.host?.lowercased() else { return }
        switch host {
        case "show": if !s.enabled { toggleEnabled() }
        case "hide": if s.enabled { toggleEnabled() }
        case "toggle": toggleEnabled()
        case "poke": didClick()
        case "presentation": togglePresentation()
        case "set":
            // tapper://set?style=tiny|paw|middle&mood=0-4&color=0-7&sound=on|off&animate=on|off
            for q in URLComponents(string: str)?.queryItems ?? [] {
                let v = (q.value ?? "").lowercased(), on = ["1", "on", "true", "yes"].contains(v)
                switch q.name.lowercased() {
                case "style":
                    if let i = ["tiny", "paw", "middle"].firstIndex(of: v) ?? Int(v), let st = HandStyle(rawValue: i) { s.style = st }
                case "mood": if let m = Int(v) { s.mood = min(max(m, 0), 4) }
                case "color": if let c = Int(v) { s.colorIndex = min(max(c, 0), stickColors.count - 1) }
                case "sound": s.soundOn = on
                case "animate": s.animateOnClick = on
                default: NSLog("Tapper: unknown setting \(q.name)")
                }
            }
            apply()
        default: NSLog("Tapper: unknown URL \(str)")
        }
    }

    func applicationWillTerminate(_ note: Notification) { Cursor.setHidden(false) }

    @objc private func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        if s.enabled { overlays.forEach { $0.orderFrontRegardless() } }
        tick()
    }

    @objc private func reassertCursor() {
        guard s.enabled else { return }
        Cursor.setHidden(true)
    }

    private func apply() {
        rig.apply()
        if s.enabled {
            overlays.forEach { $0.orderFrontRegardless() }
            if displayTimer == nil {
                // ~120 Hz on ProMotion; the spring needs a steady clock.
                let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common)
                displayTimer = t
            }
        } else {
            displayTimer?.invalidate(); displayTimer = nil
            rig.rig.removeFromSuperlayer()
            overlays.forEach { $0.orderOut(nil) }
        }
        Cursor.setHidden(s.enabled)
        statusItem.button?.image = NSImage(systemSymbolName: s.enabled ? "hand.point.up.left.fill" : "hand.point.up.left",
                                           accessibilityDescription: "Tapper")
        if !s.enabled && presentation { togglePresentation() }
    }

    /// Overlay on the display under the pointer + the pointer in its coordinates.
    private func currentOverlay() -> (OverlayWindow, CGPoint)? {
        let p = NSEvent.mouseLocation
        guard let o = overlays.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? overlays.first else { return nil }
        return (o, CGPoint(x: p.x - o.frame.minX, y: p.y - o.frame.minY))
    }

    private var tickCount = 0

    private func tick() {
        guard s.enabled else { return }
        // ~20 Hz check that nobody re-showed the system arrow.
        tickCount &+= 1
        if tickCount % 6 == 0 { Cursor.enforce() }
        guard let (o, p) = currentOverlay() else { return }
        if rig.rig.superlayer !== o.root {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            o.root.addSublayer(rig.rig)
            CATransaction.commit()
        }
        rig.step(to: p)
    }

    fileprivate func didClick() {
        guard s.enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        clickTimes.append(now)
        clickTimes.removeAll { now - $0 > 0.7 }
        let power = 1 + 0.6 * CGFloat(clickTimes.count - 1)   // faster clicking → wilder poke
        if s.animateOnClick, let (o, p) = currentOverlay() {
            rig.jab(power: power)
            Burst.pop(in: o.root, at: p, power: power, color: s.stickColor)
        }
        Knock.play()
    }

    // MARK: Actions

    @objc func toggleEnabled() { s.enabled.toggle(); apply() }

    @objc func moodChanged(_ sl: NSSlider) {
        let v = Int(sl.doubleValue.rounded())
        guard v != s.mood else { return }
        s.mood = v; rig.apply()
    }

    @objc func setStyle(_ sender: NSMenuItem) { s.style = HandStyle(rawValue: sender.tag) ?? .tinyHand; rig.apply() }
    @objc func setColor(_ sender: NSMenuItem) { s.colorIndex = sender.tag; rig.apply() }
    @objc func toggleAnimate() { s.animateOnClick.toggle() }
    @objc func toggleSound() { s.soundOn.toggle() }
    @objc func volumeChanged(_ sl: NSSlider) { s.volume = sl.doubleValue }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { NSLog("Tapper login item error: \(error)") }
    }

    @objc func togglePresentation() {
        let screen = currentOverlay()?.0.screen ?? NSScreen.main!
        if presentation {
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: false) }
            if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            eventTap = nil; tapSource = nil; presentation = false
            toast.show("Presentation mode off", on: screen)
            return
        }
        // An event tap that drops events needs Accessibility permission.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            toast.show("Allow Tapper in Settings → Privacy & Security → Accessibility", on: screen)
            return
        }
        if !s.enabled { s.enabled = true; apply() }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .leftMouseDragged, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        presentation = true
        toast.show("Presentation mode on · clicks only poke · ⌃⌥T to exit", on: screen)
    }

    // Rebuilt on every open so it reflects current state. Layout mirrors the original.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let show = NSMenuItem(title: s.enabled ? "Hide pointer" : "Show pointer", action: #selector(toggleEnabled), keyEquivalent: "p")
        show.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(show)
        let pres = NSMenuItem(title: "Presentation mode", action: #selector(togglePresentation), keyEquivalent: "t")
        pres.keyEquivalentModifierMask = [.control, .option]
        pres.state = presentation ? .on : .off
        menu.addItem(pres)
        menu.addItem(.separator())

        menu.addItem(moodItem(value: s.mood, target: self, action: #selector(moodChanged(_:))))
        for st in HandStyle.allCases {
            let it = NSMenuItem(title: st.title, action: #selector(setStyle(_:)), keyEquivalent: "")
            it.tag = st.rawValue
            it.state = s.style == st ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let colors = NSMenu()
        for (i, (name, c)) in stickColors.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(setColor(_:)), keyEquivalent: "")
            it.tag = i; it.image = swatch(c); it.target = self
            it.state = s.colorIndex == i ? .on : .off
            colors.addItem(it)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())

        let anim = NSMenuItem(title: "Animate on click", action: #selector(toggleAnimate), keyEquivalent: "")
        anim.state = s.animateOnClick ? .on : .off
        menu.addItem(anim)
        let snd = NSMenuItem(title: "Knock sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.state = s.soundOn ? .on : .off
        menu.addItem(snd)
        menu.addItem(sliderItem("Volume", value: s.volume, target: self, action: #selector(volumeChanged(_:))))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for it in menu.items where it.action != nil && it.action != #selector(NSApplication.terminate(_:)) { it.target = self }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
