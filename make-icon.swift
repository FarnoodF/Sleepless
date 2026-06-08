// Sleepless app icon generator (native, AppKit-rendered).
//
// Renders a friendly AI/chatbot robot — white "helmet" head with a lavender visor,
// two big eyes, knob-tipped antennae and side ears — on a continuous-curvature
// ("squircle") Liquid-Glass plate carrying the brand's purple gradient. The
// Dock/Finder icon carries the full robot identity; the menu bar still uses a
// simplified monochrome template glyph so it stays legible at 16 px.
// Each iconset size is rendered directly from vector shapes (no raster downscaling).
//
// Build + run:  swiftc -O -framework AppKit make-icon.swift -o /tmp/mkicon && /tmp/mkicon [outDir]
// Then:         iconutil -c icns Sleepless.iconset -o Sleepless.icns
//
// Output directory = first CLI argument, else the current working directory.
// (No hardcoded paths, so it works from any clone — build.sh passes a temp dir.)
import AppKit

// ---- Brand palette (2026 redesign): a violet -> deep-purple diagonal gradient,
// lighter at the top-left so it harmonises with the system's icon lighting. The
// white robot reads cleanly on top; the violet mid-stop matches the popover accent.
let plateTop = NSColor(srgbRed: 167/255.0, green: 139/255.0, blue: 250/255.0, alpha: 1) // #A78BFA light violet
let plateMid = NSColor(srgbRed: 139/255.0, green:  92/255.0, blue: 246/255.0, alpha: 1) // #8B5CF6 violet
let plateBot = NSColor(srgbRed: 109/255.0, green:  40/255.0, blue: 217/255.0, alpha: 1) // #6D28D9 deep purple

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let iconset = "\(outDir)/Sleepless.iconset"

