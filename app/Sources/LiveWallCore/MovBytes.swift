// Minimal QuickTime/ISO box reader and in-place editor over a byte array.
//
// The box-walking helpers follow pudding0503/live-photo-batch `prepare_wallpaper_video.py` (MIT, see
// THIRD_PARTY/live-photo-batch.LICENSE). Differences: every field access honours the box version (v0/v1), 64-bit
// chunk offsets (`co64`) are handled, and the video track is found through its handler type, not by searching for
// the bytes "vide".
import Foundation

public enum MovError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .malformed(let m): return "MOV malformed: \(m)"
        case .unsupported(let m): return "MOV unsupported: \(m)"
        }
    }
}

struct Box {
    let kind: String
    let offset: Int
    let size: Int
    let headerSize: Int

    var dataOffset: Int { offset + headerSize }
    var end: Int { offset + size }
}

extension Array where Element == UInt8 {
    func be32(_ o: Int) -> Int {
        Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }

    func be64(_ o: Int) -> Int {
        (be32(o) << 32) | be32(o + 4)
    }

    func fourcc(_ o: Int) -> String {
        String(decoding: self[o..<o + 4], as: UTF8.self)
    }

    mutating func setBE32(_ o: Int, _ v: Int) {
        precondition(v >= 0 && v <= 0xFFFF_FFFF, "value does not fit in 32 bits")
        self[o] = UInt8((v >> 24) & 0xFF)
        self[o + 1] = UInt8((v >> 16) & 0xFF)
        self[o + 2] = UInt8((v >> 8) & 0xFF)
        self[o + 3] = UInt8(v & 0xFF)
    }

    mutating func setBE64(_ o: Int, _ v: Int) {
        setBE32(o, (v >> 32) & 0xFFFF_FFFF)
        setBE32(o + 4, v & 0xFFFF_FFFF)
    }

    /// Does the byte pattern occur between `from` and `to`?
    func contains(_ pattern: [UInt8], from: Int, to: Int) -> Bool {
        guard pattern.count > 0, to - from >= pattern.count else { return false }
        var i = from
        while i <= to - pattern.count {
            if self[i] == pattern[0], Array(self[i..<i + pattern.count]) == pattern { return true }
            i += 1
        }
        return false
    }
}

func be32Bytes(_ v: Int) -> [UInt8] {
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

enum MovBoxes {
    /// Boxes whose payload is a plain list of child boxes.
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "tref", "tapt"]

    static func parse(_ d: [UInt8], at offset: Int, end: Int) throws -> Box {
        guard offset + 8 <= end else { throw MovError.malformed("truncated box header") }
        var size = d.be32(offset)
        let kind = d.fourcc(offset + 4)
        var header = 8
        if size == 1 {
            guard offset + 16 <= end else { throw MovError.malformed("truncated extended box header") }
            size = d.be64(offset + 8)
            header = 16
        } else if size == 0 {
            size = end - offset
        }
        guard size >= header, offset + size <= end else { throw MovError.malformed("invalid \(kind) box size") }
        return Box(kind: kind, offset: offset, size: size, headerSize: header)
    }

    static func children(_ d: [UInt8], of parent: Box) throws -> [Box] {
        guard containers.contains(parent.kind) else { return [] }
        return try list(d, from: parent.dataOffset, to: parent.end)
    }

    static func list(_ d: [UInt8], from start: Int, to end: Int) throws -> [Box] {
        var out: [Box] = []
        var o = start
        while o < end {
            let b = try parse(d, at: o, end: end)
            out.append(b)
            o = b.end
        }
        return out
    }

    static func topLevel(_ d: [UInt8]) throws -> [Box] { try list(d, from: 0, to: d.count) }

    static func child(_ d: [UInt8], _ parent: Box, _ kind: String) throws -> Box {
        guard let c = try children(d, of: parent).first(where: { $0.kind == kind }) else {
            throw MovError.malformed("missing \(kind) in \(parent.kind)")
        }
        return c
    }

    static func descendant(_ d: [UInt8], _ parent: Box, _ path: [String]) throws -> Box {
        var cur = parent
        for k in path { cur = try child(d, cur, k) }
        return cur
    }

    static func rootBox(_ d: [UInt8]) -> Box { Box(kind: "moov", offset: 0, size: d.count, headerSize: 8) }
}

// MARK: - track-level accessors (all version aware)

enum TrackFields {
    static func version(_ d: [UInt8], _ box: Box) -> Int { Int(d[box.dataOffset]) }

    static func trackID(_ d: [UInt8], _ track: Box) throws -> Int {
        let tkhd = try MovBoxes.child(d, track, "tkhd")
        return d.be32(tkhd.dataOffset + (version(d, tkhd) == 1 ? 20 : 12))
    }

    static func setTrackID(_ d: inout [UInt8], _ track: Box, _ id: Int) throws {
        let tkhd = try MovBoxes.child(d, track, "tkhd")
        d.setBE32(tkhd.dataOffset + (version(d, tkhd) == 1 ? 20 : 12), id)
    }

    static func trackDuration(_ d: [UInt8], _ track: Box) throws -> Int {
        let tkhd = try MovBoxes.child(d, track, "tkhd")
        return version(d, tkhd) == 1 ? d.be64(tkhd.dataOffset + 28) : d.be32(tkhd.dataOffset + 20)
    }

