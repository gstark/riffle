// The search API's request and response shapes. See src/search/request.ts and src/search/service.ts.

import Foundation

/// A calendar day, written YYYY-MM-DD as the API expects.
public struct Day: Hashable, Comparable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day that contains `date` in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Midnight at the start of the day in `calendar`'s time zone.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public var text: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// For example "1 Jan 2024".
    public var display: String {
        "\(day) \(Self.monthNames[month - 1]) \(year)"
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let day = Day(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a YYYY-MM-DD date: \(text)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

public enum Sort: String, CaseIterable, Sendable, Codable {
    case relevance, newest, oldest
}

/// Who decided the filters of a search.
public enum QuerySource: String, Sendable, Codable {
    /// Claude read the text.
    case claude
    /// Claude failed. The search used the text as typed.
    case plain
    /// The request had exact filters, or only quoted phrases with nothing for Claude to read.
    case filters
}

/// Every search option of the API. The API requires all fields.
public struct SearchFilters: Equatable, Sendable, Codable {
    public var text: String
    /// Parts of sender names or addresses. A message matches any one of them.
    public var from: [String]
    /// Parts of recipient names or addresses. A message matches any one of them.
    public var to: [String]
    /// First day to include.
    public var after: Day?
    /// First day to leave out.
    public var before: Day?
    /// Label names. A message must have all of them.
    public var labels: [String]
    public var includeSpamTrash: Bool
    /// True: only with attachments. False: only without. Nil: either.
    public var hasAttachment: Bool?
    public var sort: Sort

    public init(
        text: String = "",
        from: [String] = [],
        to: [String] = [],
        after: Day? = nil,
        before: Day? = nil,
        labels: [String] = [],
        includeSpamTrash: Bool = false,
        hasAttachment: Bool? = nil,
        sort: Sort = .newest
    ) {
        self.text = text
        self.from = from
        self.to = to
        self.after = after
        self.before = before
        self.labels = labels
        self.includeSpamTrash = includeSpamTrash
        self.hasAttachment = hasAttachment
        self.sort = sort
    }

    /// No filters: all mail, newest first.
    public static let empty = SearchFilters()

    private enum CodingKeys: String, CodingKey {
        case text, from, to, after, before, labels, includeSpamTrash, hasAttachment, sort
    }

    /// Writes nil as null. The synthesized encoder leaves the key out, and the API rejects that.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(after, forKey: .after)
        try container.encode(before, forKey: .before)
        try container.encode(labels, forKey: .labels)
        try container.encode(includeSpamTrash, forKey: .includeSpamTrash)
        try container.encode(hasAttachment, forKey: .hasAttachment)
        try container.encode(sort, forKey: .sort)
    }
}

/// One thread in the results.
public struct SearchResult: Identifiable, Equatable, Sendable, Decodable {
    public let id: String
    public let threadId: String
    public let date: Date
    /// The From header, for example "Acme Insurance <support@insurer.example>".
    public let from: String
    public let subject: String
    public let snippet: String
    /// Label names.
    public let labels: [String]
    public let hasAttachment: Bool
    public let gmailUrl: URL

    public init(
        id: String, threadId: String, date: Date, from: String, subject: String, snippet: String,
        labels: [String], hasAttachment: Bool, gmailUrl: URL
    ) {
        self.id = id
        self.threadId = threadId
        self.date = date
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.labels = labels
        self.hasAttachment = hasAttachment
        self.gmailUrl = gmailUrl
    }

    /// The sender's name, or the address when the header has no name.
    public var senderName: String {
        guard let open = from.firstIndex(of: "<") else { return from }
        let name = from[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        return from[from.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }
}

public struct SearchResponse: Equatable, Sendable, Decodable {
    /// The filters that the search used.
    public let filters: SearchFilters
    public let source: QuerySource
    public let results: [SearchResult]

    public init(filters: SearchFilters, source: QuerySource, results: [SearchResult]) {
        self.filters = filters
        self.source = source
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case query, results
    }

    private struct SourceField: Decodable {
        let source: QuerySource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filters = try container.decode(SearchFilters.self, forKey: .query)
        source = try container.decode(SourceField.self, forKey: .query).source
        results = try container.decode([SearchResult].self, forKey: .results)
    }
}

/// The body of GET /health.
public struct Health: Equatable, Sendable, Decodable {
    /// The date of the newest message in the index. Nil when the index is empty.
    public let newestMessageAt: Date?

    public init(newestMessageAt: Date?) {
        self.newestMessageAt = newestMessageAt
    }
}

public struct LabelInfo: Hashable, Sendable, Decodable {
    public let name: String
    /// "system" or "user", as Gmail gives it.
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}
