import Foundation
@testable import PerryBrain

extension HTTPModelProvider {
    static func preset(
        _ presetID: String,
        baseURL: URL? = nil,
        key: String = "test",
        transport: any HTTPLineStreaming = URLSessionLineStreaming()
    ) -> HTTPModelProvider {
        let preset = ProviderPreset.preset(id: presetID)!
        return HTTPModelProvider(
            wire: preset.wire, id: ProviderID(rawValue: presetID), displayName: preset.name,
            baseURL: baseURL ?? preset.baseURL!, apiKeyProvider: { key }, models: preset.suggested!, transport: transport
        )
    }
}
