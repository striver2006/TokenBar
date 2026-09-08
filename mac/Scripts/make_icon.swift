#!/usr/bin/env swift

// 生成 TokenBar 应用图标 master 图 (1024x1024 PNG)。
// 设计:macOS 风格圆角方块(squircle),靛蓝对角渐变底,
// 中央琥珀色闪电(呼应菜单栏 ⚡ 品牌),底部柔和投影与顶部高光。
//
// 用法: swift Scripts/make_icon.swift <输出 PNG 路径>

import Foundation
import CoreGraphics
import ImageIO

let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon_1024.png")

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// ---- 底板:macOS 图标网格 squircle(824/1024,圆角 22.5%) ----
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin,
                  width: CGFloat(size) - 2 * margin, height: CGFloat(size) - 2 * margin)
let radius = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.addPath(squircle)
ctx.clip()

// 背景对角渐变:靛蓝深 → 靛蓝亮(左上 → 右下)
let bgGradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.122, green: 0.110, blue: 0.310, alpha: 1),   // #1F1C4F
    CGColor(srgbRed: 0.290, green: 0.243, blue: 0.816, alpha: 1),   // #4A3ED0
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: CGFloat(size)),
                       end: CGPoint(x: CGFloat(size), y: 0), options: [])

// 闪电背后的琥珀色柔光
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.988, green: 0.761, blue: 0.239, alpha: 0.50),
    CGColor(srgbRed: 0.988, green: 0.761, blue: 0.239, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])

// 顶部高光提升质感
let sheen = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12),
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924),
                       end: CGPoint(x: 512, y: 330), options: [])

// ---- 闪电(标准 CG 自下而上坐标,经典斜切形状) ----
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 545, y: 812))
bolt.addLine(to: CGPoint(x: 345, y: 479))
bolt.addLine(to: CGPoint(x: 479, y: 479))
bolt.addLine(to: CGPoint(x: 445, y: 212))
bolt.addLine(to: CGPoint(x: 679, y: 565))
bolt.addLine(to: CGPoint(x: 525, y: 565))
bolt.addLine(to: CGPoint(x: 592, y: 812))
bolt.closeSubpath()

// 第一遍:实底填充 + 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 42,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38))
ctx.addPath(bolt)
ctx.setFillColor(CGColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1)) // #F59E0B
ctx.fillPath()
ctx.restoreGState()

// 第二遍:裁剪到闪电内部,画纵向渐变,再用 round join 内描边柔化尖角
ctx.saveGState()
ctx.addPath(bolt)
ctx.clip()
let boltGradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.992, green: 0.796, blue: 0.325, alpha: 1),   // #FDCB53 亮
    CGColor(srgbRed: 0.965, green: 0.643, blue: 0.031, alpha: 1),   // #F6A408 深
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(boltGradient, start: CGPoint(x: 512, y: 812),
                       end: CGPoint(x: 512, y: 212), options: [])
ctx.addPath(bolt)
ctx.setStrokeColor(CGColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1))
ctx.setLineWidth(30)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// ---- 底板内侧 1px 高光描边(macOS 图标常见细节) ----
ctx.saveGState()
ctx.addPath(squircle)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("master icon written: \(outputURL.path)")
