import Foundation

/// Read-only summaries of what the engine actually served, for the device log. Pure functions over
/// `Data`: they never change a byte of what is served and cost one pass over an init segment and the
/// head of the first media segment, once per session.
enum MP4Inspect {

    private struct Box {
        let type: String
        let start: Int
        let end: Int
        var bodyStart: Int { start + 8 }
    }

    private static func u16(_ d: Data, _ i: Int) -> Int {
        Int(d[d.startIndex + i]) << 8 | Int(d[d.startIndex + i + 1])
    }

    private static func u32(_ d: Data, _ i: Int) -> Int {
        u16(d, i) << 16 | u16(d, i + 2)
    }

    private static func fourCC(_ d: Data, _ i: Int) -> String {
        String(decoding: (0..<4).map { d[d.startIndex + i + $0] }, as: UTF8.self)
    }

    private static func hex(_ d: Data, _ range: Range<Int>) -> String {
        range.map { String(format: "%02x", d[d.startIndex + $0]) }.joined()
    }

    /// Child boxes of `[from, to)`. A 64-bit size or a size that overruns the range ends the walk.
    private static func boxes(_ d: Data, from: Int, to: Int) -> [Box] {
        var out: [Box] = []
        var i = from
        while i + 8 <= to {
            let size = u32(d, i)
            guard size >= 8, i + size <= to else { break }
            out.append(Box(type: fourCC(d, i + 4), start: i, end: i + size))
            i += size
        }
        return out
    }

    private static let videoEntries: Set<String> = [
        "hvc1", "hev1", "dvh1", "dvhe", "avc1", "avc3", "dva1", "dvav", "av01", "dav1",
    ]

