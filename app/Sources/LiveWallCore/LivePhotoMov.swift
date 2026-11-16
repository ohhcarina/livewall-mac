// Turns a plain HEVC .mov into a Live Photo wallpaper video by splicing in the device-verified timed-metadata tracks.
//
// Ported from pudding0503/live-photo-batch `prepare_wallpaper_video.py` (MIT, Copyright (c) 2026 Haoning Wu; see
// THIRD_PARTY/live-photo-batch.LICENSE) and the still-image-time patch of this repo's research/pipeline/build_lp.py.
// What it does, in order:
//   1. drop any existing live-photo-info / still-image-time track,
//   2. rewrite the file as  <ftyp etc.> <mdat: video payload + metadata payloads> <moov>,
//   3. clone the two metadata templates (new track ID, `cdsc` reference to the video track, sample tables, edit
//      lists) and append them to the moov,
//   4. set still-image-time (leading empty edit of the still track), fix that track's tkhd duration,
//   5. add the QuickTime track aperture (`tapt`) to the video track.
import Foundation

public enum LivePhotoMov {
    static let livePhotoInfoKey = Array("com.apple.quicktime.live-photo-info".utf8)
    static let stillImageTimeKey = Array("com.apple.quicktime.still-image-time".utf8)

    /// - Parameters:
    ///   - input: an .mov with one HEVC video track, `mdat` before `moov`.
    ///   - stillImageTime: seconds from the start of the video; must lie inside the video.
    /// - Returns: the wallpaper-ready .mov bytes.
    public static func prepareWallpaperVideo(_ input: [UInt8], stillImageTime: Double) throws -> [UInt8] {
        let top = try MovBoxes.topLevel(input)
        guard let mdat = top.first(where: { $0.kind == "mdat" }) else { throw MovError.malformed("no mdat") }
        guard let inMoov = top.first(where: { $0.kind == "moov" }) else { throw MovError.malformed("no moov") }
        guard mdat.headerSize == 8 || mdat.headerSize == 16, inMoov.headerSize == 8 else {
            throw MovError.unsupported("extended-size moov")
        }
        guard mdat.offset < inMoov.offset else { throw MovError.unsupported("moov before mdat") }

        var moov = Array(input[inMoov.offset..<inMoov.end])

        // 1. remove existing Live Photo metadata tracks (back to front so offsets stay valid)
        for track in try MovBoxes.children(moov, of: MovBoxes.rootBox(moov)).reversed() where track.kind == "trak" {
            if moov.contains(livePhotoInfoKey, from: track.offset, to: track.end)
                || moov.contains(stillImageTimeKey, from: track.offset, to: track.end) {
                moov.removeSubrange(track.offset..<track.end)
            }
        }
        moov.setBE32(0, moov.count)

        let root = MovBoxes.rootBox(moov)
        let tracks = try MovBoxes.children(moov, of: root).filter { $0.kind == "trak" }
        guard let video = try tracks.first(where: { try TrackFields.handlerType(moov, $0) == "vide" }) else {
            throw MovError.malformed("no video track")
        }
        let videoID = try TrackFields.trackID(moov, video)
        let videoSamples = try TrackFields.sampleCount(moov, video)
        let videoMediaDuration = try TrackFields.mediaDuration(moov, video)
        let videoTimescale = try TrackFields.mediaTimescale(moov, video)
        let movieTimescale = try TrackFields.movieTimescale(moov, root)
        var nextID = try tracks.map { try TrackFields.trackID(moov, $0) }.max()! + 1

        // presentation window of the video from its edit list (segments with media_time >= 0)
        let edits = try TrackFields.editList(moov, video)
        let presentationDuration: Int
        let presentationStart: Int
        if let edits {
            let real = edits.filter { $0.mediaTime >= 0 }
            guard let first = real.first else { throw MovError.malformed("video edit list has no media segment") }
            presentationDuration = real.reduce(0) { $0 + $1.duration }
            presentationStart = first.mediaTime
        } else {
            presentationDuration = Int((Double(videoMediaDuration) * Double(movieTimescale) / Double(videoTimescale)).rounded())
            presentationStart = 0
        }
        let leadingDuration = Int((Double(presentationStart) * Double(movieTimescale) / Double(videoTimescale)).rounded())

        let stillDuration = Double(presentationDuration) / Double(movieTimescale)
        guard stillImageTime >= 0, stillImageTime < stillDuration else {
            throw MovError.malformed("still-image-time \(stillImageTime)s is outside the video (\(stillDuration)s)")
        }

        // 2. new layout: prefix boxes, mdat(video payload + metadata payloads), moov
        let payload = Array(input[mdat.dataOffset..<mdat.end])
        var prefix: [UInt8] = []
        for b in top where b.kind != "mdat" && b.kind != "moov" { prefix += input[b.offset..<b.end] }
        let payloadOffset = prefix.count + 8
        let delta = payloadOffset - mdat.dataOffset
        for t in tracks { try TrackFields.shiftChunkOffsets(&moov, t, by: delta) }

        // 3. clone the metadata templates
        var cloned: [[UInt8]] = []
        var metaPayloads: [[UInt8]] = []
        var metaOffset = payloadOffset + payload.count
        for template in MetadataTemplates.all {
            var clone = template.track
            let cloneBox = Box(kind: "trak", offset: 0, size: clone.count, headerSize: 8)
            try TrackFields.setTrackID(&clone, cloneBox, nextID)
            try addVideoReference(&clone, videoTrackID: videoID)
            let c = Box(kind: "trak", offset: 0, size: clone.count, headerSize: 8)
            try setSingleChunkOffset(&clone, c, metaOffset)

            var sample = template.sample
            if template.isLivePhotoInfo {
                sample = Array(repeating: template.sample, count: videoSamples).flatMap { $0 }
                let metaTimescale = try TrackFields.mediaTimescale(clone, c)
                let total = Int((Double(videoMediaDuration) * Double(metaTimescale) / Double(videoTimescale)).rounded())
                guard total % videoSamples == 0 else {
                    throw MovError.malformed("video duration cannot be divided into metadata frame samples")
                }
                try setLivePhotoInfoTiming(&clone, c, count: videoSamples, sampleDuration: total / videoSamples,
                                           presentationDuration: presentationDuration, leading: leadingDuration)
            } else {
                try setStillImageTime(&clone, c, seconds: stillImageTime, movieTimescale: movieTimescale)
            }
            cloned.append(clone)
            metaPayloads.append(sample)
            metaOffset += sample.count
            nextID += 1
        }

        let lastTrackEnd = tracks.map(\.end).max()!
        moov.insert(contentsOf: cloned.flatMap { $0 }, at: lastTrackEnd)
        moov.setBE32(0, moov.count)
        let mvhd = try MovBoxes.child(moov, MovBoxes.rootBox(moov), "mvhd")
        moov.setBE32(mvhd.end - 4, nextID)         // next_track_ID

        // 5. aperture on the video track
        try addTrackAperture(&moov)

        let newPayload = payload + metaPayloads.flatMap { $0 }
        var out = prefix
        out += be32Bytes(newPayload.count + 8)
        out += Array("mdat".utf8)
        out += newPayload
        out += moov
        return out
    }

