import Foundation
import Testing
@testable import CookCore

private func sampleCook(start: Date, title: String = "Brisket") -> Cook {
    let key = ChannelKey(deviceSerial: "RFX-1", channel: "1")
    var cook = Cook(title: title, startedAt: start,
                    probes: [CookProbe(key: key, label: "Brisket, flat", role: .internal, target: Temperature(fahrenheit: 203))])
    cook.append(Sample(time: start, celsius: 4), to: key)
    cook.append(Sample(time: start.addingTimeInterval(15), celsius: 4.5), to: key)
    cook.notes.append(CookNote(time: start.addingTimeInterval(10), text: "Wrapped \"tight\""))
    return cook
}

@Suite("Cook stores")
struct CookStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "openmeat-tests-\(UUID().uuidString)")
    }

    @Test func fileStoreRoundTripsAndLists() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileCookStore(directory: dir)

        let older = sampleCook(start: t0, title: "Older")
        let newer = sampleCook(start: t0.addingTimeInterval(86_400), title: "Newer")
        try await store.save(older)
        try await store.save(newer)

        #expect(try await store.load(id: older.id) == older)
        #expect(try await store.summaries().map(\.title) == ["Newer", "Older"])

        try await store.delete(id: older.id)
        #expect(try await store.summaries().map(\.title) == ["Newer"])
        await #expect(throws: CookStoreError.notFound(older.id)) { try await store.load(id: older.id) }
    }

    @Test func saveOverwrites() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileCookStore(directory: dir)
        var cook = sampleCook(start: t0)
        try await store.save(cook)
        cook.title = "Renamed"
        try await store.save(cook)
        #expect(try await store.summaries().map(\.title) == ["Renamed"])
    }

    @Test func inMemoryStore() async throws {
        let cook = sampleCook(start: t0)
        let store = InMemoryCookStore([cook])
        #expect(try await store.load(id: cook.id) == cook)
        await store.delete(id: cook.id)
        #expect(await store.summaries().isEmpty)
    }
}

@Suite("Export")
struct ExportTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func csvIsTimeOrderedWithEscapedFields() {
        let lines = CookExporter.csv(sampleCook(start: t0), unit: .fahrenheit).split(separator: "\n").map(String.init)
        #expect(lines[0] == "timestamp,elapsed_s,probe,role,temp_F,note")
        #expect(lines.count == 4)
        #expect(lines[1].hasSuffix(",0,\"Brisket, flat\",internal,39.2,"))
        #expect(lines[2].hasSuffix(",10,,,,\"Wrapped \"\"tight\"\"\""))
        #expect(lines[3].contains(",15,"))
    }

    @Test func jsonRoundTrips() throws {
        let cook = sampleCook(start: t0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Cook.self, from: CookExporter.json(cook)).id == cook.id)
    }
}
