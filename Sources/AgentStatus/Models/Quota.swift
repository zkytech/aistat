import Foundation

struct ProductUsage: Decodable, Sendable, Equatable, Identifiable {
    let product: String
    let usagePercent: Double

    var id: String { product }

    init(product: String, usagePercent: Double) {
        self.product = product
        self.usagePercent = usagePercent.clampedPercentage
    }

    private enum CodingKeys: String, CodingKey {
        case product, usagePercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try container.decode(String.self, forKey: .product)
        usagePercent = try container.decode(FlexibleDouble.self, forKey: .usagePercent).value.clampedPercentage
    }
}

struct WeeklyQuota: Sendable, Equatable {
    let usedPercent: Double?
    let periodStart: Date?
    let periodEnd: Date?
    let productUsage: [ProductUsage]

    var remainingPercent: Double? {
        usedPercent.map { (100 - $0).clampedPercentage }
    }

    var isExhausted: Bool {
        usedPercent.map { $0 >= 100 } ?? false
    }
}

struct MonthlyQuota: Sendable, Equatable {
    let limitCents: Int
    let usedCents: Int
}

struct AccountQuota: Identifiable, Sendable, Equatable {
    let account: AuthAccount
    var weekly: WeeklyQuota?
    var monthly: MonthlyQuota?
    var errorMessage: String?

    var id: String { account.id }

    var isUnavailable: Bool {
        account.disabled || account.unavailable || weekly?.isExhausted == true
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a number or numeric string")
            )
        }
    }
}

private extension Double {
    var clampedPercentage: Double { min(max(self, 0), 100) }
}
