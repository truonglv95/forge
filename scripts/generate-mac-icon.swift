import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ForgeIcon-1024.png"
let size = 1024
let scale = CGFloat(size)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fatalError("Unable to create CGContext")
}
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: y * scale)
}

func drawLinearGradient(_ colors: [CGColor], _ locations: [CGFloat], _ start: CGPoint, _ end: CGPoint) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil)
}

func polygon(_ pts: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = pts.first else { return path }
    path.move(to: first)
    for p in pts.dropFirst() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

func strokeGlow(path: CGPath, color: CGColor, width: CGFloat, blur: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setShadow(offset: .zero, blur: blur * scale, color: color)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width * scale)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// Flip into top-left coordinates.
ctx.translateBy(x: 0, y: scale)
ctx.scaleBy(x: 1, y: -1)

let outer = rect(0.055, 0.055, 0.89, 0.89)
let outerPath = roundedPath(outer, 0.205)

ctx.saveGState()
ctx.addPath(outerPath)
ctx.clip()
drawLinearGradient(
    [rgb(0.028, 0.032, 0.043), rgb(0.075, 0.087, 0.116), rgb(0.018, 0.020, 0.028)],
    [0.0, 0.56, 1.0],
    point(0.08, 0.05),
    point(0.92, 0.96)
)

// Soft blue light from the upper right.
let glowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        rgb(0.10, 0.43, 0.88, 0.46),
        rgb(0.05, 0.15, 0.34, 0.18),
        rgb(0.0, 0.0, 0.0, 0.0)
    ] as CFArray,
    locations: [0.0, 0.38, 1.0]
)!
ctx.drawRadialGradient(
    glowGradient,
    startCenter: point(0.73, 0.25),
    startRadius: 0,
    endCenter: point(0.73, 0.25),
    endRadius: 0.62 * scale,
    options: []
)

// Subtle forge-grid texture.
ctx.setLineWidth(1.0)
ctx.setStrokeColor(rgb(1, 1, 1, 0.035))
for i in stride(from: 0.14, through: 0.86, by: 0.08) {
    ctx.move(to: point(i, 0.11))
    ctx.addLine(to: point(i - 0.28, 0.91))
    ctx.strokePath()
}
for i in stride(from: 0.18, through: 0.88, by: 0.10) {
    ctx.move(to: point(0.11, i))
    ctx.addLine(to: point(0.89, i - 0.18))
    ctx.strokePath()
}
ctx.restoreGState()

// Outer bevel.
ctx.addPath(outerPath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
ctx.setLineWidth(1.6 * scale / 1024)
ctx.strokePath()

let innerPath = roundedPath(rect(0.083, 0.083, 0.834, 0.834), 0.176)
ctx.addPath(innerPath)
ctx.setStrokeColor(rgb(0.05, 0.16, 0.30, 0.62))
ctx.setLineWidth(4)
ctx.strokePath()

// Cyan forge spark.
ctx.saveGState()
ctx.addPath(outerPath)
ctx.clip()

let spark = polygon([
    point(0.50, 0.145),
    point(0.587, 0.382),
    point(0.842, 0.50),
    point(0.587, 0.618),
    point(0.50, 0.855),
    point(0.413, 0.618),
    point(0.158, 0.50),
    point(0.413, 0.382),
])

strokeGlow(path: spark, color: rgb(0.15, 0.64, 1.0, 0.45), width: 24, blur: 28)
ctx.addPath(spark)
ctx.setFillColor(rgb(0.08, 0.30, 0.62, 0.30))
ctx.fillPath()
ctx.addPath(spark)
ctx.setStrokeColor(rgb(0.31, 0.78, 1.0, 0.88))
ctx.setLineWidth(9)
ctx.setLineJoin(.round)
ctx.strokePath()

// Molten Forge "F" mark.
let mark = CGMutablePath()
mark.move(to: point(0.355, 0.315))
mark.addLine(to: point(0.675, 0.315))
mark.addLine(to: point(0.675, 0.425))
mark.addLine(to: point(0.505, 0.425))
mark.addLine(to: point(0.505, 0.492))
mark.addLine(to: point(0.637, 0.492))
mark.addLine(to: point(0.637, 0.602))
mark.addLine(to: point(0.505, 0.602))
mark.addLine(to: point(0.505, 0.708))
mark.addLine(to: point(0.355, 0.708))
mark.closeSubpath()

ctx.saveGState()
ctx.addPath(mark)
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 22, color: rgb(1.0, 0.34, 0.04, 0.55))
ctx.setFillColor(rgb(0.95, 0.25, 0.02, 0.95))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(mark)
ctx.clip()
drawLinearGradient(
    [rgb(1.0, 0.82, 0.18), rgb(1.0, 0.45, 0.05), rgb(0.78, 0.18, 0.02)],
    [0.0, 0.54, 1.0],
    point(0.42, 0.30),
    point(0.62, 0.72)
)
ctx.restoreGState()

ctx.addPath(mark)
ctx.setStrokeColor(rgb(1.0, 0.93, 0.52, 0.72))
ctx.setLineWidth(5)
ctx.setLineJoin(.round)
ctx.strokePath()

// Small molten cut to make the mark feel machined.
let cut = CGMutablePath()
cut.move(to: point(0.405, 0.365))
cut.addLine(to: point(0.611, 0.365))
cut.addLine(to: point(0.585, 0.388))
cut.addLine(to: point(0.405, 0.388))
cut.closeSubpath()
ctx.addPath(cut)
ctx.setFillColor(rgb(1.0, 0.95, 0.56, 0.26))
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else {
    fatalError("Unable to create image")
}

let url = URL(fileURLWithPath: output)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
if !CGImageDestinationFinalize(destination) {
    fatalError("Unable to write PNG")
}
