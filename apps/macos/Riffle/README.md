# Riffle

Riffle is a macOS menu bar app that searches the email index.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- An Apple Development certificate. With ad-hoc signing, each build has a new signature, and macOS asks for Keychain access again.

## Build and install

1. Install XcodeGen and just:

   ```sh
   brew install xcodegen just
   ```

2. From the repository root, build and install:

   ```sh
   just riffle
   ```

The `riffle` recipe does these steps:

1. If `Local.xcconfig` does not exist, it makes the file with the team ID from your Apple Development certificate. To use a different team, edit `DEVELOPMENT_TEAM` in `Local.xcconfig`.
2. It makes the Xcode project with XcodeGen.
3. It builds a Release build.
4. It quits Riffle if Riffle runs.
5. It replaces `/Applications/Riffle.app` with the new build.
6. It opens the new build.

## Install with Homebrew

```sh
brew install gstark/tap/riffle
```

To publish a new release, run `just homebrew` from the repository root. The recipe does these steps:

1. It builds a Release build.
2. It publishes the build as a GitHub release of gstark/riffle.
3. It writes `Casks/riffle.rb` in the gstark/tap tap, and then commits and pushes the cask.

The working tree must be clean. The gstark/tap tap must be installed with `brew tap gstark/tap`.

## Work in Xcode

To work in Xcode, run `just riffle` one time to make `Local.xcconfig`. Then run `xcodegen` in this folder, and open `Riffle.xcodeproj`. You must run `xcodegen` again after you add or remove a file.

## First start

1. Open Riffle. The envelope icon shows in the menu bar.
2. Click the icon. The setup screen opens.
3. Enter the search URL. Get it from the infrastructure output:

   ```sh
   cd infra && tofu output -raw search_url
   ```

4. Enter the token from `~/.config/email-search/token`.
5. Click **Test and save**.

Riffle keeps the URL in its preferences and the token in the Keychain. To change them, right-click the icon and choose **Settings…**.

To start Riffle at login, add it in System Settings > General > Login Items.

## Use

- Press ⌥⌘E, or click the icon, to open the panel.
- Type a search and press Return. Claude reads the search and shows it as a sentence of filters.
- Put words in quotes, such as `"Claude Duet"`, to find mail that has those words in that order. Case does not matter. Claude reads only the words outside the quotes.
- Click a filter in the sentence to change it. A filter change searches again without Claude.
- Press ↓ to go to the results. Press Return, or click a result, to open the thread in Gmail.
- Press Esc to close the panel.

## Receipts

Right-click the icon and choose **Receipts…**. The window shows the receipts that Riffle found in your mail: orders, subscription charges, and refunds. Shipping notices are hidden until you add them with the first token of the sentence.

- The sidebar groups the receipts by merchant or by month. Click a group to show only its receipts. The counts and amounts follow the other filters, so a search for `40-60` shows which merchants have a charge in that range.
- Type in the search field. Riffle reads the text on the Mac, without Claude. Examples: `amazon`, `42.17`, `$40-$60`, `over 100`, `about 42`, `march`, `q3 2025`, `last month`, `card 6534`, `refunds`, `"power bank"`. Words that are not a filter must appear in the merchant, the subject, an item, or the order ID.
- The sentence under the field shows the filters. Click a value to change it from a menu. The amount opens a small editor. A change writes the new search text.
- The ledger lists the receipts by month, with the net amount of each month. A refund is in parentheses.
- The detail has two tabs. **Receipt** shows the items, the totals, and the PDF from the merchant. **Email** shows the email, a button that opens it in Gmail, the related receipts, and the PDF of the email.
- **Export CSV** saves the receipts in the list for a spreadsheet.

## App icon

`Icon/build_icon.py` draws the app icon. It writes `Icon/icon.svg` and all sizes into `Riffle/Assets.xcassets/AppIcon.appiconset`. To change the icon, edit the script and run it:

```sh
pip install resvg-py
python3 Icon/build_icon.py
```

## Tests

The logic that does not need the UI is in the RiffleKit package:

```sh
cd RiffleKit && swift test
```
