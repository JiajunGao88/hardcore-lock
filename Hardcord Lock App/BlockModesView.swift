//
//  BlockModesView.swift
//  Hardcord Lock App
//
//  Mode switcher (NOW / SCHEDULE / AI) and the two new mode screens.
//  Visual language matches the rest of the app: black, monospaced, brutalist.
//

import SwiftUI
import UIKit
import FamilyControls
import UserNotifications

// MARK: - Shared tickers

/// Timer publishers MUST outlive a View struct. A `let` (or an inline
/// `Timer.publish(...)`) stored on a view is re-created on every re-init, and
/// SwiftUI then cancels and re-subscribes — restarting the interval. ContentView
/// re-renders ~2x/second while a lock runs, so such a timer would never fire.
/// These live for the process instead, so their cadence is stable.
enum AppClock {
    static let everyThirtySeconds = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    static let everyTenSeconds = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
}

// MARK: - Mode

enum BlockMode: String, CaseIterable, Identifiable {
    case now = "NOW"
    case schedule = "SCHEDULE"
    case ai = "AI"
    var id: String { rawValue }
}

// MARK: - Design tokens

/// One place for the brutalist look: black, white, monospaced, hairlines.
/// Secondary text is white at fixed opacities rather than `.gray`, which
/// shifts with the system appearance and fell under WCAG contrast on black.
enum Theme {
    static let gutter: CGFloat = 24
    static let rowPadding: CGFloat = 16
    static let hairline = Color.white.opacity(0.18)
    static let hairlineStrong = Color.white.opacity(0.4)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.38)
    static let warning = Color.orange
    static let danger = Color(red: 1, green: 0.32, blue: 0.29)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Solid white slab — the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(18, .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.white.opacity(configuration.isPressed ? 0.8 : 1))
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Hairline outline — secondary actions and tappable rows.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Text-only, for quiet links ("RESTORE PURCHASE").
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, .medium))
            .foregroundColor(Theme.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// An inline notice: orange for "won't work until you fix this", red for "broken".
struct NoticeBanner: View {
    let text: String
    var isError = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(isError ? Theme.danger : Theme.warning)
                .frame(width: 3)
            Text(text)
                .font(Theme.mono(11))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.mono(11, .bold))
                    .foregroundColor(.white)
                    .frame(minHeight: 32)
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .background(Color.white.opacity(0.05))
    }
}

// MARK: - Mode picker bar

struct ModePickerBar: View {
    @Binding var mode: BlockMode
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BlockMode.allCases) { m in
                Button(action: { withAnimation(.snappy(duration: 0.22)) { mode = m } }) {
                    Text(m.rawValue)
                        .font(Theme.mono(12, .bold))
                        .foregroundColor(mode == m ? .black : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if mode == m {
                                Rectangle().fill(Color.white).matchedGeometryEffect(id: "mode", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, Theme.gutter)
        .sensoryFeedback(.selection, trigger: mode)
    }
}

// MARK: - Small shared bits

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.mono(11, .medium))
            .tracking(0.5)
            .foregroundColor(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct OutlineRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.rowPadding)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Label over value with a chevron — the "pick something" row used everywhere.
struct PickerRow: View {
    let label: String
    let value: String
    var placeholder = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(Theme.mono(11, .medium))
                    .foregroundColor(Theme.secondary)
                Text(value)
                    .font(Theme.mono(17, .medium))
                    .foregroundColor(placeholder ? Theme.tertiary : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.tertiary)
        }
        .padding(Theme.rowPadding)
        .frame(minHeight: 64)
    }
}

/// One-glance state for a schedule row. Only BLOCKING NOW gets the solid white
/// treatment — everything else stays quiet so a list of schedules reads calmly.
private struct ScheduleStatusBadge: View {
    let status: ScheduleStatus

    var body: some View {
        switch status {
        case .off:
            EmptyView()
        case .armed:
            chip("ARMED", color: .white.opacity(0.55), filled: false)
        case .blocking:
            chip("BLOCKING NOW", color: .white, filled: true)
        case .paused(let reason):
            chip("PAUSED · \(reason)", color: Theme.warning, filled: false)
        }
    }

