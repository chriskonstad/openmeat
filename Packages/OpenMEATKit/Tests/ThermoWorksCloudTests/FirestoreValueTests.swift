import Foundation
import Testing
@testable import ThermoWorksCloud

@Suite("Firestore value decoding")
struct FirestoreValueTests {
    private func decode(_ json: String) throws -> FirestoreValue {
        try JSONDecoder().decode(FirestoreValue.self, from: Data(json.utf8))
    }

    @Test func scalars() throws {
        #expect(try decode(#"{"stringValue":"hi"}"#) == .string("hi"))
        #expect(try decode(#"{"integerValue":"42"}"#) == .integer(42))
        #expect(try decode(#"{"integerValue":42}"#) == .integer(42))
        #expect(try decode(#"{"doubleValue":1.5}"#) == .double(1.5))
        #expect(try decode(#"{"booleanValue":true}"#) == .bool(true))
        #expect(try decode(#"{"nullValue":null}"#) == .null)
        #expect(try decode(#"{"referenceValue":"projects/x"}"#) == .reference("projects/x"))
    }

    @Test func nonFiniteDoublesArriveAsStrings() throws {
        #expect(try decode(#"{"doubleValue":"Infinity"}"#).doubleValue == .infinity)
        #expect(try decode(#"{"doubleValue":"NaN"}"#).doubleValue?.isNaN == true)
    }

    @Test func nestedMapsAndArrays() throws {
        let value = try decode(#"""
        {"mapValue":{"fields":{"a":{"arrayValue":{"values":[{"integerValue":"1"},{"stringValue":"x"}]}},"b":{"mapValue":{}}}}}
        """#)
        #expect(value.mapValue?["a"]?.arrayValue == [.integer(1), .string("x")])
        #expect(value.mapValue?["b"] == .map([:]))
        #expect(try decode(#"{"arrayValue":{}}"#) == .array([]))
    }

    @Test func unknownTypesDontFailDecoding() throws {
        #expect(try decode(#"{"geoPointValue":{"latitude":1,"longitude":2}}"#) == .unsupported("geoPointValue"))
    }

    @Test func lenientNumericAccessors() {
        #expect(FirestoreValue.string("-55").intValue == -55)
        #expect(FirestoreValue.integer(248).doubleValue == 248)
        #expect(FirestoreValue.double(151.9).intValue == 151)
        #expect(FirestoreValue.integer(3).stringValue == "3")
        #expect(FirestoreValue.bool(true).doubleValue == nil)
    }

    @Test(arguments: [
        "2026-10-29T18:00:00Z",
        "2026-10-29T18:00:00.000Z",
        "2026-10-29T18:00:00.000000Z",
        "2026-10-29T18:00:00.000000000Z",
        "2026-10-29T13:00:00-05:00",
    ])
    func timestampsWithAnyPrecision(_ raw: String) throws {
        let date = try #require(FirestoreTimestamp.parse(raw))
        #expect(date == Date(timeIntervalSince1970: 1_793_296_800))
    }

    @Test func fractionalSecondsArePreservedToMillis() throws {
        let date = try #require(FirestoreTimestamp.parse("2026-10-29T18:00:00.123456Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_793_296_800.123) < 0.0005)
    }

    @Test func malformedTimestampThrows() {
        #expect(throws: DecodingError.self) { try decode(#"{"timestampValue":"yesterday"}"#) }
    }
}
