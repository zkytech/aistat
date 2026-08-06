import Foundation

struct AuthAccount: Codable, Identifiable, Sendable, Equatable {
    let provider: String
    let email: String?
    let account: String?
    let label: String?
    /// Auth file name used by Management API field updates (e.g. `foo.json`).
    let name: String?
    let authIndex: String
    let status: String?
    let unavailable: Bool
    let statusMessage: String?
    let disabled: Bool
    let nextRetryAfter: String?
    let success: Int?
    let failed: Int?

    var id: String { authIndex }

    /// Preferred identifier when patching auth-file fields.
    var managementName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return authIndex
    }

    var displayName: String {
        [email, account, label]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? authIndex
    }

    init(
        provider: String,
        email: String? = nil,
        account: String? = nil,
        label: String? = nil,
        name: String? = nil,
        authIndex: String,
        status: String? = nil,
        unavailable: Bool = false,
        statusMessage: String? = nil,
        disabled: Bool = false,
        nextRetryAfter: String? = nil,
        success: Int? = nil,
        failed: Int? = nil
    ) {
        self.provider = provider
        self.email = email
        self.account = account
        self.label = label
        self.name = name
        self.authIndex = authIndex
        self.status = status
        self.unavailable = unavailable
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.nextRetryAfter = nextRetryAfter
        self.success = success
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey {
        case provider, email, account, label, name, status, unavailable, disabled, success, failed
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case nextRetryAfter = "next_retry_after"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        authIndex = try container.decode(FlexibleString.self, forKey: .authIndex).value
        status = try container.decodeIfPresent(String.self, forKey: .status)
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        nextRetryAfter = try container.decodeIfPresent(String.self, forKey: .nextRetryAfter)
        success = try container.decodeIfPresent(Int.self, forKey: .success)
        failed = try container.decodeIfPresent(Int.self, forKey: .failed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(authIndex, forKey: .authIndex)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(unavailable, forKey: .unavailable)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(disabled, forKey: .disabled)
        try container.encodeIfPresent(nextRetryAfter, forKey: .nextRetryAfter)
        try container.encodeIfPresent(success, forKey: .success)
        try container.encodeIfPresent(failed, forKey: .failed)
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer")
            )
        }
    }
}
