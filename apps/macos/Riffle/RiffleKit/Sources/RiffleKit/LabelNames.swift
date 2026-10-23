// How Gmail label names show in Riffle.

public enum LabelNames {
    private static let friendly = [
        "INBOX": "Inbox",
        "SENT": "Sent",
        "STARRED": "Starred",
        "IMPORTANT": "Important",
        "UNREAD": "Unread",
        "DRAFT": "Drafts",
        "CHAT": "Chat",
        "CATEGORY_PERSONAL": "Personal",
        "CATEGORY_SOCIAL": "Social",
        "CATEGORY_PROMOTIONS": "Promotions",
        "CATEGORY_UPDATES": "Updates",
        "CATEGORY_FORUMS": "Forums",
    ]

    /// The includeSpamTrash filter controls these, so the labels editor does not show them.
    private static let hidden: Set<String> = ["SPAM", "TRASH"]

    private static func isSystem(_ name: String) -> Bool {
        friendly[name] != nil || hidden.contains(name) || name.hasPrefix("CATEGORY_")
    }

    public static func display(_ name: String) -> String {
        friendly[name] ?? name
    }

    /// The labels that the labels editor offers, sorted by display name.
    public static func pickable(_ labels: [LabelInfo]) -> [LabelInfo] {
        labels
            .filter { !hidden.contains($0.name) }
            .sorted { display($0.name).localizedStandardCompare(display($1.name)) == .orderedAscending }
    }

    /// The labels that a result row shows: user labels only.
    public static func rowLabels(_ names: [String]) -> [String] {
        names.filter { !isSystem($0) }
    }
}
