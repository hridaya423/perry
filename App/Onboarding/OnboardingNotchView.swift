import SwiftUI
import PerryOverlay

struct OnboardingNotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel

    private var beatIndex: Int {
        director.beat.flatMap { OnboardingDirector.Beat.allCases.firstIndex(of: $0) } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if director.beat == .hello {
                    NotchPeek()
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    OnboardingProgress(current: beatIndex, count: OnboardingDirector.Beat.allCases.count)
                        .animation(PerryTheme.Motion.enter, value: beatIndex)
                }
                HStack {
                    if director.canGoBack {
                        Button { director.goBack() } label: {
                            Label("Back", systemImage: "chevron.left").imageScale(.small)
                        }
                        .buttonStyle(OnboardingLinkStyle())
                        .transition(.opacity)
                    }
                    Spacer()
                    WindowControlButton(systemImage: "xmark", label: "Close") { director.close() }
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
        .foregroundStyle(PerryTheme.Colors.text)
        .background { SketchbookGrain() }
        .tint(PerryTheme.Colors.accent)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : PerryTheme.Motion.enter, value: director.beat)
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
