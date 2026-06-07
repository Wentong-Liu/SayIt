import SwiftUI
import SayItCore

/// The "Dictionary" (词典) settings pane: lists, adds, edits, and deletes user-dictionary entries.
///
/// Entries feed PR-2's ``DictionaryRewriter``, which reads ``DictionaryStore/all()`` after polish and rewrites
/// dictated text to each entry's canonical form. This pane only manages the data through ``DictionaryViewModel``
/// (which wraps the ``DictionaryStore`` actor); it does not touch the dictation pipeline.
struct DictionarySettingsView: View {
    @State private var viewModel: DictionaryViewModel

    /// The entry currently being edited in the sheet (`nil` = adding a new one); non-nil drives sheet presentation.
    @State private var editorContext: EditorContext?

    /// Identifies the editor sheet's mode: adding a brand-new entry or editing an existing one.
    private enum EditorContext: Identifiable {
        case add
        case edit(DictionaryEntry)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let entry): return entry.id.uuidString
            }
        }
    }

    /// - Parameter store: the shared dictionary store (the App injects a single instance pointing at the same
    ///   `dictionary.json` the dictation pipeline reads).
    init(store: DictionaryStore) {
        _viewModel = State(initialValue: DictionaryViewModel(store: store))
    }

    var body: some View {
        Form {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                entriesSection
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorContext = .add
                } label: {
                    Label("dictionary.add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorContext) { context in
            switch context {
            case .add:
                DictionaryEntryEditor(entry: nil) { saved in
                    Task { await viewModel.add(
                        canonical: saved.canonical,
                        variants: saved.variants,
                        caseSensitive: saved.caseSensitive,
                        enabled: saved.enabled
                    ) }
                }
            case .edit(let entry):
                DictionaryEntryEditor(entry: entry) { saved in
                    Task { await viewModel.update(saved.applied(to: entry)) }
                }
            }
        }
        .onAppear {
            Task { await viewModel.reload() }
            viewModel.startObserving()
        }
        .onDisappear { viewModel.stopObserving() }
    }

    /// Shown when the dictionary is empty: a short hint plus an add button.
    @ViewBuilder
    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("dictionary.empty.title")
                    .font(.headline)
                Text("dictionary.empty.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("dictionary.add") { editorContext = .add }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// The list of entries: one row each, with an enabled toggle and edit / delete affordances.
    @ViewBuilder
    private var entriesSection: some View {
        Section("dictionary.section.entries") {
            ForEach(viewModel.entries) { entry in
                EntryRow(
                    entry: entry,
                    onToggle: { enabled in
                        Task { await viewModel.setEnabled(enabled, for: entry) }
                    },
                    onEdit: { editorContext = .edit(entry) },
                    onDelete: { Task { await viewModel.remove(id: entry.id) } }
                )
            }
        }
    }
}

// MARK: - Row

/// A single dictionary entry row: canonical (bold) + variants (secondary), an enabled toggle, and an explicit
/// Edit / Delete in the context menu (macOS list swipe inside a `Form` is unreliable, so we expose explicit actions).
private struct EntryRow: View {
    let entry: DictionaryEntry
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.canonical)
                    .fontWeight(.semibold)
                if !entry.variants.isEmpty {
                    Text(entry.variants.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Per-row enabled toggle writes through immediately so the rewriter's `enabled` read stays in sync.
            Toggle("dictionary.field.enabled", isOn: Binding(
                get: { entry.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu {
            Button("dictionary.edit") { onEdit() }
            Button("dictionary.delete", role: .destructive) { onDelete() }
        }
        .swipeActions(edge: .trailing) {
            Button("dictionary.delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Editor sheet

/// The add / edit form. Returns the user's input via `onSave`; the caller decides whether it is a new entry
/// (``DictionaryViewModel/add(canonical:variants:caseSensitive:enabled:)``) or an update of an existing one
/// (``EditorResult/applied(to:)`` preserving id / createdAt / usageCount).
private struct DictionaryEntryEditor: View {
    /// The existing entry being edited, or `nil` when adding a new one (drives the title + initial field values).
    let entry: DictionaryEntry?
    let onSave: (EditorResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var canonical: String
    /// Variants edited as free text, one per line; split + sanitized on save.
    @State private var variantsText: String
    @State private var caseSensitive: Bool
    @State private var enabled: Bool

    init(entry: DictionaryEntry?, onSave: @escaping (EditorResult) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _canonical = State(initialValue: entry?.canonical ?? "")
        _variantsText = State(initialValue: (entry?.variants ?? []).joined(separator: "\n"))
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
        _enabled = State(initialValue: entry?.enabled ?? true)
    }

    private var trimmedCanonical: String {
        canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry == nil ? "dictionary.editor.title.new" : "dictionary.editor.title.edit")
                .font(.headline)
                .padding([.top, .horizontal])

            Form {
                Section {
                    TextField("dictionary.field.canonical",
                              text: $canonical,
                              prompt: Text("dictionary.field.canonical.placeholder"))
                }

                Section {
                    TextEditor(text: $variantsText)
                        .frame(minHeight: 80)
                        .font(.body.monospaced())
                } header: {
                    Text("dictionary.field.variants")
                } footer: {
                    Text("dictionary.field.variants.hint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("dictionary.field.enabled", isOn: $enabled)
                    Toggle("dictionary.field.caseSensitive", isOn: $caseSensitive)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("dictionary.cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("dictionary.save") {
                    onSave(EditorResult(
                        canonical: trimmedCanonical,
                        variants: variantsText.split(whereSeparator: \.isNewline).map(String.init),
                        caseSensitive: caseSensitive,
                        enabled: enabled
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedCanonical.isEmpty)
            }
            .padding()
        }
        .frame(width: 380, height: 360)
    }
}

/// The editor's collected input. Variants are raw (line-split); sanitizing happens in the view-model so the
/// add and update paths share one normalization point.
private struct EditorResult {
    let canonical: String
    let variants: [String]
    let caseSensitive: Bool
    let enabled: Bool

    /// Builds the updated entry from an existing one, preserving its id / createdAt / usageCount / scope / source
    /// and applying the edited fields. Variants are sanitized against the new canonical.
    func applied(to original: DictionaryEntry) -> DictionaryEntry {
        var copy = original
        copy.canonical = canonical
        copy.variants = DictionaryViewModel.sanitize(variants, canonical: canonical)
        copy.caseSensitive = caseSensitive
        copy.enabled = enabled
        return copy
    }
}

#Preview {
    DictionarySettingsView(store: DictionaryStore())
        .frame(width: 480, height: 420)
}