    // MARK: - template patching

    /// Insert `tref { cdsc -> videoTrackID }` in front of `mdia`.
    private static func addVideoReference(_ d: inout [UInt8], videoTrackID: Int) throws {
        let track = Box(kind: "trak", offset: 0, size: d.count, headerSize: 8)
        let mdia = try MovBoxes.child(d, track, "mdia")
        let ref = be32Bytes(12) + Array("cdsc".utf8) + be32Bytes(videoTrackID)
        let tref = be32Bytes(20) + Array("tref".utf8) + ref
        d.insert(contentsOf: tref, at: mdia.offset)
        d.setBE32(0, d.count)
    }

    private static func setSingleChunkOffset(_ d: inout [UInt8], _ track: Box, _ offset: Int) throws {
        let stco = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl", "stco"])
        guard d.be32(stco.dataOffset + 4) == 1 else { throw MovError.malformed("template metadata track must have one chunk") }
        d.setBE32(stco.dataOffset + 8, offset)
    }

    /// Two-entry edit list: first entry = leading empty edit, second = the media segment.
    private static func setMetadataEditList(_ d: inout [UInt8], _ track: Box, duration: Int, leading: Int) throws {
        let edts = try MovBoxes.child(d, track, "edts")
        let elst = try MovBoxes.child(d, edts, "elst")
        let v = TrackFields.version(d, elst)
        guard d.be32(elst.dataOffset + 4) == 2 else { throw MovError.malformed("template edit list must have two entries") }
        let first = elst.dataOffset + 8
        let second = first + (v == 1 ? 20 : 12)
        if v == 1 { d.setBE64(first, leading); d.setBE64(second, duration) } else { d.setBE32(first, leading); d.setBE32(second, duration) }
    }

