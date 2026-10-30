import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

extension AppController {
    func saveInterview(_ facts: InterviewModel.Facts) async {
        guard let files = memoryFiles else { return }
        for (field, value) in [("Name", facts.name), ("Work", facts.work), ("Apps", facts.apps), ("Learning goal", facts.goal), ("Answer style", facts.style)] {
            try? files.setProfileField(field, value)
        }
        if !facts.name.isEmpty, !facts.spoken.isEmpty {
            try? PronunciationStore(directory: storageDirectory).set(Pronunciation(written: facts.name, spoken: facts.spoken))
        }
        await setMemoryEnabled(true)
    }

    func importMemory(from service: InterviewModel.MemoryService) async -> String? {
        let page = URL(string: service == .chatGPT ? "https://chatgpt.com/#settings/Personalization" : "https://claude.ai/settings/capabilities")!
        let browser = NSWorkspace.shared.urlForApplication(toOpen: page)
        let bundleID = browser.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let browserName = browser?.deletingPathExtension().lastPathComponent ?? "the browser"
        let goal = switch service {
        case .chatGPT: """
            ChatGPT’s settings are open in \(browserName), on Personalization. Open the memory summary, or Manage memories. \
            It opens in a dialog over the settings. ChatGPT can take up to a minute to write the summary, so look again every few \
            seconds until the text appears. Read the text inside the dialog, not the page behind it, and scroll inside the dialog \
            to its end if it is long. Give all of it back word for word as your answer, with nothing added. Do not change or delete anything. \
            If the page asks me to sign in or log in, answer exactly SIGNED_OUT.
            """
        case .claude: """
            Claude’s settings are open in \(browserName), on Capabilities. Find Memory and open what Claude remembers about me. \
            It may open in a dialog: read the text inside the dialog, not the page behind it, and scroll inside it to the end. \
            Wait until it has loaded, then give all of it back word for word as your answer, with nothing added. \
            Do not change or delete anything. If the page asks me to sign in or log in, answer exactly SIGNED_OUT.
            """
        }
        for attempt in 0..<3 {
            if attempt > 0 {
                voice.speak("Sign in to \(service.rawValue), and I’ll try again.")
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return nil }
            }
            NSWorkspace.shared.open(page)
            try? await Task.sleep(for: .seconds(3))
            let target = bundleID.map { CuaTargetHint(bundleID: $0) }
            let answer = await agentCoordinator.runToEnd(threadID: UUID(), goal: goal, kind: .doTask, target: target).answer
            let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.contains("SIGNED_OUT") { continue }
            return reply.isEmpty ? nil : reply
        }
        return nil
    }

    func saveImportedFacts(_ facts: [LearnedFact]) async {
        guard !facts.isEmpty else { return }
        await setMemoryEnabled(true)
        for fact in facts {
            _ = await memoryStore.remember(MemoryRecord(category: .aboutYou, summary: fact.text, subject: fact.subject))
        }
    }
}
