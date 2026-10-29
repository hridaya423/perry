import SwiftUI

/// Other agents' pointers (§5 ghost cursors): a dashed-outline glass
/// pointer per external cursor plus its caption, so parallel workers are
/// visible without ever reading as the user's own cursor.
struct GhostCursorLayer: View {
    @ObservedObject var state: PerryCursorState
    let screenFrame: CGRect

    private var cursorsOnThisScreen: [PerryExternalCursor] {
        state.externalSecondaryCursors.filter { cursor in
            screenFrame.contains(cursor.screenLocation)
        }
    }

    var body: some View {
        ForEach(cursorsOnThisScreen) { cursor in
            ghostCursor(cursor)
        }
    }

    @ViewBuilder
    private func ghostCursor(_ cursor: PerryExternalCursor) -> some View {
        let local = PerryOverlaySpace.localPoint(cursor.screenLocation, in: screenFrame)
        let position = PerryOverlaySpace.characterCenter(pointingAt: local, size: 30)
        let color = perryAccentColor(cursor.accentHex)
        ZStack {
            // §5 ghost morph: another agent's pointer is a dashed outline,
            // never filled — reads as Perry's, not the user's.
            PerryCharacter(mood: .working, size: 30)
                .shadow(color: color.opacity(0.90), radius: 10, x: 0, y: 0)
                .position(position)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))

            if let caption = cursor.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                PerryAnchoredCaption(
                    caption: caption,
                    anchor: CGRect(x: position.x - 15, y: position.y - 15, width: 30, height: 30),
                    avoiding: state.captionLayout(in: screenFrame).obstacles,
                    screenFrame: screenFrame
                )
            }
        }
        .animation(PerryOverlayTheme.Motion.travelFast, value: cursor.screenLocation)
    }
}
