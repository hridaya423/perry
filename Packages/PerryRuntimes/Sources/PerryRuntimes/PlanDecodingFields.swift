import Foundation

struct PlanDecodingFields {
    private let values: KeyedDecodingContainer<Key>

    init(_ decoder: Decoder, allowed: Set<String>) throws {
        values = try decoder.container(keyedBy: Key.self)
        let unknown = Set(values.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ExecutablePlanError.invalid("unknown plan fields: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    func decode<T: Decodable>(_ type: T.Type = T.self, _ key: String) throws -> T {
        try values.decode(type, forKey: Key(key))
    }

    func optional<T: Decodable>(_ type: T.Type = T.self, _ key: String) throws -> T? {
        try values.decodeIfPresent(type, forKey: Key(key))
    }

    func decoder(_ key: String) throws -> Decoder {
        try values.superDecoder(forKey: Key(key))
    }

    static func enumPayload(
        _ decoder: Decoder,
        cases: [String: Set<String>]
    ) throws -> (name: String, fields: PlanDecodingFields) {
        let root = try decoder.container(keyedBy: Key.self)
        guard root.allKeys.count == 1,
              let key = root.allKeys.first,
              let allowed = cases[key.stringValue] else {
            throw ExecutablePlanError.invalid("action value requires exactly one supported variant")
        }
        return (key.stringValue, try PlanDecodingFields(root.superDecoder(forKey: key), allowed: allowed))
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}
