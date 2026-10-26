import SwiftUI
import PerryOverlay

struct OnboardingNotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel
    var onClose: (() -> Void)?

    private var beatIndex: Int {
        director.beat.flatMap { OnboardingDirector.Beat.allCases.firstIndex(of: $0) } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if director.beat == .greet {
                    NotchPeek()
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    OnboardingProgress(current: beatIndex, count: OnboardingDirector.Beat.allCases.count)
                        .animation(OnboardingStyle.enter, value: beatIndex)
                }
                HStack {
                    if director.canGoBack {
                        Button { director.goBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(OnboardingLinkStyle())
                        .transition(.opacity)
                    }
                    Spacer()
                    Button { onClose?() ?? model.deps.controller?.collapseNotch() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(OnboardingLinkStyle())
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                }
            }
            .frame(height: 36)
            .padding(.horizontal, 6)

            ZStack {
                HomeOnboardingView(director: director, model: model, brain: model.deps.brain) {
                    model.deps.controller?.openOnboardingSettings()
                }
                .id(director.beat)
                .transition(beatTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
        .frame(
            maxWidth: PerryTheme.Sizing.onboardingContentWidth,
            maxHeight: PerryTheme.Sizing.onboardingContentHeight,
            alignment: .top
        )
        .clipped()
        .foregroundStyle(PerryTheme.Colors.text)
        .background { SketchbookGrain() }
        .background(PerryTheme.Colors.crown)
        .tint(PerryTheme.Colors.accent)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : OnboardingStyle.enter, value: director.beat)
        .onAppear { director.resumePermissionPolling() }
        .onDisappear { director.pausePermissionPolling() }
    }

    private var beatTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let lead: CGFloat = director.direction == .forward ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: BeatShift(x: 36 * lead, blur: 10, opacity: 0), identity: BeatShift()),
            removal: .modifier(active: BeatShift(x: -24 * lead, blur: 8, opacity: 0), identity: BeatShift())
                .animation(.timingCurve(0.4, 0, 1, 1, duration: 0.2))
        )
    }
}

private struct BeatShift: ViewModifier {
    var x: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
