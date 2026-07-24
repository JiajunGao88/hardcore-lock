//
//  BlockModesView.swift
//  Hardcord Lock App
//
//  Mode switcher (NOW / SCHEDULE / AI) and the two new mode screens.
//  Visual language matches the rest of the app: black, monospaced, brutalist.
//

import SwiftUI
import FamilyControls

// MARK: - Mode

enum BlockMode: String, CaseIterable, Identifiable {
    case now = "NOW"
    case schedule = "SCHEDULE"
    case ai = "AI"
    var id: String { rawValue }
}

// MARK: - Mode picker bar

struct ModePickerBar: View {
    @Binding var mode: BlockMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BlockMode.allCases) { m in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { mode = m } }) {
                    Text(m.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(mode == m ? .black : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == m ? Color.white : Color.clear)
                }
            }
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 24)
    }
}

// MARK: - Small shared bits

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OutlineRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
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
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.gray)
            HStack(spacing: 6) {
                Picker("", selection: $hour) {
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

                Picker("", selection: $minute) {
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

// MARK: - SCHEDULE mode

struct ScheduleModeView: View {
    @ObservedObject var scheduleManager = ScheduleManager.shared
    @ObservedObject var storeManager = StoreManager.shared

    /// Present the Pro paywall (feature is Pro-gated).
    var requestPaywall: () -> Void

    @State private var editing: ScheduleConfig?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                SectionLabel(text: "AUTO-BLOCK ON A SCHEDULE")
                Spacer()
            }
            .padding(.horizontal, 24)

            if let warning = scheduleManager.lastBudgetWarning {
                Text(warning)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }

            ScrollView {
                VStack(spacing: 12) {
                    if scheduleManager.schedules.isEmpty {
                        Text("No schedules yet.\nCreate one to block apps automatically\nat the times you choose.")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    } else {
                        ForEach(scheduleManager.schedules) { config in
                            scheduleRow(config)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }

            Button(action: {
                guard storeManager.canUseSchedule else { requestPaywall(); return }
                editing = nil
                showEditor = true
            }) {
                Text("+ NEW SCHEDULE")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
            }
            .padding(.horizontal, 24)

            if !storeManager.purchasedPro {
                Text(storeManager.scheduleTrialsRemaining > 0
                     ? "FREE TRIAL: \(storeManager.scheduleTrialsRemaining)/\(TrialGate.limit) SCHEDULED SESSIONS LEFT"
                     : "TRIAL USED UP — SCHEDULE MODE IS A PRO FEATURE")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
        .padding(.bottom, 16)
        .sheet(isPresented: $showEditor) {
            ScheduleEditorView(existing: editing)
        }
    }

    private func scheduleRow(_ config: ScheduleConfig) -> some View {
        Button(action: {
            guard storeManager.canUseSchedule else { requestPaywall(); return }
            editing = config
            showEditor = true
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(config.name.uppercased())
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        if scheduleManager.isActiveNow(config) {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.white)
                        }
                    }
                    Text(scheduleSummary(config))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        if newValue && !storeManager.canUseSchedule { requestPaywall(); return }
                        scheduleManager.setEnabled(config.id, newValue)
                    }
                ))
                .labelsHidden()
                .tint(.white)
            }
            .padding(16)
            .overlay(Rectangle().stroke(Color.white.opacity(config.isEnabled ? 0.35 : 0.15), lineWidth: 1))
        }
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

    private let id: String

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

    /// iOS rejects monitoring intervals shorter than 15 minutes — validate here
    /// so the user gets a clear message instead of a generic system error.
    private var windowIssue: String? {
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        let minLen = 15
        if end == 0 {                        // "until midnight" — same-day
            if 1440 - start < minLen { return "Window must be at least 15 minutes." }
        } else if end <= start {             // overnight split into two halves
            if 1440 - start < minLen { return "Overnight start must be 23:45 or earlier (iOS minimum window is 15 min)." }
            if end < minLen { return "Overnight end must be 00:15 or later (iOS minimum window is 15 min)." }
        } else if end - start < minLen {
            return "Window must be at least 15 minutes."
        }
        return nil
    }

    private var canSave: Bool { appCount > 0 && !weekdays.isEmpty && windowIssue == nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Text(existing == nil ? "NEW SCHEDULE" : "EDIT SCHEDULE")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.top, 20)

                    // Name
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "NAME")
                        TextField("", text: $name)
                            .font(.system(size: 17, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .tint(.white)
                            .padding(14)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }

                    // Apps
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "APPS TO BLOCK")
                        Button(action: { showPicker = true }) {
                            HStack {
                                Text(appCount == 0 ? "None selected" : "\(appCount) selected")
                                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                Spacer()
                                Text(">").foregroundColor(.gray)
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                            }
                            .padding(14)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        }
                    }

                    // Weekdays
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "DAYS")
                        HStack(spacing: 6) {
                            ForEach(WeekdayHelper.ordered, id: \.weekday) { item in
                                let on = weekdays.contains(item.weekday)
                                Button(action: {
                                    if on { weekdays.remove(item.weekday) } else { weekdays.insert(item.weekday) }
                                }) {
                                    Text(item.short)
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(on ? .black : .gray)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(on ? Color.white : Color.clear)
                                        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            quickButton("WEEKDAYS") { weekdays = [2, 3, 4, 5, 6] }
                            quickButton("EVERY DAY") { weekdays = Set(1...7) }
                        }
                    }

                    // Time window
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "TIME WINDOW")
                        HStack(spacing: 12) {
                            TimeWheel(title: "FROM", hour: $startHour, minute: $startMinute)
                            TimeWheel(title: "TO", hour: $endHour, minute: $endMinute)
                        }
                        .frame(maxWidth: .infinity)
                        if let issue = windowIssue {
                            Text(issue)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.orange.opacity(0.9))
                        } else if isOvernight {
                            Text("Overnight window — ends next morning.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                    }

                    // Cadence
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "REPEAT")
                        HStack {
                            Text(everyNWeeks <= 1 ? "Every week" : "Every \(everyNWeeks) weeks")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            Stepper("", value: $everyNWeeks, in: 1...8).labelsHidden().tint(.white)
                        }
                        .padding(14)
                        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }

                    // Save
                    Button(action: save) {
                        Text("SAVE SCHEDULE")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.white)
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)

                    if existing != nil {
                        Button(action: deleteSchedule) {
                            Text("DELETE")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }

                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 24)
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
    }

    private func quickButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
    }

    private func save() {
        var cfg = existing ?? ScheduleConfig(id: id)
        cfg.name = name.isEmpty ? "Focus block" : name
        cfg.weekdays = weekdays.sorted()
        cfg.startHour = startHour
        cfg.startMinute = startMinute
        cfg.endHour = endHour
        cfg.endMinute = endMinute
        cfg.everyNWeeks = everyNWeeks
        cfg.isEnabled = true
        if existing == nil || cfg.anchorEpoch == 0 {
            cfg.anchorEpoch = Date().timeIntervalSince1970
        }
        scheduleManager.upsert(cfg, selection: selection)
        dismiss()
    }

    private func deleteSchedule() {
        scheduleManager.delete(id)
        dismiss()
    }
}

