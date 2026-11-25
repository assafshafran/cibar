import Foundation

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Providers {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    static func fetch(_ source: Source, azureToken: String, githubToken: String, top: Int) async throws -> [BuildRun] {
        guard source.isConfigured else { throw ProviderError("Incomplete source: open Settings to finish it") }
        switch source.provider {
        case .azure: return try await AzureDevOps.fetch(source, token: azureToken, top: top)
        case .github: return try await GitHub.fetch(source, token: githubToken, top: top)
        }
    }
}

// MARK: - Azure DevOps

enum AzureDevOps {
    private struct List: Decodable { let value: [Build] }
    private struct Build: Decodable {
        struct Named: Decodable { let name: String? }
        struct Person: Decodable { let displayName: String? }
        struct Links: Decodable { struct Href: Decodable { let href: String? }; let web: Href? }
        let id: Int
        let buildNumber: String?
        let status: String?
        let result: String?
        let queueTime: String?
        let startTime: String?
        let finishTime: String?
        let sourceBranch: String?
        let sourceVersion: String?
        let triggerInfo: [String: String]?
        let definition: Named?
        let repository: Named?
        let requestedFor: Person?
        let _links: Links?
    }

    static func fetch(_ s: Source, token: String, top: Int) async throws -> [BuildRun] {
        guard !token.isEmpty else { throw ProviderError("Add an Azure DevOps token in Settings") }
        var c = URLComponents()
        c.scheme = "https"; c.host = "dev.azure.com"
        c.path = "/\(s.organization)/\(s.project)/_apis/build/builds"
        var q = [
            URLQueryItem(name: "api-version", value: "7.1"),
            URLQueryItem(name: "$top", value: String(top)),
            URLQueryItem(name: "queryOrder", value: "queueTimeDescending"),
        ]
        let defs = s.definitionIDList
        if !defs.isEmpty { q.append(URLQueryItem(name: "definitions", value: defs.map(String.init).joined(separator: ","))) }
        let branch = s.branch.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { q.append(URLQueryItem(name: "branchName", value: branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)")) }
        c.queryItems = q
        guard let url = c.url else { throw ProviderError("Invalid organization or project name") }

        var req = URLRequest(url: url)
        req.setValue("Basic " + Data(":\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("true", forHTTPHeaderField: "X-TFS-FedAuthRedirect-Suppress")

        let (data, resp) = try await Providers.session.data(for: req)
        let http = resp as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        switch http?.statusCode ?? 0 {
        case 200 where type.contains("json"): break
        case 200, 203, 302, 401: throw ProviderError("Azure DevOps rejected the token (needs Build: Read, and access to \(s.organization))")
        case 403: throw ProviderError("The token has no access to \(s.project) builds")
        case 404: throw ProviderError("Organization or project not found")
        case let code: throw ProviderError("Azure DevOps returned HTTP \(code)")
        }

        let list = try JSONDecoder().decode(List.self, from: data)
        return list.value.map { b in
            let state: BuildState
            switch (b.status ?? "").lowercased() {
            case "inprogress", "cancelling": state = .running
            case "notstarted", "postponed": state = .queued
            case "completed":
                switch (b.result ?? "").lowercased() {
                case "succeeded": state = .succeeded
                case "partiallysucceeded": state = .partial
                case "failed": state = .failed
                case "canceled": state = .canceled
                default: state = .unknown
                }
            default: state = .unknown
            }
            let message = b.triggerInfo?["ci.message"] ?? b.triggerInfo?["pr.title"]
            let title = message?.split(separator: "\n").first.map(String.init) ?? b.definition?.name ?? "Build \(b.id)"
            let branch = b.sourceBranch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") }
            return BuildRun(
                id: "\(s.id):\(b.id)", sourceID: s.id,
                number: b.buildNumber ?? "#\(b.id)", title: title,
                pipeline: b.definition?.name ?? "", repo: b.repository?.name,
                branch: branch, commit: b.sourceVersion.map { String($0.prefix(7)) },
                author: b.requestedFor?.displayName, state: state,
                queued: ISODate.parse(b.queueTime), started: ISODate.parse(b.startTime),
                finished: ISODate.parse(b.finishTime),
                url: b._links?.web?.href.flatMap(URL.init(string:)))
        }
    }
}

// MARK: - GitHub Actions

enum GitHub {
    private struct List: Decodable { let workflow_runs: [Run] }
    private struct Run: Decodable {
        struct Actor: Decodable { let login: String? }
        struct Repo: Decodable { let name: String? }
        let id: Int
        let name: String?
        let display_title: String?
        let run_number: Int?
        let status: String?
        let conclusion: String?
        let created_at: String?
        let run_started_at: String?
        let updated_at: String?
        let head_branch: String?
        let head_sha: String?
        let html_url: String?
        let actor: Actor?
        let repository: Repo?
    }

    static func fetch(_ s: Source, token: String, top: Int) async throws -> [BuildRun] {
        let wf = s.workflow.trimmingCharacters(in: .whitespaces)
        var c = URLComponents()
        c.scheme = "https"; c.host = "api.github.com"
        c.path = wf.isEmpty
            ? "/repos/\(s.owner)/\(s.repo)/actions/runs"
            : "/repos/\(s.owner)/\(s.repo)/actions/workflows/\(wf)/runs"
        var q = [URLQueryItem(name: "per_page", value: String(top))]
        let branch = s.branch.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { q.append(URLQueryItem(name: "branch", value: branch)) }
        c.queryItems = q
        guard let url = c.url else { throw ProviderError("Invalid owner or repository name") }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("BuildBar", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, resp) = try await Providers.session.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 401: throw ProviderError("GitHub rejected the token")
        case 403, 429:
            if http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw ProviderError(token.isEmpty ? "GitHub rate limit reached: add a token in Settings" : "GitHub rate limit reached")
            }
            throw ProviderError("The token has no access to \(s.owner)/\(s.repo) Actions")
        case 404: throw ProviderError(token.isEmpty ? "Repository not found (private? add a GitHub token)" : "Repository or workflow not found")
        case let code: throw ProviderError("GitHub returned HTTP \(code)")
        }

        let list = try JSONDecoder().decode(List.self, from: data)
        return list.workflow_runs.map { r in
            let state: BuildState
            switch (r.status ?? "").lowercased() {
            case "in_progress": state = .running
            case "queued", "waiting", "requested", "pending": state = .queued
            case "completed":
                switch (r.conclusion ?? "").lowercased() {
                case "success": state = .succeeded
                case "failure", "timed_out", "startup_failure": state = .failed
                case "cancelled", "skipped", "neutral", "stale": state = .canceled
                case "action_required": state = .partial
                default: state = .unknown
                }
            default: state = .unknown
            }
            return BuildRun(
                id: "\(s.id):\(r.id)", sourceID: s.id,
                number: r.run_number.map { "#\($0)" } ?? "#\(r.id)",
                title: r.display_title ?? r.name ?? "Run \(r.id)",
                pipeline: r.name ?? "", repo: r.repository?.name,
                branch: r.head_branch, commit: r.head_sha.map { String($0.prefix(7)) },
                author: r.actor?.login, state: state,
                queued: ISODate.parse(r.created_at), started: ISODate.parse(r.run_started_at),
                finished: state.isFinished ? ISODate.parse(r.updated_at) : nil,
                url: r.html_url.flatMap(URL.init(string:)))
        }
    }

    struct RepoInfo: Decodable, Identifiable, Hashable {
        let full_name: String
        let `private`: Bool
        let pushed_at: String?
        var id: String { full_name }
    }

    private static func get(_ path: String, token: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("BuildBar", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await Providers.session.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401: throw ProviderError("GitHub rejected the token")
        case let code: throw ProviderError("GitHub returned HTTP \(code)")
        }
    }

    private static func pages(_ path: String, token: String) async throws -> [RepoInfo] {
        var all: [RepoInfo] = []
        for page in 1...5 {
            let sep = path.contains("?") ? "&" : "?"
            let batch = try JSONDecoder().decode([RepoInfo].self, from: try await get("\(path)\(sep)per_page=100&page=\(page)", token: token))
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    /// Repositories the token was granted, plus the user's own public repositories
    /// (a fine-grained token limited to selected repos doesn't list the others, though it can read them).
    static func listRepos(token: String) async throws -> [RepoInfo] {
        guard !token.isEmpty else { throw ProviderError("Save a GitHub token first") }
        var byName: [String: RepoInfo] = [:]
        for r in try await pages("/user/repos?sort=pushed", token: token) { byName[r.full_name.lowercased()] = r }
        struct Me: Decodable { let login: String }
        if let me = try? JSONDecoder().decode(Me.self, from: try await get("/user", token: token)),
           let publicRepos = try? await pages("/users/\(me.login)/repos?type=owner&sort=pushed", token: token) {
            for r in publicRepos where byName[r.full_name.lowercased()] == nil { byName[r.full_name.lowercased()] = r }
            // Organizations: the token's view (may be empty for fine-grained tokens) plus public memberships.
            struct Org: Decodable { let login: String }
            var orgs = Set<String>()
            for path in ["/user/orgs?per_page=100", "/users/\(me.login)/orgs?per_page=100"] {
                if let data = try? await get(path, token: token),
                   let list = try? JSONDecoder().decode([Org].self, from: data) { orgs.formUnion(list.map(\.login)) }
            }
            for org in orgs.sorted() {
                guard let repos = try? await pages("/orgs/\(org)/repos?type=public&sort=pushed", token: token) else { continue }
                for r in repos where byName[r.full_name.lowercased()] == nil { byName[r.full_name.lowercased()] = r }
            }
        }
        return byName.values.sorted { ($0.pushed_at ?? "") > ($1.pushed_at ?? "") }
    }

    /// Reads the token of an installed, signed-in `gh` CLI, if there is one.
    static func ghCLIToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
