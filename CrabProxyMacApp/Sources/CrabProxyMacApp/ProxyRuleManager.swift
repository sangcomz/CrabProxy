import Foundation

enum ProxyRuleSyncError: Error, LocalizedError {
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case let .invalidValue(message):
            return message
        }
    }
}

struct ProxyRuleManager {
    func syncRules(
        to engine: RustProxyEngine,
        allowRules: [AllowRuleInput],
        mapLocalRules: [MapLocalRuleInput],
        statusRewriteRules: [StatusRewriteRuleInput]
    ) throws {
        try engine.clearRules()

        for matcher in normalizedAllowMatchers(from: allowRules) {
            try engine.addAllowRule(matcher)
        }

        for (index, draft) in mapLocalRules.enumerated() {
            if !draft.isEnabled {
                continue
            }

            let matcher = trimmed(draft.matcher)
            let sourceValue = trimmed(draft.sourceValue)
            let contentType = optionalTrimmed(draft.contentType)
            let status = try parseStatusCode(
                draft.statusCode,
                defaultValue: 200,
                field: "Map Local #\(index + 1) status"
            )

            if matcher.isEmpty && sourceValue.isEmpty && contentType == nil {
                continue
            }
            guard !matcher.isEmpty else {
                throw ProxyRuleSyncError.invalidValue(
                    "Map Local #\(index + 1): matcher is required"
                )
            }
            guard !sourceValue.isEmpty else {
                throw ProxyRuleSyncError.invalidValue(
                    "Map Local #\(index + 1): source value is required"
                )
            }

            let source: MapLocalSource
            switch draft.sourceType {
            case .file:
                source = .file(path: sourceValue)
            case .text:
                source = .text(value: sourceValue)
            }

            try engine.addMapLocalRule(
                MapLocalRuleConfig(
                    matcher: matcher,
                    source: source,
                    statusCode: status,
                    contentType: contentType
                )
            )
        }

        for (index, draft) in statusRewriteRules.enumerated() {
            let matcher = trimmed(draft.matcher)
            let fromStatus = try parseOptionalStatusCode(
                draft.fromStatusCode,
                field: "Status Rewrite #\(index + 1) from"
            )
            let toStatus = try parseStatusCode(
                draft.toStatusCode,
                defaultValue: nil,
                field: "Status Rewrite #\(index + 1) to"
            )

            if matcher.isEmpty && fromStatus == nil && trimmed(draft.toStatusCode).isEmpty {
                continue
            }
            guard !matcher.isEmpty else {
                throw ProxyRuleSyncError.invalidValue(
                    "Status Rewrite #\(index + 1): matcher is required"
                )
            }

            try engine.addStatusRewriteRule(
                StatusRewriteRuleConfig(
                    matcher: matcher,
                    fromStatusCode: fromStatus,
                    toStatusCode: toStatus
                )
            )
        }
    }

    func normalizedAllowMatchers(from allowRules: [AllowRuleInput]) -> [String] {
        var seen: Set<String> = []
        var values: [String] = []

        for draft in allowRules {
            let matcher = trimmed(draft.matcher)
            if matcher.isEmpty {
                continue
            }
            let key = matcher.lowercased()
            if seen.insert(key).inserted {
                values.append(matcher)
            }
        }
        return values
    }

    private func parseStatusCode(
        _ input: String,
        defaultValue: UInt16?,
        field: String
    ) throws -> UInt16 {
        let value = trimmed(input)
        if value.isEmpty {
            if let defaultValue {
                return defaultValue
            }
            throw ProxyRuleSyncError.invalidValue("\(field) is required")
        }
        guard let code = UInt16(value), (100...599).contains(code) else {
            throw ProxyRuleSyncError.invalidValue(
                "\(field) must be a valid HTTP status (100-599)"
            )
        }
        return code
    }

    private func parseOptionalStatusCode(_ input: String, field: String) throws -> Int? {
        let value = trimmed(input)
        if value.isEmpty {
            return nil
        }
        guard let code = Int(value), (100...599).contains(code) else {
            throw ProxyRuleSyncError.invalidValue(
                "\(field) must be empty or a valid HTTP status (100-599)"
            )
        }
        return code
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
