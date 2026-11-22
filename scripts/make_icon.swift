// swift scripts/make_icon.swift GibVid/Resources/Assets.xcassets/AppIcon.appiconset/icon.png
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Indiquer le chemin du PNG de sortie.")
}

let side = 1024
let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
let ink = CGColor(srgbRed: 0.06, green: 0.06, blue: 0.065, alpha: 1)
let paper = CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)
context.setFillColor(ink)
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.translateBy(x: 512, y: 512)
context.rotate(by: 8 * .pi / 180)

// Photogramme découpé en biais et coin de pellicule replié.
context.setFillColor(paper)
context.move(to: CGPoint(x: -280, y: 240))
context.addLine(to: CGPoint(x: 275, y: 240))
context.addQuadCurve(to: CGPoint(x: 305, y: 210), control: CGPoint(x: 305, y: 240))
context.addLine(to: CGPoint(x: 305, y: -48))
context.addLine(to: CGPoint(x: 100, y: -240))
context.addLine(to: CGPoint(x: -280, y: -240))
context.addQuadCurve(to: CGPoint(x: -310, y: -210), control: CGPoint(x: -310, y: -240))
context.addLine(to: CGPoint(x: -310, y: 210))
context.addQuadCurve(to: CGPoint(x: -280, y: 240), control: CGPoint(x: -310, y: 240))
context.closePath()
context.fillPath()

context.setFillColor(ink)
for x in stride(from: -246, through: 204, by: 90) {
    context.fill(CGRect(x: x, y: 152, width: 43, height: 32))
}
context.move(to: CGPoint(x: -87, y: 88))
context.addLine(to: CGPoint(x: 88, y: -13))
context.addLine(to: CGPoint(x: -87, y: -114))
context.closePath()
context.fillPath()

context.setFillColor(CGColor(gray: 0.52, alpha: 1))
context.move(to: CGPoint(x: 100, y: -240))
context.addQuadCurve(to: CGPoint(x: 136, y: -50), control: CGPoint(x: 150, y: -138))
context.addQuadCurve(to: CGPoint(x: 305, y: -48), control: CGPoint(x: 211, y: -72))
context.closePath()
context.fillPath()

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
