import AppKit
import Foundation
import XCTest
@testable import SwiftScraperCore

@MainActor
final class PDFRendererTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    func testRenderValidHTMLProducesPDFFile() throws {
        let outputURL = try makeTempDirectory().appendingPathComponent("output.pdf")
        let renderer = PDFRenderer(logger: StderrLogger(verbose: false))

        try renderer.render(html: "<html><body><p>Hello</p></body></html>", outputURL: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let data = try Data(contentsOf: outputURL)
        XCTAssertFalse(data.isEmpty)
    }

    func testRenderProducesValidPDFHeader() throws {
        let outputURL = try makeTempDirectory().appendingPathComponent("output.pdf")
        let renderer = PDFRenderer(logger: StderrLogger(verbose: false))

        try renderer.render(html: "<html><body><h1>Test</h1></body></html>", outputURL: outputURL)

        let data = try Data(contentsOf: outputURL)
        assertPDFMagicBytes(data)
    }

    func testRenderHTMLFromConverterProducesValidPDF() throws {
        let outputURL = try makeTempDirectory().appendingPathComponent("output.pdf")
        let html = MarkdownHTMLConverter.convert(markdown: "# Test\n\nHello, world!")
        let renderer = PDFRenderer(logger: StderrLogger(verbose: false))

        try renderer.render(html: html, outputURL: outputURL)

        let data = try Data(contentsOf: outputURL)
        assertPDFMagicBytes(data)
    }

    func testRenderCanApplyRequestedFontFamily() throws {
        guard NSFont(name: "Noto Sans JP", size: 12) != nil else {
            throw XCTSkip("Noto Sans JP is not installed on this host")
        }

        let outputURL = try makeTempDirectory().appendingPathComponent("output.pdf")
        let renderer = PDFRenderer(logger: StderrLogger(verbose: false))

        try renderer.render(
            html: "<html><body><p>楽天銀行 Noto Sans JP</p></body></html>",
            outputURL: outputURL,
            fontFamily: "Noto Sans JP"
        )

        let pdfData = try Data(contentsOf: outputURL)
        let pdfText = String(decoding: pdfData, as: UTF8.self)
        XCTAssertTrue(pdfText.contains("NotoSansJP"))
    }

    private func assertPDFMagicBytes(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let header = Array(data.prefix(4))
        XCTAssertEqual(header, [0x25, 0x50, 0x44, 0x46], "Data should start with %PDF magic bytes", file: file, line: line)
    }
}