    private func chip(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(Theme.mono(9, .bold))
            .foregroundColor(filled ? .black : color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(filled ? color : Color.clear)
            .overlay(
                Group {
                    if !filled { Rectangle().stroke(color.opacity(0.5), lineWidth: 1) }
                }
            )
    }
}

/// A compact hour/minute wheel matching the existing duration picker style.
struct TimeWheel: View {
    let title: String
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.mono(11, .medium))
                .foregroundColor(Theme.secondary)
            HStack(spacing: 6) {
                Picker("\(title) hour", selection: $hour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d", h))
                            .font(.system(size: 22, weight: .medium, design: .monospaced))
                            .foregroundColor(.white).tag(h)
                    }
                }
                .pickerStyle(.wheel).frame(width: 80, height: 150).clipped()

                Text(":")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Picker("\(title) minute", selection: $minute) {
                    ForEach(0..<60, id: \.self) { m in
                        Text(String(format: "%02d", m))
                            .font(.system(size: 22, weight: .medium, design: .monospaced))
                            .foregroundColor(.white).tag(m)
                    }
                }
                .pickerStyle(.wheel).frame(width: 80, height: 150).clipped()
            }
        }
    }
}

// MARK: - Shared formatting & controls

enum UIFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "45m", "2h 30m", "3d 4h" — never "4320m".
    static func duration(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = (seconds % 86_400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

extension ScheduleManager.ChangeRefusal {
    var message: String {
        switch self {
        case .committed(let until):
            let when = until.map { "until \(UIFormat.time.string(from: $0))" } ?? "until this block ends"
            return "This schedule is blocking right now. It can't be switched off, edited or deleted \(when).\n\nThat's the point."
        }
    }
}

/// Square, high-contrast switch. The stock Toggle tinted white draws a white
/// thumb on a white track — the ON state was nearly invisible.
struct BrutalToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Rectangle()
                .fill(on ? Color.white : Color.clear)
                .overlay(Rectangle().stroke(on ? Color.white : Theme.hairlineStrong, lineWidth: 1))
            Rectangle()
                .fill(on ? Color.black : Theme.secondary)
                .frame(width: 18, height: 18)
                .padding(5)
        }
        .frame(width: 52, height: 28)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .light), trigger: on)
        .accessibilityElement()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

// MARK: - SCHEDULE mode

struct ScheduleModeView: View {
    @ObservedObject var scheduleManager = ScheduleManager.shared
    @ObservedObject var storeManager = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Present the Pro paywall (feature is Pro-gated).
    var requestPaywall: () -> Void

    /// `sheet(item:)`, not a Bool + separate state: with the Bool the sheet could
    /// render before `editing` was set and open the wrong schedule (or a blank one).
    @State private var editing: ScheduleConfig?
    @State private var creating = false
    @State private var refusalMessage: String?

    /// A schedule's status depends on the wall clock, but SwiftUI only re-renders
    /// on published changes — without this tick a window opening while the screen
    /// is up would never light up. 30s is enough: windows are minute-aligned.
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionLabel(text: "AUTO-BLOCK ON A SCHEDULE")

                if let warning = scheduleManager.lastBudgetWarning {
                    NoticeBanner(text: warning)
                }

