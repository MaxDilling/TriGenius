import SwiftUI
import FoundationModels

struct ModelEntry: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let model: SystemLanguageModel
}

extension ModelEntry {
    static let all: [ModelEntry] = [
        ModelEntry(
            name: "Default",
            description: "General-purpose language model",
            model: .default
        ),
        ModelEntry(
            name: "Content Tagging",
            description: "Detect topics, actions & emotions",
            model: SystemLanguageModel(useCase: .contentTagging)
        ),
    ]
}

@Observable
final class FoundationModelChatViewModel {
    var userInput: String = ""
    var response: String = ""
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var selectedEntry: ModelEntry = ModelEntry.all[0]

    func sendMessage() async {
        let prompt = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
            self.response = ""
        }

        do {
            let session = LanguageModelSession(model: selectedEntry.model)
            let result = try await session.respond(to: prompt)
            await MainActor.run {
                self.response = result.content
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

struct FoundationModelChatView: View {
    @State private var viewModel = FoundationModelChatViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Foundation Models")
                .font(.headline)

            modelList

            Divider()

            chatSection
        }
        .padding()
        .background(Color.appSecondaryBackground)
        .cornerRadius(16)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available models")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(ModelEntry.all) { entry in
                ModelRowView(
                    entry: entry,
                    isSelected: entry.id == viewModel.selectedEntry.id
                ) {
                    if entry.model.isAvailable {
                        viewModel.selectedEntry = entry
                        viewModel.response = ""
                        viewModel.errorMessage = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chatSection: some View {
        let availability = viewModel.selectedEntry.model.availability
        switch availability {
        case .available:
            chatContent
        case .unavailable(.deviceNotEligible):
            unavailableText("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            unavailableText("Please enable Apple Intelligence in Settings.")
        case .unavailable(.modelNotReady):
            unavailableText("The model is still loading or not ready.")
        case .unavailable:
            unavailableText("The model is currently unavailable.")
        }
    }

    @ViewBuilder
    private var chatContent: some View {
        if !viewModel.response.isEmpty {
            ScrollView {
                Text(viewModel.response)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.appTertiaryBackground)
                    .cornerRadius(10)
            }
            .frame(maxHeight: 160)
        }

        if let error = viewModel.errorMessage {
            Text(error)
                .foregroundColor(.red)
                .font(.caption)
        }

        HStack(spacing: 8) {
            TextField("Enter a message…", text: $viewModel.userInput, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color.appTertiaryBackground)
                .cornerRadius(10)
                .disabled(viewModel.isLoading)

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(viewModel.userInput.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
                }
            }
            .disabled(viewModel.isLoading || viewModel.userInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func unavailableText(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelRowView: View {
    let entry: ModelEntry
    let isSelected: Bool
    let onTap: () -> Void

    private var availability: SystemLanguageModel.Availability {
        entry.model.availability
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(.primary)
                    Text(entry.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(statusLabel)
                    .font(.caption2)
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.15))
                    .cornerRadius(6)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(10)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.appTertiaryBackground)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!entry.model.isAvailable)
    }

    private var statusColor: Color {
        switch availability {
        case .available: return .green
        case .unavailable(.modelNotReady): return .orange
        default: return .red
        }
    }

    private var statusLabel: String {
        switch availability {
        case .available: return "Available"
        case .unavailable(.deviceNotEligible): return "Unsupported"
        case .unavailable(.appleIntelligenceNotEnabled): return "Disabled"
        case .unavailable(.modelNotReady): return "Loading…"
        case .unavailable: return "Unavailable"
        }
    }
}
