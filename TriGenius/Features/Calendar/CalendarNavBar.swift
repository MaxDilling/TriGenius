import SwiftUI

// MARK: - Calendar nav chrome (glass)
//
// The floating glass control layer above the grid, mirroring Apple Calendar: a pill
// with the month name (a back chevron that zooms out to the month, in week mode) and
// a right-hand pill with search + add ("+" opens the workout editor; search is a
// mockup only, per the design reference). Below the pill, in week mode, a date strip shows
// the visible week, highlights the selected day and the columns currently on screen,
// and tabs to a day.

struct CalendarNavBar: View {
    @Bindable var viewModel: CalendarViewModel
    /// Day columns visible in the week grid — used to highlight the on-screen range.
    let visibleCount: Int
    /// Opens the workout editor to create a plan (the "+" control).
    let onAdd: () -> Void

    /// All nav pills share this height + a capsule corner radius so they line up.
    private let pillHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            GlassEffectContainer(spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    leftPill
                    Spacer(minLength: Theme.Spacing.s)
                    todayPill
                    controls
                }
            }
            if viewModel.mode == .week {
                dateStrip
            } else {
                monthHeader
            }
        }
    }

    // Week mode: chevron + month name (tap zooms out to the month). Month mode has no
    // left pill — the month name lives in the big header below.
    @ViewBuilder
    private var leftPill: some View {
        if viewModel.mode == .week {
            Button { viewModel.showMonth() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                    Text(viewModel.monthLabel).font(.title3.weight(.semibold))
                }
                .padding(.horizontal, Theme.Spacing.m)
                .frame(height: pillHeight)
            }
            .buttonStyle(.plain)
            .glassSurface(cornerRadius: pillHeight / 2)
        }
    }

    // Month mode header: the big month-name text + the weekday row (indented to line
    // up with the grid's week-number gutter).
    private var monthHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(viewModel.monthLabel)
                .font(.largeTitle.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Spacer().frame(width: CalendarLayout.monthGutter)
                ForEach(viewModel.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // Jump back to today — sits beside the (mockup) search/add controls.
    private var todayPill: some View {
        Button { viewModel.goToToday() } label: {
            Text("Today")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.m)
                .frame(height: pillHeight)
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: pillHeight / 2)
    }

    // Search (still a visual mockup, by design) + add (creates a planned workout).
    private var controls: some View {
        HStack(spacing: Theme.Spacing.l) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: pillHeight)
        .glassSurface(cornerRadius: pillHeight / 2)
    }

    // MARK: Date strip

    // Mirrors Apple: the weekday letters sit on their own row, and only the *numbers*
    // below them get the grey capsule spanning the on-screen range. The leftmost
    // visible day (the "anchor") carries the accent circle; tapping a day makes it the
    // new leftmost day.
    private var dateStrip: some View {
        let cal = Self.weekCalendar
        let weekStart = TrainingVolume.weekStart(of: viewModel.firstVisibleDay, calendar: cal)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let leftIndex = days.firstIndex { cal.isDate($0, inSameDayAs: viewModel.firstVisibleDay) } ?? 0
        let span = max(1, min(visibleCount, 7 - leftIndex))
        return GeometryReader { geo in
            let colWidth = geo.size.width / 7
            VStack(spacing: 4) {
                // Weekday letters — outside the capsule, like Apple.
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: colWidth)
                    }
                }
                // Numbers — the grey capsule spans only this row. Its left edge aligns with
                // the anchor day's circle *left edge* and it shares the circle's height, so
                // the capsule's own left semicircle coincides exactly with the accent circle
                // — the circle caps the capsule cleanly (Apple-style) — while the right edge
                // still reaches the end of the on-screen span.
                ZStack(alignment: .leading) {
                    // Center of the anchor day's circle, and where the grey range ends.
                    let anchorCenter = colWidth * CGFloat(leftIndex) + colWidth / 2
                    let capsuleLeft = anchorCenter - Self.circleDiameter / 2
                    let capsuleRight = colWidth * CGFloat(leftIndex + span)
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: capsuleRight - capsuleLeft, height: Self.circleDiameter)
                        .offset(x: capsuleLeft)
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            numberCell(day: day, calendar: cal, width: colWidth)
                        }
                    }
                }
            }
        }
        .frame(height: 58)
    }

    private func numberCell(day: Date, calendar cal: Calendar, width: CGFloat) -> some View {
        let isAnchor = cal.isDate(day, inSameDayAs: viewModel.firstVisibleDay)
        let isToday = cal.isDateInToday(day)
        return Text("\(cal.component(.day, from: day))")
            .font(.subheadline.weight(isAnchor || isToday ? .bold : .regular))
            .foregroundStyle(isAnchor ? .white : (isToday ? Color.accentColor : .primary))
            .frame(width: Self.circleDiameter, height: Self.circleDiameter)
            .background { if isAnchor { Circle().fill(Color.accentColor) } }
            .frame(width: width, height: Self.circleDiameter)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.scrollWeek(to: day) }
    }

    /// The anchor day's accent circle and the grey range capsule share this diameter so
    /// the circle caps the capsule's left end flush (Apple-style).
    private static let circleDiameter: CGFloat = 30

    private static let weekCalendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }()
}
