import SwiftUI

struct HomeOnboardingView: View {
    @ObservedObject var director: OnboardingDirector
    let brain: BrainController?
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch director.beat {
            case .greet:
                Text("Welcome to Perry").font(.title2.weight(.semibold))
                Text("Connect your account and try a conversation. Screen access and practice can come later.")
                Button("Set up Perry") { director.skip() }
                    .buttonStyle(.borderedProminent)
            case .brainChoice:
                if let brain {
                    HomeConnectionView(brain: brain, onConnected: { director.noteBrainChoiceMade() }, openSettings: openSettings)
                }
                Button("Set up a model later") { director.skip() }
            case .firstTalk:
                Text("Try your first conversation").font(.headline)
                if let brain { HomeConnectionView(brain: brain, openSettings: openSettings) }
                Text("Ask a question below, then try a follow-up. You can type without granting screen or microphone access.")
                Button("Skip for now") { director.skip() }
            case .screenAccess:
                Text("Help in other apps").font(.headline)
                Text("Accessibility lets Perry point to and interact with controls. Screen Recording lets Perry understand visible content. Turn on Perry in each settings page when you’re ready.")
                VStack(alignment: .leading, spacing: 8) {
                    if director.permissions?.accessibility == true {
                        Label("Accessibility ready", systemImage: "checkmark.circle")
                    } else {
                        Button("Open Accessibility Settings") { director.openAccessibilitySettings() }
                    }
                    if director.permissions?.screenRecording.isUsable == true {
                        Label("Screen Recording ready", systemImage: "checkmark.circle")
                    } else {
                        Button("Open Screen Recording Settings") { director.openScreenRecordingSettings() }
                    }
                }
                .controlSize(.small)
                Button("Do this later") { director.skip() }
            case .practice:
                Text("Try Perry in a practice window").font(.headline)
                if director.practiceStarted, let step = director.practiceStep {
                    Text(OnboardingDirector.practiceScript(for: step))
                } else {
                    Text("Practice pointing, guidance, renaming with undo, and dictation using sample content.")
                    Button("Start practice") { director.startPractice() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Skip practice") { director.skip() }
            case .finale:
                Text("You can come back anytime").font(.headline)
                Text("Home keeps your conversations and ongoing work together. Open it with Control–Command–Space.")
                Button("Done") { director.skip() }
                    .buttonStyle(.borderedProminent)
            case nil:
                EmptyView()
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .task(id: director.beat) { await director.refreshPermissions() }
    }
}
