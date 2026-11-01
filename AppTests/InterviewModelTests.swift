import AppKit
import PerryBrain
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class InterviewModelTests: XCTestCase {
    private func model(complete: ((String) async throws -> String)? = nil, saved: @escaping (InterviewModel.Facts) -> Void = { _ in }) -> InterviewModel {
        InterviewModel(name: "Ada", effects: .init(complete: complete, save: saved, listensAfterSpeaking: false))
    }

    private static let emptyProfile: (String) async throws -> String = { prompt in
        prompt.contains("Reply with JSON only, exactly this shape")
            ? #"{"work":null,"apps":[],"learningGoal":null}"#
            : prompt.contains("Reply with the question or NONE") ? "NONE" : "ok"
    }

    private func settle(_ interview: InterviewModel) async throws {
        for _ in 0..<300 where interview.thinking || interview.extracting { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testTheIntroductionAsksOnlyForWhatItLeftOut() async throws {
        let interview = model(complete: { prompt in
            prompt.contains("Reply with JSON only, exactly this shape")
                ? #"{"work":"Product designer","apps":["Figma","Notion"],"learningGoal":null}"#
                : prompt.contains("Reply with the question or NONE") ? "NONE" : prompt.contains("facts") ? #"{"facts": []}"# : "Spanish, nice."
        })
        XCTAssertEqual(interview.step, .pronounce)
        interview.confirmPronunciation()
        XCTAssertEqual(interview.questions, [ProfileExtraction.intro])
        interview.answer("I'm a product designer at a small studio, mostly in Figma and Notion")
        try await settle(interview)
        XCTAssertEqual(interview.step, .question(1))
        XCTAssertEqual(interview.questions, [ProfileExtraction.intro, "What do you want to learn first?"])
        interview.answer("Spanish")
        XCTAssertEqual(interview.step, .summary)
        try await settle(interview)
        XCTAssertEqual(interview.facts, .init(name: "Ada", work: "Product designer", apps: "Figma, Notion", goal: "Spanish"))
    }

    func testACompleteIntroductionEarnsOneFollowUpInstead() async throws {
        let interview = model(complete: { prompt in
            prompt.contains("Reply with JSON only, exactly this shape")
                ? #"{"work":"Startup founder","apps":["Linear"],"learningGoal":"Sales"}"#
                : prompt.contains("Reply with the question or NONE") ? "Are you raising money right now?" : "ok"
        })
        interview.confirmPronunciation()
        interview.answer("I run a tiny startup that sells software to dentists, live in Linear, and want to get better at sales")
        try await settle(interview)
        XCTAssertEqual(interview.step, .question(1))
        XCTAssertEqual(interview.questions[1], "Are you raising money right now?")
        XCTAssertEqual(interview.kind(at: 1), .followUp)
        XCTAssertEqual(interview.questionCount, 2)
    }

    func testAnIntroductionWithoutABrainEndsTheQuestions() {
        let interview = model()
        interview.confirmPronunciation()
        interview.answer("I teach chemistry and want to learn Figma")
        XCTAssertEqual(interview.step, .done)
        XCTAssertEqual(interview.questions, [ProfileExtraction.intro])
    }

    func testAnUnreadableReplyNeverFallsBackToFixedQuestions() async throws {
        let interview = model(complete: { _ in "Sure! Here is what I found." })
        interview.confirmPronunciation()
        interview.answer("I teach chemistry and want to learn Figma")
        try await settle(interview)
        XCTAssertEqual(interview.step, .done)
        XCTAssertEqual(interview.questions, [ProfileExtraction.intro])
    }

    func testTwoShortAnswersEndTheQuestions() async throws {
        let interview = model(complete: Self.emptyProfile)
        interview.confirmPronunciation()
        interview.answer("Hi, I'm Ada")
        try await settle(interview)
        XCTAssertEqual(interview.questions.count, 4)
        interview.answer("Student")
        interview.answer(nil)
        XCTAssertEqual(interview.step, .summary)
        XCTAssertEqual(interview.facts.work, "Student")
    }

    func testTheTimeBudgetEndsTheQuestions() async throws {
        var now = Date()
        let interview = InterviewModel(name: "Ada", effects: .init(complete: Self.emptyProfile, now: { now }))
        interview.confirmPronunciation()
        interview.answer("I teach")
        try await settle(interview)
        now = now.addingTimeInterval(120)
        interview.answer("I teach chemistry at a big school")
        XCTAssertEqual(interview.step, .summary)
    }

    func testPronunciationIsKeptAndSpoken() {
        var spoken: [String] = []
        let interview = InterviewModel(name: "Hridya", effects: .init(sayName: { spoken.append($0) }))
        interview.sayName()
        interview.draft = "Hrid-yah"
        interview.confirmPronunciation()
        interview.sayName()
        XCTAssertEqual(spoken, ["Hridya", "Hrid-yah"])
        XCTAssertEqual(interview.facts.spoken, "Hrid-yah")
    }

    func testPerryImportsMemoryItselfAndKeepsCheckedFacts() async throws {
        var kept: [LearnedFact] = []
        var asked: [InterviewModel.MemoryService] = []
        let interview = InterviewModel(name: "Ada", effects: .init(
            complete: { _ in #"{"facts": [{"text": "Designs for a fintech app", "kind": "profile", "subject": "work"}, {"text": "Likes short answers", "kind": "preference", "subject": "style"}]}"# },
            saveNotes: { kept = $0 },
            listensAfterSpeaking: false,
            importMemory: { asked.append($0); return "- designs for a fintech app\n- likes short answers" }
        ))
        interview.confirmPronunciation()
        interview.answer(nil)
        XCTAssertEqual(interview.step, .importOffer)
        interview.chooseImport(.chatGPT)
        XCTAssertEqual(interview.step, .importConsent(.chatGPT))
        XCTAssertEqual(asked, [])
        interview.allowImport(true)
        for _ in 0..<300 where interview.step != .summary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(asked, [.chatGPT])
        XCTAssertEqual(interview.notes.map(\.fact.text), ["Designs for a fintech app", "Likes short answers"])
        XCTAssertTrue(interview.spokenSummary.hasSuffix("Did I get that right?"))
        interview.notes[1].kept = false
        interview.confirmSummary()
        XCTAssertEqual(kept.map(\.text), ["Designs for a fintech app"])
    }

    func testSkippingTheImportStopsTheAgentAndKeepsNothingItLaterReturns() async throws {
        var cancelled = false
        let interview = InterviewModel(name: "Ada", effects: .init(
            complete: { _ in #"{"facts": [{"text": "Designs for a fintech app", "kind": "profile", "subject": "work"}]}"# },
            listensAfterSpeaking: false,
            importMemory: { _ in
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true }
                return "- designs for a fintech app"
            }
        ))
        interview.confirmPronunciation()
        interview.answer(nil)
        interview.chooseImport(.chatGPT)
        interview.allowImport(true)
        try await Task.sleep(for: .milliseconds(50))
        interview.cancelImport()
        XCTAssertEqual(interview.step, .done)
        for _ in 0..<100 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cancelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(interview.notes.isEmpty)
        XCTAssertEqual(interview.step, .done)
    }

    func testBackFromTheConsentStepLeavesTheInterviewAtTheConsentStep() {
        let interview = InterviewModel(name: "Ada", effects: .init(complete: { _ in "" }, listensAfterSpeaking: false, importMemory: { _ in nil }))
        interview.confirmPronunciation()
        interview.answer(nil)
        interview.chooseImport(.chatGPT)
        interview.suspendImport()
        XCTAssertEqual(interview.step, .importConsent(.chatGPT))
    }

    func testBackDuringTheImportStopsTheAgentAndReturnsToTheConsentStep() async throws {
        var cancelled = false
        let interview = InterviewModel(name: "Ada", effects: .init(
            complete: { _ in #"{"facts": [{"text": "Designs for a fintech app", "kind": "profile", "subject": "work"}]}"# },
            listensAfterSpeaking: false,
            importMemory: { _ in
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true }
                return "- designs for a fintech app"
            }
        ))
        interview.confirmPronunciation()
        interview.answer(nil)
        interview.chooseImport(.chatGPT)
        interview.allowImport(true)
        try await Task.sleep(for: .milliseconds(50))
        interview.suspendImport()
        XCTAssertEqual(interview.step, .importConsent(.chatGPT))
        for _ in 0..<100 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cancelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(interview.notes.isEmpty)
        XCTAssertEqual(interview.step, .importConsent(.chatGPT))
    }

    func testDecliningTheImportGoesStraightToTheSummary() {
        let interview = InterviewModel(name: "Ada", effects: .init(complete: { _ in "" }, listensAfterSpeaking: false, importMemory: { _ in nil }))
        interview.confirmPronunciation()
        interview.answer(nil)
        XCTAssertEqual(interview.step, .importOffer)
        interview.chooseImport(InterviewModel.MemoryService.heard("neither, thanks"))
        XCTAssertEqual(interview.step, .done)
    }

    func testSayingNoToOpeningMemoryOpensNothing() {
        var asked: [InterviewModel.MemoryService] = []
        let interview = InterviewModel(name: "Ada", effects: .init(complete: { _ in "" }, listensAfterSpeaking: false,
                                                                   importMemory: { asked.append($0); return nil }))
        interview.confirmPronunciation()
        interview.answer(nil)
        interview.chooseImport(.claude)
        interview.allowImport(InterviewModel.heardYes("no, not now") ?? true)
        XCTAssertEqual(interview.step, .done)
        XCTAssertEqual(asked, [])
    }

    func testASpokenCorrectionFixesOnlyWhatItNames() async throws {
        var saved: InterviewModel.Facts?
        let interview = model(complete: { prompt in
            prompt.contains("I understood") ? #"{"work":"Chemistry teacher","apps":[],"learningGoal":null}"# : try await Self.emptyProfile(prompt)
        }, saved: { saved = $0 })
        interview.confirmPronunciation()
        interview.answer("Hi")
        try await settle(interview)
        interview.answer("I study chemistry at university")
        interview.answer("Figma")
        interview.answer("Spanish")
        try await settle(interview)
        XCTAssertEqual(interview.step, .summary)
        interview.correct("No, I teach chemistry now")
        try await settle(interview)
        XCTAssertEqual(interview.step, .done)
        XCTAssertEqual(saved?.work, "Chemistry teacher")
        XCTAssertEqual(saved?.apps, "Figma")
        XCTAssertEqual(saved?.goal, "Spanish")
    }

    func testHearingYesNoAndAService() {
        XCTAssertEqual(InterviewModel.heardYes("Yeah, that's right"), true)
        XCTAssertEqual(InterviewModel.heardYes("Not quite"), false)
        XCTAssertEqual(InterviewModel.heardYes("Yes, but I moved to Berlin"), false)
        XCTAssertNil(InterviewModel.heardYes("Hmm"))
        XCTAssertEqual(InterviewModel.MemoryService.heard("I use ChatGPT mostly"), .chatGPT)
        XCTAssertEqual(InterviewModel.MemoryService.heard("Claude"), .claude)
        XCTAssertNil(InterviewModel.MemoryService.heard("neither"))
    }

    func testCancellingSavesNothing() {
        var saves = 0
        let interview = model(complete: { _ in "" }, saved: { _ in saves += 1 })
        interview.confirmPronunciation()
        interview.answer("Founder")
        interview.cancel()
        XCTAssertEqual(interview.step, .done)
        interview.confirmSummary()
        XCTAssertEqual(saves, 0)
    }

    func testSkippingEveryQuestionSavesNothing() {
        var saves = 0
        let interview = model(complete: { _ in "" }, saved: { _ in saves += 1 })
        interview.confirmPronunciation()
        interview.answer(nil)
        XCTAssertEqual(interview.step, .done)
        XCTAssertEqual(saves, 0)
    }

    func testConfirmingWritesThePinnedProfileAndTurnsMemoryOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController.testing(directory: directory)
        defer { controller.subsystems.notchPresence.stop() }
        let before = await controller.currentMemoryConfiguration()
        XCTAssertFalse(before.enabled)
        await controller.saveInterview(.init(name: "Ada", work: "Designer", apps: "Figma, Notion", goal: "", spoken: "Ay-da", style: "Short and direct"))
        let files = try XCTUnwrap(controller.memoryFiles)
        XCTAssertEqual(files.profileField("Name"), "Ada")
        XCTAssertEqual(files.profileField("Work"), "Designer")
        XCTAssertEqual(files.profileField("Apps"), "Figma, Notion")
        XCTAssertNil(files.profileField("Learning goal"))
        XCTAssertEqual(files.profileField("Answer style"), "Short and direct")
        XCTAssertEqual(PronunciationStore(directory: directory).entries().map(\.spoken), ["Ay-da"])
        let after = await controller.currentMemoryConfiguration()
        XCTAssertTrue(after.enabled)
    }

    func testTheConsentLineNamesACloudBrainOnly() {
        XCTAssertNil(InterviewModel.cloudLine(choice: .local, hasSavedChoice: true))
        XCTAssertNil(InterviewModel.cloudLine(choice: .chatGPT, hasSavedChoice: false))
        XCTAssertEqual(InterviewModel.cloudLine(choice: .chatGPT, hasSavedChoice: true), "I share your notes with ChatGPT when I answer.")
    }

    func testAppChipsComeFromInstalledApps() {
        let chips = InterviewModel.appChips { ["Figma", "Xcode", "Slack"].contains($0) }
        XCTAssertEqual(chips, ["Figma", "Xcode", "Slack"])
    }

    func testRenderEveryInterviewStep() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/onboarding-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let director = OnboardingDirector()
        director.start(resume: false)
        while director.beat != .interview { director.skip() }
        defer { director.stop() }
        let interview = InterviewModel(name: "Ada", effects: .init(
            complete: { prompt in
                prompt.contains("Reply with JSON only") || prompt.contains("Reply with the question or NONE")
                    ? try await Self.emptyProfile(prompt) : "Teaching chemistry, so labs fill your week."
            },
            listensAfterSpeaking: false,
            importMemory: { _ in try? await Task.sleep(for: .seconds(30)); return nil }
        ))
        let frame = NSRect(x: 0, y: 0, width: PerryTheme.Sizing.onboardingContentWidth, height: 380)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let host = NSHostingView(rootView: InterviewBeat(
            director: director,
            model: interview,
            cloudLine: "I share your notes with ChatGPT when I answer.",
            appChips: ["Notion", "Figma", "Xcode"]
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(width: frame.width, height: frame.height)
        .background(PerryTheme.Colors.canvas)
        .foregroundStyle(PerryTheme.Colors.text)
        .environment(\.colorScheme, .dark))
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        func shot(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("interview-\(name).png"))
        }
        try await shot("2-pronounce")
        interview.confirmPronunciation()
        try await shot("3-intro")
        interview.draft = "I teach chemistry at a big school and plan every lab in Notion and Figma."
        try await shot("3b-intro-typed")
        interview.answer(interview.draft)
        try await settle(interview)
        try await shot("4-work")
        interview.answer("Chemistry teacher")
        interview.draft = "Notion, Figma and Xcode"
        try await shot("5-apps-with-reaction")
        interview.answer(interview.draft)
        interview.answer("How options trading works")
        try await settle(interview)
        try await shot("6-import-offer")
        interview.chooseImport(.chatGPT)
        try await shot("6b-import-consent")
        interview.allowImport(true)
        try await shot("7-importing")
        interview.cancelImport()
        try await shot("8-summary")
    }

    func testSavedFactsStartWithACapital() {
        XCTAssertEqual(InterviewModel.capitalized("spanish"), "Spanish")
        XCTAssertEqual(InterviewModel.capitalized("iMovie and figma"), "iMovie and figma")
        XCTAssertEqual(InterviewModel.capitalized("GitHub"), "GitHub")
        XCTAssertEqual(InterviewModel.capitalized(nil), "")
    }
}
