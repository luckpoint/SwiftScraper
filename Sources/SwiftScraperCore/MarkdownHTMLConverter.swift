import Foundation
import Ink

enum MarkdownHTMLConverter {
    static func convert(markdown: String) -> String {
        let parser = MarkdownParser()
        let body = parser.html(from: markdown)
        return wrapInDocument(body: body)
    }

    private static func wrapInDocument(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 800px; margin: 0 auto; padding: 0 20px; line-height: 1.6; color: #333; }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.2em; margin-bottom: 0.4em; }
        pre { background: #f5f5f5; padding: 12px; overflow-x: auto; border-radius: 4px; }
        code { background: #f5f5f5; padding: 2px 4px; border-radius: 2px; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 16px; color: #666; }
        img { max-width: 100%; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #ddd; padding: 6px 12px; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
