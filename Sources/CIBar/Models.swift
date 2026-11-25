import AppKit
import Foundation

/// The provider-neutral state of one build / workflow run.
enum BuildState: String, Codable {
    case queued, running, succeeded, partial, failed, canceled, unknown

    var isActive: Bool { self == .queued || self == .running }
    var isFinished: Bool { !isActive && self != .unknown }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .partial: "Partially succeeded"
        case .failed: "Failed"
        case .canceled: "Canceled"
        case .unknown: "Unknown"
        }
    }

    var color: NSColor {
        switch self {
        case .queued: .systemGray
        case .running: .systemBlue
        case .succeeded: .systemGreen
        case .partial: .systemOrange
        case .failed: .systemRed
        case .canceled, .unknown: .systemGray
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "slash.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// Higher = more attention-worthy (used to pick the menu bar badge colour).
    var severity: Int {
        switch self {
        case .failed: 4
        case .partial: 3
        case .canceled: 2
        case .succeeded: 1
        default: 0
        }
    }
}

struct BuildRun: Identifiable, Equatable {
    let id: String          // "<source uuid>:<run id>"
    let sourceID: UUID
    let number: String
    let title: String
    let pipeline: String
    let repo: String?
    let branch: String?
    let commit: String?
    let author: String?
    let state: BuildState
    let queued: Date?
    let started: Date?
    let finished: Date?
    let url: URL?

    var sortDate: Date { queued ?? started ?? finished ?? .distantPast }
}

enum Provider: String, Codable, CaseIterable, Identifiable {
    case azure, github
    var id: String { rawValue }
    var name: String { self == .azure ? "Azure DevOps" : "GitHub" }
    var symbol: String { self == .azure ? "cloud.fill" : "chevron.left.forwardslash.chevron.right" }
}

/// One thing to watch: an Azure DevOps project (optionally limited to pipeline ids)
/// or a GitHub repository (optionally limited to one workflow).
struct Source: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: Provider
    var enabled = true
    var name = ""
    // Azure DevOps
    var organization = ""
    var project = ""
    var definitionIDs = ""      // comma-separated pipeline (definition) ids; empty = all
    // GitHub
    var owner = ""
    var repo = ""
    var workflow = ""           // workflow file name or id; empty = all
    // Both
    var branch = ""             // empty = all branches

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        switch provider {
        case .azure: return project.isEmpty ? "Azure DevOps" : project
        case .github: return owner.isEmpty ? "GitHub" : "\(owner)/\(repo)"
        }
    }

    var webURL: URL? {
        switch provider {
        case .azure:
            var c = URLComponents()
            c.scheme = "https"; c.host = "dev.azure.com"
            c.path = "/\(organization)/\(project)/_build"
            let first = definitionIDList.first
            if definitionIDList.count == 1, let first { c.queryItems = [URLQueryItem(name: "definitionId", value: String(first))] }
            return c.url
        case .github:
            return URL(string: "https://github.com/\(owner)/\(repo)/actions")
        }
    }

    var definitionIDList: [Int] {
        definitionIDs.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
    }

    var isConfigured: Bool {
        switch provider {
        case .azure: !organization.isEmpty && !project.isEmpty
        case .github: !owner.isEmpty && !repo.isEmpty
        }
    }

    /// Builds a source from a pasted browser URL, e.g.
    /// https://dev.azure.com/Org/Project/_build?definitionId=105
    /// https://org.visualstudio.com/Project/_build
    /// https://github.com/owner/repo/actions/workflows/ci.yml
    static func from(urlString raw: String) -> Source? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = c.host?.lowercased() else { return nil }
        let parts = c.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let query = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        if host == "dev.azure.com", parts.count >= 2 {
            var s = Source(provider: .azure)
            s.organization = parts[0]; s.project = parts[1]
            s.definitionIDs = query["definitionid"] ?? ""
            return s
        }
        if host.hasSuffix(".visualstudio.com"), parts.count >= 1 {
            var s = Source(provider: .azure)
            s.organization = String(host.dropLast(".visualstudio.com".count))
            s.project = parts[0]
            s.definitionIDs = query["definitionid"] ?? ""
            return s
        }
        if host == "github.com" || host == "www.github.com", parts.count >= 2 {
            var s = Source(provider: .github)
            s.owner = parts[0]
            s.repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            if parts.count >= 5, parts[2] == "actions", parts[3] == "workflows" { s.workflow = parts[4] }
            return s
        }
        return nil
    }
}

enum ISODate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts any number of fractional-second digits (Azure sends 7).
    static func parse(_ s: String?) -> Date? {
        guard var str = s, !str.isEmpty else { return nil }
        if let r = str.range(of: #"\.\d+"#, options: .regularExpression) { str.removeSubrange(r) }
        guard let d = formatter.date(from: str), d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }
}