    static func setTrackDuration(_ d: inout [UInt8], _ track: Box, _ duration: Int) throws {
        let tkhd = try MovBoxes.child(d, track, "tkhd")
        if version(d, tkhd) == 1 { d.setBE64(tkhd.dataOffset + 28, duration) } else { d.setBE32(tkhd.dataOffset + 20, duration) }
    }

    static func mediaTimescale(_ d: [UInt8], _ track: Box) throws -> Int {
        let mdhd = try MovBoxes.descendant(d, track, ["mdia", "mdhd"])
        return d.be32(mdhd.dataOffset + (version(d, mdhd) == 1 ? 20 : 12))
    }

    static func mediaDuration(_ d: [UInt8], _ track: Box) throws -> Int {
        let mdhd = try MovBoxes.descendant(d, track, ["mdia", "mdhd"])
        return version(d, mdhd) == 1 ? d.be64(mdhd.dataOffset + 24) : d.be32(mdhd.dataOffset + 16)
    }

    static func setMediaDuration(_ d: inout [UInt8], _ track: Box, _ duration: Int) throws {
        let mdhd = try MovBoxes.descendant(d, track, ["mdia", "mdhd"])
        if version(d, mdhd) == 1 { d.setBE64(mdhd.dataOffset + 24, duration) } else { d.setBE32(mdhd.dataOffset + 16, duration) }
    }

    static func sampleCount(_ d: [UInt8], _ track: Box) throws -> Int {
        let stsz = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl", "stsz"])
        return d.be32(stsz.dataOffset + 8)
    }

    /// Sample sizes of the track in decode order (`stsz`). A non-zero fixed size means every sample is that big, so then
    /// ONE entry is returned instead of `count` of them: use it for max/min, not for counting or indexing frames.
    static func sampleSizes(_ d: [UInt8], _ track: Box) throws -> [Int] {
        let stsz = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl", "stsz"])
        let end = stsz.offset + stsz.size
        guard stsz.dataOffset + 12 <= end else { throw MovError.malformed("truncated stsz") }
        let fixed = d.be32(stsz.dataOffset + 4), count = d.be32(stsz.dataOffset + 8)
        if fixed != 0 { return count > 0 ? [fixed] : [] }          // all samples equal: one entry says everything
        guard stsz.dataOffset + 12 + count * 4 <= end else { throw MovError.malformed("stsz sample count does not fit its box") }
        return (0..<count).map { d.be32(stsz.dataOffset + 12 + $0 * 4) }
    }

    /// Handler type of the track (`vide`, `meta`, `soun` ...).
    static func handlerType(_ d: [UInt8], _ track: Box) throws -> String {
        let hdlr = try MovBoxes.descendant(d, track, ["mdia", "hdlr"])
        return d.fourcc(hdlr.dataOffset + 8)
    }

    static func movieTimescale(_ d: [UInt8], _ moov: Box) throws -> Int {
        let mvhd = try MovBoxes.child(d, moov, "mvhd")
        return d.be32(mvhd.dataOffset + (version(d, mvhd) == 1 ? 20 : 12))
    }

    /// Edit-list entries as (segmentDuration, mediaTime) in movie / media timescale units.
    static func editList(_ d: [UInt8], _ track: Box) throws -> [(duration: Int, mediaTime: Int)]? {
        guard let edts = try MovBoxes.children(d, of: track).first(where: { $0.kind == "edts" }) else { return nil }
        let elst = try MovBoxes.child(d, edts, "elst")
        let v = version(d, elst)
        let n = d.be32(elst.dataOffset + 4)
        var o = elst.dataOffset + 8
        var out: [(Int, Int)] = []
        for _ in 0..<n {
            if v == 1 {
                let mt = d.be64(o + 8)
                out.append((d.be64(o), mt))   // all-ones wraps to -1: an empty edit
                o += 20
            } else {
                let mt = d.be32(o + 4)
                out.append((d.be32(o), mt == 0xFFFF_FFFF ? -1 : mt))
                o += 12
            }
        }
        return out
    }

    /// Shift every chunk offset of the track by `delta` (stco or co64).
    static func shiftChunkOffsets(_ d: inout [UInt8], _ track: Box, by delta: Int) throws {
        let stbl = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl"])
        if let stco = try MovBoxes.children(d, of: stbl).first(where: { $0.kind == "stco" }) {
            let count = d.be32(stco.dataOffset + 4)
            for i in 0..<count {
                let o = stco.dataOffset + 8 + i * 4
                let v = d.be32(o) + delta
                guard v >= 0, v <= 0xFFFF_FFFF else { throw MovError.unsupported("chunk offset does not fit in stco") }
                d.setBE32(o, v)
            }
        } else if let co64 = try MovBoxes.children(d, of: stbl).first(where: { $0.kind == "co64" }) {
            let count = d.be32(co64.dataOffset + 4)
            for i in 0..<count {
                let o = co64.dataOffset + 8 + i * 8
                d.setBE64(o, d.be64(o) + delta)
            }
        } else {
            throw MovError.malformed("track has neither stco nor co64")
        }
    }
}