    /// `moov>trak>mdia>minf>stbl>stsd>entry` for the video track, the entry's children with sizes, and the
    /// three boxes that decide how AVFoundation reads the picture: `hvcC` (profile, level, NAL length
    /// size), the Dolby Vision `dvcC`/`dvvC` (hex) and `colr` (nclx tuple and full-range flag).
    static func describeInit(_ d: Data) -> String {
        let top = boxes(d, from: 0, to: d.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { return "init tree: no moov" }
        for trak in boxes(d, from: moov.bodyStart, to: moov.end) where trak.type == "trak" {
            var path = ["moov(\(moov.end - moov.start))", "trak(\(trak.end - trak.start))"]
            var cursor = trak
            var stsd: Box?
            for name in ["mdia", "minf", "stbl", "stsd"] {
                guard let next = boxes(d, from: cursor.bodyStart, to: cursor.end).first(where: { $0.type == name })
                else { break }
                path.append("\(name)(\(next.end - next.start))")
                cursor = next
                if name == "stsd" { stsd = next }
            }
            guard let stsd, stsd.end - stsd.start >= 16 else { continue }
            // stsd is a full box: version/flags (4) + entry count (4), then the entries.
            for entry in boxes(d, from: stsd.bodyStart + 8, to: stsd.end) where videoEntries.contains(entry.type) {
                // A visual sample entry has 78 bytes of fixed fields before its child boxes.
                let kids = boxes(d, from: entry.bodyStart + 78, to: entry.end)
                var line = "init tree: " + path.joined(separator: ">")
                    + ">\(entry.type)(\(entry.end - entry.start))["
                    + kids.map { "\($0.type)(\($0.end - $0.start))" }.joined(separator: " ") + "]"
                line += " hvcC=" + (kids.first { $0.type == "hvcC" }.map { hvcCSummary(d, $0) } ?? "none")
                let dv = kids.first { $0.type == "dvcC" || $0.type == "dvvC" }
                line += " " + (dv.map { "\($0.type)=\(hex(d, $0.bodyStart..<$0.end))" } ?? "dvcC=none")
                line += " colr=" + (kids.first { $0.type == "colr" }.map { colrSummary(d, $0) } ?? "none")
                return line
            }
        }
        return "init tree: no video sample entry"
    }

    private static func hvcCSummary(_ d: Data, _ box: Box) -> String {
        guard box.end - box.bodyStart >= 22 else { return "truncated" }
        let b = box.bodyStart
        let profile = Int(d[d.startIndex + b + 1]) & 0x1F
        let level = Int(d[d.startIndex + b + 12])
        let lengthSize = Int(d[d.startIndex + b + 21]) & 0x3
        return "profile=\(profile) level=\(level) lengthSizeMinusOne=\(lengthSize)"
    }

    private static func colrSummary(_ d: Data, _ box: Box) -> String {
        let b = box.bodyStart
        guard box.end - b >= 4 else { return "truncated" }
        let kind = fourCC(d, b)
        guard kind == "nclx", box.end - b >= 11 else { return kind }
        let full = (d[d.startIndex + b + 10] & 0x80) != 0
        return "nclx \(u16(d, b + 4))/\(u16(d, b + 6))/\(u16(d, b + 8)) full=\(full ? 1 : 0)"
    }

    /// The HEVC NAL unit types of the first `accessUnits` samples of a media segment (`moof` + `mdat`):
    /// a histogram, and for the first sample the order the NALs come in, with whether the Dolby Vision RPU
    /// (type 62) sits after the last slice. Types: 32/33/34 parameter sets, 19/20/1/0 slices, 39/40 SEI,
    /// 62 RPU, 63 enhancement layer.
    static func describeFragment(_ d: Data, accessUnits: Int = 3, lengthSize: Int = 4) -> String {
        let top = boxes(d, from: 0, to: d.count)
        guard let moof = top.first(where: { $0.type == "moof" }),
              let traf = boxes(d, from: moof.bodyStart, to: moof.end).first(where: { $0.type == "traf" }),
              let tfhd = boxes(d, from: traf.bodyStart, to: traf.end).first(where: { $0.type == "tfhd" }),
              let trun = boxes(d, from: traf.bodyStart, to: traf.end).first(where: { $0.type == "trun" })
        else { return "first segment: no moof/traf/trun" }

        let tfFlags = u32(d, tfhd.bodyStart) & 0xFFFFFF
        var p = tfhd.bodyStart + 8   // version/flags + track_ID
        var baseOffset = moof.start
        if tfFlags & 0x1 != 0 { baseOffset = u32(d, p + 4); p += 8 }
        if tfFlags & 0x2 != 0 { p += 4 }
        if tfFlags & 0x8 != 0 { p += 4 }
        let defaultSize = tfFlags & 0x10 != 0 ? u32(d, p) : 0

        let trFlags = u32(d, trun.bodyStart) & 0xFFFFFF
        let count = u32(d, trun.bodyStart + 4)
        var q = trun.bodyStart + 8
        var dataOffset = 0
        if trFlags & 0x1 != 0 { dataOffset = u32(d, q); q += 4 }
        if trFlags & 0x4 != 0 { q += 4 }
        var sizes: [Int] = []
        for _ in 0..<min(count, accessUnits) {
            if trFlags & 0x100 != 0 { q += 4 }
            var size = defaultSize
            if trFlags & 0x200 != 0 { size = u32(d, q); q += 4 }
            if trFlags & 0x400 != 0 { q += 4 }
            if trFlags & 0x800 != 0 { q += 4 }
            sizes.append(size)
        }

        var histogram: [Int: Int] = [:]
        var firstOrder: [Int] = []
        var pos = baseOffset + dataOffset
        for (n, size) in sizes.enumerated() {
            guard size > 0, pos + size <= d.count else { break }
            var i = pos
            while i + lengthSize + 2 <= pos + size {
                var nalLen = 0
                for k in 0..<lengthSize { nalLen = nalLen << 8 | Int(d[d.startIndex + i + k]) }
                guard nalLen > 0, i + lengthSize + nalLen <= pos + size else { break }
                let type = Int(d[d.startIndex + i + lengthSize] >> 1) & 0x3F
                histogram[type, default: 0] += 1
                if n == 0 { firstOrder.append(type) }
                i += lengthSize + nalLen
            }
            pos += size
        }
        let hist = histogram.keys.sorted().map { "\($0):\(histogram[$0]!)" }.joined(separator: " ")
        let lastSlice = firstOrder.lastIndex { $0 < 32 }
        let firstRPU = firstOrder.firstIndex(of: 62)
        let placement: String
        switch (firstRPU, lastSlice) {
        case (nil, _): placement = "no RPU in AU0"
        case (let r?, let s?): placement = r > s ? "RPU after last slice" : "RPU BEFORE last slice"
        default: placement = "RPU without slices"
        }
        return "first segment: samples=\(count) firstSampleSize=\(sizes.first ?? 0) "
            + "NAL types over first \(sizes.count) AU [\(hist)] AU0 order=\(firstOrder) \(placement)"
    }
}

/// What the session served, gathered where it is decided and read at the first frame, so one log line
/// can say what was served and what mode the panel was in. Written by the HLS producer and the display
/// controller, read by the native host; it changes no behaviour.
final class PlaybackFingerprint: @unchecked Sendable {
    static let shared = PlaybackFingerprint()

    private let lock = NSLock()
    private var facts: [String: String] = [:]

    func set(_ key: String, _ value: String) {
        lock.lock(); facts[key] = value; lock.unlock()
    }

    func line(route: String) -> String {
        lock.lock(); defer { lock.unlock() }
        func f(_ k: String) -> String { facts[k] ?? "unknown" }
        return "fingerprint: route=\(route) sampleEntry=\(f("sampleEntry")) dvProfile=\(f("dvProfile")) "
            + "recordSource=\(f("recordSource")) colr=\(f("colr")) variant=\(f("variant")) "
            + "displayMode=\(f("displayMode"))"
    }
}
