// A main menu with only the standard Edit menu. Riffle has no menu bar, so the menu never shows.
// The text fields get their key equivalents (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z) from this menu.
// AppKit adds "Start Dictation…", "Emoji & Symbols", and "AutoFill" to a menu named "Edit".

import AppKit

@MainActor
enum EditMenu {
    static func install() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(
            withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V"
        )
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // AppKit always treats the first item as the app menu.
        let appItem = NSMenuItem(title: "Riffle", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu(title: "Riffle")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
