import Foundation

protocol CLIProxyClientProtocol: Sendable {
    func fetchAccounts() async throws -> [AuthAccount]
    func fetchWeeklyQuota(for account: AuthAccount) async throws -> WeeklyQuota
    func fetchMonthlyQuota(for account: AuthAccount) async throws -> MonthlyQuota?
    func updateAuthPriorities(_ priorities: [(name: String, priority: Int)]) async throws
}

enum CLIProxyClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case decoding(String)
    case emptyResponse
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在 Settings 配置 baseURL 与 managementKey"
        case .invalidBaseURL(let value):
            return "无效 baseURL: \(value)"
        case .httpStatus(let code, let message):
            return "HTTP \(code): \(message)"
        case .decoding(let message):
            return "解析失败: \(message)"
        case .emptyResponse:
            return "空响应"
        case .unsupportedProvider(let provider):
            return "不支持的 provider: \(provider)"
        }
    }
}

struct CLIProxyClient: CLIProxyClientProtocol {
    static let managementUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let grokBillingUserAgent = "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)"
    static let codexUserAgent = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"

    static let weeklyBillingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let monthlyBillingURL = "https://cli-chat-proxy.grok.com/v1/billing"
    static let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

    private let baseURL: String
    private let managementKey: String
    private let session: URLSession

    init(connection: CLIProxyConnection, session: URLSession = .shared) {
        self.baseURL = connection.normalizedBaseURL
        self.managementKey = connection.normalizedManagementKey
        self.session = session
    }

