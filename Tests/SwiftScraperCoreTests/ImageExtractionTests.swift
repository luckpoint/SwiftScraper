import Foundation
import XCTest
@testable import SwiftScraperCore

final class ImageExtractionTests: XCTestCase {
    func testLogoLikeHeaderImageDrops() {
        let candidate = makeCandidate(
            src: "/assets/logo.svg",
            currentSrc: "https://example.com/assets/logo.svg",
            alt: "Example",
            id: "site-logo",
            className: "site-logo brand",
            naturalWidth: 180,
            naturalHeight: 48,
            renderedWidth: 120,
            renderedHeight: 32,
            top: 16,
            isVisible: true,
            inArticle: false,
            inHeader: true,
            inNav: false,
            inFigure: false,
            figcaption: "",
            linkedHref: "https://example.com/",
            linkedToRoot: true,
            filename: "logo.svg",
            isSvg: true,
            nearestTextBlockLength: 0,
            ancestors: [
                .init(tag: "header", id: "top", className: "site-header", role: "banner"),
            ]
        )

        let result = ImageHeuristics.score(candidate, keepThreshold: 0.65)

        XCTAssertEqual(result.decision, .drop)
        XCTAssertTrue(result.reasons.contains("logo_keyword"))
        XCTAssertTrue(result.reasons.contains("header_or_nav"))
        XCTAssertTrue(result.reasons.contains("linked_to_root"))
        XCTAssertTrue(result.reasons.contains("svg"))
    }

    func testArticleFigureImageKeeps() {
        let candidate = makeCandidate(
            src: "/images/article-hero.jpg",
            currentSrc: "https://example.com/images/article-hero.jpg",
            alt: "Important product screenshot",
            id: "hero-image",
            className: "featured-image",
            naturalWidth: 1600,
            naturalHeight: 900,
            renderedWidth: 800,
            renderedHeight: 450,
            top: 240,
            isVisible: true,
            inArticle: true,
            inHeader: false,
            inNav: false,
            inFigure: true,
            figcaption: "Architecture diagram",
            linkedHref: "",
            linkedToRoot: false,
            filename: "article-hero.jpg",
            isSvg: false,
            nearestTextBlockLength: 280,
            ancestors: [
                .init(tag: "figure", id: "", className: "hero", role: ""),
                .init(tag: "article", id: "", className: "post-content", role: ""),
            ]
        )

        let result = ImageHeuristics.score(candidate, keepThreshold: 0.65)

        XCTAssertEqual(result.decision, .keep)
        XCTAssertTrue(result.reasons.contains("in_article"))
        XCTAssertTrue(result.reasons.contains("in_figure"))
        XCTAssertTrue(result.reasons.contains("has_figcaption"))
        XCTAssertTrue(result.reasons.contains("large_rendered"))
    }

    func testArticleOnlyFilterOverridesDecisionOutsideArticle() {
        let candidate = makeCandidate(
            src: "/images/hero.jpg",
            currentSrc: "https://example.com/images/hero.jpg",
            alt: "Prominent hero image",
            id: "hero",
            className: "hero-image",
            naturalWidth: 1600,
            naturalHeight: 900,
            renderedWidth: 700,
            renderedHeight: 420,
            top: 120,
            isVisible: true,
            inArticle: false,
            inHeader: false,
            inNav: false,
            inFigure: true,
            figcaption: "Top hero",
            linkedHref: "",
            linkedToRoot: false,
            filename: "hero.jpg",
            isSvg: false,
            nearestTextBlockLength: 200,
            ancestors: [
                .init(tag: "section", id: "lead", className: "hero", role: ""),
            ]
        )

        let evaluated = ImageHeuristics.evaluate(
            [candidate],
            configuration: ImageExtractionConfiguration(enabled: true, filter: .articleOnly, scoreThreshold: 0.65)
        )

        XCTAssertEqual(evaluated.count, 1)
        XCTAssertEqual(evaluated[0].result.decision, .drop)
        XCTAssertTrue(evaluated[0].result.reasons.contains("filtered_article_only"))
    }

    func testImageContentFilterRemovesDroppedImageSources() throws {
        let html = """
        <main>
          <img src="/assets/logo.svg" alt="Logo">
          <figure>
            <img src="/images/article-hero.jpg" alt="Hero">
          </figure>
        </main>
        """

        let evaluatedImages = [
            EvaluatedImageCandidate(
                candidate: makeCandidate(
                    src: "/assets/logo.svg",
                    currentSrc: "https://example.com/assets/logo.svg",
                    alt: "Logo",
                    isVisible: true,
                    inHeader: true,
                    linkedToRoot: true,
                    filename: "logo.svg",
                    isSvg: true
                ),
                result: .init(score: 0.01, decision: .drop, reasons: ["logo_keyword"])
            ),
            EvaluatedImageCandidate(
                candidate: makeCandidate(
                    src: "/images/article-hero.jpg",
                    currentSrc: "https://example.com/images/article-hero.jpg",
                    alt: "Hero image",
                    naturalWidth: 1600,
                    naturalHeight: 900,
                    renderedWidth: 800,
                    renderedHeight: 450,
                    top: 200,
                    isVisible: true,
                    inArticle: true,
                    inFigure: true,
                    figcaption: "Hero",
                    filename: "article-hero.jpg"
                ),
                result: .init(score: 0.92, decision: .keep, reasons: ["in_article"])
            ),
        ]

        let filtered = try ImageContentFilter.filter(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .contentOnly,
            evaluatedImages: evaluatedImages,
            configuration: ImageExtractionConfiguration(enabled: true)
        )

        XCTAssertFalse(filtered.contains("/assets/logo.svg"))
        XCTAssertTrue(filtered.contains("/images/article-hero.jpg"))
    }

    private func makeCandidate(
        src: String,
        currentSrc: String,
        alt: String,
        id: String = "",
        className: String = "",
        naturalWidth: Double = 0,
        naturalHeight: Double = 0,
        renderedWidth: Double = 0,
        renderedHeight: Double = 0,
        top: Double = 0,
        left: Double = 0,
        isVisible: Bool = false,
        inArticle: Bool = false,
        inHeader: Bool = false,
        inNav: Bool = false,
        inFooter: Bool = false,
        inAside: Bool = false,
        inFigure: Bool = false,
        figcaption: String = "",
        linkedHref: String = "",
        linkedToRoot: Bool = false,
        filename: String,
        isDataUri: Bool = false,
        isSvg: Bool = false,
        nearestTextBlockLength: Int = 0,
        ancestors: [ImageCandidate.Ancestor] = []
    ) -> ImageCandidate {
        ImageCandidate(
            index: 0,
            src: src,
            currentSrc: currentSrc,
            alt: alt,
            title: "",
            id: id,
            className: className,
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            renderedWidth: renderedWidth,
            renderedHeight: renderedHeight,
            top: top,
            left: left,
            loading: "",
            decoding: "",
            role: "",
            ariaHidden: "false",
            isVisible: isVisible,
            inArticle: inArticle,
            inHeader: inHeader,
            inNav: inNav,
            inFooter: inFooter,
            inAside: inAside,
            inFigure: inFigure,
            figcaption: figcaption,
            linkedHref: linkedHref,
            linkedToRoot: linkedToRoot,
            filename: filename,
            isDataUri: isDataUri,
            isSvg: isSvg,
            nearestTextBlockLength: nearestTextBlockLength,
            ancestors: ancestors
        )
    }
}
