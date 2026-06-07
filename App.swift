// App.swift. Sleepless: a standalone menu-bar toggle that keeps the Mac running
// with the lid closed (on battery, no external display) via `pmset disablesleep`.
//
// Mechanism (verified live on this machine; disablesleep is UNDOCUMENTED in
// pmset(1) but real. It sets IORegistry "SleepDisabled" = Yes and disables
// idle + Apple-menu + lid-close clamshell sleep):
//   ON : sudo pmset -a disablesleep 1
//   OFF: sudo pmset -a disablesleep 0
//   READ (no root): pmset -g | grep -i SleepDisabled  (value 1 = ON; 0/absent = OFF)
// The OFF/ON commands run passwordless via a tightly-scoped /etc/sudoers.d drop-in.
// disablesleep is runtime-only and resets to 0 on reboot, and that reset is a
// deliberate safety feature; the app does NOT auto re-arm.
//
// UI: clicking the menu-bar agent glyph opens a small native popover with an NSSwitch
// toggle (the System-Settings control), a state caption, auto-off controls, monitored
// agent status, the battery-floor slider, a Launch-at-login switch, and Quit. The
// menu-bar glyph also shows state at a glance.
//
// The menu-bar mark is deliberately simple: an outline agent means the Mac sleeps
// normally, a filled agent means it is being kept awake, and a filled agent with a
// small dot means it is awake on battery with the auto-off safety net live.
//
// Several fail-safe features layer on top, none of which adds a daemon or
// persists OS state (so "reboot resets it" still holds):
//   1. Auto-off timer (1h / 2h) — a one-shot in-memory Timer that flips sleep back
//      on when it fires. Dies on quit; nothing survives a reboot.
//   2. Launch at login (SMAppService.mainApp) — OFF by default. The app always
//      launches reading the TRUE system state, so a login launch can never
//      re-enable disablesleep on its own.
//   3. Low-Power-Mode auto-off — on battery, if Low Power Mode is on, Sleepless
//      turns itself off. Same shape as the battery floor, evaluated on the same tick.
//   4. Agent/internet auto-off — opt-in safety cutoffs with a grace period; they only
//      turn Sleepless off and never re-arm keep-awake.
//
// Build (mirrors Nexus.app): Command Line Tools `swiftc`, NO Xcode project.
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 -framework AppKit \
//          -framework ServiceManagement -framework Network ...
//   File MUST be named App.swift and compiled -parse-as-library so the
//   @main enum + @MainActor static main() entry is Swift-6 isolation-safe.
import AppKit
import Darwin
import ServiceManagement

// MARK: - Tunables
private let pollInterval: TimeInterval = 30
private let visibleAgentRefreshInterval: TimeInterval = 2
private let cutoffGraceInterval: TimeInterval = 120
// Battery-floor config (user-adjustable via the popover slider; persisted in UserDefaults).
private let floorKey = "batteryFloorPercent"
private let agentAutoOffKey = "agentAutoOffEnabled"
private let internetAutoOffKey = "internetAutoOffEnabled"
private let floorDefault = 15
private let floorMin = 5
private let floorMax = 50
private let appDisplayName = "Sleepless Agents"
private let sudoersDropInPath = "/etc/sudoers.d/sleepless-disablesleep"
private let sudoersCommandGrant = "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"

// MARK: - Menu-bar agent glyph (native SF Symbols, MONOCHROME template — state by SHAPE)
// macOS convention: a menu-bar extra is a template image (no colour) so it adapts to light/dark
// bars and inverts on highlight. State is read from the SILHOUETTE, not colour. The old
// empty-vs-filled cups looked near-identical at 16 px, so we switch the silhouette dramatically
// with an agent/robot silhouette:
//   OFF   (sleeps normally)        = robot outline
//   ON    (kept awake, on power)   = filled robot
//   ARMED (kept awake, on battery) = filled robot + a small dot (auto-off safety net live)
// All template (monochrome); if the robot symbol is unavailable, the coffee-cup glyph is used.
enum SleepGlyph {
    case off
    case on
    case armed
}

private func makeCupGlyph(_ glyph: SleepGlyph) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(scale: .medium))
    let name = (glyph == .off) ? "robot" : "robot.fill"
    let fallback = (glyph == .off) ? "cup.and.saucer" : "cup.and.heat.waves.fill"
    let base = NSImage(systemSymbolName: name, accessibilityDescription: appDisplayName)?
        .withSymbolConfiguration(cfg)
        ?? NSImage(systemSymbolName: fallback, accessibilityDescription: appDisplayName)?
            .withSymbolConfiguration(cfg)
        ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: appDisplayName)
        ?? NSImage()

    guard glyph == .armed else {
        base.isTemplate = true
        return base
    }
    // ARMED: full steaming cup + a small filled dot top-right (the "auto-off safety net is live"
    // mark). Drawn in template black so it tints + inverts with the menu bar exactly like the cup.
    let size = base.size
    guard size.width > 0, size.height > 0 else { base.isTemplate = true; return base }
    let composed = NSImage(size: size)
    composed.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    let d = max(size.height * 0.26, 4)
    let dot = NSBezierPath(ovalIn: NSRect(x: size.width - d, y: size.height - d, width: d, height: d))
    NSColor.black.setFill()
    dot.fill()
    composed.unlockFocus()
    composed.isTemplate = true
    return composed
}

