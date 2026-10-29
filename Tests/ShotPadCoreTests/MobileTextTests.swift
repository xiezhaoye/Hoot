import AppKit
import XCTest
@testable import ShotPadCore

final class MobileTextTests: XCTestCase {
    private func line(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat = 300, height: CGFloat = 20) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    func testChineseSoftWrapsMergeWithoutSpacesOrExtraNewlines() {
        let paragraphs = MobileTextLayout.paragraphs(from: [
            line("这是一段需要", y: 0), line("合并的中文内容，不应该多出换行。", y: 30)
        ])
        XCTAssertEqual(paragraphs, [TextParagraph("这是一段需要合并的中文内容，不应该多出换行。")])
    }

    func testParagraphGapsAndFirstLineIndentArePreserved() {
        let paragraphs = MobileTextLayout.paragraphs(from: [
            line("第一段开头", x: 40, y: 0, width: 260), line("继续第一段。", y: 30),
            line("第二段开头", x: 40, y: 60, width: 260), line("继续第二段。", y: 90),
            line("第三段使用更大的段间距。", y: 150)
        ])
        XCTAssertEqual(paragraphs.map(\.text), ["第一段开头继续第一段。", "第二段开头继续第二段。", "第三段使用更大的段间距。"])
    }

    func testSentenceAtSoftWrapDoesNotInventParagraphBreak() {
        let paragraphs = MobileTextLayout.paragraphs(from: [
            line("One sentence ends.", y: 0, width: 250),
            line("Another sentence continues within", y: 30),
            line("the same original paragraph.", y: 60)
        ])
        XCTAssertEqual(paragraphs.map(\.text), ["One sentence ends. Another sentence continues within the same original paragraph."])
    }

    func testEnglishWordBoundariesHyphensAndClosingQuotes() {
        XCTAssertEqual(MobileTextLayout.paragraphs(from: [line("This is one", y: 0), line("paragraph with words.", y: 30)]).map(\.text), ["This is one paragraph with words."])
        XCTAssertEqual(MobileTextLayout.paragraphs(from: [line("A well-", y: 0), line("known example", y: 30)]).map(\.text), ["A well-known example"])
        XCTAssertEqual(MobileTextLayout.paragraphs(from: [line("A recon\u{00ad}", y: 0), line("structed example", y: 30)]).map(\.text), ["A reconstructed example"])
        XCTAssertEqual(MobileTextLayout.paragraphs(from: [line("A \"quoted line\"", y: 0), line("continues here", y: 30)]).map(\.text), ["A \"quoted line\" continues here"])
    }

    func testHeadingAndWrappedListItemsKeepTheirStructure() {
        let paragraphs = MobileTextLayout.paragraphs(from: [
            line("标题", y: 0, height: 36),
            line("- 第一项", y: 60), line("这一项的续行", x: 28, y: 90, width: 272), line("以及第三行。", x: 28, y: 120, width: 272),
            line("- 第二项", y: 150),
            line("普通正文。", y: 190)
        ])
        XCTAssertEqual(paragraphs, [TextParagraph("标题", kind: .heading), TextParagraph("- 第一项这一项的续行以及第三行。", kind: .list), TextParagraph("- 第二项", kind: .list), TextParagraph("普通正文。")])
        XCTAssertNotNil(MobileTextLayout.listPrefix("1. First item"))
        XCTAssertNotNil(MobileTextLayout.listPrefix("（一）第一项"))
        XCTAssertNotNil(MobileTextLayout.listPrefix("•第一项"))
        XCTAssertNil(MobileTextLayout.listPrefix("1.25 是一个小数"))
    }

    func testSameRowFragmentsOrderByXAndDuplicateObservationsDisappear() {
        let paragraphs = MobileTextLayout.paragraphs(from: [
            line("world", x: 65, y: 0, width: 55), line("Hello", y: 1, width: 55),
            line("Hello", x: 1, y: 1, width: 55)
        ])
        XCTAssertEqual(paragraphs.map(\.text), ["Hello world"])
        let repeated = MobileTextLayout.paragraphs(from: [line("a", y: 0, width: 8), line("a", x: 10, y: 1, width: 8)])
        XCTAssertEqual(repeated.map(\.text), ["a a"])
    }

    func testBlankObservationsDoNotCreateEmptyParagraphs() {
        XCTAssertEqual(MobileTextLayout.paragraphs(from: [line("  \n\t ", y: 0), line("正文", y: 30)]), [TextParagraph("正文")])
        XCTAssertTrue(MobileTextLayout.paragraphs(from: []).isEmpty)
    }

