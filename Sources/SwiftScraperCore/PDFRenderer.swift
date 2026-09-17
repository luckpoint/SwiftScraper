import AppKit
import Foundation

@MainActor
public final class PDFRenderer {
    private let logger: StderrLogger

    public init(logger: StderrLogger) {
        self.logger = logger
    }

    public func render(html: String, outputURL: URL) throws {
        logger.info("Converting HTML to NSAttributedString")
        guard let htmlData = html.data(using: .utf8) else {
            throw ScraperError.pdfRenderFailed("Unable to convert the HTML to UTF-8 data")
        }

        let attrStr = try NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )

        let pageWidth: CGFloat = 595.28
        let pageHeight: CGFloat = 841.89
        let margin: CGFloat = 36
        let contentWidth = pageWidth - margin * 2

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: pageWidth, height: pageHeight)
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary().setObject(
            outputURL, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying
        )

        let textStorage = NSTextStorage(attributedString: attrStr)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        logger.info("Layout finished: \(Int(usedRect.height)) pt")

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: contentWidth, height: usedRect.height)
        )
        textView.textContainer = textContainer
        textView.isEditable = false
        textView.isSelectable = false

        logger.info("Generating the PDF")
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = false
        printOp.showsProgressPanel = false
        printOp.canSpawnSeparateThread = false

        guard printOp.run() else {
            throw ScraperError.pdfRenderFailed("The print operation failed")
        }
    }
}