// Flipped container so popover content lays out top-down with simple frames.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// Brand accent (2026 "Liquid Glass" redesign): indigo -> violet -> fuchsia. The
// violet mid-tone is the single accent the popover uses to communicate the
// privileged "awake" state, matching the app icon's gradient mid-stop. These are
// the only hard-coded colours; everything else stays on system semantic colours so
// the panel still reads as a first-party control.
private let brandAccent = NSColor(srgbRed: 139/255.0, green: 92/255.0, blue: 246/255.0, alpha: 1)   // #8B5CF6 violet
private let brandAccentSoft = NSColor(srgbRed: 167/255.0, green: 139/255.0, blue: 250/255.0, alpha: 1) // #A78BFA

// Frosted-glass popover backing: a flipped NSVisualEffectView so content still
// lays out top-down while the panel gets a translucent, blurred material that
// samples the desktop/windows behind it (system light/dark aware). On macOS 26 the
// .popover material renders as the system Liquid Glass automatically; we deliberately
// keep this native (no hand-rolled tint on the surface) so a sudo-touching panel
// stays visually first-party. Colour lives on the controls, never the surface.
private final class GlassView: NSVisualEffectView { override var isFlipped: Bool { true } }

// Inset grouping "card" (System Settings rhythm): a flipped, layer-backed container
// with a subtle, appearance-adaptive fill, a hairline border, and continuous-corner
// rounding. When `active`, the card carries a faint brand-violet wash + a violet
// hairline so the privileged "kept awake" state is unmistakable at a glance in the
// accent colour (Apple's "tint elements, not surfaces" model). Re-resolved on
// light/dark changes and on state changes via updateLayer.
private final class CardView: NSView {
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if active {
            layer?.backgroundColor = brandAccent.withAlphaComponent(dark ? 0.18 : 0.10).cgColor
            layer?.borderColor = brandAccent.withAlphaComponent(dark ? 0.60 : 0.45).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
                                           : NSColor.black.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08)
                                       : NSColor.black.withAlphaComponent(0.06)).cgColor
            layer?.borderWidth = 1
        }
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let power = PowerController()
    private let agentMonitor = AgentMonitor()
    private let connectivityMonitor = ConnectivityMonitor()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let onGlyph = makeCupGlyph(.on)
    private let offGlyph = makeCupGlyph(.off)
    private let armedGlyph = makeCupGlyph(.armed)

    // Popover UI
    private let popover = NSPopover()
    private var toggleSwitch: NSSwitch!
    private var mainCard: CardView!         // group-1 card; gets the brand-violet wash when awake
    private var headerMark: NSImageView!    // header coffee mark; tints violet when awake
    private var captionLabel: NSTextField!
    private var floorValueLabel: NSTextField!
    private var floorSlider: NSSlider!
    private var autoOffControl: NSSegmentedControl!
    private var countdownLabel: NSTextField!
    private var internetSwitch: NSSwitch!
    private var internetStatusLabel: NSTextField!
    private var agentAutoOffSwitch: NSSwitch!
    private var agentSummaryLabel: NSTextField!
    private var agentEmptyLabel: NSTextField!
    private var agentRows: [AgentID: (name: NSTextField, status: NSTextField, setup: NSButton)] = [:]
    private var loginSwitch: NSSwitch!
    private var clickMonitor: Any?
    private var batteryFloorPercent = floorDefault
    private var internetAutoOffEnabled = false
    private var agentAutoOffEnabled = false
    private var isOn = false
    private var userForcedOn = false   // user deliberately turned it on; honor over the Low Power Mode auto-off (the hard battery floor still wins)
    private var lastAgentSnapshots: [AgentToolSnapshot] = []
    private var lastInternetReachable = true
    private var noAgentsSince: Date?
    private var noInternetSince: Date?
    private var agentStatusTicker: Timer?
    private var agentRefreshInFlight = false
    private var agentRefreshPending = false
    private var pendingAgentRefreshCompletions: [() -> Void] = []

    // Auto-off timer (in-memory; dies on quit, never survives a reboot)
    private var autoOffMinutes = 0           // 0 = none (stay on until off), 60, or 120
    private var keepAwakeTimer: Timer?       // one-shot: flips sleep back on when it fires
    private var countdownTicker: Timer?      // 1 Hz label refresh, only while the popover is open
    private var timerEndDate: Date?

    private let popoverWidth: CGFloat = 360
    private let popoverHeight: CGFloat = 632

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryFloorPercent = min(max((UserDefaults.standard.object(forKey: floorKey) as? Int) ?? floorDefault, floorMin), floorMax)
        internetAutoOffEnabled = UserDefaults.standard.bool(forKey: internetAutoOffKey)
        agentAutoOffEnabled = UserDefaults.standard.bool(forKey: agentAutoOffKey)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = offGlyph
            button.action = #selector(statusClicked)
            button.target = self
        }
        popover.behavior = .applicationDefined   // app-managed dismissal (no transient close/reopen flicker)
        popover.animates = true
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.contentViewController = makeContentController()

        refresh()   // reflect TRUE system state on launch (never a stale assumption)
        timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                     selector: #selector(poll), userInfo: nil, repeats: true)
    }

    // MARK: - Popover content (native NSSwitch toggle, macOS-aligned)
    private func makeContentController() -> NSViewController {
        let W = popoverWidth, pad: CGFloat = 16
        let contentW = W - pad * 2
        let ci: CGFloat = 12                 // card inner padding
        let cw = contentW - ci * 2           // card inner content width

        // Standard system popover material: untinted, no forced emphasis, so it reads
        // as a first-party control (like the Wi-Fi / Sound / Battery popovers), not a
        // themed panel. NSPopover supplies its own corner, shadow, and arrow.
        let root = GlassView(frame: NSRect(x: 0, y: 0, width: W, height: popoverHeight))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        // Header: small agent mark + app name (quiet system glyph, not a branded logo).
        // The mark tints to the brand violet while the Mac is kept awake.
        let mark = NSImageView(frame: NSRect(x: pad, y: 14, width: 18, height: 18))
        let headerCup = makeCupGlyph(.on); headerCup.isTemplate = true
        mark.image = headerCup
        mark.contentTintColor = .labelColor
        root.addSubview(mark)
        headerMark = mark
        let title = makeLabel(appDisplayName, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        title.frame = NSRect(x: pad + 24, y: 14, width: contentW - 24, height: 20)
        root.addSubview(title)

        // Grouped inset cards (System Settings rhythm) replace per-row hairline separators.
        func makeCard(_ rect: NSRect) -> CardView {
            let c = CardView(frame: rect)
            c.wantsLayer = true
            root.addSubview(c)
            return c
        }
        let swProto = NSSwitch().intrinsicContentSize
        let swW = swProto.width > 0 ? swProto.width : 38
        let swH = swProto.height > 0 ? swProto.height : 21

        // GROUP 1 — main switch + state caption
        let g1y: CGFloat = 46, g1h: CGFloat = 84
        let g1 = makeCard(NSRect(x: pad, y: g1y, width: contentW, height: g1h))
        mainCard = g1
        let rowLabel = makeLabel("Keep awake with lid closed", font: .systemFont(ofSize: 13), color: .labelColor)
        rowLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g1.addSubview(rowLabel)
        toggleSwitch = NSSwitch()
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled(_:))
        toggleSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g1.addSubview(toggleSwitch)
        captionLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        captionLabel.frame = NSRect(x: ci, y: ci + 30, width: cw, height: 32)
        captionLabel.usesSingleLineMode = false
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2
        captionLabel.cell?.wraps = true
        g1.addSubview(captionLabel)

        // GROUP 2 — auto-off timer (label + segmented [Off | 1h | 2h] + countdown)
        let g2y = g1y + g1h + 10, g2h: CGFloat = 70
        let g2 = makeCard(NSRect(x: pad, y: g2y, width: contentW, height: g2h))
        let timerLabel = makeLabel("Auto-off timer", font: .systemFont(ofSize: 13), color: .labelColor)
        timerLabel.frame = NSRect(x: ci, y: ci, width: 110, height: 22)
        g2.addSubview(timerLabel)
        autoOffControl = NSSegmentedControl(labels: ["Off", "1h", "2h"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(autoOffChanged(_:)))
        autoOffControl.selectedSegment = 0
        autoOffControl.controlSize = .regular
        autoOffControl.segmentStyle = .automatic
        autoOffControl.sizeToFit()
        let segSize = autoOffControl.frame.size
        let segW = segSize.width > 0 ? segSize.width : 150
        autoOffControl.frame = NSRect(x: contentW - ci - segW, y: ci - 1, width: segW, height: max(segSize.height, 24))
        g2.addSubview(autoOffControl)
        countdownLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        countdownLabel.frame = NSRect(x: ci, y: ci + 32, width: cw, height: 16)
        g2.addSubview(countdownLabel)

        // GROUP 3 — agents (only installed/detectable tools are shown)
        let g3y = g2y + g2h + 10, g3h: CGFloat = 134
        let g3 = makeCard(NSRect(x: pad, y: g3y, width: contentW, height: g3h))
        let agentsLabel = makeLabel("Agents", font: .systemFont(ofSize: 13), color: .labelColor)
        agentsLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g3.addSubview(agentsLabel)
        agentAutoOffSwitch = NSSwitch()
        agentAutoOffSwitch.target = self
        agentAutoOffSwitch.action = #selector(agentAutoOffToggled(_:))
        agentAutoOffSwitch.state = agentAutoOffEnabled ? .on : .off
        agentAutoOffSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g3.addSubview(agentAutoOffSwitch)
        agentSummaryLabel = makeLabel("Auto-off when no agents are running", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        agentSummaryLabel.frame = NSRect(x: ci, y: ci + 26, width: cw, height: 17)
        g3.addSubview(agentSummaryLabel)
        agentEmptyLabel = makeLabel("No supported agent tools found", font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
        agentEmptyLabel.frame = NSRect(x: ci, y: ci + 54, width: cw, height: 17)
        g3.addSubview(agentEmptyLabel)
        for (idx, id) in AgentID.allCases.enumerated() {
            let y = ci + 52 + CGFloat(idx * 23)
            let name = makeLabel(id.displayName, font: .systemFont(ofSize: 12), color: .labelColor)
            name.frame = NSRect(x: ci, y: y, width: 112, height: 18)
            let status = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            status.alignment = .right
            status.frame = NSRect(x: ci + 112, y: y, width: cw - 112 - 66, height: 18)
            let setup = NSButton(title: "Set Up", target: self, action: #selector(setupAgentIntegration(_:)))
            setup.tag = idx
            setup.controlSize = .small
            setup.bezelStyle = .rounded
            setup.frame = NSRect(x: contentW - ci - 58, y: y - 2, width: 58, height: 22)
            g3.addSubview(name); g3.addSubview(status); g3.addSubview(setup)
            agentRows[id] = (name, status, setup)
        }

        // GROUP 4 — internet auto-off
        let g4y = g3y + g3h + 10, g4h: CGFloat = 58
        let g4 = makeCard(NSRect(x: pad, y: g4y, width: contentW, height: g4h))
        let internetLabel = makeLabel("Auto-off at no internet", font: .systemFont(ofSize: 13), color: .labelColor)
        internetLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g4.addSubview(internetLabel)
        internetSwitch = NSSwitch()
        internetSwitch.target = self
        internetSwitch.action = #selector(internetAutoOffToggled(_:))
        internetSwitch.state = internetAutoOffEnabled ? .on : .off
        internetSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g4.addSubview(internetSwitch)
        internetStatusLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        internetStatusLabel.frame = NSRect(x: ci, y: ci + 26, width: cw, height: 16)
        g4.addSubview(internetStatusLabel)

        // GROUP 5 — battery-floor (label + value + slider + min/max hints)
        let g5y = g4y + g4h + 10, g5h: CGFloat = 86
        let g5 = makeCard(NSRect(x: pad, y: g5y, width: contentW, height: g5h))
        let floorLabel = makeLabel("Auto-off at low battery", font: .systemFont(ofSize: 13), color: .labelColor)
        floorLabel.frame = NSRect(x: ci, y: ci, width: cw - 54, height: 18)
        g5.addSubview(floorLabel)
        floorValueLabel = makeLabel("\(batteryFloorPercent)%", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        floorValueLabel.alignment = .right
        floorValueLabel.frame = NSRect(x: contentW - ci - 54, y: ci, width: 54, height: 18)
        g5.addSubview(floorValueLabel)
        floorSlider = NSSlider(value: Double(batteryFloorPercent), minValue: Double(floorMin), maxValue: Double(floorMax),
                               target: self, action: #selector(floorSliderChanged(_:)))
        floorSlider.isContinuous = true
        floorSlider.controlSize = .regular
        floorSlider.frame = NSRect(x: ci, y: ci + 24, width: cw, height: 20)
        g5.addSubview(floorSlider)
        let minHint = makeLabel("\(floorMin)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        minHint.frame = NSRect(x: ci, y: ci + 48, width: 34, height: 13)
        g5.addSubview(minHint)
        let maxHint = makeLabel("\(floorMax)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        maxHint.alignment = .right
        maxHint.frame = NSRect(x: contentW - ci - 34, y: ci + 48, width: 34, height: 13)
        g5.addSubview(maxHint)

        // GROUP 6 — launch at login (off by default; never auto-enables sleep prevention)
        let g6y = g5y + g5h + 10, g6h: CGFloat = 42
        let g6 = makeCard(NSRect(x: pad, y: g6y, width: contentW, height: g6h))
        let loginLabel = makeLabel("Launch at login", font: .systemFont(ofSize: 13), color: .labelColor)
        loginLabel.frame = NSRect(x: ci, y: 10, width: cw - swW - 8, height: 22)
        g6.addSubview(loginLabel)
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggled(_:))
        loginSwitch.state = loginItemEnabled() ? .on : .off
        loginSwitch.frame = NSRect(x: contentW - ci - swW, y: 10 + (22 - swH) / 2, width: swW, height: swH)
        g6.addSubview(loginSwitch)

        // Footer — Quit (separated by space, not a hairline)
        let quit = NSButton(title: "Quit \(appDisplayName)", target: self, action: #selector(quit))
        quit.controlSize = .regular
        quit.bezelStyle = .rounded
        quit.sizeToFit()
        let qs = quit.frame.size
        quit.frame = NSRect(x: W - pad - qs.width, y: g6y + g6h + 10, width: qs.width, height: qs.height)
        root.addSubview(quit)

        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        return t
    }

    // MARK: - Click the menu-bar cup to open/close the popover
    @objc private func statusClicked() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        refresh()                              // sync switch/caption to TRUE state before showing
        refreshAgentStatus()
        loginSwitch?.state = loginItemEnabled() ? .on : .off
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if keepAwakeTimer != nil { startCountdownTicker() }
        startAgentStatusTicker()
        updateCountdownLabel()
        // Close when the user clicks anywhere outside the app (status bar, another app, desktop).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        countdownTicker?.invalidate(); countdownTicker = nil   // stop the 1 Hz label refresh (keep-awake timer keeps running)
        agentStatusTicker?.invalidate(); agentStatusTicker = nil
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        if performToggle(wantOn: sender.state == .on) {
            sender.state = .off   // setup needed / failed: reflect reality (performToggle notified)
        }
    }

    // Core keep-awake toggle, decoupled from the UI sender. Returns true ONLY when the user
    // must act (the passwordless grant is missing and setup did not complete) so the caller can
    // reflect OFF. The decision to prompt is made on the REAL sudo result (see setDisableSleep),
    // never by re-reading SleepDisabled: a successful sudo means the command ran, even if a
    // safety net (Low Power Mode / battery floor) legitimately turns sleep back on afterwards —
    // which must NOT be mistaken for "permission missing" and trigger a password prompt. This
    // unobservable, state-proxy decision is what made earlier releases re-prompt spuriously.
    @discardableResult
    private func performToggle(wantOn: Bool) -> Bool {
        var result = setDisableSleep(wantOn)
        // Only a genuinely MISSING grant warrants the one-time native-auth setup. A successful
        // sudo (.ok) — or any other failure — never re-prompts here.
        if wantOn, result == .grantMissing {
            if installGrantViaAuth() { result = setDisableSleep(true) }
            if result != .ok {
                notify("Couldn't keep awake. The permission isn't set up yet.")
                return true
            }
        }
        // A deliberate, successful turn-on wins over the Low Power Mode auto-off (hard floor still wins).
        userForcedOn = wantOn && result == .ok
        refresh()                              // applies UI + safety nets; switch reflects reality
        if isOn, autoOffMinutes > 0 { startKeepAwakeTimer(minutes: autoOffMinutes) }
        return false
    }

    // Install the one-time scoped grant via a SINGLE native macOS authorization (the
    // standard Touch ID / password sheet) — no Terminal. The privileged script is
    // generated from constants baked into this binary, not loaded from the mutable app
    // bundle, then validated with visudo before installation.
    // Returns true once the passwordless grant is in place; after that the app never asks again.
    @discardableResult
    private func installGrantViaAuth() -> Bool {
        let intro = NSAlert()
        intro.alertStyle = .informational
        intro.messageText = "Enable keeping your Mac awake"
        intro.informativeText = "\(appDisplayName) flips a protected macOS setting (pmset disablesleep), so it needs your permission once. macOS will ask you to authenticate (Touch ID or your password). After that the switch works instantly, with no more prompts."
        intro.addButton(withTitle: "Enable")
        intro.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return false }

        guard let userSpec = sudoersUserSpec() else {
            notify("Couldn't set up permission: unsupported user ID.")
            return false
        }

        let grant = "\(userSpec) \(sudoersCommandGrant)"
        let installScript = [
            "set -euo pipefail",
            "tmp=\"$(/usr/bin/mktemp)\"",
            "trap '/bin/rm -f \"$tmp\"' EXIT",
            "/usr/bin/printf '%s\\n' \(shellSingleQuoted(grant)) > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null",
            "/usr/bin/install -m 0440 -o root -g wheel \"$tmp\" \(shellSingleQuoted(sudoersDropInPath))",
            "/usr/sbin/visudo -c >/dev/null"
        ].joined(separator: "; ")
        let shellCmd = "/bin/bash -c \(shellSingleQuoted(installScript))"
        let osa = "do shell script \(appleScriptStringLiteral(shellCmd)) with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        let errData: Data
        do {
            try proc.run()
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        }
        catch { notify("Couldn't start the one-time setup."); return false }
        if proc.terminationStatus == 0 { return true }   // sudoers drop-in installed successfully
        if proc.terminationStatus != 128 {               // 128 = user cancelled the auth sheet
            let err = String(data: errData, encoding: .utf8) ?? ""
            if !err.isEmpty { NSLog("Sleepless setup failed: %@", err) }
            notify("Setup didn't complete. Try again, or run grant.sh from the app bundle.")
        }
        return false
    }

    private func sudoersUserSpec() -> String? {
        let uid = getuid()
        guard uid > 0 else { return nil }
        return "#\(uid)"
    }

    private func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // A brief, subtle pulse on the menu-bar glyph whenever the state (and thus the cup
    // shape) changes, so the change is noticeable. Opacity-only: no layer geometry is
    // mutated, so it can't shift the status item on any macOS version.
    private func pulseStatusItem() {
        guard let b = statusItem.button else { return }
        b.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = 0.34
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        b.layer?.add(pulse, forKey: "statePulse")
    }

    @objc private func poll() {
        refreshAgentStatus()
        connectivityMonitor.checkNow { [weak self] reachable in
            guard let self else { return }
            self.lastInternetReachable = reachable
            self.renderInternetSection()
            self.refresh()
        }
    }

    // MARK: - Auto-off timer (Feature 1)
    @objc private func autoOffChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: autoOffMinutes = 60
        case 2: autoOffMinutes = 120
        default: autoOffMinutes = 0
        }
        if isOn, autoOffMinutes > 0 {
            startKeepAwakeTimer(minutes: autoOffMinutes)
        } else {
            cancelKeepAwakeTimer()
            updateCountdownLabel()
        }
    }

    private func startKeepAwakeTimer(minutes: Int) {
        cancelKeepAwakeTimer()
        guard minutes > 0, isOn else { updateCountdownLabel(); return }
        let seconds = TimeInterval(minutes * 60)
        timerEndDate = Date().addingTimeInterval(seconds)
        keepAwakeTimer = Timer.scheduledTimer(timeInterval: seconds, target: self,
                                              selector: #selector(keepAwakeTimerFired), userInfo: nil, repeats: false)
        if popover.isShown { startCountdownTicker() }
        updateCountdownLabel()
    }

    private func cancelKeepAwakeTimer() {
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        countdownTicker?.invalidate(); countdownTicker = nil
        timerEndDate = nil
    }

    @objc private func keepAwakeTimerFired() {
        setDisableSleep(false)
        cancelKeepAwakeTimer()
        autoOffMinutes = 0
        autoOffControl?.selectedSegment = 0
        applyUI(on: readSleepDisabled())
        notify("Auto-off timer ended. \(appDisplayName) turned off.")
    }

    private func startCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(countdownTick), userInfo: nil, repeats: true)
    }

    @objc private func countdownTick() { updateCountdownLabel() }

    private func updateCountdownLabel() {
        guard let end = timerEndDate, isOn else { countdownLabel?.stringValue = ""; return }
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        guard remaining > 0 else { countdownLabel?.stringValue = ""; return }
        let h = remaining / 3600, m = (remaining % 3600) / 60, s = remaining % 60
        let t = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        countdownLabel?.stringValue = "Auto-off in \(t)"
    }

    // MARK: - Agent + internet cutoffs
    @objc private func agentAutoOffToggled(_ sender: NSSwitch) {
        if sender.state == .on {
            refreshAgentStatus { [weak self] in
                guard let self else { return }
                let healthyCount = self.lastAgentSnapshots.filter { $0.status != .setupNeeded }.count
                if self.lastAgentSnapshots.isEmpty {
                    self.agentAutoOffEnabled = false
                    sender.state = .off
                    UserDefaults.standard.set(false, forKey: agentAutoOffKey)
                    self.notify("No supported agent tools found.")
                } else if healthyCount == 0 {
                    self.agentAutoOffEnabled = false
                    sender.state = .off
                    UserDefaults.standard.set(false, forKey: agentAutoOffKey)
                    self.notify("Set up an agent detector before enabling agent auto-off.")
                } else {
                    self.agentAutoOffEnabled = true
                    UserDefaults.standard.set(true, forKey: agentAutoOffKey)
                }
                self.renderAgentSection()
            }
            return
        }
        agentAutoOffEnabled = false
        UserDefaults.standard.set(false, forKey: agentAutoOffKey)
        noAgentsSince = nil
        renderAgentSection()
    }

    @objc private func internetAutoOffToggled(_ sender: NSSwitch) {
        internetAutoOffEnabled = sender.state == .on
        UserDefaults.standard.set(internetAutoOffEnabled, forKey: internetAutoOffKey)
        if !internetAutoOffEnabled { noInternetSince = nil }
        renderInternetSection()
    }

    @objc private func setupAgentIntegration(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < AgentID.allCases.count else { return }
        let id = AgentID.allCases[sender.tag]
        let result = agentMonitor.installIntegration(for: id)
        if result.ok {
            notify(result.message)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(id.displayName) detector set up"
            alert.informativeText = "\(appDisplayName) installed an app-wide hook for \(id.displayName). The row should now show Idle, and it will show Active only while the hook is producing fresh activity heartbeats."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            notify("Couldn't set up \(id.displayName). Details were logged.")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't set up \(id.displayName)"
            alert.informativeText = "\(result.message)\n\nDebug log:\n\(result.logURL.path)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshAgentStatus()
    }

    private func startAgentStatusTicker() {
        agentStatusTicker?.invalidate()
        agentStatusTicker = Timer.scheduledTimer(timeInterval: visibleAgentRefreshInterval, target: self,
                                                 selector: #selector(agentStatusTick), userInfo: nil, repeats: true)
    }

    @objc private func agentStatusTick() { refreshAgentStatus() }

    private func refreshAgentStatus(completion: (() -> Void)? = nil) {
        guard !agentRefreshInFlight else {
            agentRefreshPending = true
            if let completion { pendingAgentRefreshCompletions.append(completion) }
            return
        }
        agentRefreshInFlight = true
        agentMonitor.snapshotsAsync { [weak self] snapshots in
            guard let self else { return }
            self.agentRefreshInFlight = false
            self.lastAgentSnapshots = snapshots
            self.renderAgentSection()
            completion?()
            if self.agentRefreshPending {
                let completions = self.pendingAgentRefreshCompletions
                self.pendingAgentRefreshCompletions = []
                self.agentRefreshPending = false
                self.refreshAgentStatus {
                    completions.forEach { $0() }
                }
            }
        }
    }

    private func renderAgentSection() {
        agentAutoOffSwitch?.state = agentAutoOffEnabled ? .on : .off
        let activeCount = lastAgentSnapshots.filter { $0.status == .active }.count
        let healthyCount = lastAgentSnapshots.filter { $0.status != .setupNeeded }.count
        if lastAgentSnapshots.isEmpty {
            agentSummaryLabel?.stringValue = "Auto-off when no agents are running"
            agentEmptyLabel?.isHidden = false
            agentAutoOffSwitch?.isEnabled = false
        } else {
            agentEmptyLabel?.isHidden = true
            agentAutoOffSwitch?.isEnabled = true
            if activeCount > 0 {
                agentSummaryLabel?.stringValue = "\(activeCount) active agent\(activeCount == 1 ? "" : "s") detected"
            } else if healthyCount == 0 {
                agentSummaryLabel?.stringValue = "Set up a detector before auto-off can act"
            } else {
                agentSummaryLabel?.stringValue = "No active agents detected"
            }
        }

        for id in AgentID.allCases {
            guard let row = agentRows[id] else { continue }
            guard let snapshot = lastAgentSnapshots.first(where: { $0.id == id }) else {
                row.name.isHidden = true
                row.status.isHidden = true
                row.setup.isHidden = true
                continue
            }
            row.name.isHidden = false
            row.status.isHidden = false
            let setupNeeded = snapshot.status == .setupNeeded
            row.setup.isHidden = !setupNeeded
            let statusRightEdge = setupNeeded ? row.setup.frame.minX - 8 : row.setup.frame.maxX
            row.status.frame.size.width = max(0, statusRightEdge - row.status.frame.minX)
            row.status.stringValue = snapshot.status.rawValue
            row.status.textColor = snapshot.status == .active ? brandAccentSoft : .secondaryLabelColor
        }
    }

    private func renderInternetSection() {
        internetSwitch?.state = internetAutoOffEnabled ? .on : .off
        internetStatusLabel?.stringValue = lastInternetReachable
            ? "Internet reachable"
            : "Internet not reachable"
        internetStatusLabel?.textColor = lastInternetReachable ? .secondaryLabelColor : .systemOrange
    }

    // MARK: - Launch at login (Feature 2) — OFF by default; never re-enables sleep prevention
    @objc private func loginToggled(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sleepless: login item update failed: %@", error.localizedDescription)
            notify("Couldn't update Launch at login.")
        }
        sender.state = loginItemEnabled() ? .on : .off
    }

    private func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Core state sync
    @objc private func refresh() {
        let on = readSleepDisabled()
        applyUI(on: on)
        if on { enforceSafetyNets() }
    }

    private func applyUI(on: Bool) {
        isOn = on
        if !on { cancelKeepAwakeTimer() }   // going OFF clears any countdown/timer
        // ARMED = kept awake while actively discharging on battery, so the
        // auto-off safety net is live. Distinct menu-bar glyph (cup + dot).
        var armed = false
        if on {
            let (onBattery, discharging, _) = batteryStatus()
            armed = onBattery && discharging
        }
        if let button = statusItem.button {
            let newImage = on ? (armed ? armedGlyph : onGlyph) : offGlyph
            if button.image !== newImage {   // state (cup shape) changed -> swap + pulse
                button.image = newImage
                pulseStatusItem()
            }
            button.toolTip = on
                ? (armed
                    ? "\(appDisplayName): on (battery). Auto-off at \(batteryFloorPercent)% or in Low Power Mode."
                    : "\(appDisplayName): on. Stays awake with the lid closed.")
                : "\(appDisplayName): off. Sleeps normally."
        }
        toggleSwitch?.state = on ? .on : .off
        // Brand-violet accent communicates the privileged "awake" state at a glance.
        mainCard?.active = on
        headerMark?.contentTintColor = on ? brandAccentSoft : .labelColor
        renderText()
        renderAgentSection()
        renderInternetSection()
        updateCountdownLabel()
    }

    // Update text labels only (no pmset subprocess; safe to call on every slider tick).
    private func renderText() {
        floorValueLabel?.stringValue = "\(batteryFloorPercent)%"
        if isOn {
            var cutoffs = ["\(batteryFloorPercent)% battery", "Low Power Mode"]
            if internetAutoOffEnabled { cutoffs.append("no internet") }
            if agentAutoOffEnabled { cutoffs.append("no agents") }
            captionLabel?.stringValue = "Stays awake with the lid closed. Turns off at " + cutoffs.joined(separator: ", ") + "."
        } else {
            captionLabel?.stringValue = "Sleeps normally when you close the lid."
        }
    }

    @objc private func floorSliderChanged(_ sender: NSSlider) {
        let v = min(max(Int(sender.doubleValue.rounded()), floorMin), floorMax)
        if v != batteryFloorPercent {
            batteryFloorPercent = v
            UserDefaults.standard.set(v, forKey: floorKey)
        }
        renderText()
    }

    @discardableResult
    private func setDisableSleep(_ on: Bool) -> ToggleResult {
        power.setDisableSleep(on)
    }

    // MARK: - Battery + Low-Power-Mode safety nets (silent; no extra UI) — Feature 3
    private func enforceSafetyNets() {
        let (onBattery, discharging, percent) = batteryStatus()
        if onBattery, discharging {
            // Hard battery floor ALWAYS wins, even over a deliberate turn-on: never drain to empty.
            if percent <= batteryFloorPercent {
                turnOffFromSafetyNet("Battery low (\(percent)%). \(appDisplayName) turned off.")
                userForcedOn = false
                return
            }
            // Low Power Mode auto-off, UNLESS the user deliberately chose to keep awake this session.
            if ProcessInfo.processInfo.isLowPowerModeEnabled && !userForcedOn {
                turnOffFromSafetyNet("Low Power Mode on. \(appDisplayName) turned off.")
                return
            }
        }

        enforceInternetCutoff()
        enforceAgentCutoff()
    }

    private func enforceInternetCutoff() {
        guard internetAutoOffEnabled else { noInternetSince = nil; return }
        if lastInternetReachable {
            noInternetSince = nil
            return
        }
        let since = noInternetSince ?? Date()
        noInternetSince = since
        if Date().timeIntervalSince(since) >= cutoffGraceInterval {
            noInternetSince = nil
            turnOffFromSafetyNet("No internet connection. \(appDisplayName) turned off.")
        }
    }

    private func enforceAgentCutoff() {
        guard agentAutoOffEnabled else { noAgentsSince = nil; return }
        if lastAgentSnapshots.isEmpty {
            agentAutoOffEnabled = false
            UserDefaults.standard.set(false, forKey: agentAutoOffKey)
            noAgentsSince = nil
            renderAgentSection()
            notify("No supported agent tools found. Agent auto-off was disabled.")
            return
        }
        let healthy = lastAgentSnapshots.filter { $0.status != .setupNeeded }
        guard !healthy.isEmpty else { noAgentsSince = nil; return }
        if healthy.contains(where: { $0.status == .active }) {
            noAgentsSince = nil
            return
        }
        let since = noAgentsSince ?? Date()
        noAgentsSince = since
        if Date().timeIntervalSince(since) >= cutoffGraceInterval {
            noAgentsSince = nil
            turnOffFromSafetyNet("No agents running. \(appDisplayName) turned off.")
        }
    }

    private func turnOffFromSafetyNet(_ message: String) {
        setDisableSleep(false)
        applyUI(on: readSleepDisabled())
        notify(message)
    }

    // MARK: - Readers (no root needed)
    private func readSleepDisabled() -> Bool {
        power.readSleepDisabled()
    }

    private func batteryStatus() -> (onBattery: Bool, discharging: Bool, percent: Int) {
        let status = power.batteryStatus()
        return (status.onBattery, status.discharging, status.percent)
    }

    // MARK: - Notification (mirrors Nexus' osascript approach)
    private func notify(_ message: String) {
        let script = "display notification \(appleScriptStringLiteral(message)) with title \(appleScriptStringLiteral(appDisplayName)) sound name \(appleScriptStringLiteral("Tink"))"
        _ = ShellRunner.capture("/usr/bin/osascript", ["-e", script])
    }

    private func appleScriptStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum SleeplessApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

nonisolated(unsafe) private var delegateKey = 0
