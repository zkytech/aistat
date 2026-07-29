import Foundation

struct AuthAccount: Decodable, Identifiable, Sendable, Equatable {
    let provider: String
    let email: String?
    let account: String?
    let label: String?
    let authIndex: String
    let status: String?
    let unavailable: Bool
    let statusMessage: String?
    let disabled: Bool
    let nextRetryAfter: String?
    let success: Int?
    let failed: Int?

    var id: String { authIndex }

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
        case provider, email, account, label, status, unavailable, disabled, success, failed
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
        authIndex = try container.decode(FlexibleString.self, forKey: .authIndex).value
        status = try container.decodeIfPresent(String.self, forKey: .status)
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        nextRetryAfter = try container.decodeIfPresent(String.self, forKey: .nextRetryAfter)
        success = try container.decodeIfPresent(Int.self, forKey: .success)
        failed = try container.decodeIfPresent(Int.self, forKey: .failed)
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