// Continuous-curvature squircle path (superellipse, exponent ~5 ~= Apple plate).
func squirclePath(rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func renderIcon(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Apple plate grid: ~824 plate on 1024 canvas (≈100px gutter), scaled to S.
    let gutter = S * (100.0 / 1024.0)
    let plate = CGRect(x: gutter, y: gutter, width: S - 2 * gutter, height: S - 2 * gutter)
    let path = squirclePath(rect: plate)

    // Plate fill: light-violet -> violet -> deep-purple diagonal gradient (lighter
    // top-left, deeper bottom-right) so it agrees with the system icon lighting.
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs,
        colors: [plateTop.cgColor, plateMid.cgColor, plateBot.cgColor] as CFArray,
        locations: [0, 0.5, 1])!
    cg.drawLinearGradient(grad,
        start: CGPoint(x: plate.minX, y: plate.maxY),   // top-left (light violet)
        end:   CGPoint(x: plate.maxX, y: plate.minY),   // bottom-right (deep purple)
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Soft top-left glass sheen (specular highlight, radial white), clipped to plate.
    let sheen = CGGradient(colorsSpace: cs,
        colors: [NSColor(white: 1, alpha: 0.32).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
        locations: [0, 1])!
    let gc = CGPoint(x: plate.minX + plate.width * 0.32, y: plate.maxY - plate.height * 0.26)
    cg.drawRadialGradient(sheen, startCenter: gc, startRadius: 0,
                          endCenter: gc, endRadius: plate.width * 0.66, options: [])

    // Faint white "lit from within" glow behind the robot for depth.
    let glow = CGGradient(colorsSpace: cs,
        colors: [NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
        locations: [0, 1])!
    let glowC = CGPoint(x: plate.midX, y: plate.midY)
    cg.drawRadialGradient(glow, startCenter: glowC, startRadius: 0,
                          endCenter: glowC, endRadius: plate.width * 0.44, options: [])

    cg.restoreGState()

    // ---- AI / chatbot robot: a friendly white "helmet" head with a lavender visor,
    // two big eyes, side ears, and short antennae that stick OUT of the ears. The
    // antennae sit on the sides (not above the head) so the face reads big and central.
    let pw = plate.width, ph = plate.height
    let cx = plate.midX
    let cy = plate.midY
    let headW = pw * 0.54
    let headH = ph * 0.54
    let head = CGRect(x: cx - headW / 2, y: cy - headH / 2, width: headW, height: headH)
    let headCorner = headW * 0.30             // large radius -> soft, helmet-like silhouette

    // Ears: white rounded tabs on each side at head mid-height.
    let earW = pw * 0.085
    let earH = ph * 0.22
    func earRect(_ sign: CGFloat) -> CGRect {
        let earX = sign < 0 ? head.minX - earW * 0.45 : head.maxX - earW * 0.55
        return CGRect(x: earX, y: cy - earH / 2, width: earW, height: earH)
    }

    // Straight, vertical antennae rising from the ears (knob-tipped). Drawn first so
    // the ear covers the join and they read as rooted in the ear.
    cg.saveGState()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(max(pw * 0.020, 1.6))
    cg.setLineCap(.round)
    for sign in [-1.0, 1.0] as [CGFloat] {
        let ear = earRect(sign)
        let baseX = ear.midX
        let baseY = ear.maxY - earH * 0.10
        let tipX  = ear.midX                       // straight up (no outward lean)
        let tipY  = head.maxY + ph * 0.050          // rises above the head top
        cg.move(to: CGPoint(x: baseX, y: baseY))
        cg.addLine(to: CGPoint(x: tipX, y: tipY))
        cg.strokePath()
        let knob = pw * 0.060
        cg.addEllipse(in: CGRect(x: tipX - knob / 2, y: tipY - knob / 2, width: knob, height: knob))
        NSColor.white.setFill(); cg.fillPath()
    }
    cg.restoreGState()

    // Ears drawn over the antenna base.
    NSColor.white.setFill()
    for sign in [-1.0, 1.0] as [CGFloat] {
        let ear = earRect(sign)
        cg.addPath(CGPath(roundedRect: ear, cornerWidth: earW * 0.45, cornerHeight: earW * 0.45, transform: nil))
        cg.fillPath()
    }

    // Head (white) with a soft drop shadow for depth on the glass plate.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.022,
                 color: NSColor(srgbRed: 0.20, green: 0.06, blue: 0.40, alpha: 0.45).cgColor)
    cg.addPath(CGPath(roundedRect: head, cornerWidth: headCorner, cornerHeight: headCorner, transform: nil))
    NSColor.white.setFill()
    cg.fillPath()
    cg.restoreGState()

    // Visor: an inset rounded panel with a subtle lavender -> white vertical gradient.
    let visor = head.insetBy(dx: headW * 0.135, dy: headH * 0.150)
    let visorCorner = visor.width * 0.34
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: visor, cornerWidth: visorCorner, cornerHeight: visorCorner, transform: nil))
    cg.clip()
    let visorGrad = CGGradient(colorsSpace: cs,
        colors: [NSColor(srgbRed: 214/255.0, green: 204/255.0, blue: 255/255.0, alpha: 1).cgColor,  // top: light lavender
                 NSColor.white.cgColor] as CFArray,                                                  // bottom: white
        locations: [0, 1])!
    cg.drawLinearGradient(visorGrad,
        start: CGPoint(x: visor.midX, y: visor.maxY),
        end:   CGPoint(x: visor.midX, y: visor.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // Eyes: two big, dark-violet dots centered in the visor.
    let eye = NSColor(srgbRed: 59/255.0, green: 30/255.0, blue: 120/255.0, alpha: 1)
    eye.setFill()
    let eyeR  = headW * 0.075
    let eyeDX = headW * 0.15
    let eyeY  = visor.midY + visor.height * 0.02
    for sign in [-1.0, 1.0] as [CGFloat] {
        cg.addEllipse(in: CGRect(x: cx + sign * eyeDX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
        cg.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
try? fm.removeItem(atPath: iconset)
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// 10 standard iconset entries (size, @2x?) -> render each directly from vector.
let specs: [(String, CGFloat)] = [
    ("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
    ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024),
]
for (name, px) in specs { write(renderIcon(px), "\(iconset)/\(name).png") }
write(renderIcon(1024), "\(outDir)/Sleepless-1024.png")
print("rendered iconset (\(specs.count) sizes) + Sleepless-1024.png")
