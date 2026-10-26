import Testing
import Foundation
@testable import AetherEngine

/// A file that stores a track far after the video (a flat MP4 with its audio or subtitle samples after
/// the video) makes the demuxer read past the streaming window every few video packets. The far-forward
/// branch served those only from a resident detour block and otherwise re-anchored the window there, so
/// every switch tore the video connection down and opened a new one. It now fetches them through the
/// detour cache, as the backward branch does; a playback reposition still anchors at the landing.
@Suite("Detour forward ping-pong")
struct DetourForwardPingPongTests {

    private static let chunk = 256 * 1024

    /// The detour fetch's interactive budget is a wall clock; see Issue782RestartReanchorTests.
    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, detourFetchBudget: 30)
    }

    private func matchesPattern(_ buf: UnsafeMutablePointer<UInt8>, count: Int, at offset: Int64) -> Bool {
        (0..<count).allSatisfy { buf[$0] == ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    @Test("a far-forward read is a detour block, and the video window keeps streaming behind it",
          .timeLimit(.minutes(2)))
    func forwardReadDetours() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        let video: Int64 = 2 * 1024 * 1024
        var read: Int64 = 0
        while read < video {
            let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
            #expect(n > 0)
            if n <= 0 { return }
            read += Int64(n)
        }

        let track: Int64 = 48 * 1024 * 1024 + 4321
        #expect(reader.seek(offset: track, whence: Int32(SEEK_SET)) == track)
        let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
        #expect(n > 0)
        #expect(matchesPattern(buf, count: n, at: track), "the track read served the wrong bytes")
        #expect(reader.detourResidentBlocksForTesting == 1, "the track read was not served as a detour block")
        #expect(!server.requestedRanges.contains { $0.start == track },
                "the window was re-anchored at the track: \(server.requestedRanges.map(\.start))")

        let requestsBefore = server.requestedRanges.count
        #expect(reader.seek(offset: read, whence: Int32(SEEK_SET)) == read)
        let m = Int(reader.read(into: buf, size: Int32(Self.chunk)))
        #expect(m > 0)
        #expect(matchesPattern(buf, count: m, at: read), "the video read served the wrong bytes")
        #expect(server.requestedRanges.count == requestsBefore,
                "returning to the video opened a connection: \(server.requestedRanges.map(\.start))")
    }

    @Test("a far-forward read after a playback reposition still anchors the window at the landing",
          .timeLimit(.minutes(2)))
    func repositionAnchorsAtLanding() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)

        let landing: Int64 = 48 * 1024 * 1024 + 4321
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        reader.notePlaybackRepositioned()
        let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
        #expect(n > 0)
        #expect(matchesPattern(buf, count: n, at: landing), "the landing served the wrong bytes")
        #expect(reader.detourResidentBlocksForTesting == 0, "the landing was served as a detour block")
        #expect(server.requestedRanges.contains { $0.start == landing },
                "no connection was anchored at the landing: \(server.requestedRanges.map(\.start))")
    }
}
