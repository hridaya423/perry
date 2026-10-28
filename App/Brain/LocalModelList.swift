import PerryBrain
import SwiftUI

extension ModelOffer.Size {
    var title: String {
        switch self {
        case .recommended: "Recommended"
        case .small: "Small"
        }
    }

    var promise: String {
        switch self {
        case .recommended: "Finds the right button most often, even on busy screens."
        case .small: "Twice as fast and lighter on memory. Misses more on busy screens."
        }
    }
}

struct LocalModelList: View {
    let offers: [ModelOffer]
    let selected: String?
    let choose: (ModelOffer) -> Void

    static func gigabytes(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f GB", value) : String(format: "%.0f GB", value.rounded())
    }

    static func machineLine(_ profile: MachineProfile, freeGB: Double) -> String {
        "\(LocalBrainView.machineLine(profile)) memory, \(gigabytes(freeGB)) free on disk."
    }

    static func modelName(_ rung: ModelRung) -> String {
        rung.name.replacingOccurrences(of: "-", with: " ")
    }

    var body: some View {
        let best = ModelFit.recommended(offers)?.size
        ForEach(Array(offers.enumerated()), id: \.element.size) { index, offer in
            if index > 0 { SettingsDivider() }
            Button { choose(offer) } label: {
                HStack(alignment: .center, spacing: 10) {
                    RadioMark(selected: selected == offer.rung.id)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(offer.size.title)
                            Text(Self.modelName(offer.rung)).settingNote()
                            if offer.size == best, best != .recommended {
                                Text("Best for this Mac")
                                    .font(PerryTheme.Scale.meta)
                                    .foregroundStyle(PerryTheme.Colors.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(PerryTheme.Colors.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(detail(offer))
                            .settingNote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(Self.gigabytes(offer.rung.downloadGB))
                        .settingNote()
                        .monospacedDigit()
                }
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(offer.blocker != nil)
            .opacity(offer.blocker == nil ? 1 : 0.5)
            .accessibilityAddTraits(selected == offer.rung.id ? .isSelected : [])
        }
    }

    private func detail(_ offer: ModelOffer) -> String {
        switch offer.blocker {
        case nil: offer.size.promise
        case .memory: "Needs more memory than this Mac has."
        case .disk(let needed): "Needs \(Self.gigabytes(needed)) free on disk."
        }
    }
}
