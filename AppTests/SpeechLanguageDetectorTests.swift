import XCTest
@testable import Perry

final class SpeechLanguageDetectorTests: XCTestCase {
    func testMultilingualFixturesResolveToExactSupportedLocales() {
        for fixture in Self.fixtures {
            let detected = SpeechLanguageDetector.localeIdentifier(
                for: fixture.transcript,
                supportedIdentifiers: fixture.supportedIdentifiers
            )

            XCTAssertEqual(detected, fixture.expectedIdentifier, fixture.transcript)
            XCTAssertTrue(fixture.supportedIdentifiers.contains(detected ?? ""))
        }
    }

    func testUnsupportedDetectedLanguageIsFilteredOut() {
        let spanish = Self.fixtures.first { $0.expectedIdentifier == "es-ES" }!

        XCTAssertNil(
            SpeechLanguageDetector.localeIdentifier(
                for: spanish.transcript,
                supportedIdentifiers: ["en-US", "fr-FR"]
            )
        )
    }

    func testLanguageChangeCanRerouteOnlyOnce() {
        let spanish = Self.fixtures.first { $0.expectedIdentifier == "es-ES" }!
        let supportedIdentifiers = ["en-US", "es-ES", "fr-FR"]

        let firstTarget = SpeechLanguageDetector.rerouteTarget(
            for: spanish.transcript,
            activeIdentifier: "en-US",
            supportedIdentifiers: supportedIdentifiers,
            rerouteAlreadyAttempted: false
        )
        let secondTarget = SpeechLanguageDetector.rerouteTarget(
            for: spanish.transcript,
            activeIdentifier: "en-US",
            supportedIdentifiers: supportedIdentifiers,
            rerouteAlreadyAttempted: true
        )

        XCTAssertEqual(firstTarget, "es-ES")
        XCTAssertNil(secondTarget)
    }

    func testSameLanguageDoesNotRerouteAcrossLocaleVariants() {
        let spanish = Self.fixtures.first { $0.expectedIdentifier == "es-ES" }!

        XCTAssertNil(
            SpeechLanguageDetector.rerouteTarget(
                for: spanish.transcript,
                activeIdentifier: "es-MX",
                supportedIdentifiers: ["es-ES", "es-MX"],
                rerouteAlreadyAttempted: false
            )
        )
    }

    private struct Fixture {
        let transcript: String
        let expectedIdentifier: String
        let supportedIdentifiers: [String]
    }

    private static let fixtures = [
        Fixture(
            transcript: "The quick brown fox jumps over the lazy dog. Please open the settings window.",
            expectedIdentifier: "en-US",
            supportedIdentifiers: ["en-US", "fr-FR"]
        ),
        Fixture(
            transcript: "El zorro marrón salta sobre el perro perezoso. Abre la ventana de configuración.",
            expectedIdentifier: "es-ES",
            supportedIdentifiers: ["en-US", "es-ES"]
        ),
        Fixture(
            transcript: "Le rapide renard brun saute par-dessus le chien paresseux. Ouvre la fenêtre des réglages.",
            expectedIdentifier: "fr-FR",
            supportedIdentifiers: ["fr-FR", "en-US"]
        ),
        Fixture(
            transcript: "Der schnelle braune Fuchs springt über den faulen Hund. Öffne bitte das Einstellungsfenster.",
            expectedIdentifier: "de-DE",
            supportedIdentifiers: ["de-DE", "en-US"]
        ),
        Fixture(
            transcript: "素早い茶色のキツネが怠惰な犬を飛び越えます。設定ウインドウを開いてください。",
            expectedIdentifier: "ja-JP",
            supportedIdentifiers: ["en-US", "ja-JP"]
        ),
        Fixture(
            transcript: "快速的棕色狐狸跳过了懒狗。请打开设置窗口。",
            expectedIdentifier: "zh-CN",
            supportedIdentifiers: ["en-US", "zh-CN"]
        ),
        Fixture(
            transcript: "O raposo castanho rápido salta sobre o cão preguiçoso. Abra a janela de definições.",
            expectedIdentifier: "pt-PT",
            supportedIdentifiers: ["pt-PT", "en-US"]
        ),
    ]
}
