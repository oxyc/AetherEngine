import Testing
import Foundation
@testable import AetherEngine

/// The served-bytes summaries the device log carries. Both are pure over `Data`, built here from a
/// hand-made init segment and a hand-made length-prefixed access unit.
@Suite("PlaybackDiagnostics: init box tree and NAL histogram")
struct PlaybackDiagnosticsTests {

    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(body.count + 8) + Array(type.utf8) + body
    }

    private static func initSegment(colr: [UInt8]?) -> Data {
        var hvcC = [UInt8](repeating: 0, count: 23)
        hvcC[0] = 1; hvcC[1] = 2; hvcC[12] = 150; hvcC[21] = 0x0B
        let dvcC: [UInt8] = [1, 0, 0x0A, 0x35] + [UInt8](repeating: 0, count: 20)
        var kids = box("hvcC", hvcC) + box("dvcC", dvcC)
        if let colr { kids += box("colr", colr) }
        let entry = box("dvh1", [UInt8](repeating: 0, count: 78) + kids)
        let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + entry)
        let trak = box("trak", box("mdia", box("minf", box("stbl", stsd))))
        return Data(box("moov", trak))
    }

    @Test("the init tree names the sample entry, its children, hvcC, dvcC and colr")
    func initTreeDescribesTheVideoEntry() {
        let colr = Array("nclx".utf8) + [0, 9, 0, 16, 0, 9, 0x80]
        let text = MP4Inspect.describeInit(Self.initSegment(colr: colr))
        #expect(text.contains("stsd("))
        #expect(text.contains("dvh1("))
        #expect(text.contains("[hvcC(31) dvcC(32) colr(19)]"))
        #expect(text.contains("hvcC=profile=2 level=150 lengthSizeMinusOne=3"))
        #expect(text.contains("dvcC=01000a35"))
        #expect(text.contains("colr=nclx 9/16/9 full=1"))
    }

    @Test("an init with no colr says so")
    func initWithoutColr() {
        let text = MP4Inspect.describeInit(Self.initSegment(colr: nil))
        #expect(text.contains("colr=none"))
        #expect(text.contains("[hvcC(31) dvcC(32)]"))
    }

    @Test("garbage is described as such, not crashed on")
    func garbageInit() {
        #expect(MP4Inspect.describeInit(Data([1, 2, 3])).contains("no moov"))
    }

    /// One length-prefixed NAL: 2-byte header carrying `type`, plus a payload byte.
    private static func nal(_ type: Int) -> [UInt8] {
        let body: [UInt8] = [UInt8(type << 1), 0x01, 0xAA]
        return be32(body.count) + body
    }

    /// styp-less fragment: moof(traf(tfhd, trun)) + mdat holding the given access units.
    private static func fragment(_ units: [[Int]]) -> Data {
        let samples = units.map { $0.flatMap { nal($0) } }
        var trunBody: [UInt8] = [0, 0, 0x02, 0x01] + be32(samples.count) + be32(0)  // size + data-offset present
        for s in samples { trunBody += be32(s.count) }
        let tfhd = box("tfhd", [0, 0x02, 0x00, 0x00] + be32(1))   // default-base-is-moof
        let trunBox = box("trun", trunBody)
        let traf = box("traf", tfhd + trunBox)
        let moofSize = 8 + traf.count
        // data_offset points just past the mdat header, relative to the moof start.
        let offset = moofSize + 8
        var fixedTrun: [UInt8] = [0, 0, 0x02, 0x01] + be32(samples.count) + be32(offset)
        for s in samples { fixedTrun += be32(s.count) }
        let moof = box("moof", box("traf", tfhd + box("trun", fixedTrun)))
        return Data(moof + box("mdat", samples.flatMap { $0 }))
    }

    @Test("the histogram counts NAL types and finds the RPU after the last slice")
    func histogramWithRPUAfterSlices() {
        let au = [35, 19, 62]
        let text = MP4Inspect.describeFragment(Self.fragment([au, [1, 62], [1, 62]]))
        #expect(text.contains("samples=3"))
        #expect(text.contains("[1:2 19:1 35:1 62:3]"))
        #expect(text.contains("AU0 order=[35, 19, 62]"))
        #expect(text.contains("RPU after last slice"))
    }

    @Test("an RPU ahead of the slices is reported as such")
    func rpuBeforeSlices() {
        let text = MP4Inspect.describeFragment(Self.fragment([[62, 19]]))
        #expect(text.contains("RPU BEFORE last slice"))
    }

    @Test("an access unit with no RPU says so")
    func noRPU() {
        #expect(MP4Inspect.describeFragment(Self.fragment([[19]])).contains("no RPU in AU0"))
    }
}