// MARK: - AI mode

struct AIModeView: View {
    @ObservedObject var habit = HabitEngine.shared
    @ObservedObject var storeManager = StoreManager.shared

    var requestPaywall: () -> Void
    /// Start a challenge lock now (handled by ContentView so paywall/free logic applies).
    var startChallenge: () -> Void

    @State private var showPicker = false
    @State private var localSelection = HabitEngine.shared.watchedSelection

    private var watchedCount: Int {
        let s = habit.watchedSelection
        return s.applicationTokens.count + s.categoryTokens.count + s.webDomainTokens.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Intro
                VStack(alignment: .leading, spacing: 8) {
                    Text("PREDICT & PREVENT")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("We learn when you reach for distracting apps, then nudge you to lock in BEFORE the urge hits. On-device. Private.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Enable
                OutlineRow {
                    HStack {
                        Text("AI MODE")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { habit.config.isEnabled },
                            set: { v in
                                if v && !storeManager.canUseAI { requestPaywall(); return }
                                if v && watchedCount == 0 { showPicker = true }
                                habit.setEnabled(v)
                            }
                        ))
                        .labelsHidden().tint(.white)
                    }
                }

                // Watched apps
                Button(action: {
                    localSelection = habit.watchedSelection
                    showPicker = true
                }) {
                    OutlineRow {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("APPS TO WATCH")
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)
                                Text(watchedCount == 0 ? "None selected" : "\(watchedCount) selected")
                                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            Spacer()
                            Text(">").foregroundColor(.gray)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                        }
                    }
                }

                // Lead time + duration
                HStack(spacing: 12) {
                    leadTimePicker
                    durationPicker
                }

                // Insight panel
                insightPanel

                // Challenge now
                Button(action: {
                    if !storeManager.canUseAI { requestPaywall(); return }
                    if watchedCount == 0 { showPicker = true; return }
                    startChallenge()
                }) {
                    Text("CHALLENGE ME NOW")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                }

                if !storeManager.purchasedPro {
                    Text(storeManager.aiTrialsRemaining > 0
                         ? "FREE TRIAL: \(storeManager.aiTrialsRemaining)/\(TrialGate.limit) AI LOCKS LEFT"
                         : "TRIAL USED UP — AI MODE IS A PRO FEATURE")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                }

                #if DEBUG
                Button(action: { habit.resetLearning() }) {
                    Text("🧪 Reset learning")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.red.opacity(0.6))
                }
                #endif

                Color.clear.frame(height: 12)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $localSelection)
        .onChange(of: showPicker) { _, isShowing in
            if !isShowing { habit.saveWatchedSelection(localSelection) }
        }
    }

    private var leadTimePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "NUDGE LEAD")
            Menu {
                ForEach([5, 10, 15, 20, 30], id: \.self) { m in
                    Button("\(m) min before") {
                        var c = habit.config; c.leadMinutes = m; habit.updateConfig(c)
                    }
                }
            } label: {
                HStack {
                    Text("\(habit.config.leadMinutes) min")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text("▾").foregroundColor(.gray)
                }
                .padding(12)
                .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
        }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "LOCK FOR")
            Menu {
                ForEach([(30, "30m", 1800), (60, "1h", 3600), (120, "2h", 7200), (180, "3h", 10800)], id: \.0) { item in
                    Button(item.1) {
                        var c = habit.config; c.lockDurationSeconds = item.2; habit.updateConfig(c)
                    }
                }
            } label: {
                HStack {
                    Text(durationLabel(habit.config.lockDurationSeconds))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text("▾").foregroundColor(.gray)
                }
                .padding(12)
                .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
        }
    }

    private func durationLabel(_ s: Int) -> String {
        s % 3600 == 0 ? "\(s / 3600)h" : "\(s / 60)m"
    }

    private var insightPanel: some View {
        OutlineRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "YOUR HABIT MAP")
                    Spacer()
                    Text("\(habit.daysObserved)d learned")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                }

                if habit.isLearning {
                    Text("Learning your habits… need \(habit.config.minObservationDays) days of data. Keep AI mode on.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.gray)
                } else if let peak = habit.predictedPeakLabel {
                    Text("PEAK: \(peak)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("You'll be nudged \(habit.config.leadMinutes) min before.")
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)
                } else {
                    Text("No strong pattern yet — your usage is fairly even. We'll keep watching.")
                        .font(.system(size: 13, design: .monospaced)).foregroundColor(.gray)
                }

                histogram
            }
        }
    }

    private var histogram: some View {
        let freqs = habit.frequencies
        let peak = habit.predictedPeakIndex
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<AIConfig.displayBins, id: \.self) { i in
                let f = i < freqs.count ? freqs[i] : 0
                let hour = AIConfig.displayBinStartHour(i)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(peak == i ? Color.white : Color.white.opacity(0.3))
                        .frame(height: max(3, CGFloat(f) * 64))
                    // Label every 3rd hour to avoid clutter (6, 9, 12, …).
                    Text(hour % 3 == 0 ? "\(hour)" : " ")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 92, alignment: .bottom)
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
