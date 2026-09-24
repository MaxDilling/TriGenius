import SwiftUI

// MARK: - Tissue Load group detail
//
// One group: its two tissues side by side over the window, the sentence that says
// which of them sets the forecast, and the sessions on either side of today that
// explain it — each one opens its workout. The figure here is a read-only locator,
// not a control.

struct TissueGroupDetail: View {
    let model: TissueGroupDetailModel
    var onAskCoach: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                lanes
                if !model.rows.isEmpty { sessions }
                Button { onAskCoach(model.coachPrompt) } label: {
                    Text("Ask coach about \(model.group.label.lowercased())")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color.appBackground)
        // The content header is the title; the bar carries only the way back.
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            if let today = model.today, let geometry = TissueBodyGeometry.shared {
                TissueBodyMap(side: geometry.side(for: model.group),
                              fills: [model.group: Theme.Palette.Tissue.load(today.muscle)],
                              states: [model.group: today],
                              selected: model.group)
                    .frame(width: TissueMetrics.detailFigure)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.group.label)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Estimated from your training")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.clearCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.clearLabel)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Lanes

    private var lanes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                laneRow(label: nil) { index in
                    let day = model.days[index]
                    VStack(spacing: 1) {
                        Text(day.letter)
                            .font(.caption2)
                            .foregroundStyle(day.isToday ? Color.primary : .secondary)
                        Text(day.dayNumber)
                            .font(day.isToday ? .caption2.weight(.bold) : .caption2)
                            .foregroundStyle(day.isToday ? Color.primary : .secondary)
                    }
                }
                laneRow(label: "Muscle") { index in
                    MuscleMark(level: model.states[index].muscle,
                               size: CGSize(width: 0, height: 8), fillsWidth: true)
                }
                if let tendonLabel = model.tendonLabel {
                    laneRow(label: tendonLabel) { index in
                        TendonMark(level: model.states[index].tendon ?? .fresh)
                    }
                }
            }
            Text(model.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.l)
    }

    private func laneRow<Content: View>(label: String?,
                                        @ViewBuilder content: @escaping (Int) -> Content) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            ForEach(model.states.indices, id: \.self) { index in
                content(index)
                    .frame(maxWidth: .infinity)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                if let recordId = row.recordId {
                    NavigationLink { WorkoutDetailDestination(id: recordId) } label: { sessionRow(row, opens: true) }
                        .buttonStyle(.plain)
                } else {
                    sessionRow(row, opens: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Theme.Radius.l)
    }

    private func sessionRow(_ row: TissueGroupDetailModel.Row, opens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(row.title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            if let load = row.load {
                Text(load)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(row.note)
                .font(.caption.weight(row.isWarning ? .semibold : .regular))
                .foregroundStyle(row.isWarning ? Theme.Palette.Tissue.conflict : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

#if DEBUG
#Preview("2.3 Group detail") {
    NavigationStack {
        if let model = TissueGroupDetailModel.make(group: .calves, input: TissuePreviewFixture.conflict) {
            TissueGroupDetail(model: model)
        }
    }
}
#endif
