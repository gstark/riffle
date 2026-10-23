import Testing
@testable import RiffleKit

@Suite struct LabelNamesTests {
    @Test(arguments: [
        ("INBOX", "Inbox"), ("SENT", "Sent"), ("STARRED", "Starred"), ("IMPORTANT", "Important"),
        ("UNREAD", "Unread"), ("DRAFT", "Drafts"), ("CHAT", "Chat"), ("CATEGORY_PERSONAL", "Personal"),
        ("CATEGORY_SOCIAL", "Social"), ("CATEGORY_PROMOTIONS", "Promotions"), ("CATEGORY_UPDATES", "Updates"),
        ("CATEGORY_FORUMS", "Forums"), ("Receipts", "Receipts"), ("Home/Taxes", "Home/Taxes"),
    ])
    func display(_ name: String, _ expected: String) {
        #expect(LabelNames.display(name) == expected)
    }

    @Test func pickableHidesSpamAndTrashAndSortsByDisplayName() {
        let labels = [
            LabelInfo(name: "Receipts", type: "user"),
            LabelInfo(name: "SPAM", type: "system"),
            LabelInfo(name: "INBOX", type: "system"),
            LabelInfo(name: "TRASH", type: "system"),
            LabelInfo(name: "CATEGORY_UPDATES", type: "system"),
        ]
        #expect(LabelNames.pickable(labels).map(\.name) == ["INBOX", "Receipts", "CATEGORY_UPDATES"])
    }

    @Test func rowLabelsShowsUserLabelsOnly() {
        let names = ["INBOX", "UNREAD", "Receipts", "CATEGORY_UPDATES", "CATEGORY_NEW", "SPAM", "Home/Taxes"]
        #expect(LabelNames.rowLabels(names) == ["Receipts", "Home/Taxes"])
    }
}
