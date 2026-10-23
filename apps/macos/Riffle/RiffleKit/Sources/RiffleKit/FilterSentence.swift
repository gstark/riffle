// The filters as one sentence, for example
// "Mail about insurance renewal from acme, with attachments, best match first."

public enum FilterField: String, CaseIterable, Sendable {
    case text, from, to, after, before, labels, attachment, spamTrash, sort

    /// The name on the "+ filter" buttons.
    public var title: String {
        switch self {
        case .text: "Words"
        case .from: "From"
        case .to: "To"
        case .after: "Since"
        case .before: "Before"
        case .labels: "Labels"
        case .attachment: "Attachments"
        case .spamTrash: "Spam and trash"
        case .sort: "Sort"
        }
    }
}

public enum SentencePart: Equatable, Sendable {
    case words(String)
    /// A value that opens the editor of its filter.
    case token(FilterField, String)
}

extension Sort {
    public var phrase: String {
        switch self {
        case .relevance: "best match first"
        case .newest: "newest first"
        case .oldest: "oldest first"
        }
    }
}

extension SearchFilters {
    public func isSet(_ field: FilterField) -> Bool {
        switch field {
        case .text: !text.isEmpty
        case .from: !from.isEmpty
        case .to: !to.isEmpty
        case .after: after != nil
        case .before: before != nil
        case .labels: !labels.isEmpty
        case .attachment: hasAttachment != nil
        case .spamTrash: includeSpamTrash
        case .sort: true
        }
    }

    /// The filters that "+ filter" offers.
    public var unsetFields: [FilterField] {
        FilterField.allCases.filter { !isSet($0) }
    }

    /// The filters without `field`. The sort cannot be removed.
    public func removing(_ field: FilterField) -> SearchFilters {
        var filters = self
        switch field {
        case .text:
            filters.text = ""
            // Best match needs words to rank by.
            if filters.sort == .relevance { filters.sort = .newest }
        case .from: filters.from = []
        case .to: filters.to = []
        case .after: filters.after = nil
        case .before: filters.before = nil
        case .labels: filters.labels = []
        case .attachment: filters.hasAttachment = nil
        case .spamTrash: filters.includeSpamTrash = false
        case .sort: break
        }
        return filters
    }
}

public func filterSentence(_ filters: SearchFilters) -> [SentencePart] {
    var parts: [SentencePart] = []

    func words(_ text: String) {
        if case .words(let last)? = parts.last {
            parts[parts.count - 1] = .words(last + text)
        } else {
            parts.append(.words(text))
        }
    }

    func tokens(_ field: FilterField, _ values: [String], joiner: String) {
        for (index, value) in values.enumerated() {
            if index > 0 { words(joiner) }
            parts.append(.token(field, value))
        }
    }

    let filtered = FilterField.allCases.contains { $0 != .sort && filters.isSet($0) }
    words(filtered ? "Mail" : "All mail")

    if filters.isSet(.text) {
        words(" about ")
        parts.append(.token(.text, filters.text))
    }
    if filters.isSet(.from) {
        words(" from ")
        tokens(.from, filters.from, joiner: " or ")
    }
    if filters.isSet(.to) {
        words(" to ")
        tokens(.to, filters.to, joiner: " or ")
    }
    if let after = filters.after {
        words(" since ")
        parts.append(.token(.after, after.display))
    }
    if let before = filters.before {
        words(" before ")
        parts.append(.token(.before, before.display))
    }
    if filters.isSet(.labels) {
        words(" labeled ")
        tokens(.labels, filters.labels.map(LabelNames.display), joiner: " and ")
    }
    if let hasAttachment = filters.hasAttachment {
        words(hasAttachment ? ", with " : ", without ")
        parts.append(.token(.attachment, "attachments"))
    }
    if filters.includeSpamTrash {
        words(", including ")
        parts.append(.token(.spamTrash, "spam and trash"))
    }
    words(", ")
    parts.append(.token(.sort, filters.sort.phrase))
    words(".")
    return parts
}

/// One word or token of the sentence, for a layout that wraps between words.
public struct SentenceWord: Equatable, Sendable {
    public let text: String
    /// Nil for the plain words.
    public let field: FilterField?
    /// True when no space comes before the word, for example the comma after a token.
    public let attached: Bool

    public init(text: String, field: FilterField?, attached: Bool) {
        self.text = text
        self.field = field
        self.attached = attached
    }
}

public func sentenceWords(_ parts: [SentencePart]) -> [SentenceWord] {
    var words: [SentenceWord] = []
    var space = false
    for part in parts {
        switch part {
        case .words(let text):
            for (index, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { space = true }
                guard !piece.isEmpty else { continue }
                words.append(SentenceWord(text: String(piece), field: nil, attached: !space && !words.isEmpty))
                space = false
            }
        case .token(let field, let value):
            words.append(SentenceWord(text: value, field: field, attached: !space && !words.isEmpty))
            space = false
        }
    }
    return words
}
