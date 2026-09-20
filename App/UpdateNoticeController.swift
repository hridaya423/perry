import AppKit
import Sparkle

enum PerryUpdaterAvailability: Equatable {
    case available
    case unavailable(String)
}

struct PerryUpdaterConfiguration: Equatable {
    let feedURL: URL
    let publicKey: Data

    init?(info: [String: Any]) {
        guard let feedValue = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feedValue),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              feedURL.user == nil,
              feedURL.password == nil,
              let publicKeyValue = info["SUPublicEDKey"] as? String,
              let publicKey = Data(base64Encoded: publicKeyValue),
              publicKey.count == 32 else {
            return nil
        }
        self.feedURL = feedURL
        self.publicKey = publicKey
    }
}

@MainActor
final class UpdateNoticeController {
    private let onPresent: () -> Void
    private let onSpeak: (String) -> Void
    private let defaults: UserDefaults
    private let updaterController: SPUStandardUpdaterController?
    private var hasStarted = false
    private var hasPresented = false

    var availability: PerryUpdaterAvailability {
        updaterController == nil
            ? .unavailable("This build does not have a valid HTTPS update feed and EdDSA public key.")
            : .available
    }

    init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        onPresent: @escaping () -> Void,
        onSpeak: @escaping (String) -> Void
    ) {
        self.defaults = defaults
        self.onPresent = onPresent
        self.onSpeak = onSpeak
        updaterController = Self.makeUpdaterController(bundle: bundle)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let previousVersion = defaults.string(forKey: "perry.lastSeenVersion")
        defaults.set(currentVersion, forKey: "perry.lastSeenVersion")
        guard let previousVersion, previousVersion != currentVersion else { return }
        DispatchQueue.main.async { [weak self] in
            self?.present()
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static func makeUpdaterController(bundle: Bundle) -> SPUStandardUpdaterController? {
        guard PerryUpdaterConfiguration(info: bundle.infoDictionary ?? [:]) != nil else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private func present() {
        guard !hasPresented else { return }
        hasPresented = true
        onSpeak("Perry updated. See what’s new?")
        onPresent()
    }
}
