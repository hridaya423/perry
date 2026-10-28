import XCTest
@testable import PerryBrain

final class ClickGrounderEvalTests: XCTestCase {
    func testALiveServerFindsMostTargetsOnTheHardSet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["PERRY_GROUNDER_URL"].flatMap(URL.init(string:)),
              let folder = environment["PERRY_GROUNDER_TASKS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw XCTSkip("Set PERRY_GROUNDER_URL and PERRY_GROUNDER_TASKS to run against a live model")
        }
        let minimum = Int(environment["PERRY_GROUNDER_MINIMUM"] ?? "") ?? 28
        let tasks = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("tasks.json"))) as! [[Any]]
        let grounder = ClickGrounder(endpoint: { .init(baseURL: server, apiKey: environment["PERRY_GROUNDER_KEY"]) })
        var hits = 0
        var seconds: [Double] = []
        for task in tasks {
            let scene = task[0] as! String, goal = task[1] as! String, box = (task[2] as! [NSNumber]).map(\.doubleValue)
            let screenshot = try Data(contentsOf: folder.appendingPathComponent("\(scene).png"))
            let started = Date()
            let located = try await grounder.locate(goal, screenshot: screenshot, windowSize: CGSize(width: 1920, height: 1080))
            seconds.append(Date().timeIntervalSince(started))
            let hit = (box[0] - 4...box[2] + 4).contains(located.point.x) && (box[1] - 4...box[3] + 4).contains(located.point.y)
            hits += hit ? 1 : 0
        }
        seconds.sort()
        print("grounder eval: \(hits)/\(tasks.count) hits, median \(String(format: "%.2f", seconds[seconds.count / 2])) s, mean \(String(format: "%.2f", seconds.reduce(0, +) / Double(seconds.count))) s")
        XCTAssertGreaterThanOrEqual(hits, minimum)
    }
}
