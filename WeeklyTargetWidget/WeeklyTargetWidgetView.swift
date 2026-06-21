import SwiftUI
import WidgetKit

// MARK: - Weekly Target Widget View
//
// Renders the per-discipline weekly volume rings (swim/bike/run) from the latest
// snapshot the app wrote. systemMedium shows the three rings with TSS labels;
// systemSmall shows three compact rings to keep the at-a-glance parity with the
// dashboard.

struct WeeklyTargetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WeeklyTargetSnapshot

    private var disciplines: [WeeklyTargetSnapshot.Entry] { snapshot.disciplines }

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        default:
            mediumBody
        }
    }

    // MARK: Medium — three labeled rings

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 12) {
                ForEach(disciplines, id: \.sport) { entry in
                    WidgetRing(entry: entry, diameter: 56, lineWidth: 6, showLabels: true)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Small — three compact rings

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This Week")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(disciplines, id: \.sport) { entry in
                    WidgetRing(entry: entry, diameter: 40, lineWidth: 5, showLabels: false)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Weekly Target")
                .font(.caption.weight(.semibold))
            Spacer()
            Text(weekRange)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var weekRange: String {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 6, to: snapshot.weekStart) ?? snapshot.weekStart
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        return "\(fmt.string(from: snapshot.weekStart)) – \(fmt.string(from: end))"
    }
}
