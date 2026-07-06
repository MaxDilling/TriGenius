import SwiftUI
import Combine

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    enum Author { case user, coach, tool }
    var id = UUID()
    let author: Author
    var text: String
    let timestamp: Date
    /// Set only for `.tool` messages (Debug Mode) — the underlying tool call.
    var toolEvent: CoachToolEvent? = nil
    /// Set for auto-emitted card rows (plan mutations) — rendered as a
    /// `ChatCardView` instead of a text bubble.
    var card: ChatCard? = nil

    var isUser: Bool { author == .user }
}

// MARK: - Chat ViewModel

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    /// Dots visible: the coach is working and no text is currently streaming
    /// into a bubble. Cleared on each text chunk, raised again on every tool
    /// execution, so the long tool phases between text segments stay covered.
    var isThinking = false
    /// A send is in flight end-to-end — drives the stop button and input lock.
    var isResponding = false
    var showGreeting = true

    private let brain: CoachBrain
    private var respondTask: Task<Void, Never>?

    /// The coach bubble currently being streamed into, if any. Reset to `nil`
    /// whenever a tool call is rendered, so text arriving *after* a tool call
    /// starts a fresh bubble *below* it — keeping tool calls and reply text in
    /// the chronological order they actually occurred.
    private var currentCoachID: UUID?

    /// Computed once at init — avoids re-running brain.greeting() (memory
    /// access + Calendar allocation) on every body re-evaluation / keystroke.
    let greeting: String

    init(brain: CoachBrain) {
        self.brain = brain
        self.greeting = brain.greeting()
    }

    /// Wire this view model up as the brain's tool-event observer. Called from
    /// the view's `onAppear` — NOT from `init` — so the handler always points at
    /// the live `@State` instance. SwiftUI re-evaluates `CoachChatView.init` (and
    /// thus constructs throwaway view models) on every parent re-render; doing
    /// this in `init` would let a discarded model hijack the single handler slot
    /// with a `[weak self]` that immediately deallocates, silently dropping tool
    /// bubbles. `attach()` is idempotent and self-healing on each appearance.
    func attach() {
        // Debug Mode: render the coach's hidden tool calls inline. The handler
        // only fires when Debug Mode is on (gated in CoachBrain).
        brain.toolEventHandler = { [weak self] event in
            guard let self else { return }
            self.messages.append(ChatMessage(
                author: .tool,
                text: event.name,
                timestamp: event.timestamp,
                toolEvent: event
            ))
            // Close the current coach segment: any reply text that streams in
            // after this tool call belongs in a new bubble *below* it.
            self.currentCoachID = nil
        }
        // Fires on every tool execution (not debug-gated): bring the thinking
        // indicator back while tools run between streamed text segments.
        brain.toolActivityHandler = { [weak self] in
            guard let self, self.isResponding else { return }
            self.isThinking = true
        }
        // Auto-cards from the plan-mutation tools: each card is its own coach
        // row, mirroring the tool-bubble mechanism so ordering stays
        // chronological during streaming.
        brain.chatCardHandler = { [weak self] card in
            guard let self else { return }
            self.messages.append(ChatMessage(author: .coach, text: "", timestamp: Date(), card: card))
            // Self-managing backends (Apple FM) stream one cumulative transcript
            // per turn — resetting the bubble there would duplicate its text.
            if !self.brain.backendManagesConversation { self.currentCoachID = nil }
        }
    }

    /// The message currently receiving streamed text — its `MarkdownText` treats
    /// an unterminated ```card fence as pending instead of a raw code block.
    var streamingMessageID: UUID? { isResponding ? currentCoachID : nil }

    /// Warm up the backend (Apple FM) so the first reply comes back faster.
    func prewarm() {
        brain.prewarm()
    }

    /// Drop text into the input field without sending it — the athlete reviews,
    /// edits, and sends. Used when arriving from a tapped message (see CoachRouter).
    func prefill(_ text: String) {
        inputText = text
        showGreeting = false
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        inputText = ""
        send(text)
    }

    /// Re-send an earlier user message: rewind the conversation (UI + brain
    /// history) to just before it and send it again — e.g. after switching the
    /// model in Settings when the answer disappointed.
    func retry(_ message: ChatMessage) {
        guard message.isUser, !isResponding,
              let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        // Ordinal among user messages — user chat messages map 1:1, in order,
        // onto the brain's user text turns.
        let ordinal = messages[...idx].count { $0.isUser }
        brain.rewind(toUserTurn: ordinal)
        messages.removeSubrange(idx...)
        send(message.text)
    }

    /// Cancel the in-flight response. Text already streamed stays in place.
    func stop() {
        respondTask?.cancel()
    }

    private func send(_ text: String) {
        showGreeting = false
        messages.append(ChatMessage(author: .user, text: text, timestamp: Date()))
        isResponding = true
        isThinking = true
        currentCoachID = nil
        respondTask = Task { [weak self] in
            await self?.deliver(text)
        }
    }

    private func deliver(_ text: String) async {
        var produced = false

        // `onPartial` delivers cumulative text for the current segment. The
        // first chunk of a segment swaps the thinking indicator for a coach
        // bubble; later chunks update it in place. A tool call between segments
        // resets `currentCoachID` (see `attach()`), so text that follows starts
        // a new bubble *below* the tool call — preserving chronological order.
        let final = await brain.sendMessage(text) { [weak self] partial in
            guard let self else { return }
            self.isThinking = false
            produced = true
            if let id = self.currentCoachID,
               let idx = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[idx].text = partial
            } else {
                let id = UUID()
                self.currentCoachID = id
                self.messages.append(ChatMessage(id: id, author: .coach, text: partial, timestamp: Date()))
            }
        }

        // Fallback: if no partial ever arrived, show the final text.
        if !produced && !final.isEmpty {
            messages.append(ChatMessage(author: .coach, text: final, timestamp: Date()))
        }
        isThinking = false
        isResponding = false
        respondTask = nil
    }

    func reset() {
        respondTask?.cancel()
        respondTask = nil
        isThinking = false
        isResponding = false
        brain.reset()
        messages = []
        showGreeting = true
    }

    /// File a bug/feedback report: snapshot the current conversation transcript
    /// (plus the athlete's optional note) into the local `ReportStore`.
    func fileReport(note: String) {
        let transcript = messages.map { msg -> Report.Line in
            let text: String
            if msg.author == .tool, let e = msg.toolEvent {
                text = "\(e.name)(\(e.argumentsJSON)) → \(e.resultPreview)"
            } else if let card = msg.card {
                text = "[card] \(card)"
            } else {
                text = msg.text
            }
            return Report.Line(author: authorToken(msg.author), text: text, timestamp: msg.timestamp)
        }
        ReportStore.shared.add(note: note, transcript: transcript)
    }

    private func authorToken(_ author: ChatMessage.Author) -> String {
        switch author {
        case .user: return "user"
        case .coach: return "coach"
        case .tool: return "tool"
        }
    }
}

