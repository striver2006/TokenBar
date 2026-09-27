import SwiftUI
import XCTest
@testable import TokenBar

/// SVG path 解析器与厂商 Logo 路径数据的完整性测试。
final class ProviderLogoTests: XCTestCase {
    /// 全部内置厂商 Logo 路径可被解析,且落在 24×24 viewBox 内。
    func testAllProviderLogosParseWithinViewBox() {
        for provider in ProviderType.allCases {
            let paths = ProviderLogo.paths(for: provider)
            XCTAssertFalse(paths.isEmpty, "\(provider) 缺少 logo 路径")

            var combined = Path()
            for d in paths {
                combined.addPath(SVGPathParser.parse(d))
            }
            let box = combined.boundingRect
            XCTAssertFalse(box.isNull, "\(provider) logo 解析结果为空")
            XCTAssertGreaterThan(box.width, 1, "\(provider) logo 宽度过小")
            XCTAssertGreaterThan(box.height, 1, "\(provider) logo 高度过小")
            XCTAssertGreaterThanOrEqual(box.minX, -0.5, "\(provider) logo 越出 viewBox 左边界")
            XCTAssertGreaterThanOrEqual(box.minY, -0.5, "\(provider) logo 越出 viewBox 上边界")
            XCTAssertLessThanOrEqual(box.maxX, 24.5, "\(provider) logo 越出 viewBox 右边界")
            XCTAssertLessThanOrEqual(box.maxY, 24.5, "\(provider) logo 越出 viewBox 下边界")
        }
    }

    /// 自定义预设名称关键词能命中品牌 Logo。
    func testPresetLogoMatching() {
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "小米 MiMo (Xiaomi)"))
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "腾讯混元 (Tencent Hunyuan)"))
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "阶跃星辰 (StepFun)"))
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "硅基流动 (SiliconFlow)"))
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "MiniMax (名之梦)"))
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "百度千帆 (文心一言)"))
        // 用户改过名(含关键词)也应命中
        XCTAssertNotNil(ProviderLogo.presetLogo(forName: "我的 MiniMax 中转"))
        // 无品牌特征的名称回退 nil
        XCTAssertNil(ProviderLogo.presetLogo(forName: "OpenAI 兼容代理"))
        XCTAssertNil(ProviderLogo.presetLogo(forName: "零一万物 (01.AI)"))
        XCTAssertNil(ProviderLogo.presetLogo(forName: "我的自建网关"))
    }

    /// 解析器基础语义:M/L/Z、相对命令、H/V、二次曲线与弧线。
    func testParserPrimitives() {
        // 三角形
        let triangle = SVGPathParser.parse("M2 2 L10 2 L6 10 Z")
        let tb = triangle.boundingRect
        XCTAssertEqual(tb.minX, 2, accuracy: 0.001)
        XCTAssertEqual(tb.maxX, 10, accuracy: 0.001)

        // 相对命令 + 粘连数字
        let rel = SVGPathParser.parse("m2 2l8 0-4 8z")
        XCTAssertEqual(rel.boundingRect.width, triangle.boundingRect.width, accuracy: 0.001)

        // H/V
        let hv = SVGPathParser.parse("M1 1 H11 V11 H1 Z")
        XCTAssertEqual(hv.boundingRect.width, 10, accuracy: 0.001)

        // 弧线(半圆):flag 与坐标粘连的写法
        let arc = SVGPathParser.parse("M2 12A10 10 0 0112 2 10 10 0 0122 12")
        XCTAssertFalse(arc.boundingRect.isNull)
        // 半圆端点应精确落在 (2,12) 与 (22,12)
        let w = arc.boundingRect.width
        XCTAssertEqual(w, 20, accuracy: 0.5)

        // 二次曲线 + T 反射
        let quad = SVGPathParser.parse("M2 2Q6 6 10 2T18 2")
        XCTAssertFalse(quad.boundingRect.isNull)
    }
}
