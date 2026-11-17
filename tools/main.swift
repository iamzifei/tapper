// Renders marketing art from the app's own vector glove (Sources/Tapper/Art.swift):
//   swiftc Sources/Tapper/Art.swift tools/main.swift -o /tmp/tapper-art && /tmp/tapper-art <outdir>
// Outputs icon_1024.png (app icon master) and glove-<style>.png for the website.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func save(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

// Website sprites: one PNG per style at 4 px per hand unit.
for s in HandStyle.allCases {
    save(Art.image(s, scale: 2, backing: 2)!, "glove-\(["tiny", "paw", "middle"][s.rawValue]).png")
}

// App icon: warm squircle, stick from the bottom-right, glove poking up-left.
let N = 1024
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let inset: CGFloat = 100, side = CGFloat(N) - inset * 2
let squircle = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(squircle); ctx.clip()
let grad = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 1, green: 0.72, blue: 0.25, alpha: 1).cgColor,
                                                   NSColor(srgbRed: 1, green: 0.42, blue: 0.20, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(N)), end: CGPoint(x: CGFloat(N), y: 0), options: [])
// Comic burst lines around the fingertip.
let tip = CGPoint(x: 370, y: 690)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(22); ctx.setLineCap(.round)
for a in stride(from: 0.6, through: 2.9, by: 0.46) {
    ctx.move(to: CGPoint(x: tip.x + cos(a) * 95, y: tip.y + sin(a) * 95))
    ctx.addLine(to: CGPoint(x: tip.x + cos(a) * 160, y: tip.y + sin(a) * 160))
}
ctx.strokePath()
// Rig: rotate so the hand points up-left; stick continues down-right.
ctx.saveGState()
ctx.translateBy(x: tip.x, y: tip.y); ctx.rotate(by: 0.62); ctx.scaleBy(x: 3.4, y: 3.4)
let stick = CGMutablePath()
stick.move(to: CGPoint(x: Art.stickX - 5, y: -Art.handLength + 4))
stick.addLine(to: CGPoint(x: Art.stickX + 5, y: -Art.handLength + 4))
stick.addLine(to: CGPoint(x: Art.stickX + 3, y: -330)); stick.addLine(to: CGPoint(x: Art.stickX - 3, y: -330))
stick.closeSubpath()
ctx.addPath(stick); ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fillPath()
Art.draw(.tinyHand, in: ctx)
ctx.restoreGState()
save(ctx.makeImage()!, "icon_1024.png")
print("ok")
