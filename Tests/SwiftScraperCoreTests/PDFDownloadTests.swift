import Foundation
import XCTest
@testable import SwiftScraperCore

final class PDFDownloadFileNamingTests: XCTestCase {
    func testSourceDirectoryIncludesHostAndSourcePath() {
        let outputDirectory = URL(fileURLWithPath: "/tmp/downloads")
        let sourceURL = URL(string: "https://www.okta.com/legal/trustandcompliance/")!

        let directory = PDFDownloadFileNaming.sourceDirectory(for: sourceURL, under: outputDirectory)

        XCTAssertEqual(directory.path, "/tmp/downloads/www.okta.com/legal/trustandcompliance")
    }

    func testSuggestedFileNameUsesTruncatedLinkTextAndOriginalFilename() {
        let original = "okta-model-card-governance-analyzer-2026-02-13.pdf"
        let fileName = PDFDownloadFileNaming.suggestedFileName(
            linkText: "Okta Model Card Governance Analyzer Long Display Name",
            originalFilename: original
        )

        XCTAssertEqual(fileName, "Okta Model Card Governance Ana-\(original)")
    }

    func testSuggestedFileNameFallsBackToOriginalWhenLinkTextIsEmpty() {
        let fileName = PDFDownloadFileNaming.suggestedFileName(
            linkText: " \n ",
            originalFilename: "report.pdf"
        )

        XCTAssertEqual(fileName, "report.pdf")
    }

    func testSuggestedFileNameSanitizesUnsafeCharacters() {
        let fileName = PDFDownloadFileNaming.suggestedFileName(
            linkText: "SOC/Report: 2026",
            originalFilename: "okta/report.pdf"
        )

        XCTAssertEqual(fileName, "SOC_Report_ 2026-okta_report.pdf")
    }

    func testOriginalFilenameUsesDecodedLastPathComponent() {
        let url = URL(string: "https://example.com/files/Annual%20Report.pdf?download=1")!

        XCTAssertEqual(PDFDownloadFileNaming.originalFilename(from: url), "Annual Report.pdf")
    }

    func testUniqueFileURLAddsCounterForDuplicateNames() {
        let directory = URL(fileURLWithPath: "/tmp/downloads")
        var used: Set<String> = []

        let first = PDFDownloadFileNaming.uniqueFileURL(
            suggestedFileName: "report.pdf",
            in: directory,
            usedFileNames: &used
        )
        let second = PDFDownloadFileNaming.uniqueFileURL(
            suggestedFileName: "report.pdf",
            in: directory,
            usedFileNames: &used
        )

        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        XCTAssertEqual(second.lastPathComponent, "report-2.pdf")
    }
}

final class PDFDownloadFormatterTests: XCTestCase {
    func testFormatEncodesDownloadResultAsJSON() throws {
        let link = PDFLinkCandidate(url: URL(string: "https://example.com/report.pdf")!, text: "Report")
        let outputURL = URL(fileURLWithPath: "/tmp/downloads/example.com/report.pdf")
        let result = PDFDownloadRunResult(
            sourceURL: URL(string: "https://example.com/legal/")!,
            sourceDirectory: URL(fileURLWithPath: "/tmp/downloads/example.com/legal"),
            outputDirectory: URL(fileURLWithPath: "/tmp/downloads"),
            files: [
                .succeeded(link: link, originalFilename: "report.pdf", outputURL: outputURL),
            ]
        )

        let json = try PDFDownloadFormatter.format(result)
        let decoded = try JSONDecoder().decode(PDFDownloadRunResult.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.source.url, "https://example.com/legal/")
        XCTAssertEqual(decoded.source.directory, "/tmp/downloads/example.com/legal")
        XCTAssertEqual(decoded.outputDirectory, "/tmp/downloads")
        XCTAssertEqual(decoded.pdfCount, 1)
        XCTAssertEqual(decoded.successCount, 1)
        XCTAssertEqual(decoded.failureCount, 0)
        XCTAssertEqual(decoded.files[0].pdfURL, "https://example.com/report.pdf")
        XCTAssertEqual(decoded.files[0].outputPath, "/tmp/downloads/example.com/report.pdf")
    }

    func testFormatEncodesBatchDownloadResultAsJSON() throws {
        let link = PDFLinkCandidate(url: URL(string: "https://example.com/report.pdf")!, text: "Report")
        let outputURL = URL(fileURLWithPath: "/tmp/downloads/example.com/legal/report.pdf")
        let pageResult = PDFDownloadRunResult(
            sourceURL: URL(string: "https://example.com/legal/")!,
            sourceDirectory: URL(fileURLWithPath: "/tmp/downloads/example.com/legal"),
            outputDirectory: URL(fileURLWithPath: "/tmp/downloads"),
            files: [
                .succeeded(link: link, originalFilename: "report.pdf", outputURL: outputURL),
                .failed(link: link, originalFilename: "report.pdf", outputURL: outputURL, error: "HTTP 403"),
            ]
        )
        let result = PDFDownloadBatchRunResult(
            sourceKind: "url-file",
            sourceLocation: "/tmp/urls.txt",
            outputDirectory: URL(fileURLWithPath: "/tmp/downloads"),
            pages: [
                .succeeded(pageResult),
                .failed(url: URL(string: "https://example.com/missing")!, error: "ページロードに失敗しました"),
            ]
        )

        let json = try PDFDownloadFormatter.format(result)
        let decoded = try JSONDecoder().decode(PDFDownloadBatchRunResult.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.source.kind, "url-file")
        XCTAssertEqual(decoded.pageCount, 2)
        XCTAssertEqual(decoded.pageSuccessCount, 0)
        XCTAssertEqual(decoded.pageFailureCount, 2)
        XCTAssertEqual(decoded.pdfCount, 2)
        XCTAssertEqual(decoded.successCount, 1)
        XCTAssertEqual(decoded.failureCount, 1)
        XCTAssertTrue(decoded.hasFailures)
    }
}

final class PDFDownloadRequestBuilderTests: XCTestCase {
    func testMakeRequestUsesWebViewUserAgentWhenHeaderIsNotSpecified() {
        let request = PDFDownloadRequestBuilder.makeRequest(
            url: URL(string: "https://example.com/files/report.pdf")!,
            timeout: 10,
            customHeaders: [:],
            cookies: [],
            userAgent: "Mozilla/5.0 SwiftScraperWebKit"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 SwiftScraperWebKit")
    }

    func testMakeRequestPrefersExplicitUserAgentHeader() {
        let request = PDFDownloadRequestBuilder.makeRequest(
            url: URL(string: "https://example.com/files/report.pdf")!,
            timeout: 10,
            customHeaders: ["User-Agent": "Explicit UA"],
            cookies: [],
            userAgent: "Mozilla/5.0 SwiftScraperWebKit"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Explicit UA")
    }

    func testMakeRequestAddsMatchingCookies() {
        let request = PDFDownloadRequestBuilder.makeRequest(
            url: URL(string: "https://docs.example.com/files/report.pdf")!,
            timeout: 10,
            customHeaders: [:],
            cookies: [
                CookieDefinition(name: "session", value: "abc", domain: "example.com", path: "/", secure: true),
                CookieDefinition(name: "other", value: "ignored", domain: "other.example", path: "/", secure: true),
            ],
            userAgent: nil
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
    }
}
