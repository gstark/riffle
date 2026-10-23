// The editor row below the filter sentence: the "+ filter" buttons, or the editor of one filter.
// Each change searches again with the full filter state.

import RiffleKit
import SwiftUI

struct FilterEditorView: View {
    let model: SearchModel
    let filters: SearchFilters

    var body: some View {
        Group {
            switch model.editor {
            case .add:
                addButtons
            case .field(let field):
                editor(for: field).id(field)
            case nil:
                EmptyView()
            }
        }
        .font(Theme.detailFont)
        .controlSize(.regular)
    }

    private var addButtons: some View {
        WrapLayout(lineHeight: 38, spacing: 8) {
            ForEach(filters.unsetFields, id: \.self) { field in
                Button(field.title) { model.editor = .field(field) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func editor(for field: FilterField) -> some View {
        let edit = FilterEdit(model: model, filters: filters, field: field)
        switch field {
        case .text: TextEditorRow(edit: edit)
        case .from, .to: TermsEditorRow(edit: edit)
        case .after, .before: DayEditorRow(edit: edit)
        case .labels: LabelsEditorRow(edit: edit)
        case .attachment: AttachmentEditorRow(edit: edit)
        case .spamTrash: SpamTrashEditorRow(edit: edit)
        case .sort: SortEditorRow(edit: edit)
        }
    }
}

/// What every editor needs: the current filters, a way to apply new ones, and Remove.
@MainActor
private struct FilterEdit {
    let model: SearchModel
    let filters: SearchFilters
    let field: FilterField

    func apply(_ filters: SearchFilters) {
        model.editor = nil
        guard filters != self.filters else { return }
        Task { await model.setFilters(filters) }
    }

    func remove() {
        guard filters.isSet(field) else {
            model.editor = nil
            return
        }
        Task { await model.remove(field) }
    }
}

/// A label, the control, then Remove and Apply on the right.
private struct EditorRow<Control: View>: View {
    let edit: FilterEdit
    var apply: (() -> Void)?
    var applyDisabled = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(edit.field.title)
                .foregroundStyle(Theme.secondary)
                .frame(width: 132, alignment: .leading)
            control
            Spacer(minLength: 0)
            if edit.field != .sort {
                Button("Remove") { edit.remove() }
            }
            if let apply {
                Button("Apply", action: apply).disabled(applyDisabled)
            }
        }
    }
}

private struct TextEditorRow: View {
    let edit: FilterEdit
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        EditorRow(edit: edit, apply: apply) {
            TextField("Words to search for", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(apply)
        }
        .onAppear {
            draft = edit.filters.text
            focused = true
        }
    }

    private func apply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return edit.remove() }
        var filters = edit.filters
        filters.text = String(text.prefix(500))
        edit.apply(filters)
    }
}

private struct TermsEditorRow: View {
    let edit: FilterEdit
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var values: [String] {
        edit.field == .from ? edit.filters.from : edit.filters.to
    }

    var body: some View {
        EditorRow(edit: edit, apply: apply) {
            TextField("Names or addresses, separated by commas", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(apply)
        }
        .onAppear {
            draft = values.joined(separator: ", ")
            focused = true
        }
    }

    private func apply() {
        let terms = draft
            .split(separator: ",")
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            .filter { !$0.isEmpty }
            .prefix(10)
        guard !terms.isEmpty else { return edit.remove() }
        var filters = edit.filters
        if edit.field == .from { filters.from = Array(terms) } else { filters.to = Array(terms) }
        edit.apply(filters)
    }
}

private struct DayEditorRow: View {
    let edit: FilterEdit
    @State private var date = Date.now

    /// The filters with the picked day.
    private var picked: SearchFilters {
        var filters = edit.filters
        if edit.field == .after { filters.after = Day(date) } else { filters.before = Day(date) }
        return filters
    }

    private var valid: Bool {
        guard let after = picked.after, let before = picked.before else { return true }
        return after < before
    }

    var body: some View {
        EditorRow(edit: edit, apply: { edit.apply(picked) }, applyDisabled: !valid) {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
            if !valid {
                Text("Since must be earlier than before.").foregroundStyle(Theme.secondary)
            }
        }
        .onAppear {
            let day = edit.field == .after ? edit.filters.after : edit.filters.before
            if let day { date = day.date() }
        }
    }
}

private struct LabelsEditorRow: View {
    let edit: FilterEdit
    @State private var selected: Set<String> = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorRow(edit: edit, apply: apply, applyDisabled: selected.isEmpty) {
                TextField("Find a label", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            list
                .padding(.leading, 144)
        }
        .task { await edit.model.loadLabels() }
        .onAppear { selected = Set(edit.filters.labels) }
    }

    @ViewBuilder
    private var list: some View {
        switch edit.model.labels {
        case .notLoaded, .loading:
            ProgressView().controlSize(.small)
        case .failed:
            Text("Riffle cannot load the labels. Close this editor and open it again.").foregroundStyle(Theme.secondary)
        case .loaded(let labels):
            let shown = labels.filter { query.isEmpty || LabelNames.display($0.name).localizedStandardContains(query) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown, id: \.name) { label in
                        Toggle(LabelNames.display(label.name), isOn: binding(for: label.name))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { isOn in
                if isOn { selected.insert(name) } else { selected.remove(name) }
            }
        )
    }

    private func apply() {
        var filters = edit.filters
        // Keep the order of the labels that were set, then add the new ones by name.
        filters.labels = edit.filters.labels.filter(selected.contains) + selected.subtracting(edit.filters.labels).sorted()
        edit.apply(filters)
    }
}

private struct AttachmentEditorRow: View {
    let edit: FilterEdit

    var body: some View {
        EditorRow(edit: edit) {
            Picker("Attachments", selection: Binding(get: { edit.filters.hasAttachment }, set: set)) {
                Text("With").tag(Bool?.some(true))
                Text("Without").tag(Bool?.some(false))
                Text("Either").tag(Bool?.none)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func set(_ value: Bool?) {
        var filters = edit.filters
        filters.hasAttachment = value
        edit.apply(filters)
    }
}

private struct SpamTrashEditorRow: View {
    let edit: FilterEdit

    var body: some View {
        EditorRow(edit: edit) {
            Toggle("Include spam and trash", isOn: Binding(get: { edit.filters.includeSpamTrash }, set: set))
                .toggleStyle(.checkbox)
        }
    }

    private func set(_ value: Bool) {
        var filters = edit.filters
        filters.includeSpamTrash = value
        edit.apply(filters)
    }
}

private struct SortEditorRow: View {
    let edit: FilterEdit

    /// Best match needs words to rank by.
    private var options: [Sort] {
        edit.filters.text.isEmpty ? [.newest, .oldest] : Sort.allCases
    }

    var body: some View {
        EditorRow(edit: edit) {
            Picker("Sort", selection: Binding(get: { edit.filters.sort }, set: set)) {
                ForEach(options, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func set(_ sort: Sort) {
        var filters = edit.filters
        filters.sort = sort
        edit.apply(filters)
    }
}

private extension Sort {
    var title: String {
        switch self {
        case .relevance: "Best match"
        case .newest: "Newest"
        case .oldest: "Oldest"
        }
    }
}
