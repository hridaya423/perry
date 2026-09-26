import XCTest
@testable import PerryGuide

final class AppSkillLibraryTests: XCTestCase {
    func testBundledSkillMatchesTheFrontmostBundle() {
        let library = AppSkillLibrary()

        let skill = library.skill(for: "com.apple.finder")

        XCTAssertEqual(skill?.source, .bundled)
        XCTAssertTrue(skill?.body.contains("Finder skill") == true)
    }

    func testBundledSkillsCoverTheFiveLiveGuideApps() {
        let library = AppSkillLibrary()

        let bundleIDs = [
            "com.apple.finder",
            "com.apple.Preview",
            "com.apple.Notes",
            "com.apple.systempreferences",
            "com.apple.Safari",
        ]

        XCTAssertEqual(bundleIDs.compactMap { library.skill(for: $0) }.count, bundleIDs.count)
    }

    func testBundledSkillsCoverTheScorecardApps() {
        let library = AppSkillLibrary()

        // Megaplan §6 scorecard apps; Sheets is web-only and rides the Chrome skill.
        let bundleIDs = [
            "com.blackmagic-design.DaVinciResolve",
            "com.figma.Desktop",
            "com.microsoft.Excel",
            "notion.id",
            "com.tinyspeck.slackmacgap",
            "com.google.Chrome",
            "com.apple.finder",
            "com.apple.iWork.Keynote",
            "com.apple.FinalCut",
            "com.apple.logic10",
            "com.apple.systempreferences",
        ]

        for bundleID in bundleIDs {
            XCTAssertNotNil(library.skill(for: bundleID), "missing bundled skill for \(bundleID)")
        }
    }

    func testUserSkillOverridesTheBundledSkillAndCanBeRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = AppSkillLibrary(storageDirectory: directory)
        try library.save("User Finder instructions", for: "com.apple.finder")

        XCTAssertEqual(library.skill(for: "com.apple.finder")?.source, .user)
        XCTAssertEqual(library.promptContext(for: "com.apple.finder"), "User Finder instructions")

        try library.removeUserSkill(for: "com.apple.finder")
        XCTAssertEqual(library.skill(for: "com.apple.finder")?.source, .bundled)
    }

    func testManifestSuppliesBundledDisplayNames() {
        let library = AppSkillLibrary()

        XCTAssertEqual(library.skill(for: "com.apple.finder")?.displayName, "Finder")
        XCTAssertEqual(library.skill(for: "com.microsoft.VSCode")?.displayName, "Visual Studio Code")
    }

    func testUserSkillDisplayNameDerivesFromBundleID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = AppSkillLibrary(storageDirectory: directory)
        try library.save("custom notes", for: "com.example.Prompter")

        XCTAssertEqual(library.skill(for: "com.example.Prompter")?.displayName, "Prompter")
    }

    func testOversizedSkillIsRejectedOnSaveAndIgnoredOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = AppSkillLibrary(storageDirectory: directory)
        let oversized = String(repeating: "x", count: AppSkillLibrary.maximumSkillBytes + 1)

        XCTAssertThrowsError(try library.save(oversized, for: "com.example.big")) { error in
            XCTAssertEqual(error as? AppSkillError, .skillTooLarge)
        }

        let skillsDirectory = directory.appendingPathComponent("AppSkills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        try oversized.write(to: skillsDirectory.appendingPathComponent("com.example.big.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(library.skill(for: "com.example.big"))
    }

    func testInvalidBundleIDsCannotEscapeTheSkillDirectory() {
        let library = AppSkillLibrary(storageDirectory: FileManager.default.temporaryDirectory)

        XCTAssertNil(library.skill(for: "../../secrets"))
        XCTAssertThrowsError(try library.save("bad", for: "../../secrets"))
    }

    func testSkillActivationControlsPromptInjection() {
        let suiteName = "perry-skill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppSkillLibrary(defaults: defaults)

        XCTAssertNotNil(library.promptContext(for: "com.apple.finder"))
        library.setEnabled(false, for: "com.apple.finder")
        XCTAssertNil(library.promptContext(for: "com.apple.finder"))

        library.setEnabled(true, for: "com.apple.finder")
        XCTAssertNotNil(library.promptContext(for: "com.apple.finder"))
    }
}
