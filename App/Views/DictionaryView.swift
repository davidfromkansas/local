import SwiftData
import SwiftUI

struct DictionaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DictionaryWord.term) private var words: [DictionaryWord]
    @State private var editing: DictionaryWord?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if words.isEmpty {
                    ContentUnavailableView {
                        Label("Your words", systemImage: "character.book.closed")
                    } description: {
                        Text("Add names, brands or jargon so Taki spells them right — or replace a word you say with what you want typed.")
                    } actions: {
                        Button("Add a word") { adding = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(words) { word in
                            Button { editing = word } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.replacement.isEmpty ? word.term : word.replacement)
                                        .foregroundStyle(.primary)
                                    if !word.replacement.isEmpty {
                                        Text("when you say “\(word.term)”")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(words[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) { WordEditor(word: nil) }
            .sheet(item: $editing) { word in WordEditor(word: word) }
        }
    }
}

private struct WordEditor: View {
    let word: DictionaryWord?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var replacement = ""

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Word or phrase, e.g. Priya", text: $term)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Taki will always spell it exactly like this.")
                }
                Section {
                    TextField("Replace with (optional)", text: $replacement)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Say “my email”, get “david@example.com”. Leave empty to just fix the spelling.")
                }
            }
            .navigationTitle(word == nil ? "New word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(trimmedTerm.isEmpty)
                }
            }
            .onAppear {
                term = word?.term ?? ""
                replacement = word?.replacement ?? ""
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let cleanReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let word {
            word.term = trimmedTerm
            word.replacement = cleanReplacement
        } else {
            context.insert(DictionaryWord(term: trimmedTerm, replacement: cleanReplacement))
        }
        dismiss()
    }
}
