import BranchRadarCore
import Foundation

struct JSONRenderer {
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func render<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

struct HumanRenderer {
    func render(_ analysis: BranchAnalysis) -> String {
        var lines: [String] = []
        lines.append("\(symbol(for: analysis.status)) \(analysis.branch)")
        lines.append("  target: \(analysis.target)")
        lines.append("  ahead: \(analysis.ahead)  behind: \(analysis.behind)")

        if analysis.status == .conflict {
            appendConflicts(analysis.conflicts, to: &lines, indent: "  ")
        }
        return lines.joined(separator: "\n")
    }

    func render(_ report: ScanReport) -> String {
        var lines = ["Branch Radar", "Target: \(report.target)", ""]
        if report.branches.isEmpty {
            lines.append("No local branches to analyze.")
            return lines.joined(separator: "\n")
        }

        for (index, branch) in report.branches.enumerated() {
            lines.append(render(branch))
            if index != report.branches.count - 1 {
                lines.append("")
            }
        }

        let conflicts = report.branches.filter { $0.status == .conflict }.count
        lines.append("")
        lines.append("Summary: \(report.branches.count) checked, \(conflicts) conflicting")
        return lines.joined(separator: "\n")
    }

    func render(_ report: PullRequestReport) -> String {
        var lines = ["Branch Radar PRs", "Target: \(report.target)", ""]
        guard !report.pullRequests.isEmpty else {
            lines.append("No open pull requests target this branch.")
            return lines.joined(separator: "\n")
        }

        for pullRequest in report.pullRequests {
            let author = pullRequest.author.map { " by \($0.displayName)" } ?? ""
            lines.append("#\(pullRequest.id) \(pullRequest.title)\(author)")
            lines.append("  \(pullRequest.source.branchName) → \(pullRequest.target.branchName)")
            lines.append("  source: \(shortOID(pullRequest.source.latestCommit))")
        }
        lines.append("")
        lines.append("Summary: \(report.pullRequests.count) open PRs")
        return lines.joined(separator: "\n")
    }

    func render(_ report: ProjectionReport) -> String {
        var lines = ["Branch Radar Projection", "Branch: \(report.branch)", "Target: \(report.target)", ""]
        lines.append("Current: \(symbol(for: report.current.status)) \(report.current.status.rawValue)")
        if report.current.status == .conflict {
            appendConflicts(report.current.conflicts, to: &lines, indent: "  ")
        }

        guard !report.projections.isEmpty else {
            lines.append("")
            lines.append("No other open pull requests to project.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for projection in report.projections {
            let pr = projection.pullRequest
            lines.append("\(projectionSymbol(projection.outcome)) after PR #\(pr.id): \(pr.title)")
            lines.append("  \(pr.source.branchName) → \(pr.target.branchName)")
            appendConflicts(projection.conflicts, to: &lines, indent: "  ")
            if let message = projection.message {
                lines.append("  \(message)")
            }
        }

        let conflicts = report.projections.filter { $0.outcome == .conflict }.count
        lines.append("")
        lines.append("Summary: \(report.projections.count) scenarios, \(conflicts) projected conflicts")
        return lines.joined(separator: "\n")
    }

    func render(_ report: ProjectedScanReport) -> String {
        var lines = ["Branch Radar", "Target: \(report.target)", "Projected against open PRs", ""]
        guard !report.branches.isEmpty else {
            lines.append("No local branches to analyze.")
            return lines.joined(separator: "\n")
        }

        for (index, branch) in report.branches.enumerated() {
            lines.append("\(symbol(for: branch.current.status)) \(branch.branch)")
            let conflicts = branch.projections.filter { $0.outcome == .conflict }
            let unavailable = branch.projections.filter { $0.outcome == .unavailable || $0.outcome == .incomingConflict }
            if conflicts.isEmpty {
                lines.append("  projected: clean across \(branch.projections.count) scenarios")
            } else {
                for projection in conflicts {
                    lines.append("  ✗ conflicts after PR #\(projection.pullRequest.id): \(projection.pullRequest.title)")
                    appendConflicts(projection.conflicts, to: &lines, indent: "    ")
                }
            }
            if !unavailable.isEmpty {
                lines.append("  ? \(unavailable.count) scenario(s) unavailable")
            }
            if index != report.branches.count - 1 { lines.append("") }
        }

        let branchesWithProjectedConflicts = report.branches.filter {
            $0.projections.contains { $0.outcome == .conflict }
        }.count
        lines.append("")
        lines.append("Summary: \(report.branches.count) branches, \(branchesWithProjectedConflicts) with projected conflicts")
        return lines.joined(separator: "\n")
    }

    private func appendConflicts(_ conflicts: [Conflict], to lines: inout [String], indent: String) {
        for conflict in conflicts {
            let kind = conflict.kind == .unknown ? "conflict" : conflict.kind.rawValue
            lines.append("\(indent)! \(conflict.path) [\(kind)]")
        }
    }

    private func symbol(for status: AnalysisStatus) -> String {
        switch status {
        case .clean: return "✓"
        case .conflict: return "✗"
        }
    }

    private func projectionSymbol(_ outcome: ProjectionOutcome) -> String {
        switch outcome {
        case .clean: return "✓"
        case .conflict: return "✗"
        case .incomingConflict: return "!"
        case .unavailable: return "?"
        }
    }

    private func shortOID(_ oid: String) -> String {
        String(oid.prefix(10))
    }
}
