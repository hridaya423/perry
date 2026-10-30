import SwiftUI

struct NotchShape: Shape {
    static let closed = NotchShape(topRadius: 6, bottomRadius: 14)
    static let open = NotchShape(topRadius: 18, bottomRadius: 22)

    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius
        let bottom = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension NotchShape {
    func surface(crown: CGFloat, lifted: Bool = true) -> some View {
        fill(PerryTheme.Colors.canvas)
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: PerryTheme.Colors.crown, location: crown / (crown + 80)),
                                       .init(color: PerryTheme.Colors.crown.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: crown + 80)
            }
            .clipShape(self)
            .overlay(stroke(LinearGradient(colors: [PerryTheme.Colors.veil(0), PerryTheme.Colors.veil(0.16)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 2, y: 1)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: 18, y: 8)
    }
}
