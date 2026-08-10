import BranchRadarCore
import Foundation

struct JSONRenderer {
    private let encoder: JSONEncoder
    init() { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; self.encoder = encoder }
    func render<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
}

struct HumanRenderer {
    func render(_ analysis: BranchAnalysis) -> String {
        var lines = ["\(symbol(for: analysis.status)) \(analysis.branch)", "  target: \(analysis.target)", "  ahead: \(analysis.ahead)  behind: \(analysis.behind)"]
        if analysis.status == .conflict { appendConflicts(analysis.conflicts, to: &lines, indent: "  ") }
        return lines.joined(separator: "\n")
    }

    func render(_ report: ScanReport) -> String {
        var lines = ["Branch Radar", "Target: \(report.target)", ""]
        guard !report.branches.isEmpty else { lines.append("No local branches to analyze."); return lines.joined(separator: "\n") }
        for (index, branch) in report.branches.enumerated() { lines.append(render(branch)); if index != report.branches.count - 1 { lines.append("") } }
        lines.append(""); lines.append("Summary: \(report.branches.count) checked, \(report.branches.filter { $0.status == .conflict }.count) conflicting")
        return lines.joined(separator: "\n")
    }

    func render(_ report: PullRequestReport) -> String {
        var lines = ["Branch Radar PRs", "Target: \(report.target)", ""]
        guard !report.pullRequests.isEmpty else { lines.append("No open pull requests target this branch."); return lines.joined(separator: "\n") }
        for pr in report.pullRequests {
            let author = pr.author.map { " by \($0.displayName)" } ?? ""
            lines.append("#\(pr.id) \(pr.title)\(author)")
            lines.append("  \(pr.source.branchName) → \(pr.target.branchName)")
            lines.append("  source: \(shortOID(pr.source.latestCommit))")
        }
        lines.append(""); lines.append("Summary: \(report.pullRequests.count) open PRs")
        return lines.joined(separator: "\n")
    }

    func render(_ report: ProjectionReport) -> String {
        var lines = ["Branch Radar Projection", "Branch: \(report.branch)", "Target: \(report.target)", ""]
        lines.append("Current: \(symbol(for: report.current.status)) \(report.current.status.rawValue)")
        if report.current.status == .conflict { appendConflicts(report.current.conflicts, to: &lines, indent: "  ") }
        if let freshness = report.targetFreshness, freshness.status != .current {
            let count = freshness.commitsBehind.map { " (\($0) commit(s))" } ?? ""
            lines.append("Target: \(freshnessSymbol(freshness.status)) \(freshness.status.rawValue) vs Bitbucket\(count)")
        }
        if report.projections.isEmpty { lines.append(""); lines.append("No other open pull requests to project.") }
        else {
            lines.append("")
            for projection in report.projections {
                let pr = projection.pullRequest
                lines.append("\(projectionSymbol(projection.outcome)) after PR #\(pr.id): \(pr.title)")
                lines.append("  \(pr.source.branchName) → \(pr.target.branchName)")
                lines.append("  strategy: \(strategyDescription(projection.mergeStrategy))")
                appendConflicts(projection.conflicts, to: &lines, indent: "  ")
                appendRisks(projection.risks, to: &lines, indent: "  ")
                if let message = projection.message { lines.append("  \(message)") }
            }
        }
        if !report.recommendations.isEmpty {
            lines.append(""); lines.append("Recommended:")
            for recommendation in report.recommendations { lines.append("  • \(recommendation.message)") }
        }
        let conflicts = report.projections.filter { $0.outcome == .conflict }.count
        let risks = report.projections.filter { $0.outcome == .risk }.count
        let rejected = report.projections.filter { $0.outcome == .strategyRejected }.count
        lines.append("")
        lines.append("Summary: \(report.projections.count) scenarios, \(conflicts) projected conflicts, \(risks) collision risks, \(rejected) strategy rejections")
        return lines.joined(separator: "\n")
    }

