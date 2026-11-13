import SwiftUI
import AppKit

@main
struct MemoBridgeApp: App {
    @StateObject private var store = MemoStore()

    var body: some Scene {
        WindowGroup("MemoBridge") {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 650)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Recordings") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private extension MemoState {
    var label: String {
        switch self {
        case .unavailable: return "Audio unavailable"
        case .preparing: return "Preparing"
        case .pending: return "Not transcribed"
        case .transcribing: return "Transcribing"
        case .complete: return "Completed"
        case .outdated: return "Review transcript"
        case .failed: return "Transcription failed"
        }
    }
    var symbol: String {
        switch self {
        case .unavailable: return "icloud.slash"
        case .preparing: return "clock"
        case .pending: return "circle.dashed"
        case .transcribing: return "waveform"
        case .complete: return "checkmark.circle.fill"
        case .outdated: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .complete: return .green
        case .outdated, .failed: return .orange
        case .transcribing: return .accentColor
        case .preparing, .pending, .unavailable: return .secondary
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var store: MemoStore
    @StateObject private var tags = TagStore()
    @State private var selection: String?
    @State private var query = ""
    @State private var selectedTag = ""
    @AppStorage("MemoBridge.minimumDurationSeconds") private var minimumDurationSeconds = RecordingVisibility.defaultMinimumDurationSeconds
    @State private var transcriptText = ""
    @State private var transcriptLoading = false
    @State private var transcriptLoadError: String?
    @State private var transcriptLoadID = UUID()
    @State private var settingsPresented = false
    @State private var uploadPresented = false
    @State private var deletionPresented = false
    @State private var transcriptDeletionPresented = false
    @State private var operationError: String?
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFocused: Bool

    private var durationEligibleMemos: [Memo] {
        store.memos.filter { memo in
            RecordingVisibility.includes(duration: memo.duration, minimumDurationSeconds: minimumDurationSeconds)
        }
    }
    private var shownMemos: [Memo] {
        durationEligibleMemos.filter { memo in
            (selectedTag.isEmpty || tags.hasTag(selectedTag, memoID: memo.id)) &&
            (query.isEmpty || memo.title.localizedCaseInsensitiveContains(query))
        }
    }
    private var visibleTags: [String] {
        tags.allTags.filter { tag in durationEligibleMemos.contains { tags.hasTag(tag, memoID: $0.id) } }
    }
    private var selectedMemo: Memo? { store.memos.first { $0.id == selection } }

    var body: some View {
        navigation
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { store.refresh(); tags.load(directory: store.dataDirectory); updateTranscript() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh recordings")
                Button { settingsPresented = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $uploadPresented) {
            if let memo = selectedMemo, let transcriptURL = memo.transcriptURL {
                NotebookUploadView(recordingID: memo.id, transcriptURL: transcriptURL, dataDirectory: store.dataDirectory)
            }
        }
        .alert("Delete from MemoBridge?", isPresented: $deletionPresented, presenting: selectedMemo) { memo in
            Button("Delete from MemoBridge", role: .destructive) { deleteMemo(memo) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the recording from MemoBridge and prevents it from reappearing when you refresh. Your original Voice Memo, iCloud recording, local transcript, and tags are kept. You can restore it in Settings → Recently Removed.")
        }
        .alert("Delete local transcript?", isPresented: $transcriptDeletionPresented, presenting: selectedMemo) { memo in
            Button("Move to Trash", role: .destructive) { deleteTranscript(memo) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Only the local transcript will be moved to Trash. The original recording will not be changed.")
        }
        .alert("Action unavailable", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button("OK") { operationError = nil }
        } message: { Text(operationError ?? "") }
        .onAppear {
            store.refresh()
            tags.load(directory: store.dataDirectory)
            updateSelectedMemo()
        }
        .onChange(of: selection) { _ in updateSelectedMemo() }
        .onChange(of: store.memos) { _ in
            if let selection, !durationEligibleMemos.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            updateTranscript()
        }
        .onChange(of: store.dataDirectory) { directory in
            tags.load(directory: directory)
            updateTranscript()
        }
        .onChange(of: minimumDurationSeconds) { _ in
            if let selection, !durationEligibleMemos.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
        .onChange(of: visibleTags) { available in
            if !selectedTag.isEmpty && !available.contains(selectedTag) { selectedTag = "" }
        }
    }

    private var navigation: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let memo = selectedMemo {
                detail(for: memo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select a recording").font(.headline)
                    Text("View details or start a local transcription.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
                HStack {
                    Text("Recordings").font(.headline)
                    Spacer()
                    Picker("Tags", selection: $selectedTag) {
                        Text("All").tag("")
                        ForEach(visibleTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .help("Filter by tag")
                }
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 8)

                if let error = tags.errorMessage ?? (store.memos.isEmpty ? nil : store.errorMessage) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            tags.errorMessage = nil
                            store.errorMessage = nil
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                if shownMemos.isEmpty {
                    emptyList.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(shownMemos) { memo in
                            MemoRow(memo: memo).tag(memo.id)
                        }
                    }.listStyle(.inset)
                }
                Divider()
                HStack {
                    Text(String(shownMemos.count) + " recordings")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .searchable(text: $query, prompt: "Search recordings")
            .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 430)
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
            if store.memos.isEmpty, let error = store.errorMessage {
                Text("Can't Read Recordings").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Text("Allow MemoBridge to access Voice Memos when macOS asks. If needed, check System Settings > Privacy & Security > Full Disk Access; this permission is broad.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Privacy Settings") { openPrivacySettings() }
                Button("Retry") { store.refresh() }
            } else if store.memos.isEmpty && !store.hiddenMemos.isEmpty {
                Text("No visible recordings").font(.headline)
                Text("Removed recordings can be restored in Settings → Recently Removed.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !store.memos.isEmpty && durationEligibleMemos.isEmpty {
                Text("No recordings meet the minimum duration").font(.headline)
                Text("Lower the minimum duration in Settings to show shorter recordings.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !query.isEmpty || !selectedTag.isEmpty {
                Text("No matching recordings").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No Recordings Found").font(.headline)
                Text("Check that your recordings have synced to this Mac, then refresh.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(24)
    }

    private func detail(for memo: Memo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if editingTitle {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $editedTitle)
                                    .font(.title2.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 160)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                                    .focused($titleFocused)
                                    .accessibilityLabel("Recording name")
                                HStack {
                                    Button("Save") { saveTitle(memo) }
                                    Button("Cancel") { editingTitle = false }
                                    Text("\(editedTitle.count) / 1000")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Scroll for longer names; line breaks are not supported.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Text(memo.title.isEmpty ? "Untitled Recording" : memo.title)
                                    .font(.title2.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Button {
                                    editedTitle = memo.title
                                    editingTitle = true
                                    titleFocused = true
                                } label: { Label("Rename", systemImage: "pencil") }
                                    .buttonStyle(.borderless)
                                    .help("Rename in MemoBridge")
                            }
                        }
                        HStack(spacing: 8) {
                            if let date = memo.date {
                                Text(date, style: .date)
                                Text(date, style: .time)
                            }
                            if let duration = memo.duration {
                                if memo.date != nil { Text("·") }
                                Text(formatDuration(duration))
                            }
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(memo.state.label, systemImage: memo.state.symbol).font(.callout).foregroundStyle(memo.state.tint)
                }
                TagEditor(memoID: memo.id, selection: $selection, tags: tags)
                    .id(memo.id)
                    .zIndex(1)
                ActionButtonLayout(horizontalSpacing: 8, verticalSpacing: 12) {
                        Button { store.transcribe(memo) } label: { Label("Transcribe", systemImage: "waveform.badge.mic") }
                            .disabled(!canTranscribe(memo.state) || memo.audioURL == nil || store.hasActiveTranscription)
                        Button { copyTranscript() } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                            .disabled(memo.transcriptURL == nil || transcriptLoading || transcriptLoadError != nil)
                        Button { uploadPresented = true } label: { Label("Upload to Gemini Notebook", systemImage: "arrow.up.doc") }
                            .disabled(memo.transcriptURL == nil)
                        Button(role: .destructive) { transcriptDeletionPresented = true } label: {
                            Label("Delete Transcript", systemImage: "doc.badge.minus")
                        }.disabled(memo.transcriptURL == nil)
                        Button(role: .destructive) { deletionPresented = true } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .disabled(memo.state == .transcribing)
                        .help("Remove from MemoBridge; the original recording is kept")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AudioPlayerView(audioURL: memo.audioURL)
                    .id(memo.id)
                Divider()
                if memo.state == .transcribing {
                    HStack { ProgressView().controlSize(.small); Text("Transcribing locally…").foregroundStyle(.secondary) }
                }
                if memo.transcriptURL != nil {
                    GroupBox("Transcript") {
                        VStack(alignment: .leading, spacing: 10) {
                            if transcriptLoading {
                                ProgressView("Loading transcript…").controlSize(.small)
                            } else if let error = transcriptLoadError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else if transcriptText.isEmpty {
                                Text("The transcript is empty.").foregroundStyle(.secondary)
                            } else {
                                Text(transcriptText).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if memo.state == .outdated {
                        Label("The recording or transcript needs review. To transcribe again, keep a copy of the old transcript, then remove it.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("The transcript will be saved in your selected data folder after transcription.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if memo.state == .preparing {
                    Label("The audio is being prepared. MemoBridge will check again automatically.", systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                } else if memo.audioURL == nil && memo.transcriptURL == nil {
                    Label("Check that the recording is downloaded in Voice Memos, then refresh.", systemImage: "icloud.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveTitle(_ memo: Memo) {
        if store.rename(memo, to: editedTitle) {
            editingTitle = false
        } else {
            operationError = store.errorMessage ?? "Could not rename the recording."
        }
    }

    private func updateSelectedMemo() {
        editingTitle = false
        updateTranscript()
    }

    private func updateTranscript() {
        let requestID = UUID()
        transcriptLoadID = requestID
        transcriptText = ""
        transcriptLoadError = nil
        guard let url = selectedMemo?.transcriptURL else {
            transcriptLoading = false
            return
        }
        transcriptLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try TranscriptDocumentStore.read(url: url).text }
            DispatchQueue.main.async {
                guard transcriptLoadID == requestID else { return }
                transcriptLoading = false
                switch result {
                case .success(let text): transcriptText = text
                case .failure: transcriptLoadError = "Unable to read this transcript. Refresh and try again."
                }
            }
        }
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(transcriptText, forType: .string) {
            operationError = "Unable to copy the transcript to the clipboard."
        }
    }

    private func deleteMemo(_ memo: Memo) {
        if store.hideMemo(memo) {
            selection = nil
        } else if store.errorMessage == nil {
            operationError = "Could not remove this recording from MemoBridge."
        }
    }

    private func deleteTranscript(_ memo: Memo) {
        guard let url = memo.transcriptURL else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                if let error { operationError = error.localizedDescription }
                store.refresh()
            }
        }
    }

    private func canTranscribe(_ state: MemoState) -> Bool {
        switch state {
        case .pending, .failed: return true
        case .unavailable, .preparing, .transcribing, .complete, .outdated: return false
        }
    }
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TagInputFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Each editor belongs to one recording; stale focus/submit events cannot edit another.
private struct TagEditor: View {
    let memoID: String
    @Binding var selection: String?
    @ObservedObject var tags: TagStore
    @State private var newTag = ""
    @State private var showSuggestions = false
    @State private var tagInputFrame: CGRect = .zero
    @FocusState private var tagFieldFocused: Bool

    private var suggestions: [String] {
        let prefix = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return tags.allTags.filter { tag in
            !tags.hasTag(tag, memoID: memoID) &&
            (prefix.isEmpty || tag.range(of: prefix, options: [.anchored, .caseInsensitive], locale: .current) != nil)
        }
    }

    private var suggestionRows: Int { (suggestions.count + 2) / 3 }
    private var suggestionHeight: CGFloat { min(CGFloat(suggestionRows) * 34 + 20, 160) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags.tags(for: memoID), id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                            Button {
                                guard selection == memoID else { return }
                                tagFieldFocused = false
                                tags.remove(tag, memoID: memoID)
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).help("Remove tag")
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    TextField("Add tag", text: $newTag)
                        .focused($tagFieldFocused)
                        .onSubmit { addTag(newTag) }
                        .onExitCommand { showSuggestions = false; tagFieldFocused = false }
                        .textFieldStyle(.plain).frame(minWidth: 90, idealWidth: 120)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: TagInputFrameKey.self,
                                    value: geometry.frame(in: .named("MemoBridge.tagEditor")))
                            }
                        }
                        .help("Type a tag and press Return, or select an existing tag")
                }
            }
        }
        .coordinateSpace(name: "MemoBridge.tagEditor")
        .onPreferenceChange(TagInputFrameKey.self) { tagInputFrame = $0 }
        .background {
            ClickOutsideMonitor(isActive: tagFieldFocused || showSuggestions,
                                primaryAllowedRect: { bounds in tagInputFrame.intersection(bounds) }, extraAllowedRect: { bounds in
                guard showSuggestions && !suggestions.isEmpty else { return nil }
                return CGRect(x: 24, y: bounds.height + 6,
                              width: min(380, max(0, bounds.width - 24)), height: suggestionHeight)
            }, onOutsideClick: {
                tagFieldFocused = false
                showSuggestions = false
            })
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if showSuggestions && !suggestions.isEmpty {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 50), spacing: 6), count: 3), spacing: 6) {
                            ForEach(suggestions, id: \.self) { tag in
                                Button { addTag(tag) } label: {
                                    Text(tag)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, minHeight: 28)
                                        .contentShape(Rectangle())
                                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(tag)
                                .accessibilityLabel("Add tag \(tag)")
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: min(380, max(0, geometry.size.width - 24)), height: suggestionHeight)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                    .offset(x: 24, y: geometry.size.height + 6)
                }
            }
        }
        .onChange(of: tagFieldFocused) { focused in
            if focused {
                showSuggestions = true
            } else {
                // Let a click on a suggestion complete before dismissing the list.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !tagFieldFocused { showSuggestions = false }
                }
            }
        }
    }

    private func addTag(_ tag: String) {
        guard selection == memoID else { return }
        tags.add(tag, memoID: memoID)
        if tags.errorMessage == nil {
            newTag = ""
            tagFieldFocused = true
        }
    }
}

/// Keeps recording actions visible by wrapping them onto additional rows.
private struct ActionButtonLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    private func positions(for subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return (points, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .greatestFiniteMagnitude
        return positions(for: subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = positions(for: subviews, width: bounds.width).points
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                          anchor: .topLeading, proposal: .unspecified)
        }
    }
}

private struct MemoRow: View {
    let memo: Memo
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(memo.title.isEmpty ? "Untitled Recording" : memo.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let duration = memo.duration { Text(formatDuration(duration)).monospacedDigit().foregroundStyle(.secondary) }
            }
            HStack {
                if let date = memo.date { Text(date, style: .date) }
                Spacer()
                Label(memo.state.label, systemImage: memo.state.symbol).foregroundStyle(memo.state.tint)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

private func formatDuration(_ duration: Double) -> String {
    let seconds = max(0, Int(duration.isFinite ? duration : 0))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private struct SettingsView: View {
    @EnvironmentObject private var store: MemoStore
    @Environment(\.dismiss) private var dismiss
    @State private var hiddenRecordingsPresented = false
    @AppStorage("MemoBridge.minimumDurationSeconds") private var minimumDurationSeconds = RecordingVisibility.defaultMinimumDurationSeconds
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.weight(.semibold))
            GroupBox("Data Folder") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.dataDirectory.path)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Choose…") { chooseDirectory() }
                    }
                    Toggle("Create link to Voice Memos folder", isOn: Binding(
                        get: { store.audioLinksEnabled },
                        set: { store.setAudioLinksEnabled($0) }
                    ))
                    Text("Creates one link to Apple's recordings folder. Turning this off removes only the link, not the original recordings. The link is not a backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            ModelSettingsView(dataDirectory: store.dataDirectory,
                              isTranscriptionRunning: { try store.isAnyTranscriptionRunning() },
                              stopTranscription: { try await store.stopTranscription() })
            NotebookSettingsView(dataDirectory: store.dataDirectory)
            GroupBox("Recordings") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Minimum duration")
                        TextField("Seconds", value: $minimumDurationSeconds, format: .number.grouping(.never))
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: minimumDurationSeconds) { value in
                                if value < 0 { minimumDurationSeconds = 0 }
                                if value > 3600 { minimumDurationSeconds = 3600 }
                            }
                        Text("seconds")
                        Stepper("Minimum duration", value: $minimumDurationSeconds, in: 0...3600)
                            .labelsHidden()
                    }
                    Text("Recordings shorter than this are hidden from the list. Set to 0 to show all durations; recordings with unknown duration remain visible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Recently Removed") {
                HStack {
                    Text("\(store.hiddenMemos.count) removed from MemoBridge")
                    Spacer()
                    Button("Manage…") { hiddenRecordingsPresented = true }
                        .disabled(store.hiddenMemos.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("Transcription runs locally; audio is not uploaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        }
        .frame(width: 570, height: min(700, max(300, (NSScreen.main?.visibleFrame.height ?? 820) - 120)))
        .sheet(isPresented: $hiddenRecordingsPresented) {
            HiddenRecordingsView().environmentObject(store)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Data Folder"
        if panel.runModal() == .OK, let url = panel.url { store.setDataDirectory(url) }
    }

}

private struct HiddenRecordingsView: View {
    @EnvironmentObject private var store: MemoStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recently Removed").font(.title2.weight(.semibold))
            Text("These recordings are hidden only in MemoBridge. Their Voice Memos recordings and local transcripts have not been deleted. Restored recordings reappear when they are available in Voice Memos and meet the minimum duration; adjust the minimum in Settings to show shorter recordings.")
                .font(.callout).foregroundStyle(.secondary)
            if store.hiddenMemos.isEmpty {
                Text("No removed recordings.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.hiddenMemos) { memo in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memo.title).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                if let date = memo.date { Text(date, style: .date) }
                                if !memo.isAvailable { Text("Not currently available") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { _ = store.restoreMemo(id: memo.id) }
                    }
                    .padding(.vertical, 4)
                }.listStyle(.inset)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 550, height: 420)
    }
}
