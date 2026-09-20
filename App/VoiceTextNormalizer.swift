import Foundation
import PerryCore

enum VoiceTextNormalizer {
    static func normalize(_ text: String, frontmostBundleID: String?, supportDirectory: URL?) throws -> String {
        VoiceTextPolicy.normalize(
            text,
            frontmostBundleID: frontmostBundleID,
            dictionary: try VoiceDictionaryStore(supportDirectory: supportDirectory).entries()
        )
    }
}
