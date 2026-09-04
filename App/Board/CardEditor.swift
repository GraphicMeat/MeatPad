import SwiftUI
import UniformTypeIdentifiers
import MeatPadKit

/// Due dates a card can be given without opening a picker. Lives outside the views because
/// both the card's menu and its editor hand out the same "Today".
enum CardDue {
    /// Today at 17:00, or the next full hour if that has already passed.
    static func today() -> Date {
        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
        if let end, end > Date() { return end }
        let next = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    static func morning(daysFromNow days: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}

/// The card's full editor, in the shape Calendar gives an event: grouped rows — title and
/// colour, labels, date, notes — with the placeholder inside each row instead of a label
/// column beside it. Opened from the card's ⋯.
///
/// Not a modal and not a form: every row writes through to the store as it is touched, the
/// way the board itself does. Closing is not "saving", so there is no Cancel to promise an
/// undo this app doesn't have.
// ponytail: hand-rolled section blocks rather than Form(.grouped) — a grouped Form puts a
// label column down the left and scrolls, and the reference has neither.
struct CardEditor: View {
    @ObservedObject var store: BoardStore
    let boardID: UUID
    let card: Card
    @Binding var isPresented: Bool
    /// Opens straight onto the new-label field, for the context menu's "New Label…".
    var startsCreatingLabel = false

    @State private var title = ""
    @State private var body_ = ""
    @State private var bodyDebouncer = Debouncer(delay: 0.5)
    @State private var titleDebouncer = Debouncer(delay: 0.5)
    @State private var pickingDue = false
    @State private var addingLabel = false
    @State private var labelDraft = ""
    @State private var labelColor = CardLabel.palette[0]
    @State private var summarizing = false
    @State private var summarizable = false
    @FocusState private var labelFieldFocused: Bool
    @Environment(\.openWindow) private var openWindow

    private static let sectionRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 8) {
            section {
                titleRow
                HairlineDivider()
                labelsRow
                if addingLabel {
                    HairlineDivider()
                    newLabelForm
                }
            }

            section {
                dueRow
                if pickingDue {
                    HairlineDivider()
                    DatePicker("", selection: dueBinding, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .accessibilityIdentifier("cardEditor.datePicker")
                }
            }

            section { notesRow }

            section {
                if let names = card.attachments, !names.isEmpty {
                    AttachmentStrip(
                        urls: names.map { store.attachmentURL(cardID: card.id, name: $0) },
                        identifier: "cardEditor.attachment",
                        onRemove: { index in try? store.removeAttachment(boardID: boardID, cardID: card.id, name: names[index]) }
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    HairlineDivider()
                }
                addImageRow
            }

            if card.noteID != nil || summarizable {
                section {
                    if card.noteID != nil {
                        linkRow
                        if summarizable { HairlineDivider() }
                    }
                    if summarizable { summarizeRow }
                }
            }

            Button("Delete Card", role: .destructive) {
                flush(commitEdits: false)
                isPresented = false
                try? store.deleteCard(boardID: boardID, cardID: card.id)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .font(.callout)
            .padding(.top, 2)
            .accessibilityIdentifier("cardEditor.delete")
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            title = card.title
            body_ = card.body ?? ""
            labelColor = store.suggestedLabelColor
            addingLabel = startsCreatingLabel
            labelFieldFocused = startsCreatingLabel
            refreshSummarizable()
        }
        // A popover can go away without warning (click outside, Escape); the debounced text
        // has to land before the view does.
        .onDisappear { flush(commitEdits: true) }
        // The whole editor takes images, not just the strip: the strip is empty until the
        // card has one, and an empty 0pt target is not a drop target at all.
        .dropDestination(for: CardDrop.self) { drops, _ in
            var handled = false
            for case .image(let data, let ext, _) in drops {
                handled = ((try? store.addAttachment(boardID: boardID, cardID: card.id, data: data, ext: ext)) != nil) || handled
            }
            return handled
        }
    }

    // MARK: - Sections

    /// One grouped block: the rounded, faintly filled container every row sits in. Same fill
    /// as `ringlessField`, so a row in here reads like a field everywhere else in the app.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background {
                RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.sectionRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
            }
    }

    // MARK: - Title and colour

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // Wraps instead of truncating: the editor exists to show the card whole, and
                // a title clipped at "Masazas E…" is the reason it was opened.
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1...5)
                    // A popover measures its content with no width to speak of, so a
                    // vertical-axis field resolves to its one-line ideal height and then
                    // gets clipped by the popover's real width — the very truncation this
                    // editor exists to undo. `fixedSize(vertical:)` re-takes the height at
                    // the width it is actually given.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: title) { _, _ in titleDebouncer.call { commitTitle() } }
                    .onSubmit { commitTitle() }
                    .accessibilityIdentifier("cardEditor.title")

