import SwiftUI
import Combine

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    enum Author { case user, coach }
    var id = UUID()
    let author: Author
    var text: String
    let timestamp: Date

    var isUser: Bool { author == .user }
}

// MARK: - Chat ViewModel

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    var isThinking = false
    var showGreeting = true

    private let brain: CoachBrain

    /// Computed once at init — avoids re-running brain.greeting() (memory
    /// access + Calendar allocation) on every body re-evaluation / keystroke.
    let greeting: String

    init(brain: CoachBrain) {
        self.brain = brain
        self.greeting = brain.greeting()
    }

    /// Warm up the backend (Apple FM) so the first reply comes back faster.
    func prewarm() {
        brain.prewarm()
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        showGreeting = false

        messages.append(ChatMessage(author: .user, text: text, timestamp: Date()))

        isThinking = true
        let coachID = UUID()
        var inserted = false

        // `onPartial` delivers cumulative text. On the first chunk we swap the
        // thinking indicator for a coach bubble; later chunks update it in place.
        let final = await brain.sendMessage(text) { [weak self] partial in
            guard let self else { return }
            if !inserted {
                inserted = true
                self.isThinking = false
                self.messages.append(ChatMessage(id: coachID, author: .coach, text: partial, timestamp: Date()))
            } else if let idx = self.messages.firstIndex(where: { $0.id == coachID }) {
                self.messages[idx].text = partial
            }
        }

        // Fallback: if no partial ever arrived, show the final text.
        if !inserted {
            isThinking = false
            messages.append(ChatMessage(id: coachID, author: .coach, text: final, timestamp: Date()))
        }
    }

    func reset() {
        brain.reset()
        messages = []
        showGreeting = true
    }
}

// MARK: - Chat View

struct CoachChatView: View {
    @State private var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool

    init(brain: CoachBrain) {
        _viewModel = State(initialValue: ChatViewModel(brain: brain))
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
                            MessageBubble(message: message)
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
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
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
                isDisabled: viewModel.isThinking
            ) {
                Task { await viewModel.sendMessage() }
            }
        }
        .navigationTitle("TriGenius Coach")
        .task { viewModel.prewarm() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset session")
            }
        }
    }
}

// MARK: - Greeting View

private struct GreetingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue.gradient)
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser { Spacer(minLength: 40) }

            if !message.isUser {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.blue.opacity(0.12)))
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if message.isUser {
                        // User input is plain text — no markdown interpretation.
                        Text(message.text)
                    } else {
                        // Coach replies are rendered as markdown.
                        MarkdownText(markdown: message.text)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.isUser
                        ? Color.blue
                        : Color.appSecondaryBackground
                )
                .foregroundStyle(message.isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Thinking Indicator

private struct ThinkingIndicator: View {
    @State private var dotIndex = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.blue.opacity(0.12)))

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(i == dotIndex ? 1.3 : 0.8)
                        .animation(.easeInOut(duration: 0.3), value: dotIndex)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.appSecondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

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
    let isDisabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.appTertiaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused(isFocused)
                .disabled(isDisabled)
                .onSubmit {
                    if !isDisabled { onSend() }
                }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Color.blue : Color.appTertiaryLabel)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }

    private var canSend: Bool {
        !isDisabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Cross-platform colors
//
// The `*SystemBackground` / `*Label` colors only exist on UIKit (iOS).
// These helpers map them to the AppKit equivalents on macOS so the
// same SwiftUI code compiles for both platforms.

extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .tertiarySystemBackground)
        #endif
    }

    static var appTertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }
}