                if scheduleManager.schedules.isEmpty {
                    emptyState
                } else {
                    ForEach(scheduleManager.schedules) { config in
                        scheduleRow(config)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { now = Date() }
        // Timers fire nothing while suspended, so resync on foreground too.
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = Date() } }
        .onReceive(AppClock.everyThirtySeconds) { now = $0 }
        .sheet(item: $editing) { config in
            ScheduleEditorView(existing: config)
        }
        .sheet(isPresented: $creating) {
            ScheduleEditorView(existing: nil)
        }
        .alert("LOCKED IN", isPresented: Binding(
            get: { refusalMessage != nil },
            set: { if !$0 { refusalMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(refusalMessage ?? "") }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("NO SCHEDULES")
                .font(Theme.mono(14, .bold))
                .foregroundColor(.white)
            Text("Block apps automatically at the times you choose — even when FIFTEEN is closed.")
                .font(Theme.mono(12))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .overlay(Rectangle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button("+ NEW SCHEDULE") {
                guard storeManager.canUseSchedule else { requestPaywall(); return }
                creating = true
            }
            .buttonStyle(PrimaryButtonStyle())

            if !storeManager.purchasedPro {
                Text(storeManager.scheduleTrialsRemaining > 0
                     ? "FREE TRIAL: \(storeManager.scheduleTrialsRemaining)/\(TrialGate.limit) SCHEDULED SESSIONS LEFT"
                     : "TRIAL USED UP — SCHEDULE MODE IS A PRO FEATURE")
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.tertiary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    private func scheduleRow(_ config: ScheduleConfig) -> some View {
        let status = scheduleManager.status(config, now: now)
        return HStack(spacing: 12) {
            // The row body opens the editor; the switch is a sibling, not nested
            // inside the button, so flipping it never also opens the editor.
            // Viewing, editing and deleting are never paywalled — only creating.
            Button { editing = config } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(config.name.uppercased())
                            .font(Theme.mono(16, .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ScheduleStatusBadge(status: status)
                    }
                    Text(scheduleSummary(config))
                        .font(Theme.mono(12))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(2)
                    if status == .blocking, let end = scheduleManager.activeWindowEnd(config, now: now) {
                        Text("LOCKED UNTIL \(UIFormat.time.string(from: end).uppercased())")
                            .font(Theme.mono(10, .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { config.isEnabled },
                set: { newValue in
                    if newValue && !storeManager.canUseSchedule { requestPaywall(); return }
                    if let refused = scheduleManager.setEnabled(config.id, newValue) {
                        refusalMessage = refused.message
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(BrutalToggleStyle())
            .accessibilityLabel("\(config.name) enabled")
        }
        .padding(Theme.rowPadding)
        .overlay(Rectangle().stroke(status == .blocking ? Color.white : (config.isEnabled ? Theme.hairlineStrong : Theme.hairline),
                                    lineWidth: 1))
    }

    private func scheduleSummary(_ c: ScheduleConfig) -> String {
        let time = String(format: "%02d:%02d–%02d:%02d", c.startHour, c.startMinute, c.endHour, c.endMinute)
        let days = WeekdayHelper.summary(c.weekdays)
        let cadence = c.everyNWeeks <= 1 ? "" : " · every \(c.everyNWeeks) wks"
        return "\(time) · \(days)\(cadence)"
    }
}

// MARK: - Schedule editor

struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    let existing: ScheduleConfig?

    @State private var name: String
    @State private var weekdays: Set<Int>
    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int
    @State private var everyNWeeks: Int
    @State private var selection: FamilyActivitySelection
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var refusalMessage: String?

    private let id: String
    private static let maxNameLength = 24

    init(existing: ScheduleConfig?) {
        self.existing = existing
        let cfg = existing ?? ScheduleConfig(name: "Focus block", weekdays: [2, 3, 4, 5, 6])
        self.id = cfg.id
        _name = State(initialValue: cfg.name)
        _weekdays = State(initialValue: Set(cfg.weekdays))
        _startHour = State(initialValue: cfg.startHour)
        _startMinute = State(initialValue: cfg.startMinute)
        _endHour = State(initialValue: cfg.endHour)
        _endMinute = State(initialValue: cfg.endMinute)
        _everyNWeeks = State(initialValue: cfg.everyNWeeks)
        _selection = State(initialValue: ScheduleManager.shared.selection(for: cfg.id))
    }

    private var appCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
    }

    private var isOvernight: Bool {
        let end = endHour * 60 + endMinute
        return end <= (startHour * 60 + startMinute) && end != 0
    }

    /// Set while this schedule is blocking: then it is read-only.
    private var refusal: ScheduleManager.ChangeRefusal? {
        existing.flatMap { scheduleManager.refusal(for: $0.id) }
    }

    /// iOS rejects monitoring intervals shorter than 15 minutes — validate here
    /// so the user gets a clear message instead of a generic system error.
    private var windowIssue: String? {
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        let minLen = 15
        // A segment capped at midnight really ends 23:59:59, so its usable length
        // is measured against 1439 — validating against 1440 let 23:45 through
        // and iOS then rejected the 14m59s interval it produced.
        if end == 0 {                        // "until midnight" — same-day
            if 1439 - start < minLen { return "Window must be at least 15 minutes." }
        } else if end <= start {             // overnight split into two halves
            if 1439 - start < minLen { return "Overnight start must be 23:44 or earlier (iOS minimum window is 15 min)." }
            if end < minLen { return "Overnight end must be 00:15 or later (iOS minimum window is 15 min)." }
        } else if end - start < minLen {
            return "Window must be at least 15 minutes."
        }
        return nil
    }

    /// What's still missing, so a disabled SAVE is never a mystery.
    private var saveHint: String? {
        if appCount == 0 { return "Pick at least one app to block." }
        if weekdays.isEmpty { return "Pick at least one day." }
        return windowIssue
    }

    private var canSave: Bool { saveHint == nil && refusal == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let refusal {
                        NoticeBanner(text: refusal.message)
                    }

                    VStack(spacing: 24) {
                        nameSection
                        appsSection
                        daysSection
                        timeSection
                        cadenceSection
                    }
                    .disabled(refusal != nil)

                    if existing != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("DELETE SCHEDULE")
                                .font(Theme.mono(13, .bold))
                                .foregroundColor(Theme.danger)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(refusal != nil)
                        .opacity(refusal != nil ? 0.4 : 1)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(existing == nil ? "NEW SCHEDULE" : "EDIT SCHEDULE")
                        .font(Theme.mono(15, .bold))
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("CLOSE") { dismiss() }
                        .font(Theme.mono(13, .medium))
                        .foregroundColor(Theme.secondary)
                }
            }
        }
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .confirmationDialog("Delete this schedule?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteSchedule)
        }
        .alert("LOCKED IN", isPresented: Binding(
            get: { refusalMessage != nil },
            set: { if !$0 { refusalMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(refusalMessage ?? "") }
    }

    // MARK: Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "NAME")
            TextField("", text: $name, prompt: Text("Focus block").foregroundColor(Theme.tertiary))
                .font(Theme.mono(17, .medium))
                .foregroundColor(.white)
                .tint(.white)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .padding(14)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .onChange(of: name) { _, new in
                    if new.count > Self.maxNameLength { name = String(new.prefix(Self.maxNameLength)) }
                }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "APPS TO BLOCK")
            Button { showPicker = true } label: {
                PickerRow(label: "SELECTED", value: appCount == 0 ? "None selected" : "\(appCount) selected",
                          placeholder: appCount == 0)
            }
            .buttonStyle(OutlineButtonStyle())
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "DAYS")
            HStack(spacing: 6) {
                ForEach(WeekdayHelper.ordered, id: \.weekday) { item in
                    let on = weekdays.contains(item.weekday)
                    Button {
                        if on { weekdays.remove(item.weekday) } else { weekdays.insert(item.weekday) }
                    } label: {
                        Text(item.short)
                            .font(Theme.mono(14, .bold))
                            .foregroundColor(on ? .black : Theme.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? Color.white : Color.clear)
                            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[item.weekday - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                quickButton("WEEKDAYS") { weekdays = [2, 3, 4, 5, 6] }
                quickButton("WEEKENDS") { weekdays = [1, 7] }
                quickButton("EVERY DAY") { weekdays = Set(1...7) }
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "TIME WINDOW")
            HStack(spacing: 12) {
                TimeWheel(title: "FROM", hour: $startHour, minute: $startMinute)
                TimeWheel(title: "TO", hour: $endHour, minute: $endMinute)
            }
            .frame(maxWidth: .infinity)
            if let issue = windowIssue {
                Text(issue)
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.warning)
            } else if isOvernight {
                Text("Overnight window — ends next morning.")
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.secondary)
            }
        }
    }

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "REPEAT")
            HStack {
                Text(everyNWeeks <= 1 ? "Every week" : "Every \(everyNWeeks) weeks")
                    .font(Theme.mono(16, .medium))
                    .foregroundColor(.white)
                Spacer()
                Stepper("Repeat every N weeks", value: $everyNWeeks, in: 1...8).labelsHidden()
            }
            .padding(14)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            Button("SAVE SCHEDULE", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
            if refusal == nil, let hint = saveHint {
                Text(hint)
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.tertiary)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    private func quickButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(11, .bold))
                .foregroundColor(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
        }
        .buttonStyle(OutlineButtonStyle())
    }

    private func save() {
        var cfg = existing ?? ScheduleConfig(id: id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.name = trimmed.isEmpty ? "Focus block" : trimmed
        cfg.weekdays = weekdays.sorted()
        cfg.startHour = startHour
        cfg.startMinute = startMinute
        cfg.endHour = endHour
        cfg.endMinute = endMinute
        cfg.everyNWeeks = everyNWeeks
        // Editing must not silently switch a schedule the user turned off back on.
        cfg.isEnabled = existing?.isEnabled ?? true
        if existing == nil || cfg.anchorEpoch == 0 {
            cfg.anchorEpoch = Date().timeIntervalSince1970
        }
        // The window may have opened while the editor was up.
        if let refused = scheduleManager.upsert(cfg, selection: selection) {
            refusalMessage = refused.message
            return
        }
        dismiss()
    }

    private func deleteSchedule() {
        if let refused = scheduleManager.delete(id) {
            refusalMessage = refused.message
            return
        }
        dismiss()
    }
}

// MARK: - AI mode

struct AIModeView: View {
    @ObservedObject var habit = HabitEngine.shared
    @ObservedObject var storeManager = StoreManager.shared
    @ObservedObject var coach = AICoach.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var requestPaywall: () -> Void

    @State private var showPicker = false
    @State private var localSelection = HabitEngine.shared.watchedSelection
    /// The toggle was flipped on before any app was chosen; finish the job once
    /// the picker comes back with a selection.
    @State private var enableAfterPicking = false
    /// The nudge is the ONLY way an AI lock starts, so DENIED notifications
    /// silently make the whole mode inert — say so instead of promising a nudge.
    /// `.notDetermined` is not a failure: we simply haven't asked yet (enabling
    /// AI mode asks), so it must not show the "fix this in Settings" message.
    @State private var notifStatus: UNAuthorizationStatus = .authorized
    private var notificationsBlocked: Bool { notifStatus == .denied }

    private var watchedCount: Int {
        let s = habit.watchedSelection
        return s.applicationTokens.count + s.categoryTokens.count + s.webDomainTokens.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                intro
                enableRow

                Button {
                    localSelection = habit.watchedSelection
                    showPicker = true
                } label: {
                    PickerRow(label: "APPS TO WATCH", value: watchedCount == 0 ? "None selected" : "\(watchedCount) selected",
                              placeholder: watchedCount == 0)
                }
                .buttonStyle(OutlineButtonStyle())

                HStack(spacing: 12) {
                    leadTimePicker
                    durationPicker
                }

                if notificationsBlocked {
                    NoticeBanner(text: "AI mode nudges you with a notification, so it can't do anything until notifications are allowed.",
                                 actionTitle: "SETTINGS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }

                todayPanel

                if !habit.isLearning {
                    weekPanel
                    if coach.isAvailable { coachPanel }
                }

                if let warning = habit.lastBudgetWarning {
                    NoticeBanner(text: warning)
                }

                // A lock is only ever started by the user accepting a nudge —
                // there is deliberately no button here that locks on one tap.
                OutlineRow {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "NEXT NUDGE")
                        Text(nudgeLabel)
                            .font(Theme.mono(16, .medium))
                            .foregroundColor(.white)
                        Text("Tap LOCK NOW on that notification to start a \(UIFormat.duration(habit.config.lockDurationSeconds)) lock. Nothing here locks you on its own.")
                            .font(Theme.mono(11))
                            .foregroundColor(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !storeManager.purchasedPro {
                    Text(storeManager.aiTrialsRemaining > 0
                         ? "FREE TRIAL: \(storeManager.aiTrialsRemaining)/\(TrialGate.limit) AI LOCKS LEFT"
                         : "TRIAL USED UP — AI MODE IS A PRO FEATURE")
                        .font(Theme.mono(10))
                        .foregroundColor(Theme.tertiary)
                }

                #if DEBUG
                Button("🧪 Reset learning") { habit.resetLearning() }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.red.opacity(0.6))
                #endif
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .familyActivityPicker(isPresented: $showPicker, selection: $localSelection)
        .onChange(of: showPicker) { _, isShowing in
            guard !isShowing else { return }
            // Persist BEFORE enabling: setEnabled reconciles, and reconcile
            // reloads the selection from the store — enabling first would see an
            // empty selection and switch AI straight back off.
            habit.saveWatchedSelection(localSelection)
            if enableAfterPicking {
                enableAfterPicking = false
                if !SelectionStore.isEmpty(localSelection) { habit.setEnabled(true) }
            }
        }
        .task { await refreshNotificationStatus() }
        // Re-read after the user grants (or denies) permission — either in our
        // own prompt when AI mode is switched on, or over in Settings.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationStatus() } }
        }
        .onChange(of: habit.config.isEnabled) { _, _ in
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREDICT & PREVENT")
                .font(Theme.mono(16, .bold))
                .foregroundColor(.white)
            Text("Learns, per weekday, when you reach for distracting apps — then nudges you to lock in before the urge hits. On-device. Private.")
                .font(Theme.mono(12))
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enableRow: some View {
        OutlineRow {
            HStack {
                Text("AI MODE")
                    .font(Theme.mono(16, .bold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("AI mode", isOn: Binding(
                    get: { habit.config.isEnabled },
                    set: { v in
                        if v && !storeManager.canUseAI { requestPaywall(); return }
                        guard v else { enableAfterPicking = false; habit.setEnabled(false); return }
                        // Turning AI on with nothing watched would be
                        // normalized straight back to off, so pick apps
                        // FIRST and enable once we have a selection.
                        if watchedCount == 0 {
                            localSelection = habit.watchedSelection
                            enableAfterPicking = true
                            showPicker = true
                            return
                        }
                        habit.setEnabled(true)
                    }
                ))
                .labelsHidden()
                .toggleStyle(BrutalToggleStyle())
            }
        }
    }

    private var leadTimePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "NUDGE LEAD")
            Menu {
                Button("Auto — learns what works") {
                    var c = habit.config; c.adaptiveLead = true; habit.updateConfig(c)
                }
                ForEach(LeadBandit.arms, id: \.self) { m in
                    Button("\(m) min before") {
                        var c = habit.config; c.adaptiveLead = false; c.leadMinutes = m; habit.updateConfig(c)
                    }
                }
            } label: {
                menuLabel(habit.config.adaptiveLead ? "AUTO · \(habit.currentLead)m" : "\(habit.config.leadMinutes) min")
            }
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "LOCK FOR")
            Menu {
                ForEach([1800, 3600, 7200, 10800], id: \.self) { seconds in
                    Button(UIFormat.duration(seconds)) {
                        var c = habit.config; c.lockDurationSeconds = seconds; habit.updateConfig(c)
                    }
                }
            } label: {
                menuLabel(UIFormat.duration(habit.config.lockDurationSeconds))
            }
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(Theme.mono(15, .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// Today's risk curve and peak.
    private var todayPanel: some View {
        OutlineRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "TODAY'S RISK")
                    Text("\(habit.daysObserved)D LEARNED")
                        .font(Theme.mono(10, .medium))
                        .foregroundColor(Theme.tertiary)
                        .fixedSize()
                }

                if habit.isLearning {
                    Text("Learning your habits — \(habit.daysObserved)/\(habit.config.minObservationDays) days. Keep AI mode on.")
                        .font(Theme.mono(13))
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressBar(value: Double(habit.daysObserved) / Double(max(1, habit.config.minObservationDays)))
                } else if let plan = habit.todayPlan {
                    Text("PEAK \(AIConfig.minuteLabel(plan.peakMinute))")
                        .font(Theme.mono(22, .bold))
                        .foregroundColor(.white)
                    Text("\(Int(plan.probability * 100))% chance of heavy use around then.")
                        .font(Theme.mono(12))
                        .foregroundColor(Theme.secondary)
                } else {
                    Text("No reliable peak today — your usage is fairly even. Still watching.")
                        .font(Theme.mono(13))
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                histogram
            }
        }
    }

    private var histogram: some View {
        let risk = habit.riskCurve
        let peak = habit.todayPeakBin
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<AIConfig.displayBins, id: \.self) { i in
                let r = i < risk.count ? risk[i] : 0
                let hour = AIConfig.displayBinStartHour(i)
                VStack(spacing: 4) {
                    Rectangle()
                        .fill(peak == i ? Color.white : Color.white.opacity(0.3))
                        .frame(height: max(2, CGFloat(r) * 64))
                    // Label every 3rd hour to avoid clutter (9, 12, 15, …).
                    Text(hour % 3 == 0 ? "\(hour)" : " ")
                        .font(Theme.mono(8))
                        .foregroundColor(Theme.tertiary)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 84, alignment: .bottom)
        .animation(.easeOut(duration: 0.3), value: risk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peak.map { "Highest risk around \(AIConfig.binLabel($0))" } ?? "No clear peak today")
    }

    /// One line per weekday: its own peak and how sure the model is.
    private var weekPanel: some View {
        let plans = habit.weeklyPlan
        let names = Calendar.current.shortWeekdaySymbols
        return OutlineRow {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "THIS WEEK")
                ForEach(WeekdayHelper.ordered, id: \.weekday) { item in
                    let plan = plans.first { $0.weekday == item.weekday }
                    let isToday = item.weekday == habit.todayWeekday
                    HStack(spacing: 10) {
                        Text(names[item.weekday - 1].uppercased())
                            .font(Theme.mono(12, .bold))
                            .foregroundColor(isToday ? .white : Theme.secondary)
                            .frame(width: 44, alignment: .leading)
                        if let plan {
                            Text(AIConfig.minuteLabel(plan.peakMinute))
                                .font(Theme.mono(13, .medium))
                                .foregroundColor(.white)
                                .frame(width: 84, alignment: .leading)
                            ProgressBar(value: plan.probability)
                            Text("\(Int(plan.probability * 100))%")
                                .font(Theme.mono(11))
                                .foregroundColor(Theme.secondary)
                                .frame(width: 40, alignment: .trailing)
                        } else {
                            Text("no clear habit")
                                .font(Theme.mono(12))
                                .foregroundColor(Theme.tertiary)
                            Spacer()
                        }
                    }
                    .frame(minHeight: 22)
                }
            }
        }
    }

    private var coachPanel: some View {
        OutlineRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "COACH · ON-DEVICE")
                    Button(coach.isGenerating ? "THINKING…" : "REFRESH") {
                        Task { await coach.refreshIfStale(facts: habit.coachFacts(), force: true) }
                    }
                    .font(Theme.mono(11, .bold))
                    .foregroundColor(.white)
                    .disabled(coach.isGenerating)
                    .fixedSize()
                }
                if coach.isGenerating && coach.insight == nil {
                    ProgressView().tint(.white)
                }
                Text(coach.insight ?? "Tap REFRESH for a personal read of your habit map.")
                    .font(Theme.mono(13))
                    .foregroundColor(coach.insight == nil ? Theme.secondary : .white)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = coach.lastError {
                    Text(error)
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.warning)
                }
            }
        }
        .task { await coach.refreshIfStale(facts: habit.coachFacts()) }
    }