                colorStrip
            }
            if summarizing { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// The card's colour, straight out of the label palette — the same twelve everything else
    /// on the board is painted in. First swatch clears it back to plain glass.
    private var colorStrip: some View {
        HStack(spacing: 5) {
            swatch(nil, index: -1)
            ForEach(Array(CardLabel.palette.enumerated()), id: \.offset) { index, color in
                swatch(color, index: index)
            }
        }
    }

    private func swatch(_ color: RGBAColor?, index: Int) -> some View {
        let selected = card.color == color
        return ZStack {
            Circle().fill(color.map { Color($0) } ?? Color.clear)
            if color == nil {
                Circle().strokeBorder(.secondary, lineWidth: 1)
                Image(systemName: "line.diagonal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .overlay {
            Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                .padding(-2.5)
        }
        .contentShape(Circle())
        .onTapGesture { update { $0.color = color } }
        .accessibilityIdentifier(color == nil ? "cardEditor.color.none" : "cardEditor.color.\(index)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Labels

    private var labelsRow: some View {
        HStack(spacing: 6) {
            let labels = store.labels.filter { card.labelIDs?.contains($0.id) ?? false }
            if labels.isEmpty {
                Text("Add Labels").foregroundStyle(.secondary)
            } else {
                ForEach(labels) { label in
                    Text(label.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(label.color).opacity(0.3)))
                        .overlay(Capsule().strokeBorder(Color(label.color).opacity(0.75)))
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(store.labels) { label in
                    Toggle(label.name, isOn: labelBinding(label.id))
                }
                if !store.labels.isEmpty { Divider() }
                Button("New Label…") { startNewLabel() }
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("cardEditor.labels")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// Name plus a swatch, inline rather than in a second popover — a popover on top of a
    /// popover is a macOS fight nobody wins, and the form is three controls.
    private var newLabelForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $labelDraft)
                .ringlessField()
                .focused($labelFieldFocused)
                .onSubmit { createLabel() }
                .accessibilityIdentifier("newLabel.name")

            HStack(spacing: 5) {
                ForEach(Array(CardLabel.palette.enumerated()), id: \.offset) { index, color in
                    labelSwatch(color, index: index)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { addingLabel = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Create") { createLabel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(labelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("newLabel.create")
            }
            .font(.callout)
        }
        .padding(10)
    }

    private func labelSwatch(_ color: RGBAColor, index: Int) -> some View {
        Circle()
            .fill(Color(color))
            .frame(width: 16, height: 16)
            .overlay {
                Circle().strokeBorder(.primary.opacity(labelColor == color ? 0.9 : 0), lineWidth: 2)
                    .padding(-2.5)
            }
            .contentShape(Circle())
            .onTapGesture { labelColor = color }
            .accessibilityIdentifier("newLabel.swatch.\(index)")
            .accessibilityAddTraits(labelColor == color ? [.isSelected] : [])
    }

    private func startNewLabel() {
        labelDraft = ""
        labelColor = store.suggestedLabelColor
        addingLabel = true
        labelFieldFocused = true
    }

    /// Creating from a card assigns it there and then — nobody opens this to make a label
    /// they don't want on the card in front of them.
    private func createLabel() {
        guard let label = try? store.createLabel(name: labelDraft, color: labelColor) else { return }
        labelBinding(label.id).wrappedValue = true
        addingLabel = false
    }

    private func labelBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { card.labelIDs?.contains(id) ?? false },
            set: { on in
                update { card in
                    var ids = card.labelIDs ?? []
                    ids.removeAll { $0 == id }
                    if on { ids.append(id) }
                    card.labelIDs = ids.isEmpty ? nil : ids
                }
            }
        )
    }

    // MARK: - Due date

    private var dueRow: some View {
        HStack(spacing: 6) {
            Button {
                if card.due == nil { setDue(CardDue.today()) }
                pickingDue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    if let due = card.due {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Add Date").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cardEditor.due")

            if card.due != nil {
                Button {
                    pickingDue = false
                    update { $0.due = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove Due Date"))
                .accessibilityIdentifier("cardEditor.due.clear")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { card.due ?? CardDue.today() },
            set: { setDue($0) }
        )
    }

    private func setDue(_ date: Date) {
        update { $0.due = date }
        Task { await DueNotifier.shared.requestAuthorizationIfNeeded() }
    }

    // MARK: - Notes

    private var notesRow: some View {
        TextField("Add Notes", text: $body_, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(1...10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same reason as the title: a popover measures its content unbounded, so a
            // vertical-axis field settles on one line and clips unless its height is taken
            // at the width it actually gets.
            .fixedSize(horizontal: false, vertical: true)
            .newlineOnModifiedReturn()
            .onChange(of: body_) { _, _ in bodyDebouncer.call { commitBody() } }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .accessibilityIdentifier("cardEditor.notes")
    }

    // MARK: - Images

    /// NSOpenPanel is app-modal, so the popover survives it; if AppKit ever closes the
    /// popover under the panel, the images still land — the action captured the ids.
    private var addImageRow: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.prompt = String(localized: "Attach")
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url),
                      let ext = UTType(filenameExtension: url.pathExtension)?.preferredFilenameExtension else { continue }
                _ = try? store.addAttachment(boardID: boardID, cardID: card.id, data: data, ext: ext)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text("Add Image…")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .accessibilityIdentifier("cardEditor.addImage")
    }

    // MARK: - Linked note and summary

    private var linkRow: some View {
        HStack(spacing: 6) {
            Button {
                if let noteID = card.noteID { openWindow(value: noteID) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(linkedTitle).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open Note"))

            Button("Unlink") { update { $0.noteID = nil } }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var linkedTitle: String {
        guard let noteID = card.noteID,
              let note = AppModel.shared.noteStore.notes.first(where: { $0.id == noteID })
        else { return String(localized: "Note unavailable") }
        return note.title
    }

    private var summarizeRow: some View {
        Button {
            summarize()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("Summarize into Title")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .accessibilityIdentifier("cardEditor.summarize")
    }

    private func summarize() {
        let source = body_
        summarizing = true
        Task {
            let summary = await CardSummarizer.title(for: source)
            summarizing = false
            guard let summary, !summary.isEmpty else { return }
            title = summary
            commitTitle()
        }
    }

    /// Off the main thread: this only decides whether a row is drawn, never worth a frame.
    private func refreshSummarizable() {
        let source = body_
        Task {
            let available = await Task.detached { CardSummarizer.canSummarize(source) }.value
            summarizable = available
        }
    }

    // MARK: - Writing

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title is rejected by the store; keep the stored one rather than lose it.
        guard !trimmed.isEmpty, trimmed != card.title else { return }
        update { $0.title = trimmed }
    }

    private func commitBody() {
        let stored = card.body ?? ""
        guard body_ != stored else { return }
        update { $0.body = body_.isEmpty ? nil : body_ }
        refreshSummarizable()
    }

    private func flush(commitEdits: Bool) {
        titleDebouncer.cancel()
        bodyDebouncer.cancel()
        guard commitEdits else { return }
        commitTitle()
        commitBody()
    }

    private func update(_ change: (inout Card) -> Void) {
        var updated = card
        change(&updated)
        try? store.updateCard(boardID: boardID, card: updated)
    }
}
