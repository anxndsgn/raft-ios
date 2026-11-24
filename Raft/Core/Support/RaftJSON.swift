import Foundation

/// JSON coding shared by REST and realtime payloads.
///
/// Decoding is tolerant by design: unknown keys are ignored (JSONDecoder's default), models
/// decode optional fields with `lenient(_:)` so a missing *or mistyped* field becomes nil
/// instead of failing the whole row, and seqs accept both numbers and decimal strings.
enum RaftJSON {
    static let decoder: JSONDecoder = JSONDecoder()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
}

/// A key for decoding arbitrary object keys.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is absent, null or of another type.
    func lenient<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// An Int64 from a JSON number or decimal string at `key`.
    func flexibleInt64(_ key: Key) -> Int64? {
        lenient(key, as: JSONValue.self)?.int64Value
    }

    /// An Int from a JSON number or decimal string at `key`.
    func flexibleInt(_ key: Key) -> Int? {
        flexibleInt64(key).flatMap { Int(exactly: $0) }
    }

    /// A list decoded element by element: an element that does not decode is skipped, not fatal.
    func lenientArray<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        guard let raw = lenient(key, as: [JSONValue].self) else { return [] }
        return raw.compactMap { try? $0.decode(T.self) }
    }
}

/// A list that skips elements which fail to decode (used for top-level arrays).
struct LenientArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(JSONValue.self)
            }
        }
        elements = result
    }
}