    /// When today's nudge will fire, mirroring NudgeScheduler's own plan.
    private var nudgeLabel: String {
        guard habit.config.isEnabled else { return "AI mode is off" }
        guard watchedCount > 0 else { return "Pick apps to watch first" }
        guard !notificationsBlocked else { return "Notifications are off" }
        if habit.isLearning { return "Still learning — no nudge yet" }
        guard let plan = habit.todayPlan else { return "No nudge today" }
        // An after-midnight peak can fire on the next calendar day.
        let calendarToday = Calendar.current.component(.weekday, from: Date())
        let day = plan.fireWeekday == calendarToday
            ? "today"
            : Calendar.current.weekdaySymbols[plan.fireWeekday - 1]
        return "\(AIConfig.minuteLabel(plan.fireMinute)) \(day)"
    }

    private func refreshNotificationStatus() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Thin hairline progress bar in the house style.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}

// MARK: - Weekday helpers (UI)

enum WeekdayHelper {
    /// Display order Sun→Sat with Calendar weekday numbers (1=Sun … 7=Sat).
    static let ordered: [(weekday: Int, short: String)] = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")
    ]

    static func summary(_ weekdays: [Int]) -> String {
        let set = Set(weekdays)
        if set == Set(1...7) { return "Every day" }
        if set == Set([2, 3, 4, 5, 6]) { return "Weekdays" }
        if set == Set([1, 7]) { return "Weekends" }
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return weekdays.sorted().compactMap { names[$0] }.joined(separator: " ")
    }
}