    init(baseURL: String, managementKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func fetchAccounts() async throws -> [AuthAccount] {
        let request = try makeManagementRequest(
            path: "/v0/management/auth-files",
            method: "GET",
            body: nil
        )
        let data = try await perform(request)
        do {
            let response = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
            return response.accounts.filter { SubscriptionProvider.isSupported($0.provider) }
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    func fetchWeeklyQuota(for account: AuthAccount) async throws -> WeeklyQuota {
        guard let provider = SubscriptionProvider.resolve(from: account.provider) else {
            throw CLIProxyClientError.unsupportedProvider(account.provider)
        }

        switch provider {
        case .grok:
            return try await withRetry(times: 2) {
                try await fetchGrokWeeklyQuota(authIndex: account.authIndex)
            }
        case .openai:
            return try await withRetry(times: 2) {
                try await fetchCodexQuota(authIndex: account.authIndex)
            }
        case .claude:
            return try await withRetry(times: 2) {
                try await fetchClaudeQuota(authIndex: account.authIndex)
            }
        }
    }

    func fetchMonthlyQuota(for account: AuthAccount) async throws -> MonthlyQuota? {
        guard let provider = SubscriptionProvider.resolve(from: account.provider) else {
            throw CLIProxyClientError.unsupportedProvider(account.provider)
        }
        // Only Grok exposes cents-based monthly billing via this path.
        guard provider == .grok else { return nil }
        return try await fetchGrokMonthlyQuota(authIndex: account.authIndex)
    }

    func updateAuthPriorities(_ priorities: [(name: String, priority: Int)]) async throws {
        guard !priorities.isEmpty else { return }

        var failures: [String] = []
        for item in priorities {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let payload: [String: Any] = [
                "name": name,
                "priority": item.priority
            ]
            do {
                let body = try JSONSerialization.data(withJSONObject: payload, options: [])
                let request = try makeManagementRequest(
                    path: "/v0/management/auth-files/fields",
                    method: "PATCH",
                    body: body
                )
                _ = try await perform(request)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw CLIProxyClientError.httpStatus(207, failures.joined(separator: "; "))
        }
    }

    private func fetchGrokWeeklyQuota(authIndex: String) async throws -> WeeklyQuota {
        let body = try makeAPICallBody(
            authIndex: authIndex,
            url: Self.weeklyBillingURL,
            header: Self.grokHeaders
        )
        let data = try await performAPICall(body: body)
        do {
            return try JSONDecoder().decode(APIProxyResponse.self, from: data).body.config.weeklyQuota
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    private func fetchGrokMonthlyQuota(authIndex: String) async throws -> MonthlyQuota? {
        let body = try makeAPICallBody(
            authIndex: authIndex,
            url: Self.monthlyBillingURL,
            header: Self.grokHeaders
        )
        let data = try await performAPICall(body: body)
        do {
            return try JSONDecoder().decode(APIProxyResponse.self, from: data).body.config.monthlyQuota
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    private func fetchCodexQuota(authIndex: String) async throws -> WeeklyQuota {
        let body = try makeAPICallBody(
            authIndex: authIndex,
            url: Self.codexUsageURL,
            header: Self.codexHeaders
        )
        let data = try await performAPICall(body: body)
        do {
            let envelope = try JSONDecoder().decode(ManagementAPICallEnvelope.self, from: data)
            try ensureSuccessfulEnvelope(envelope)
            return try JSONDecoder().decode(CodexUsageResponse.self, from: envelope.bodyData).asWeeklyQuota()
        } catch let error as CLIProxyClientError {
            throw error
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    private func fetchClaudeQuota(authIndex: String) async throws -> WeeklyQuota {
        let body = try makeAPICallBody(
            authIndex: authIndex,
            url: Self.claudeUsageURL,
            header: Self.claudeHeaders
        )
        let data = try await performAPICall(body: body)
        do {
            let envelope = try JSONDecoder().decode(ManagementAPICallEnvelope.self, from: data)
            try ensureSuccessfulEnvelope(envelope)
            return try JSONDecoder().decode(ClaudeUsageResponse.self, from: envelope.bodyData).asWeeklyQuota()
        } catch let error as CLIProxyClientError {
            throw error
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    private static var grokHeaders: [String: String] {
        [
            "Authorization": "Bearer $TOKEN$",
            "x-xai-token-auth": "xai-grok-cli",
            "x-grok-client-version": "0.2.91",
            "accept": "*/*",
            "user-agent": grokBillingUserAgent
        ]
    }

    private static var codexHeaders: [String: String] {
        [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": codexUserAgent
        ]
    }

    private static var claudeHeaders: [String: String] {
        [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]
    }

    private func makeAPICallBody(authIndex: String, url: String, header: [String: String]) throws -> Data {
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "GET",
            "url": url,
            "header": header
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func performAPICall(body: Data) async throws -> Data {
        let request = try makeManagementRequest(
            path: "/v0/management/api-call",
            method: "POST",
            body: body
        )
        return try await perform(request)
    }

    private func ensureSuccessfulEnvelope(_ envelope: ManagementAPICallEnvelope) throws {
        guard envelope.isSuccessfulStatus else {
            throw CLIProxyClientError.httpStatus(
                envelope.statusCode ?? -1,
                envelope.errorSnippet
            )
        }
    }

    private func makeManagementRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard !baseURL.isEmpty, !managementKey.isEmpty else {
            throw CLIProxyClientError.notConfigured
        }

        guard let url = URL(string: baseURL + path) else {
            throw CLIProxyClientError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.managementUserAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func withRetry<T>(times: Int, operation: () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error?
        while attempt <= times {
            do {
                return try await operation()
            } catch {
                lastError = error
                attempt += 1
                if attempt > times { break }
                try? await Task.sleep(nanoseconds: UInt64(150_000_000 * attempt))
            }
        }
        throw lastError ?? CLIProxyClientError.emptyResponse
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyClientError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
            throw CLIProxyClientError.httpStatus(http.statusCode, message.map(String.init) ?? "unknown error")
        }

        // PATCH field updates may return an empty body with 200.
        if data.isEmpty {
            if request.httpMethod?.uppercased() == "PATCH" {
                return Data("{}".utf8)
            }
            throw CLIProxyClientError.emptyResponse
        }
        return data
    }
}
