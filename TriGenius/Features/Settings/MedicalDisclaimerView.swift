import SwiftUI

/// One-time medical disclaimer shown on first launch (Guideline 1.4.1): TriGenius
/// is not a medical device — it helps plan training, and anything health-related
/// (pain, injury, symptoms) belongs with a qualified professional. Gated by
/// `AppStorage("medical_disclaimer_accepted")`; requires an explicit acknowledgement.
struct MedicalDisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: 0)

            Image(systemName: "cross.case")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Not a medical device")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                point("TriGenius is a training-planning aid. Its coaching, numbers and suggestions are informational only and are not medical advice, diagnosis, or treatment.")
                point("It cannot assess injuries or symptoms. For pain, illness, injury, or any health concern, always consult a doctor or another qualified professional.")
                point("You are responsible for your own training decisions. Stop and seek help if something feels wrong.")
            }
            .frame(maxWidth: 460)

            Spacer(minLength: 0)

            Button(action: onAccept) {
                Text("I understand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: 460)
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
