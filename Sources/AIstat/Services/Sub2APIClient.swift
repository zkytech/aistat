import Foundation

protocol Sub2APIClientProtocol: Sendable {
    func fetchUsage() async throws -> Sub2APIUsage
}

enum Sub2APIClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case decoding(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在 Settings 配置 Sub2API baseURL 与 API Key"
        case .invalidBaseURL(let value):
            return "无效 Sub2API baseURL: \(value)"
        case .httpStatus(let code, let message):
            return "HTTP \(code): \(message)"
        case .decoding(let message):
            return "解析失败: \(message)"
        case .emptyResponse:
            return "空响应"
        }
    }
}

struct Sub2APIClient: Sub2APIClientProtocol {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    init(connection: Sub2APIConnection, session: URLSession = .shared) {
        self.baseURL = connection.normalizedBaseURL
        self.apiKey = connection.normalizedAPIKey
        self.session = session
    }

    init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func fetchUsage() async throws -> Sub2APIUsage {
        let request = try makeRequest(path: "/v1/usage", method: "GET")
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(Sub2APIUsage.self, from: data)
        } catch {
            throw Sub2APIClientError.decoding(error.localizedDescription)
        }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard !baseURL.isEmpty, !apiKey.isEmpty else {
            throw Sub2APIClientError.notConfigured
        }

        guard let url = URL(string: baseURL + path) else {
            throw Sub2APIClientError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Sub2APIClientError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
            throw Sub2APIClientError.httpStatus(http.statusCode, message.map(String.init) ?? "unknown error")
        }

        if data.isEmpty {
            throw Sub2APIClientError.emptyResponse
        }
        return data
    }
}
