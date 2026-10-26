import AppKit
import AVFoundation
import PerryCore
import PerryOverlay
import SwiftUI

struct VoiceSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$speechOutputEnabled.key) private var speechOutputEnabled = true
    @AppStorage(PerryPreferences.$speechRate.key) private var speechRate = 1.0
    @AppStorage(PerryPreferences.$speechVoiceIdentifier.key) private var speechVoiceIdentifier = ""
    @AppStorage(PerryPreferences.$voiceResponseCaptionOpacity.key) private var captionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Spoken replies") {
                Toggle("Speak replies", isOn: $speechOutputEnabled)
                    .settingsRowPadding()
                    .onChange(of: speechOutputEnabled) { _, _ in save() }
                    .onChange(of: speechVoiceIdentifier) { _, _ in save() }
                ForEach(voices, id: \.identifier) { voice in
                    SettingsDivider()
                    VoiceChoiceRow(
                        voice: voice,
                        isSelected: voice.identifier == (speechVoiceIdentifier.isEmpty ? VoiceController.speakingVoice?.identifier : speechVoiceIdentifier),
                        select: { speechVoiceIdentifier = voice.identifier },
                        preview: { controller.voice.previewSpeechVoice(voice) }
                    )
                    .settingsRowPadding()
                }
                SettingsDivider()
                SettingsRow(title: "Speed") {
                    InkSlider(value: $speechRate, range: 0.5...1.5, step: 0.1, label: "Speech speed")
                        .frame(width: 180)
                        .onChange(of: speechRate) { _, _ in save() }
                    Text("\(speechRate, specifier: "%.1f")×")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.speechRateValueWidth, alignment: .trailing)
                }
                SettingsDivider()
                SettingsRow(title: "More voices", detail: soundsRobotic ? "This voice sounds robotic. Enhanced and Premium voices sound far more natural, and they’re free." : "Download Enhanced and Premium voices in System Settings.") {
                    Button("Open…") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            SettingsCard(title: "Captions") {
                SettingsRow(title: "Caption opacity") {
                    InkSlider(value: $captionOpacity, range: 0.55...1.0, step: 0.05, label: "Caption opacity")
                        .frame(width: 180)
                    Text("\(captionOpacity * 100, specifier: "%.0f")%")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.captionOpacityValueWidth, alignment: .trailing)
                }
            }
            SettingsAdvanced(title: "Realtime voice") {
                RealtimeVoiceSection(onError: { error = $0 })
            }
        }
        .settingsErrorDialog($error)
    }

    private var voices: [AVSpeechSynthesisVoice] {
        let recommended = VoiceController.recommendedSpeechVoices()
        guard let chosen = AVSpeechSynthesisVoice(identifier: speechVoiceIdentifier),
              !recommended.contains(where: { $0.identifier == chosen.identifier }) else { return recommended }
        return [chosen] + recommended
    }

    private var soundsRobotic: Bool {
        (AVSpeechSynthesisVoice(identifier: speechVoiceIdentifier) ?? VoiceController.speakingVoice)?.quality == .default
    }

    private func save() {
        controller.voice.updateSpeechPreferences(
            SpeechPreferences(
                outputEnabled: speechOutputEnabled,
                rateMultiplier: speechRate,
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier
            )
        )
    }
}

private struct VoiceChoiceRow: View {
    let voice: AVSpeechSynthesisVoice
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(PerryTheme.Colors.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(voice.name)")
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(voice.name)
                        .font(PerryTheme.Scale.body)
                        .foregroundStyle(PerryTheme.Colors.text)
                    if let region {
                        Text(region)
                            .font(PerryTheme.Scale.body)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                    if let quality {
                        Text(quality)
                            .font(PerryTheme.Scale.meta)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(PerryTheme.Icon.inline)
                            .foregroundStyle(PerryTheme.Colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var region: String? {
        Locale(identifier: voice.language).region.flatMap { Locale.current.localizedString(forRegionCode: $0.identifier) }
    }

    private var quality: String? {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: nil
        }
    }
}
