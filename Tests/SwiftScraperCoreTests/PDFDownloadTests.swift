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

    func testUniqueFileURLCanOverwriteExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftScraperTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let existingURL = directory.appendingPathComponent("report.pdf")
        try Data("existing".utf8).write(to: existingURL)

        var usedWithoutOverwrite: Set<String> = []
        let uniqueURL = PDFDownloadFileNaming.uniqueFileURL(
            suggestedFileName: "report.pdf",
            in: directory,
            usedFileNames: &usedWithoutOverwrite
        )

        var usedWithOverwrite: Set<String> = []
        let overwriteURL = PDFDownloadFileNaming.uniqueFileURL(
            suggestedFileName: "report.pdf",
            in: directory,
            usedFileNames: &usedWithOverwrite,
            overwriteExisting: true
        )

        XCTAssertEqual(uniqueURL.lastPathComponent, "report-2.pdf")
        XCTAssertEqual(overwriteURL.lastPathComponent, "report.pdf")
    }
}

final class PDFDownloadSaverTests: XCTestCase {
    func testOverwriteExistingFileReplacesFileInsteadOfAddingCounter() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftScraperTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = rootDirectory.appendingPathComponent("source", isDirectory: true)
        let outputDirectory = rootDirectory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        let sourcePDFURL = sourceDirectory.appendingPathComponent("report.pdf")
        try Data("new".utf8).write(to: sourcePDFURL)

        let pageURL = URL(string: "https://example.com/legal/")!
        let pageOutputDirectory = PDFDownloadFileNaming.sourceDirectory(for: pageURL, under: outputDirectory)
        try FileManager.default.createDirectory(at: pageOutputDirectory, withIntermediateDirectories: true)
        let existingOutputURL = pageOutputDirectory.appendingPathComponent("Report-report.pdf")
        try Data("old".utf8).write(to: existingOutputURL)

        let saver = PDFDownloadSaver(
            outputDirectory: outputDirectory,
            timeout: 1,
            customHeaders: [:],
            overwriteExistingFiles: true,
            maximumSizeMegabytes: PDFDownloadResponseGuard.defaultMaximumMegabytes,
            logger: StderrLogger(verbose: false)
        )
        let collection = PDFLinkCollection(
            sourceURL: pageURL,
            links: [PDFLinkCandidate(url: sourcePDFURL, text: "Report")],
            userAgent: nil,
            cookies: []
        )

        let result = try await saver.save(collection)

        XCTAssertEqual(result.files[0].outputPath, existingOutputURL.path)
        XCTAssertEqual(try String(contentsOf: existingOutputURL, encoding: .utf8), "new")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: pageOutputDirectory.appendingPathComponent("Report-report-2.pdf").path
            )
        )
    }

    func testLocalFileCopyIsNotSubjectToResponseValidation() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftScraperTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = rootDirectory.appendingPathComponent("source", isDirectory: true)
        let outputDirectory = rootDirectory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        let sourcePDFURL = sourceDirectory.appendingPathComponent("report.pdf")
        try Data("not a pdf".utf8).write(to: sourcePDFURL)

        let saver = PDFDownloadSaver(
            outputDirectory: outputDirectory,
            timeout: 1,
            customHeaders: [:],
            overwriteExistingFiles: false,
            maximumSizeMegabytes: 1,
            logger: StderrLogger(verbose: false)
        )
        let collection = PDFLinkCollection(
            sourceURL: URL(string: "https://example.com/legal/")!,
            links: [PDFLinkCandidate(url: sourcePDFURL, text: "Report")],
            userAgent: nil,
            cookies: []
        )

        let result = try await saver.save(collection)

        XCTAssertTrue(result.files[0].success)
        XCTAssertEqual(try String(contentsOf: sourcePDFURL, encoding: .utf8), "not a pdf")
    }
}

final class PDFDownloadResponseGuardTests: XCTestCase {
    private func pdf(byteCount: Int) -> Data {
        var data = Data("%PDF-".utf8)
        data.append(Data(repeating: 0x41, count: max(0, byteCount - data.count)))
        return data
    }

    func testValidPDFWithinLimitPasses() {
        XCTAssertNil(PDFDownloadResponseGuard.failure(for: pdf(byteCount: 16), maximumBytes: 32))
    }

    func testBareMagicBytesArePassed() {
        XCTAssertNil(PDFDownloadResponseGuard.failure(for: Data("%PDF-".utf8), maximumBytes: 5))
    }

    func testHTMLResponseIsRejected() {
        let failure = PDFDownloadResponseGuard.failure(for: Data("<!DOCTYPE html>".utf8), maximumBytes: 1024)
        XCTAssertEqual(failure, .notPDF)
        XCTAssertEqual(failure?.message, "Response is not a PDF (missing %PDF- header)")
    }

    func testEmptyResponseIsRejected() {
        XCTAssertEqual(PDFDownloadResponseGuard.failure(for: Data(), maximumBytes: 1024), .notPDF)
    }

    func testTruncatedMagicIsRejected() {
        XCTAssertEqual(PDFDownloadResponseGuard.failure(for: Data("%PDF".utf8), maximumBytes: 1024), .notPDF)
    }

    func testSizeExactlyAtLimitPasses() {
        XCTAssertNil(PDFDownloadResponseGuard.failure(for: pdf(byteCount: 8), maximumBytes: 8))
    }

    func testSizeOneByteOverLimitIsRejected() {
        let failure = PDFDownloadResponseGuard.failure(for: pdf(byteCount: 9), maximumBytes: 8)
        XCTAssertEqual(failure, .tooLarge(byteCount: 9, maximumBytes: 8))
        XCTAssertEqual(
            failure?.message,
            "Response is 9 bytes, above the 8 byte limit (--max-pdf-size)"
        )
    }

    func testOversizedNonPDFReportsNotPDF() {
        let html = Data(repeating: 0x41, count: 64)
        XCTAssertEqual(PDFDownloadResponseGuard.failure(for: html, maximumBytes: 8), .notPDF)
    }

    func testMegabytesUseBinaryUnits() {
        XCTAssertEqual(PDFDownloadResponseGuard.maximumBytes(forMegabytes: 100), 104_857_600)
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
                .failed(url: URL(string: "https://example.com/missing")!, error: "Page load failed"),
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
                CookieDefinition(name: "session", value: "abc", domain: ".example.com", path: "/", secure: true),
                CookieDefinition(name: "other", value: "ignored", domain: "other.example", path: "/", secure: true),
            ],
            userAgent: nil
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
    }

    func testMakeRequestDoesNotSendHostOnlyCookieToSubdomain() {
        let request = PDFDownloadRequestBuilder.makeRequest(
            url: URL(string: "https://docs.example.com/files/report.pdf")!,
            timeout: 10,
            customHeaders: [:],
            cookies: [
                CookieDefinition(name: "session", value: "abc", domain: "example.com", secure: true, hostOnly: true),
            ],
            userAgent: nil
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}
