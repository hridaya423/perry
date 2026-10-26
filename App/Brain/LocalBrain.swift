import Foundation
import os
import PerryBrain

@MainActor
final class LocalBrain: ObservableObject {
    enum Phase: Equatable {
        case notSetUp
        case downloading(received: Int64, total: Int64)
        case ready
        case failed(String)
    }

    enum Budget: String, CaseIterable {
        case nothing
        case upTo2GB
        case keepMainReady

        var memoryBudget: MemoryBudget {
            switch self {
            case .nothing: .nothing
            case .upTo2GB: .upTo2GB
            case .keepMainReady: .keepMainReady
            }
        }

        var title: String {
            switch self {
            case .nothing: "Nothing"
            case .upTo2GB: "Up to 2 GB"
            case .keepMainReady: "Keep the main model ready"
            }
        }
    }

    enum CloudFallback: String, CaseIterable {
        case ask
        case never

        var title: String {
            switch self {
            case .ask: "Ask me before using the cloud"
            case .never: "Never use the cloud"
            }
        }
    }

    struct IdlePolicy: Equatable {
        let sleepIdleSeconds: Int?
        let exitAfterIdle: Duration?
    }

    static func idlePolicy(_ budget: Budget) -> IdlePolicy {
        switch budget {
        case .nothing, .upTo2GB: IdlePolicy(sleepIdleSeconds: 300, exitAfterIdle: .seconds(30 * 60))
        case .keepMainReady: IdlePolicy(sleepIdleSeconds: nil, exitAfterIdle: nil)
        }
    }

    static func files(for rung: ModelRung) -> (repo: String, paths: [String]) {
        ("unsloth/\(rung.name)-GGUF", ["\(rung.name)-\(rung.quant).gguf", "mmproj-F16.gguf"])
    }

    @Published private(set) var phase: Phase
    let engine: LocalEngine?
    private let downloader: ModelDownloader
    private let modelsDirectory: URL
    let benchURL: URL
    private var pressureMonitor: MemoryPressureMonitor?

    init(engine: LocalEngine?, downloader: ModelDownloader = ModelDownloader(), modelsDirectory: URL, benchURL: URL) {
        self.engine = engine
        self.downloader = downloader
        self.modelsDirectory = modelsDirectory
        self.benchURL = benchURL
        phase = .notSetUp
    }

    static func bundledEngine(storage: URL) -> LocalEngine? {
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "llama-server") else { return nil }
        return LocalEngine(binary: binary, directory: storage.appendingPathComponent("LocalEngine", isDirectory: true))
    }

    var hasEngine: Bool { engine != nil }

    func startWatchingMemoryPressure() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = MemoryPressureMonitor { [weak self] level in
            MainActor.assumeIsolated { self?.memoryPressure(level) }
        }
    }

    func memoryPressure(_ level: MemoryPressureMonitor.Level) {
        guard level != .normal else { return }
        engine?.memoryPressure()
    }

    func setUp(_ rung: ModelRung) async {
        guard engine != nil else {
            phase = .failed("This build doesn’t include Perry’s local engine yet, so nothing was downloaded.")
            return
        }
        let source = Self.files(for: rung)
        do {
            let files = try await downloader.files(repo: source.repo, revision: "main", paths: source.paths)
            phase = .downloading(received: 0, total: files.reduce(0) { $0 + $1.size })
            let lastPercent = OSAllocatedUnfairLock(initialState: -1)
            _ = try await downloader.download(files, to: modelsDirectory.appendingPathComponent(rung.id, isDirectory: true)) { received, total in
                let percent = total > 0 ? Int(received * 100 / total) : 0
                guard lastPercent.withLock({ last in
                    defer { last = percent }
                    return last != percent
                }) else { return }
                Task { @MainActor [weak self] in self?.phase = .downloading(received: received, total: total) }
            }
            phase = .ready
        } catch ModelDownloader.DownloadError.notEnoughSpace(let needed, let available) {
            let format = ByteCountFormatter()
            phase = .failed("This needs \(format.string(fromByteCount: needed)) free and the disk has \(format.string(fromByteCount: available)).")
        } catch {
            phase = .failed("The download stopped: \(error.localizedDescription) Choose Download again to resume.")
        }
    }
}
