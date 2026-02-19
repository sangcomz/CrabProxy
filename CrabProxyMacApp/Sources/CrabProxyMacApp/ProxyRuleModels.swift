import Foundation

enum RuleSourceType: String, CaseIterable, Identifiable {
    case file = "File"
    case text = "Text"

    var id: String { rawValue }
}

struct MapLocalRuleInput: Identifiable, Hashable {
    let id: UUID
    var isEnabled: Bool
    var matcher: String
    var sourceType: RuleSourceType
    var sourceValue: String
    var statusCode: String
    var contentType: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        matcher: String = "",
        sourceType: RuleSourceType = .file,
        sourceValue: String = "",
        statusCode: String = "200",
        contentType: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.sourceType = sourceType
        self.sourceValue = sourceValue
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

struct MapRemoteRuleInput: Identifiable, Hashable {
    let id: UUID
    var isEnabled: Bool
    var matcher: String
    var destinationURL: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        matcher: String = "",
        destinationURL: String = ""
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.destinationURL = destinationURL
    }
}

struct StatusRewriteRuleInput: Identifiable, Hashable {
    let id: UUID
    var isEnabled: Bool
    var matcher: String
    var fromStatusCode: String
    var toStatusCode: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        matcher: String = "",
        fromStatusCode: String = "",
        toStatusCode: String = "200"
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.fromStatusCode = fromStatusCode
        self.toStatusCode = toStatusCode
    }
}

struct AllowRuleInput: Identifiable, Hashable {
    let id: UUID
    var matcher: String

    init(id: UUID = UUID(), matcher: String = "") {
        self.id = id
        self.matcher = matcher
    }
}
