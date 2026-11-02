//
//  AICoach.swift
//  Hardcord Lock App
//
//  Optional language layer over HabitModel, using Apple's on-device Foundation
//  Models (iOS 26+, Apple Intelligence devices). It never predicts anything —
//  the model can't see Screen Time data either. It only turns HabitModel's
//  numbers into a short insight and a nudge line. Nothing leaves the device.
//  On unsupported devices it reports unavailable and the UI hides it.
//
//  APP TARGET ONLY — never add this file to the extension (memory budget).
//

import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AICoach: ObservableObject {
    static let shared = AICoach()

    @Published private(set) var insight: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private static let insightKey = "ai.coach.insight"
    private static let insightDayKey = "ai.coach.insightDay"

    private init() {
        insight = AppGroup.defaults.string(forKey: Self.insightKey)
    }

    /// True only when the system model is present, enabled and ready.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Regenerate at most once per day unless `force`d by the user.
    func refreshIfStale(facts: String, force: Bool = false) async {
        guard isAvailable, !isGenerating else { return }
        let today = AIStatsStore.dayKey(for: Date())
        if !force, insight != nil, AppGroup.defaults.string(forKey: Self.insightDayKey) == today { return }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let result = try await Self.generate(facts: facts)
                insight = result.insight
                AppGroup.defaults.set(result.insight, forKey: Self.insightKey)
                AppGroup.defaults.set(today, forKey: Self.insightDayKey)
                if let line = result.nudgeLine {
                    AppGroup.defaults.set(line, forKey: StoreKeys.coachNudgeLine)
                    NudgeScheduler.reschedule()
                }
            } catch {
                lastError = "The on-device coach couldn't answer right now."
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generate(facts: String) async throws -> (insight: String, nudgeLine: String?) {
        let instructions = """
        You are a blunt, supportive focus coach inside a minimalist app-blocking app. \
        Use ONLY the facts provided. Never invent numbers, app names or medical claims. \
        Plain text, no emoji, no markdown.
        """
        let session = LanguageModelSession(instructions: instructions)
        let insight = try await session.respond(to: """
        Facts about the user's distracting-app habit:
        \(facts)

        Write 2-3 short sentences: name the riskiest time(s), and one concrete, \
        doable suggestion for that time.
        """).content.trimmingCharacters(in: .whitespacesAndNewlines)

        let line = try await session.respond(to: """
        Now write ONE notification line, under 90 characters, that will be sent \
        shortly before the riskiest time to invite the user to lock their apps. \
        Imperative, direct. Return only the line.
        """).content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))

        return (insight, (line.isEmpty || line.count > 120) ? nil : line)
    }
    #endif
}
