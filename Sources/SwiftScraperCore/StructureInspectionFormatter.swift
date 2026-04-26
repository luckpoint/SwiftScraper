import Foundation

enum StructureInspectionFormatter {
    struct Report: Decodable, Equatable {
        struct Landmarks: Decodable, Equatable {
            let header: Int
            let footer: Int
            let nav: Int
            let aside: Int
            let main: Int
            let article: Int
        }

        struct RemovalCounts: Decodable, Equatable {
            let header: Int
            let footer: Int
            let nav: Int
            let aside: Int
            let sidebarLike: Int
            let hidden: Int
            let scriptLike: Int
        }

        let title: String
        let url: String
        let landmarks: Landmarks
        let candidate: String
        let candidateTextLength: Int
        let testedCandidates: Int
        let fallbackToBody: Bool
        let contentOnlyRemoval: RemovalCounts
    }

    static func render(json: String) throws -> String {
        let data = Data(json.utf8)

        let report: Report
        do {
            report = try JSONDecoder().decode(Report.self, from: data)
        } catch {
            throw ScraperError.extractionFailed("構成レポートの JSON 解釈に失敗しました: \(error.localizedDescription)")
        }

        let title = report.title.isEmpty ? "(empty)" : report.title
        let candidate = report.candidate.isEmpty ? "(not found)" : report.candidate

        return """
        title: \(title)
        url: \(report.url)
        landmarks: header=\(report.landmarks.header) footer=\(report.landmarks.footer) nav=\(report.landmarks.nav) aside=\(report.landmarks.aside) main=\(report.landmarks.main) article=\(report.landmarks.article)
        contentCandidate: \(candidate)
        candidateTextLength: \(report.candidateTextLength)
        testedCandidates: \(report.testedCandidates)
        fallbackToBody: \(report.fallbackToBody)
        contentOnlyRemoval: header=\(report.contentOnlyRemoval.header) footer=\(report.contentOnlyRemoval.footer) nav=\(report.contentOnlyRemoval.nav) aside=\(report.contentOnlyRemoval.aside) sidebarLike=\(report.contentOnlyRemoval.sidebarLike) hidden=\(report.contentOnlyRemoval.hidden) scriptLike=\(report.contentOnlyRemoval.scriptLike)
        """
    }
}