    func render(_ report: ProjectedScanReport) -> String {
        var lines = ["Branch Radar", "Target: \(report.target)", "Projected against open PRs", ""]
        guard !report.branches.isEmpty else { lines.append("No local branches to analyze."); return lines.joined(separator: "\n") }
        for (index, branch) in report.branches.enumerated() {
            lines.append("\(symbol(for: branch.current.status)) \(branch.branch)")
            let conflicts = branch.projections.filter { $0.outcome == .conflict }
            let risks = branch.projections.filter { $0.outcome == .risk }
            let unavailable = branch.projections.filter { $0.outcome == .unavailable || $0.outcome == .incomingConflict }
            let rejected = branch.projections.filter { $0.outcome == .strategyRejected }
            if conflicts.isEmpty && risks.isEmpty && rejected.isEmpty && unavailable.isEmpty {
                lines.append("  projected: clean across \(branch.projections.count) scenarios")
            }
            for projection in conflicts { lines.append("  ✗ conflicts after PR #\(projection.pullRequest.id) [\(projection.mergeStrategy.strategy.id)]: \(projection.pullRequest.title)"); appendConflicts(projection.conflicts, to: &lines, indent: "    ") }
            for projection in risks { lines.append("  ◐ risk after PR #\(projection.pullRequest.id) [\(projection.mergeStrategy.strategy.id)]: \(projection.pullRequest.title)"); appendRisks(projection.risks, to: &lines, indent: "    ") }
            for projection in rejected { lines.append("  ⊘ rejected by \(projection.mergeStrategy.strategy.id) for PR #\(projection.pullRequest.id): \(projection.pullRequest.title)") }
            if !unavailable.isEmpty { lines.append("  ? \(unavailable.count) scenario(s) unavailable") }
            if let first = branch.recommendations.first { lines.append("  → \(first.message)") }
            if index != report.branches.count - 1 { lines.append("") }
        }
        let conflictBranches = report.branches.filter { $0.projections.contains { $0.outcome == .conflict } }.count
        let riskBranches = report.branches.filter { $0.projections.contains { $0.outcome == .risk } }.count
        lines.append(""); lines.append("Summary: \(report.branches.count) branches, \(conflictBranches) with projected conflicts, \(riskBranches) with collision risk")
        return lines.joined(separator: "\n")
    }

    private func appendConflicts(_ conflicts: [Conflict], to lines: inout [String], indent: String) {
        for conflict in conflicts { lines.append("\(indent)! \(conflict.path) [\(conflict.kind == .unknown ? "conflict" : conflict.kind.rawValue)]") }
    }
    private func appendRisks(_ risks: [CollisionRisk], to lines: inout [String], indent: String) {
        for risk in risks { lines.append("\(indent)◐ \(risk.path) [\(risk.level.rawValue), \(risk.kind.rawValue)]") }
    }
    private func symbol(for status: AnalysisStatus) -> String { status == .clean ? "✓" : "✗" }
    private func projectionSymbol(_ outcome: ProjectionOutcome) -> String {
        switch outcome {
        case .clean: return "✓"
        case .risk: return "◐"
        case .conflict: return "✗"
        case .incomingConflict: return "!"
        case .strategyRejected: return "⊘"
        case .unavailable: return "?"
        }
    }
    private func strategyDescription(_ selection: MergeStrategySelection) -> String {
        let source: String
        switch selection.source {
        case .commandLine: source = "command-line override"
        case .autoMerge: source = "auto-merge selection"
        case .repositoryDefault: source = "repository default"
        }
        if selection.isAssumption {
            return "\(selection.strategy.name) [\(selection.strategy.id)] (\(source); manual merge may choose: \(selection.alternativeStrategyIDs.joined(separator: ", ")))"
        }
        return "\(selection.strategy.name) [\(selection.strategy.id)] (\(source))"
    }

    private func freshnessSymbol(_ status: TargetFreshnessStatus) -> String { status == .current ? "✓" : status == .unavailable ? "?" : "!" }
    private func shortOID(_ oid: String) -> String { String(oid.prefix(10)) }
}
