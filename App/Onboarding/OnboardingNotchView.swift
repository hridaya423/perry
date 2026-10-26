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
                if director.beat != .hello {
                    OnboardingProgress(current: beatIndex, count: OnboardingDirector.Beat.allCases.count)
                        .animation(PerryTheme.Motion.progress, value: beatIndex)
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
            .frame(height: 32)
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
            .padding(.bottom, 10)
        }
        .frame(
            maxWidth: PerryTheme.Sizing.onboardingContentWidth,
            maxHeight: PerryTheme.Sizing.onboardingContentHeight,
            alignment: .top
        )
        .foregroundStyle(PerryTheme.Colors.text)
        .background { SketchbookGrain() }
        .tint(PerryTheme.Colors.accent)
        .animation(reduceMotion ? PerryTheme.Motion.panelStateChange : PerryTheme.Motion.enter, value: director.beat)
    }

    private var beatTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let lead: CGFloat = director.direction == .forward ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: BeatShift(x: 36 * lead, blur: 4, opacity: 0), identity: BeatShift()),
            removal: .modifier(active: BeatShift(x: -24 * lead, blur: 4, opacity: 0), identity: BeatShift())
                .animation(PerryTheme.Motion.exit)
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

struct OnboardingCrown: View {
    @ObservedObject var director: OnboardingDirector

    var body: some View {
        if director.beat == .hello {
            NotchPeek()
                .offset(y: 35)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
