import Foundation

protocol CLIProxyClientProtocol: Sendable {
    func fetchXAIAccounts() async throws -> [AuthAccount]
    func fetchWeeklyQuota(authIndex: String) async throws -> WeeklyQuota
    func fetchMonthlyQuota(authIndex: String) async throws -> MonthlyQuota?
}

enum CLIProxyClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case decoding(String)
    case emptyResponse

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
        }
    }
}

struct CLIProxyClient: CLIProxyClientProtocol {
    static let managementUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let grokBillingUserAgent = "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)"
    static let weeklyBillingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let monthlyBillingURL = "https://cli-chat-proxy.grok.com/v1/billing"

    private let configuration: AppConfiguration
    private let session: URLSession

    init(configuration: AppConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchXAIAccounts() async throws -> [AuthAccount] {
        let request = try makeManagementRequest(
            path: "/v0/management/auth-files",
            method: "GET",
            body: nil
        )
        let data = try await perform(request)
        do {
            let response = try JSONDecoder().decode(AuthFilesResponse.self, from: data)
            return response.accounts.filter { $0.provider.lowercased() == "xai" }
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    func fetchWeeklyQuota(authIndex: String) async throws -> WeeklyQuota {
        try await withRetry(times: 2) {
            let body = try makeAPICallBody(authIndex: authIndex, url: Self.weeklyBillingURL)
            let request = try makeManagementRequest(
                path: "/v0/management/api-call",
                method: "POST",
                body: body
            )
            let data = try await perform(request)
            do {
                return try JSONDecoder().decode(APIProxyResponse.self, from: data).body.config.weeklyQuota
            } catch {
                throw CLIProxyClientError.decoding(error.localizedDescription)
            }
        }
    }

    func fetchMonthlyQuota(authIndex: String) async throws -> MonthlyQuota? {
        let body = try makeAPICallBody(authIndex: authIndex, url: Self.monthlyBillingURL)
        let request = try makeManagementRequest(
            path: "/v0/management/api-call",
            method: "POST",
            body: body
        )
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(APIProxyResponse.self, from: data).body.config.monthlyQuota
        } catch {
            throw CLIProxyClientError.decoding(error.localizedDescription)
        }
    }

    private func makeAPICallBody(authIndex: String, url: String) throws -> Data {
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "GET",
            "url": url,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "x-xai-token-auth": "xai-grok-cli",
                "x-grok-client-version": "0.2.91",
                "accept": "*/*",
                "user-agent": Self.grokBillingUserAgent
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func makeManagementRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard configuration.isConfigured else {
            throw CLIProxyClientError.notConfigured
        }

        let base = configuration.normalizedBaseURL
        guard let url = URL(string: base + path) else {
            throw CLIProxyClientError.invalidBaseURL(base)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.normalizedManagementKey)", forHTTPHeaderField: "Authorization")
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

        guard !data.isEmpty else {
            throw CLIProxyClientError.emptyResponse
        }
        return data
    }
}
