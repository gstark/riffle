// The search field, the filter sentence, the state message, the results, and the keyboard actions.

import AppKit
import RiffleKit
import SwiftUI

struct SearchView: View {
    @Bindable var model: SearchModel
    let state: PanelState
    let open: (URL) -> Void

    private enum Focus: Hashable {
        case search, results
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @State private var selection: SearchResult.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            if let filters = model.filters {
                FilterSentenceView(model: model, filters: filters)
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                if model.editor != nil {
                    FilterEditorView(model: model, filters: filters)
                        .padding(.horizontal, Theme.margin)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
            if model.phase == .idle {
                examples
                    .transition(.opacity)
            } else {
                Divider()
                if model.isSearching {
                    // The area grows to the normal results height first. Then the animation fades in.
                    SearchingView()
                        .frame(height: Theme.resultsMaxHeight)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(reduceMotion ? nil : Theme.resizeAnimation.delay(Theme.resizeDuration)),
                            removal: .opacity
                        ))
                } else {
                    StateMessage(model: model)
                        .transition(.opacity)
                    if !model.results.isEmpty {
                        results
                            .transition(.opacity)
                        Divider()
                        footer
                    }
                }
            }
        }
        // The panel animates to the new height with the same curve. See PanelController.setHeight.
        .animation(reduceMotion ? nil : Theme.resizeAnimation, value: model.phase)
        .animation(reduceMotion ? nil : Theme.resizeAnimation, value: model.results.isEmpty)
        .animation(reduceMotion ? nil : Theme.resizeAnimation, value: model.filters == nil)
        .animation(reduceMotion ? nil : Theme.resizeAnimation, value: model.editor == nil)
        // The clear button and Esc both clear the search. The cursor goes back to the empty field.
        .onChange(of: model.canClear) { _, canClear in
            guard !canClear else { return }
            selection = nil
            focusSearch(selectAll: false)
        }
        .onChange(of: state.openCount, initial: true) {
            selection = nil
            focusSearch(selectAll: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.searchIconSize, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            TextField("Search mail", text: $model.text)
                .textFieldStyle(.plain)
                .font(Theme.searchFont)
                .focused($focus, equals: .search)
                .onSubmit { Task { await model.submitText() } }
                .onKeyPress(.downArrow) {
                    guard !model.isSearching, let first = model.results.first else { return .ignored }
                    selection = first.id
                    focus = .results
                    return .handled
                }
            if model.canClear {
                Button(action: model.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.searchIconSize))
                        .foregroundStyle(Theme.tertiary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Theme.resizeAnimation, value: model.canClear)
        .padding(.horizontal, Theme.margin)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SearchModel.examples, id: \.self) { example in
                Button {
                    Task { await model.runExample(example) }
                } label: {
                    Label(example, systemImage: "arrow.turn.down.right")
                        .font(Theme.detailFont)
                        .foregroundStyle(Theme.secondary)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let newest = model.newestMessageAt {
                Text("Newest indexed mail: \(Self.indexDate(newest))")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 20)
    }

    /// For example "Today at 10:42 AM", or "Oct 20, 2026 at 9:12 AM" for an older date.
    private static func indexDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private var results: some View {
        ResultList(results: model.results, selection: selection) { result in
            open(result.gmailUrl)
        }
        .focusable()
        .focused($focus, equals: .results)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.return) {
            guard let result = model.results.first(where: { $0.id == selection }) else { return .ignored }
            open(result.gmailUrl)
            return .handled
        }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            model.text += press.characters
            selection = nil
            focusSearch(selectAll: false)
            return .handled
        }
    }

    private var footer: some View {
        HStack {
            Text(model.results.count == 1 ? "1 thread" : "\(model.results.count) threads")
            Spacer()
            Text("Return opens in Gmail")
        }
        .font(Theme.smallFont)
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 12)
    }

    /// Moves the result selection. Up from the first result goes back to the search field.
    private func move(by offset: Int) -> KeyPress.Result {
        let ids = model.results.map(\.id)
        guard let current = selection.flatMap(ids.firstIndex(of:)) else { return .ignored }
        let next = current + offset
        if next < 0 {
            selection = nil
            focusSearch(selectAll: false)
        } else if next < ids.count {
            selection = ids[next]
        }
        return .handled
    }

    private func focusSearch(selectAll: Bool) {
        focus = .search
        Task { @MainActor in
            // The field editor exists only after the focus change.
            await Task.yield()
            let action = selectAll ? #selector(NSText.selectAll(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
            NSApp.sendAction(action, to: nil, from: nil)
        }
    }
}
