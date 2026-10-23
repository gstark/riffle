import Testing
@testable import RiffleKit

/// The sentence as text, with tokens in brackets.
private func render(_ filters: SearchFilters) -> String {
    filterSentence(filters).map { part in
        switch part {
        case .words(let text): text
        case .token(_, let value): "[\(value)]"
        }
    }.joined()
}

@Suite struct FilterSentenceTests {
    @Test func mockup() {
        let filters = SearchFilters(text: "insurance renewal", from: ["acme"], hasAttachment: true, sort: .relevance)
        #expect(render(filters) == "Mail about [insurance renewal] from [acme], with [attachments], [best match first].")
    }

    @Test func noFilters() {
        #expect(render(.empty) == "All mail, [newest first].")
        #expect(filterSentence(.empty) == [.words("All mail, "), .token(.sort, "newest first"), .words(".")])
    }

    @Test func eachValueIsAToken() {
        let parts = filterSentence(SearchFilters(from: ["acme", "registrar"]))
        #expect(parts == [
            .words("Mail from "), .token(.from, "acme"), .words(" or "), .token(.from, "registrar"),
            .words(", "), .token(.sort, "newest first"), .words("."),
        ])
    }

    @Test func recipients() {
        #expect(render(SearchFilters(to: ["gavin", "billing"])) == "Mail to [gavin] or [billing], [newest first].")
    }

    @Test func labelsJoinWithAndUseDisplayNames() {
        #expect(render(SearchFilters(labels: ["Receipts", "INBOX"])) == "Mail labeled [Receipts] and [Inbox], [newest first].")
    }

    @Test func dates() {
        let filters = SearchFilters(after: Day(year: 2024, month: 1, day: 1), before: Day(year: 2025, month: 1, day: 1))
        #expect(render(filters) == "Mail since [1 Jan 2024] before [1 Jan 2025], [newest first].")
    }

    @Test(arguments: [(true, "with"), (false, "without")])
    func attachment(_ value: Bool, _ word: String) {
        #expect(render(SearchFilters(hasAttachment: value)) == "Mail, \(word) [attachments], [newest first].")
    }

    @Test func spamAndTrash() {
        #expect(render(SearchFilters(includeSpamTrash: true)) == "Mail, including [spam and trash], [newest first].")
    }

    @Test(arguments: [(Sort.relevance, "best match first"), (.newest, "newest first"), (.oldest, "oldest first")])
    func sort(_ sort: Sort, _ phrase: String) {
        #expect(render(SearchFilters(text: "tax", sort: sort)) == "Mail about [tax], [\(phrase)].")
    }

    @Test func allFilters() {
        let filters = SearchFilters(
            text: "tax", from: ["irs"], to: ["me"], after: Day(year: 2024, month: 1, day: 1),
            before: Day(year: 2024, month: 6, day: 1), labels: ["Home"], includeSpamTrash: true,
            hasAttachment: false, sort: .oldest
        )
        #expect(render(filters) == "Mail about [tax] from [irs] to [me] since [1 Jan 2024] before [1 Jun 2024] labeled [Home], without [attachments], including [spam and trash], [oldest first].")
    }
}

@Suite struct RemovingTests {
    private let full = SearchFilters(
        text: "tax", from: ["irs"], to: ["me"], after: Day(year: 2024, month: 1, day: 1),
        before: Day(year: 2024, month: 6, day: 1), labels: ["Home"], includeSpamTrash: true,
        hasAttachment: true, sort: .oldest
    )

    @Test(arguments: FilterField.allCases.filter({ $0 != .sort }))
    func removesOnlyThatField(_ field: FilterField) {
        let removed = full.removing(field)
        #expect(!removed.isSet(field))
        for other in FilterField.allCases where other != field {
            #expect(removed.isSet(other), "\(other) must stay set")
        }
    }

    @Test func removingTextChangesBestMatchToNewest() {
        #expect(SearchFilters(text: "tax", sort: .relevance).removing(.text).sort == .newest)
        #expect(SearchFilters(text: "tax", sort: .oldest).removing(.text).sort == .oldest)
    }

    @Test func sortCannotBeRemoved() {
        #expect(full.removing(.sort) == full)
    }

    @Test func unsetFields() {
        #expect(SearchFilters.empty.unsetFields == [.text, .from, .to, .after, .before, .labels, .attachment, .spamTrash])
        #expect(full.unsetFields.isEmpty)
    }
}

@Suite struct SentenceWordsTests {
    @Test func splitsWordsAndAttachesPunctuation() {
        let filters = SearchFilters(text: "insurance renewal", from: ["acme"], hasAttachment: true, sort: .relevance)
        #expect(sentenceWords(filterSentence(filters)) == [
            SentenceWord(text: "Mail", field: nil, attached: false),
            SentenceWord(text: "about", field: nil, attached: false),
            SentenceWord(text: "insurance renewal", field: .text, attached: false),
            SentenceWord(text: "from", field: nil, attached: false),
            SentenceWord(text: "acme", field: .from, attached: false),
            SentenceWord(text: ",", field: nil, attached: true),
            SentenceWord(text: "with", field: nil, attached: false),
            SentenceWord(text: "attachments", field: .attachment, attached: false),
            SentenceWord(text: ",", field: nil, attached: true),
            SentenceWord(text: "best match first", field: .sort, attached: false),
            SentenceWord(text: ".", field: nil, attached: true),
        ])
    }

    @Test func noFilters() {
        #expect(sentenceWords(filterSentence(.empty)) == [
            SentenceWord(text: "All", field: nil, attached: false),
            SentenceWord(text: "mail,", field: nil, attached: false),
            SentenceWord(text: "newest first", field: .sort, attached: false),
            SentenceWord(text: ".", field: nil, attached: true),
        ])
    }
}
