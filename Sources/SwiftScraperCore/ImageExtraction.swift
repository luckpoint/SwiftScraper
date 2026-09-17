import Foundation
import SwiftSoup

public enum ImageFilterMode: String, CaseIterable, Sendable {
    case all
    case articleOnly = "article-only"
}

public struct ImageExtractionConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let filter: ImageFilterMode
    public let scoreThreshold: Double
    public let includeMaybe: Bool
    public let debug: Bool

    public static let disabled = ImageExtractionConfiguration(
        enabled: false,
        filter: .all,
        scoreThreshold: 0.65,
        includeMaybe: false,
        debug: false
    )

    public init(
        enabled: Bool = false,
        filter: ImageFilterMode = .all,
        scoreThreshold: Double = 0.65,
        includeMaybe: Bool = false,
        debug: Bool = false
    ) {
        self.enabled = enabled
        self.filter = filter
        self.scoreThreshold = scoreThreshold
        self.includeMaybe = includeMaybe
        self.debug = debug
    }
}

struct ImageCandidate: Decodable, Equatable, Sendable {
    struct Ancestor: Decodable, Equatable, Sendable {
        let tag: String
        let id: String
        let className: String
        let role: String
    }

    let index: Int
    let src: String
    let currentSrc: String
    let alt: String
    let title: String
    let id: String
    let className: String
    let naturalWidth: Double
    let naturalHeight: Double
    let renderedWidth: Double
    let renderedHeight: Double
    let top: Double
    let left: Double
    let loading: String
    let decoding: String
    let role: String
    let ariaHidden: String
    let isVisible: Bool
    let inArticle: Bool
    let inHeader: Bool
    let inNav: Bool
    let inFooter: Bool
    let inAside: Bool
    let inFigure: Bool
    let figcaption: String
    let linkedHref: String
    let linkedToRoot: Bool
    let filename: String
    let isDataUri: Bool
    let isSvg: Bool
    let nearestTextBlockLength: Int
    let ancestors: [Ancestor]
}

struct ImageHeuristicResult: Equatable, Sendable {
    enum Decision: String, Codable, Equatable, Sendable {
        case keep
        case maybe
        case drop
    }

    let score: Double
    let decision: Decision
    let reasons: [String]
}

struct EvaluatedImageCandidate: Equatable, Sendable {
    let candidate: ImageCandidate
    let result: ImageHeuristicResult

    func shouldKeep(includeMaybe: Bool) -> Bool {
        switch result.decision {
        case .keep:
            return true
        case .maybe:
            return includeMaybe
        case .drop:
            return false
        }
    }
}

enum ImageHeuristics {
    static let maybeThreshold = 0.40

    static func evaluate(
        _ candidates: [ImageCandidate],
        configuration: ImageExtractionConfiguration
    ) -> [EvaluatedImageCandidate] {
        candidates.map { candidate in
            let base = score(candidate, keepThreshold: configuration.scoreThreshold)
            let scoped = applyScopeFilterIfNeeded(base, candidate: candidate, configuration: configuration)
            return EvaluatedImageCandidate(candidate: candidate, result: scoped)
        }
    }

    static func score(_ image: ImageCandidate, keepThreshold: Double) -> ImageHeuristicResult {
        var score = 0.5
        var reasons: [String] = []

        let rw = image.renderedWidth
        let rh = image.renderedHeight
        let nw = image.naturalWidth
        let nh = image.naturalHeight
        let renderedArea = rw * rh
        let aspectRatio = rh > 0 ? rw / rh : 999

        if !image.isVisible {
            score -= 0.4
            reasons.append("not_visible")
        } else {
            score += 0.05
            reasons.append("visible")
        }

        if image.inArticle {
            score += 0.25
            reasons.append("in_article")
        }

        if image.inFigure {
            score += 0.15
            reasons.append("in_figure")
        }

        if !image.figcaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 0.15
            reasons.append("has_figcaption")
        }

        if image.nearestTextBlockLength >= 80 {
            score += 0.08
            reasons.append("near_text_block")
        }

        if rw >= 300 && rh >= 180 {
            score += 0.20
            reasons.append("large_rendered")
        } else if rw >= 160 && rh >= 100 {
            score += 0.08
            reasons.append("medium_rendered")
        } else if rw < 64 || rh < 64 {
            score -= 0.30
            reasons.append("tiny_rendered")
        }

        if nw > 0 && nh > 0 {
            if nw >= 400 && nh >= 250 {
                score += 0.08
                reasons.append("large_natural")
            } else if nw < 64 || nh < 64 {
                score -= 0.20
                reasons.append("tiny_natural")
            }
        }

        let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alt.isEmpty {
            if alt.count >= 8 {
                score += 0.08
                reasons.append("descriptive_alt")
            } else {
                score -= 0.03
                reasons.append("short_alt")
            }
        } else {
            score -= 0.08
            reasons.append("empty_alt")
        }