// MARK: - Chat View

struct CoachChatView: View {
    @Environment(CoachRouter.self) private var router
    @State private var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var showReport = false

    init(brain: CoachBrain) {
        _viewModel = State(initialValue: ChatViewModel(brain: brain))
    }

    /// Consume a prompt routed in from a tapped message: drop it into the input
    /// (unsent) and clear it so later tab switches don't replay it. Intentionally
    /// does NOT raise the keyboard — forcing focus as the programmatic tab switch
    /// settles inside the NavigationStack can hang the UI on-device. The athlete
    /// taps the field to edit; the prompt is already there, waiting to be sent.
    private func consumePendingPrompt() {
        guard let prompt = router.pendingPrompt else { return }
        viewModel.prefill(prompt)
        router.pendingPrompt = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.showGreeting {
                            GreetingView(text: viewModel.greeting)
                                .padding(.top, 20)
                        }

                        ForEach(viewModel.messages) { message in
                            Group {
                                if let card = message.card {
                                    ChatCardView(card: card)
                                } else if message.author == .tool {
                                    ToolCallBubble(message: message)
                                } else {
                                    MessageBubble(
                                        message: message,
                                        isStreaming: message.id == viewModel.streamingMessageID,
                                        onRetry: message.isUser ? { viewModel.retry(message) } : nil
                                    )
                                }
                            }
                            .id(message.id)
                        }

                        if viewModel.isThinking {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                // Dismiss the keyboard by dragging the message list, so it never
                // gets stuck covering the tab bar with no way back out.
                .scrollDismissesKeyboard(.interactively)
                // Tapping anywhere in the message area also dismisses it.
                .onTapGesture { inputFocused = false }
                .onChange(of: viewModel.messages.count) {
                    // While the thinking dots are up they sit below the last
                    // message — scroll to them, not the message, or an appended
                    // tool bubble pushes them out of view.
                    if viewModel.isThinking {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    } else if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: viewModel.isThinking) {
                    if viewModel.isThinking {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input bar
            InputBar(
                text: $viewModel.inputText,
                isFocused: $inputFocused,
                isResponding: viewModel.isResponding,
                onSend: { viewModel.sendMessage() },
                onStop: { viewModel.stop() }
            )
        }
        .navigationTitle("Coach")
        // Workout cards push their detail view onto the chat's own stack; the
        // record is resolved at tap time — completed first, so a finished
        // (folded) plan's card opens the actual session.
        .navigationDestination(for: ChatCardDestination.self) { destination in
            switch destination {
            case .workout(let id):
                if let record = TrainingDataStore.shared.activity(id: id) {
                    TrainingDetailView(record: record)
                } else if let plan = TrainingDataStore.shared.scheduledWorkout(id: id) {
                    PlannedWorkoutDetailView(workout: plan)
                } else {
                    ContentUnavailableView("Workout no longer available", systemImage: "calendar.badge.minus")
                }
            }
        }
        .onAppear {
            viewModel.attach()
            // A tap may have set the prompt before this view existed / appeared.
            consumePendingPrompt()
        }
        .onChange(of: router.pendingPrompt) { _, _ in consumePendingPrompt() }
        .task { viewModel.prewarm() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showReport = true
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .help("Report an issue")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset session")
            }
        }
        .sheet(isPresented: $showReport) {
            ReportComposerView(messageCount: viewModel.messages.count) { note in
                viewModel.fileReport(note: note)
            }
        }
    }
}

// MARK: - Report Composer

/// Sheet for filing a bug/feedback report from the chat. Captures the current
/// conversation transcript plus the athlete's optional description; saved
/// locally via `ReportStore` and copyable/resettable from Settings.
private struct ReportComposerView: View {
    let messageCount: Int
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What went wrong?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Description")
                } footer: {
                    Text("Optional. The current conversation (\(messageCount) message\(messageCount == 1 ? "" : "s")) is attached automatically. Reports are saved on this device only — copy or clear them in Settings.")
                }
            }
            .navigationTitle("Report an issue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(note)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Greeting View

private struct GreetingView: View {
    let text: String

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding()
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage
    /// True while this bubble is still receiving streamed text — forwarded to
    /// `MarkdownText` so a half-arrived ```card token shows a placeholder.
    var isStreaming: Bool = false
    /// Set only for user messages: long-press → "Retry" re-sends this message
    /// against the conversation rewound to just before it.
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser { Spacer(minLength: 40) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if message.isUser {
                        // User input is plain text — no markdown interpretation.
                        Text(message.text)
                    } else {
                        // Coach replies are rendered as markdown.
                        MarkdownText(markdown: message.text, isStreaming: isStreaming)
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .foregroundStyle(message.isUser ? .white : .primary)
                .chatBubbleSurface(isUser: message.isUser)
                .contextMenu {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = message.text
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Tool Call Bubble (Debug Mode)

private struct ToolCallBubble: View {
    let message: ChatMessage
    @State private var expanded = false

    private var event: CoachToolEvent? { message.toolEvent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption2)
                    Text(event?.name ?? message.text)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let event {
                VStack(alignment: .leading, spacing: 4) {
                    Text("args: \(event.argumentsJSON)")
                    Text("→ \(event.resultPreview)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }
}

// MARK: - Thinking Indicator

private struct ThinkingIndicator: View {
    @State private var dotIndex = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(i == dotIndex ? 1.3 : 0.8)
                        .animation(.easeInOut(duration: 0.3), value: dotIndex)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .glassSurface(cornerRadius: Theme.Radius.l)

            Spacer(minLength: 40)
        }
        .onReceive(timer) { _ in
            dotIndex = (dotIndex + 1) % 3
        }
    }
}

// MARK: - Input Bar

private struct InputBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isResponding: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.appTertiaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused(isFocused)
                .disabled(isResponding)
                .onSubmit {
                    if !isResponding { onSend() }
                }

            if isResponding {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.red)
                }
                .help("Stop generating")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.blue : Color.appTertiaryLabel)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Chat bubble surface

private extension View {
    /// Coach replies use a translucent Liquid Glass bubble; the athlete's own
    /// messages use a solid, flat color. The material difference is what
    /// separates AI insight from user input (DESIGN.md §3, "Silent AI").
    @ViewBuilder
    func chatBubbleSurface(isUser: Bool) -> some View {
        if isUser {
            self.background(
                Color.blue,
                in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            )
        } else {
            self.glassSurface(cornerRadius: Theme.Radius.l)
        }
    }
}
