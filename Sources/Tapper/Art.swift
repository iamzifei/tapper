// Vector art for the pointer: cartoon glove styles drawn with Core Graphics.
//
// Coordinate system ("hand units", y-up): the hotspot (fingertip) is at (0, 0)
// and the hand hangs below it. The cuff ends at y = -handLength, where the
// stick starts at x = stickX. Everything is drawn back-to-front with a white
// fill and black outline, so shapes in front hide the outlines behind them —
// that gives the classic cartoon "finger separation" lines for free.

import AppKit

enum HandStyle: Int, CaseIterable {
    case tinyHand, catPaw, middleChild
    var title: String { ["Tiny hand", "Cat paw", "Middle child"][rawValue] }
}

enum Art {
    static let handLength: CGFloat = 104   // fingertip → bottom of cuff
    static let stickX: CGFloat = 4          // where the stick attaches (hand units)
    static let bounds = CGRect(x: -40, y: -110, width: 80, height: 118) // drawing extent incl. outline

    static let outline = NSColor.black.cgColor
    static let glove = NSColor.white.cgColor
    static let bean = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.70, alpha: 1).cgColor
    static let lineWidth: CGFloat = 3.2

    // MARK: Shape helpers

    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
    }

    static func ellipse(center c: CGPoint, w: CGFloat, h: CGFloat, angle: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
        return CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: &t)
    }

    /// Fill white (or `fill`) then stroke black.
    static func piece(_ ctx: CGContext, _ p: CGPath, fill: CGColor = glove) {
        ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(outline); ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round); ctx.strokePath()
    }

    static func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat = 2.2) {
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.setStrokeColor(outline); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.strokePath()
    }

    /// Flared cuff with ribbing, shared by the two glove styles.
    static func cuff(_ ctx: CGContext) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -15, y: -84))
        p.addLine(to: CGPoint(x: 23, y: -84))
        p.addQuadCurve(to: CGPoint(x: 26, y: -104), control: CGPoint(x: 27, y: -92))
        p.addQuadCurve(to: CGPoint(x: -18, y: -104), control: CGPoint(x: 4, y: -108))
        p.addQuadCurve(to: CGPoint(x: -15, y: -84), control: CGPoint(x: -19, y: -92))
        p.closeSubpath()
        piece(ctx, p)
        for x in stride(from: -9.0, through: 19.0, by: 7.0) {
            line(ctx, CGPoint(x: x, y: -88), CGPoint(x: x + (x - 4) * 0.08, y: -101), width: 1.8)
        }
    }

    // MARK: Styles

    static func draw(_ style: HandStyle, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        switch style {
        case .tinyHand: tinyHand(ctx)
        case .catPaw: catPaw(ctx)
        case .middleChild: middleChild(ctx)
        }
    }

    /// Classic pointing glove: index finger up, other fingers curled to the right.
    static func tinyHand(_ ctx: CGContext) {
        piece(ctx, rounded(CGRect(x: -17, y: -88, width: 46, height: 50), 15))           // palm
        piece(ctx, rounded(CGRect(x: 4, y: -76, width: 26, height: 15), 7.5))            // pinky
        piece(ctx, rounded(CGRect(x: 4, y: -65, width: 28, height: 15), 7.5))            // ring
        piece(ctx, rounded(CGRect(x: 4, y: -54, width: 27, height: 15), 7.5))            // middle
        piece(ctx, rounded(CGRect(x: -9, y: -46, width: 19, height: 48), 9.5))           // index finger
        piece(ctx, ellipse(center: CGPoint(x: -15, y: -64), w: 15, h: 30, angle: 0.45))  // thumb
        // little glove stitches on the back of the hand
        line(ctx, CGPoint(x: 0, y: -70), CGPoint(x: 1, y: -79))
        line(ctx, CGPoint(x: 8, y: -71), CGPoint(x: 9, y: -80))
        cuff(ctx)
    }

    /// Middle finger up, index curled on the left, ring + pinky on the right.
    static func middleChild(_ ctx: CGContext) {
        piece(ctx, rounded(CGRect(x: -22, y: -88, width: 50, height: 50), 15))           // palm
        piece(ctx, rounded(CGRect(x: 4, y: -72, width: 25, height: 15), 7.5))            // pinky
        piece(ctx, rounded(CGRect(x: 4, y: -60, width: 26, height: 15), 7.5))            // ring
        piece(ctx, rounded(CGRect(x: -27, y: -58, width: 24, height: 15), 7.5))          // index, curled left
        piece(ctx, rounded(CGRect(x: -9, y: -48, width: 19, height: 50), 9.5))           // middle finger
        piece(ctx, ellipse(center: CGPoint(x: -21, y: -78), w: 13, h: 22, angle: 1.1))   // thumb tucked low
        cuff(ctx)
    }

    /// A round cat paw with pink toe beans on a furry arm.
    static func catPaw(_ ctx: CGContext) {
        // furry forearm
        let arm = CGMutablePath()
        arm.move(to: CGPoint(x: -14, y: -50))
        arm.addLine(to: CGPoint(x: 22, y: -50))
        arm.addQuadCurve(to: CGPoint(x: 16, y: -104), control: CGPoint(x: 22, y: -80))
        arm.addQuadCurve(to: CGPoint(x: -8, y: -104), control: CGPoint(x: 4, y: -107))
        arm.addQuadCurve(to: CGPoint(x: -14, y: -50), control: CGPoint(x: -14, y: -80))
        arm.closeSubpath()
        piece(ctx, arm)
        // fur tufts on the arm
        line(ctx, CGPoint(x: -6, y: -82), CGPoint(x: -1, y: -86), width: 1.8)
        line(ctx, CGPoint(x: 9, y: -90), CGPoint(x: 14, y: -94), width: 1.8)
        // paw body
        piece(ctx, ellipse(center: CGPoint(x: 2, y: -36), w: 52, h: 42, angle: 0))
        // toes (the top-middle toe is the hotspot)
        let toes: [(CGFloat, CGFloat)] = [(-21, -18), (-8, -8), (8, -6), (22, -14)]
        for (x, y) in toes { piece(ctx, ellipse(center: CGPoint(x: x, y: y), w: 17, h: 18, angle: 0)) }
        // beans
        for (x, y) in toes { piece(ctx, ellipse(center: CGPoint(x: x, y: y - 1), w: 8, h: 9, angle: 0), fill: bean) }
        let pad = CGMutablePath()
        pad.addEllipse(in: CGRect(x: -13, y: -50, width: 30, height: 22))
        piece(ctx, pad, fill: bean)
    }

    /// Render a style to a CGImage at `scale` points-per-hand-unit (retina aware).
    static func image(_ style: HandStyle, scale: CGFloat, backing: CGFloat = 2) -> CGImage? {
        let px = scale * backing
        let w = Int(ceil(bounds.width * px)), h = Int(ceil(bounds.height * px))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: px, y: px)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(style, in: ctx)
        return ctx.makeImage()
    }
}