        if contextContainsAny(image, keywords: ImageKeywordSets.logoLike) {
            score -= 0.45
            reasons.append("logo_keyword")
        }

        if contextContainsAny(image, keywords: ImageKeywordSets.iconLike) {
            score -= 0.30
            reasons.append("icon_keyword")
        }

        if contextContainsAny(image, keywords: ImageKeywordSets.uiLike) {
            score -= 0.20
            reasons.append("ui_keyword")
        }

        if contextContainsAny(image, keywords: ImageKeywordSets.adLike) {
            score -= 0.35
            reasons.append("ad_keyword")
        }

        if contextContainsAny(image, keywords: ImageKeywordSets.articleLike) {
            score += 0.12
            reasons.append("article_keyword")
        }

        if image.inHeader || image.inNav {
            score -= 0.35
            reasons.append("header_or_nav")
        }

        if image.inFooter || image.inAside {
            score -= 0.18
            reasons.append("footer_or_aside")
        }

        if image.linkedToRoot {
            score -= 0.30
            reasons.append("linked_to_root")
        }

        if image.isSvg {
            score -= 0.20
            reasons.append("svg")
        }

        if image.isDataUri && renderedArea < 20_000 {
            score -= 0.30
            reasons.append("small_data_uri")
        }

        if aspectRatio > 4.5 {
            score -= 0.20
            reasons.append("extreme_wide")
        }

        if renderedArea < 5_000 {
            score -= 0.20
            reasons.append("small_area")
        }

        if renderedArea >= 120_000 {
            score += 0.10
            reasons.append("hero_like_area")
        }

        if image.top < 1200 && !image.inHeader && !image.inNav && rw >= 400 && rh >= 220 {
            score += 0.08
            reasons.append("top_large_non_header")
        }

        if image.inHeader && !image.linkedToRoot && rw >= 600 && rh >= 300 && image.inArticle {
            score += 0.18
            reasons.append("header_hero_recovery")
        }

        score = max(0.0, min(1.0, score))

        let decision: ImageHeuristicResult.Decision
        switch score {
        case keepThreshold...:
            decision = .keep
        case maybeThreshold..<keepThreshold:
            decision = .maybe
        default:
            decision = .drop
        }

        return ImageHeuristicResult(score: score, decision: decision, reasons: reasons)
    }

    private static func applyScopeFilterIfNeeded(
        _ result: ImageHeuristicResult,
        candidate: ImageCandidate,
        configuration: ImageExtractionConfiguration
    ) -> ImageHeuristicResult {
        guard configuration.filter == .articleOnly, !candidate.inArticle else {
            return result
        }

        return ImageHeuristicResult(
            score: result.score,
            decision: .drop,
            reasons: result.reasons + ["filtered_article_only"]
        )
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        let value = normalized(text)
        return keywords.contains { value.contains($0) }
    }

    private static func joinedContextStrings(for image: ImageCandidate) -> [String] {
        var values: [String] = [
            image.alt,
            image.title,
            image.id,
            image.className,
            image.filename,
        ]

        for ancestor in image.ancestors {
            values.append(ancestor.tag)
            values.append(ancestor.id)
            values.append(ancestor.className)
            values.append(ancestor.role)
        }

        return values
    }

    private static func contextContainsAny(_ image: ImageCandidate, keywords: [String]) -> Bool {
        joinedContextStrings(for: image).contains { containsAny($0, keywords: keywords) }
    }
}

private enum ImageKeywordSets {
    static let logoLike = ["logo", "brand", "branding", "site-logo", "header-logo"]
    static let iconLike = ["icon", "sprite", "favicon", "avatar", "badge", "emoji"]
    static let uiLike = ["menu", "nav", "navbar", "header", "footer", "share", "social", "button", "btn", "search"]
    static let adLike = ["ad", "ads", "advert", "banner", "promo", "sponsor"]
    static let articleLike = ["article", "post", "entry", "content", "body", "main", "hero", "featured"]
}

enum ImageContentFilter {
    static func filter(
        _ html: String,
        sourceURL: URL,
        extraction: ExtractionMode,
        evaluatedImages: [EvaluatedImageCandidate],
        configuration: ImageExtractionConfiguration
    ) throws -> String {
        let allowedSources = allowedSourceKeys(from: evaluatedImages, sourceURL: sourceURL, includeMaybe: configuration.includeMaybe)

        switch extraction {
        case .outerHTML:
            return try filterDocumentHTML(html, sourceURL: sourceURL, allowedSources: allowedSources)
        case .selectorInnerHTML, .contentOnly:
            return try filterFragmentHTML(html, sourceURL: sourceURL, allowedSources: allowedSources)
        case .bodyText, .structureInspection:
            return html
        }
    }

    private static func allowedSourceKeys(
        from evaluatedImages: [EvaluatedImageCandidate],
        sourceURL: URL,
        includeMaybe: Bool
    ) -> Set<String> {
        var allowed: Set<String> = []

        for item in evaluatedImages where item.shouldKeep(includeMaybe: includeMaybe) {
            normalizedSourceCandidates(for: item.candidate, baseURL: sourceURL).forEach { allowed.insert($0) }
        }

        return allowed
    }

