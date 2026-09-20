import XCTest
@testable import PerryCore

final class IntegrationDescriptorTests: XCTestCase {
    func testCredentialReferenceCodableStateContainsOnlyLookupCoordinates() throws {
        let reference = CredentialReference(service: "dev.perry.tests", account: "example")

        let data = try JSONEncoder().encode(reference)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let decoded = try JSONDecoder().decode(CredentialReference.self, from: data)

        XCTAssertEqual(Set(object.keys), ["service", "account"])
        XCTAssertEqual(decoded, reference)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testIntegrationDescriptorRoundTripsCredentialReferenceWithoutSecretValue() throws {
        let descriptor = IntegrationDescriptor(
            id: "example",
            displayName: "Example",
            credentialReference: CredentialReference(service: "dev.perry.tests", account: "example")
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(IntegrationDescriptor.self, from: data)

        XCTAssertEqual(decoded, descriptor)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("credentialValue"))
    }
}
