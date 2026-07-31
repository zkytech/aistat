import Foundation

protocol DeepSeekClientProtocol: Sendable {
    func fetchBalance() async throws -> DeepSeekBalance
}

enum DeepSeekAPIClientError: LocalizedError, Equatable {
    case notConfigured
    case httpStatus(Int, String)
    case decoding(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在 Settings 配置 DeepSeek API Key"
        case .httpStatus(let code, let message):
            return "HTTP \(code): \(message)"
        case .decoding(let message):
            return "解析失败: \(message)"
        case .emptyResponse:
            return "空响应"
        }
    }
}

struct DeepSeekClient: DeepSeekClientProtocol {
    /// DeepSeek 官方余额接口（固定，无需用户配置 baseURL）。
    static let balanceURL = "https://api.deepseek.com/user/balance"

    private let apiKey: String
    private let session: URLSession

    init(connection: DeepSeekConnection, session: URLSession = .shared) {
        self.apiKey = connection.normalizedAPIKey
        self.session = session
    }

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func fetchBalance() async throws -> DeepSeekBalance {
        guard !apiKey.isEmpty else {
            throw DeepSeekAPIClientError.notConfigured
        }

        guard let url = URL(string: Self.balanceURL) else {
            throw DeepSeekAPIClientError.httpStatus(-1, "无效地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Sub2APIClient.userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(DeepSeekBalance.self, from: data)
        } catch {
            throw DeepSeekAPIClientError.decoding(error.localizedDescription)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekAPIClientError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
            throw DeepSeekAPIClientError.httpStatus(http.statusCode, message.map(String.init) ?? "unknown error")
        }

        if data.isEmpty {
            throw DeepSeekAPIClientError.emptyResponse
        }
        return data
    }
}