    private static func setLivePhotoInfoTiming(_ d: inout [UInt8], _ track: Box, count: Int, sampleDuration: Int,
                                               presentationDuration: Int, leading: Int) throws {
        let stbl = try MovBoxes.descendant(d, track, ["mdia", "minf", "stbl"])
        let stts = try MovBoxes.child(d, stbl, "stts")
        let stsz = try MovBoxes.child(d, stbl, "stsz")
        let stsc = try MovBoxes.child(d, stbl, "stsc")
        guard stts.size == 24, stsc.size == 28 else { throw MovError.malformed("template sample tables must have one entry") }
        d.setBE32(stts.dataOffset + 4, 1)
        d.setBE32(stts.dataOffset + 8, count)
        d.setBE32(stts.dataOffset + 12, sampleDuration)
        d.setBE32(stsz.dataOffset + 8, count)
        d.setBE32(stsc.dataOffset + 4, 1)
        d.setBE32(stsc.dataOffset + 8, 1)
        d.setBE32(stsc.dataOffset + 12, count)
        d.setBE32(stsc.dataOffset + 16, 1)
        try TrackFields.setMediaDuration(&d, track, count * sampleDuration)
        try TrackFields.setTrackDuration(&d, track, leading + presentationDuration)
        try setMetadataEditList(&d, track, duration: presentationDuration, leading: leading)
    }

    /// Leading empty edit = still-image-time; the track's duration covers that edit plus the one real sample.
    private static func setStillImageTime(_ d: inout [UInt8], _ track: Box, seconds: Double, movieTimescale: Int) throws {
        let edts = try MovBoxes.child(d, track, "edts")
        let elst = try MovBoxes.child(d, edts, "elst")
        let v = TrackFields.version(d, elst)
        guard d.be32(elst.dataOffset + 4) == 2 else { throw MovError.malformed("still-image-time edit list must have two entries") }
        let first = elst.dataOffset + 8
        let second = first + (v == 1 ? 20 : 12)
        let leading = Int((seconds * Double(movieTimescale)).rounded())
        let tail = v == 1 ? d.be64(second) : d.be32(second)
        if v == 1 { d.setBE64(first, leading) } else { d.setBE32(first, leading) }
        try TrackFields.setTrackDuration(&d, track, leading + tail)
    }

    /// QuickTime clean / production / encoded-pixel apertures, sized from the video track's tkhd width x height.
    private static func addTrackAperture(_ moov: inout [UInt8]) throws {
        let root = MovBoxes.rootBox(moov)
        guard let video = try MovBoxes.children(moov, of: root).first(where: {
            try $0.kind == "trak" && TrackFields.handlerType(moov, $0) == "vide"
        }) else { throw MovError.malformed("no video track") }
        if try MovBoxes.children(moov, of: video).contains(where: { $0.kind == "tapt" }) { return }
        let tkhd = try MovBoxes.child(moov, video, "tkhd")
        let dims = Array(moov[tkhd.end - 8..<tkhd.end])      // 16.16 fixed width, height
        var children: [UInt8] = []
        for kind in ["clef", "prof", "enof"] {
            children += be32Bytes(20) + Array(kind.utf8) + be32Bytes(0) + dims
        }
        let tapt = be32Bytes(children.count + 8) + Array("tapt".utf8) + children
        moov.insert(contentsOf: tapt, at: tkhd.end)
        moov.setBE32(video.offset, video.size + tapt.count)
        moov.setBE32(0, moov.count)
    }
}
