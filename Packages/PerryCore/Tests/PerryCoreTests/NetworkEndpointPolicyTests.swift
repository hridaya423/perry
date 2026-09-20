import XCTest
@testable import PerryCore

final class NetworkEndpointPolicyTests: XCTestCase {
    func testAllowsEncryptedRemoteEndpoints() throws {
        try NetworkEndpointPolicy.requireSafe(URL(string: "https://api.example.com/v1")!)
        try NetworkEndpointPolicy.requireSafe(URL(string: "wss://api.example.com/realtime")!)
    }

    func testAllowsPlaintextLoopbackEndpoints() throws {
        try NetworkEndpointPolicy.requireSafe(URL(string: "http://localhost:8080")!)
        try NetworkEndpointPolicy.requireSafe(URL(string: "ws://127.0.0.1:9000")!)
        try NetworkEndpointPolicy.requireSafe(URL(string: "http://[::1]:8080")!)
    }

    func testRejectsPlaintextRemoteEndpoints() {
        XCTAssertThrowsError(try NetworkEndpointPolicy.requireSafe(URL(string: "http://api.example.com")!)) { error in
            XCTAssertEqual(error as? NetworkEndpointError, .insecureRemoteEndpoint)
        }
        XCTAssertThrowsError(try NetworkEndpointPolicy.requireSafe(URL(string: "ws://192.168.1.20:9000")!)) { error in
            XCTAssertEqual(error as? NetworkEndpointError, .insecureRemoteEndpoint)
        }
    }

    func testRejectsUnsupportedSchemes() {
        XCTAssertThrowsError(try NetworkEndpointPolicy.requireSafe(URL(string: "ftp://example.com")!)) { error in
            XCTAssertEqual(error as? NetworkEndpointError, .unsupportedScheme("ftp"))
        }
    }
}
