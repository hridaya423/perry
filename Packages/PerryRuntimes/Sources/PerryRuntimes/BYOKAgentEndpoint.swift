import Foundation
import CoreFoundation
import PerryCore

public struct BYOKAgentEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}