    func testTileOwnershipCoversEverySourceRowExactlyOnce() {
        for height in [1, 1200, 1201, 2400, 5100] {
            let tiles = TextRecognizer.reflowTiles(width: 600, height: height)
            XCTAssertEqual(tiles.first?.rect.minY, 0)
            XCTAssertEqual(tiles.last?.rect.maxY, CGFloat(height))
            for y in 0..<height {
                XCTAssertEqual(tiles.filter { $0.ownedRange.contains(CGFloat(y) + 0.5) }.count, 1)
            }
            XCTAssertTrue(tiles.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= CGFloat(height) })
        }
    }

    func testMobileImageUsesFixedWidthAndKeepsFirstAndLastParagraphReadable() throws {
        var style = ImageExportStyle(); style.shadow = false; style.background = .solid; style.color = .black
        let paragraphs = [TextParagraph("FIRST MARKER", kind: .heading)] +
            (1...14).map { TextParagraph("Paragraph \($0) keeps the complete original wording and wraps naturally for a phone screen.") } +
            [TextParagraph("LAST MARKER")]
        let image = try MobileTextRenderer.render(paragraphs, style: style)
        XCTAssertEqual(image.width, 1080)
        XCTAssertGreaterThan(image.height, 1440)
        XCTAssertEqual(pixel(image, 0, 0).0, 0)
        let recognized = try TextRecognizer.recognizeForReflow(image).map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(recognized.contains("FIRST MARKER"))
        XCTAssertTrue(recognized.contains("LAST MARKER"))
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-mobile-text.png"))
        }
    }

    func testShortTextProducesCompactCardAndHeightGrowsWithContent() throws {
        var style = ImageExportStyle(); style.shadow = false
        let short = try MobileTextRenderer.render([TextParagraph("Short card text")], style: style)
        let medium = try MobileTextRenderer.render((1...6).map { TextParagraph("Line \($0) contains some readable text.") }, style: style)
        XCTAssertEqual(short.width, 1080)
        XCTAssertLessThan(short.height, 500)
        XCTAssertGreaterThan(medium.height, short.height)
        XCTAssertLessThan(medium.height, 1440)
        let text = try TextRecognizer.recognizeForReflow(medium).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Line 1")); XCTAssertTrue(text.contains("Line 6"))
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            try XCTUnwrap(NSBitmapImageRep(cgImage: medium).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-mobile-card.png"))
        }
    }

    func testRealOCRPreservesTextNearTileBoundaryAndImageEnds() throws {
        let doc = EditorDocument(image: solid(600, 4800, .white))
        for (text, y) in [("TOP MARKER", 40), ("FIRST EDGE", 1120), ("SECOND EDGE", 1160), ("BOTTOM MARKER", 4660)] {
            doc.add(Annotation(.text(text, origin: CGPoint(x: 30, y: y), fontSize: 28), color: .black))
        }
        let recognized = try TextRecognizer.recognizeForReflow(doc.composite()).map(\.text).joined(separator: " ").uppercased()
        for marker in ["TOP MARKER", "FIRST EDGE", "SECOND EDGE", "BOTTOM MARKER"] {
            XCTAssertEqual(recognized.components(separatedBy: marker).count - 1, 1, recognized)
        }
    }

    func testChineseParagraphsAndListsRenderAsReadablePortrait() throws {
        let paragraphs = [
            TextParagraph("适配手机：保持原文，重新排版", kind: .heading),
            TextParagraph("这是一段从截图中提取的文字。原来因为截图宽度而产生的自动折行，会合并回同一个段落；真正的段落和列表会保留，不会为了排版擅自概括或删减。"),
            TextParagraph("1. 只处理文字，重新组织成适合手机阅读的竖版图片。", kind: .list),
            TextParagraph("2. 中英文混排，例如 Phone layout，也应保留正常的单词间隔。", kind: .list),
            TextParagraph("3. 点击取消或按 Esc，可以返回当前截图继续操作。", kind: .list),
            TextParagraph("这里是最后一段。默认模板中的背景、留白、圆角和阴影，会应用到最终图片，生成后直接复制到剪贴板。")
        ]
        let image = try MobileTextRenderer.render(paragraphs, style: ImageExportStyle())
        XCTAssertEqual(image.width, 1080)
        XCTAssertGreaterThan(image.height, 0)
        let text = try TextRecognizer.recognizeForReflow(image).map(\.text).joined(separator: "")
        XCTAssertTrue(text.contains("手机"))
        XCTAssertTrue(text.contains("最后一段"))
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-mobile-chinese.png"))
        }
    }

    func testEmptyOrUnreasonablyLongOutputReportsFailureInsteadOfTruncating() {
        XCTAssertThrowsError(try MobileTextRenderer.render([], style: ImageExportStyle()))
        XCTAssertThrowsError(try MobileTextRenderer.render(Array(repeating: TextParagraph("完整文字不可截断。"), count: 500), style: ImageExportStyle()))
    }
}