    private static func normalizedSourceCandidates(for candidate: ImageCandidate, baseURL: URL) -> Set<String> {
        var values: Set<String> = []

        for raw in [candidate.currentSrc, candidate.src] {
            if let normalized = normalizeSource(raw, baseURL: baseURL) {
                values.insert(normalized)
            }
        }

        return values
    }

    private static func filterDocumentHTML(_ html: String, sourceURL: URL, allowedSources: Set<String>) throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            try removeDroppedImages(from: document, sourceURL: sourceURL, allowedSources: allowedSources)
            return try document.outerHtml()
        } catch {
            throw ScraperError.extractionFailed("Image filtering failed: \(error.localizedDescription)")
        }
    }

    private static func filterFragmentHTML(_ html: String, sourceURL: URL, allowedSources: Set<String>) throws -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            try removeDroppedImages(from: document, sourceURL: sourceURL, allowedSources: allowedSources)
            if let body = document.body() {
                return try body.html()
            }
            return html
        } catch {
            throw ScraperError.extractionFailed("Image filtering failed: \(error.localizedDescription)")
        }
    }

    private static func removeDroppedImages(from document: Document, sourceURL: URL, allowedSources: Set<String>) throws {
        let images = try document.select("img").array()

        for image in images {
            guard !matchesAllowedSources(image, sourceURL: sourceURL, allowedSources: allowedSources) else {
                continue
            }

            if let parent = image.parent(), parent.tagName().lowercased() == "picture" {
                try parent.remove()
            } else {
                try image.remove()
            }
        }

        for figure in try document.select("figure").array() {
            let remainingImages = try figure.select("img, picture").array()
            if remainingImages.isEmpty {
                try figure.remove()
            }
        }
    }

    private static func matchesAllowedSources(
        _ image: Element,
        sourceURL: URL,
        allowedSources: Set<String>
    ) -> Bool {
        normalizedSourceCandidates(for: image, baseURL: sourceURL).contains(where: allowedSources.contains)
    }

    private static func normalizedSourceCandidates(for image: Element, baseURL: URL) -> Set<String> {
        var values: Set<String> = []

        for attribute in ["src", "data-src", "data-original", "data-lazy-src"] {
            if let normalized = normalizeSource(try? image.attr(attribute), baseURL: baseURL) {
                values.insert(normalized)
            }
        }

        for attribute in ["srcset", "data-srcset"] {
            let rawValue = (try? image.attr(attribute)) ?? ""
            for candidate in parseSrcset(rawValue) {
                if let normalized = normalizeSource(candidate, baseURL: baseURL) {
                    values.insert(normalized)
                }
            }
        }

        return values
    }

    private static func normalizeSource(_ rawValue: String?, baseURL: URL) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("data:") {
            return trimmed
        }

        guard let resolvedURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return trimmed
        }

        guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
            return resolvedURL.absoluteString
        }

        components.fragment = nil
        return components.url?.absoluteString ?? resolvedURL.absoluteString
    }

    private static func parseSrcset(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: ",")
            .map { candidate in
                candidate
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? ""
            }
            .filter { !$0.isEmpty }
    }
}

enum ImageDebugFormatter {
    static func render(
        pageURL: URL,
        evaluatedImages: [EvaluatedImageCandidate],
        configuration: ImageExtractionConfiguration
    ) throws -> String {
        let payload = ImageDebugPayload(
            pageURL: pageURL.absoluteString,
            filter: configuration.filter.rawValue,
            scoreThreshold: configuration.scoreThreshold,
            includeMaybe: configuration.includeMaybe,
            images: evaluatedImages.map { item in
                ImageDebugPayload.Entry(
                    index: item.candidate.index,
                    src: item.candidate.src,
                    currentSrc: item.candidate.currentSrc,
                    score: item.result.score,
                    decision: item.result.decision.rawValue,
                    reasons: item.result.reasons,
                    inArticle: item.candidate.inArticle,
                    inHeader: item.candidate.inHeader,
                    inNav: item.candidate.inNav,
                    renderedWidth: item.candidate.renderedWidth,
                    renderedHeight: item.candidate.renderedHeight
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            let data = try encoder.encode(payload)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ScraperError.outputFailed("Unable to generate the image debug JSON: \(error.localizedDescription)")
        }
    }
}

private struct ImageDebugPayload: Encodable {
    struct Entry: Encodable {
        let index: Int
        let src: String
        let currentSrc: String
        let score: Double
        let decision: String
        let reasons: [String]
        let inArticle: Bool
        let inHeader: Bool
        let inNav: Bool
        let renderedWidth: Double
        let renderedHeight: Double
    }

    let pageURL: String
    let filter: String
    let scoreThreshold: Double
    let includeMaybe: Bool
    let images: [Entry]
}
