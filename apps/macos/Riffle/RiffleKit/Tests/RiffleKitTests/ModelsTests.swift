import Foundation
import Testing
@testable import RiffleKit

@Suite struct DayTests {
    @Test func readsAndWritesText() throws {
        let day = try #require(Day("2024-01-05"))
        #expect(day == Day(year: 2024, month: 1, day: 5))
        #expect(day.text == "2024-01-05")
    }

    @Test(arguments: ["2024-1-05", "2024-13-01", "2024-01-32", "24-01-01", "2024/01/01", ""])
    func rejectsBadText(_ text: String) {
        #expect(Day(text) == nil)
    }

    @Test func displaysShortMonth() {
        #expect(Day(year: 2024, month: 1, day: 1).display == "1 Jan 2024")
        #expect(Day(year: 2025, month: 12, day: 26).display == "26 Dec 2025")
    }

    @Test func comparesByDate() {
        #expect(Day(year: 2023, month: 12, day: 31) < Day(year: 2024, month: 1, day: 1))
        #expect(Day(year: 2024, month: 2, day: 1) > Day(year: 2024, month: 1, day: 31))
    }

    @Test func convertsToAndFromDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let day = Day(year: 2024, month: 3, day: 10)
        #expect(Day(day.date(calendar: calendar), calendar: calendar) == day)
    }
}

@Suite struct SearchFiltersTests {
    @Test func encodesNilAsNull() throws {
        let data = try JSONEncoder().encode(SearchFilters.empty)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["text", "from", "to", "after", "before", "labels", "includeSpamTrash", "hasAttachment", "sort"])
        #expect(json["after"] is NSNull)
        #expect(json["before"] is NSNull)
        #expect(json["hasAttachment"] is NSNull)
        #expect(json["sort"] as? String == "newest")
    }

    @Test func encodesDaysAsText() throws {
        let filters = SearchFilters(after: Day(year: 2024, month: 1, day: 1), hasAttachment: true)
        let data = try JSONEncoder().encode(filters)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["after"] as? String == "2024-01-01")
        #expect(json["hasAttachment"] as? Bool == true)
    }
}

@Suite struct SearchResultTests {
    private func result(from: String) -> SearchResult {
        SearchResult(
            id: "m1", threadId: "t1", date: .now, from: from, subject: "", snippet: "",
            labels: [], hasAttachment: false, gmailUrl: URL(string: "https://mail.google.com")!
        )
    }

    @Test(arguments: [
        ("Acme Insurance <support@insurer.example>", "Acme Insurance"),
        ("\"Bank, The\" <alerts@bank.com>", "Bank, The"),
        ("<noreply@registrar.example>", "noreply@registrar.example"),
        ("plain@example.com", "plain@example.com"),
    ])
    func senderName(from: String, expected: String) {
        #expect(result(from: from).senderName == expected)
    }
}
