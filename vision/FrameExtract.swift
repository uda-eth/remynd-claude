// remynd-frames — pull real screen frames out of ReMynd's recording chunks.
//
// ReMynd records the screen into per-session chunk folders:
//   Recordings/<yyyy.MM.dd-HH.mm.ss.SSSS-WxH>/
//     movie-high-<W>x<H>.mov      full resolution
//     movie-half-<W>x<H>.mov      half
//     movie-small-250x<H>.mov     thumbnail
//     frames.log                  "dd.MM.yyyy HH:mm:ss.SSSS #  <index>"  (UTC)
//     frames.pts                  little-endian u64, unix_seconds * 600
//
// The .mov does NOT play at wall-clock speed: frames are packed back to back at
// the track's nominal rate (60fps here), so a 53-minute session is a ~19-second
// movie. Frame N therefore lives at N / fps seconds inside the file, and
// frames.pts / frames.log carry the only wall-clock mapping there is
// (pts value / 600 == unix epoch seconds).
//
// This tool maps a wall-clock range onto those frames, drops near-duplicates
// with a perceptual hash so a static screen doesn't cost 30 identical images,
// and writes PNGs plus a JSON manifest.
//
// Read-only: it never writes into the ReMynd profile.

import AVFoundation
import CommonCrypto
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Timeline

let PTS_TIMESCALE: Double = 600

struct Frame {
    let index: Int
    let epoch: Double        // absolute unix seconds (UTC)

    /// Position inside the .mov, which is packed at a constant nominal rate.
    func offset(fps: Double) -> Double { Double(index) / fps }
}

struct Chunk {
    let dir: URL
    let name: String
    let frames: [Frame]

    var start: Double { frames.first?.epoch ?? 0 }
    var end: Double { frames.last?.epoch ?? 0 }

    /// Movies present in this chunk, keyed by quality tier.
    func movie(quality: String) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let movs = items.filter { $0.pathExtension == "mov" }
        // Names look like movie-high-1710x1107.mov
        if let exact = movs.first(where: { $0.lastPathComponent.hasPrefix("movie-\(quality)-") }) {
            return exact
        }
        // Fall back down the ladder rather than failing outright.
        for tier in ["high", "half", "small"] {
            if let m = movs.first(where: { $0.lastPathComponent.hasPrefix("movie-\(tier)-") }) {
                return m
            }
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// Converted chunks (HLS)
//
// A chunk stays a .mov only while it is being written. Once ReMynd closes it,
// the movie is converted to HLS — `movie-<tier>-WxH.m3u8` at the chunk root,
// fMP4 segments under `_segs_/movie-<tier>-WxH/`, every segment (and the init
// segment) AES-128-CBC encrypted with one key and one IV per chunk. The key
// on disk (`_segs_/enc.key`) is itself wrapped with the user's storage key,
// which lives in the app's Keychain item and is not ours to read.
//
// So the running ReMynd app stays the key authority: it serves its own
// recordings to its own player over a loopback HTTP server, and that server
// hands out `enc.key` unwrapped. We ask it for the 16 bytes, decrypt only the
// segments a requested frame needs into a temporary fragmented MP4, and read
// that exactly like a .mov. Nothing is written into the profile; the temp
// file is deleted when we exit. Without the app running, converted chunks are
// reported as unreadable rather than silently empty.
//
// Timeline: the segment durations sum to frameCount / 60 exactly, so frame N
// still sits at N / fps seconds — the same packed clock as the .mov.
// ---------------------------------------------------------------------------

struct HLSSource {
    let tier: String
    let width: Int
    let playlist: URL
    let initURI: String                       // relative to the chunk dir
    let iv: [UInt8]
    let segments: [(uri: String, duration: Double)]
}

func parseHexBytes(_ hex: String) -> [UInt8]? {
    var h = hex.lowercased()
    if h.hasPrefix("0x") { h.removeFirst(2) }
    guard h.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var idx = h.startIndex
    while idx < h.endIndex {
        let next = h.index(idx, offsetBy: 2)
        guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}

extension Chunk {
    /// HLS playlists present at the chunk root, parsed. Empty for a live chunk.
    func hlsSources() -> [HLSSource] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [HLSSource] = []
        for pl in items where pl.pathExtension == "m3u8" && pl.lastPathComponent.hasPrefix("movie-") {
            // movie-half-2135x593.m3u8
            let base = pl.deletingPathExtension().lastPathComponent
            let parts = base.split(separator: "-")
            guard parts.count >= 3, let dims = parts.last,
                  let w = Int(dims.split(separator: "x").first ?? "") else { continue }
            let tier = String(parts[1])
            guard let text = try? String(contentsOf: pl, encoding: .utf8) else { continue }
            var iv: [UInt8]? = nil
            var initURI: String? = nil
            var segs: [(String, Double)] = []
            var pendingDuration: Double? = nil
            var encrypted = false
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#EXT-X-KEY:") {
                    encrypted = !line.contains("METHOD=NONE")
                    if let r = line.range(of: "IV=") {
                        let rest = line[r.upperBound...]
                        let hex = rest.split(separator: ",").first.map(String.init) ?? ""
                        iv = parseHexBytes(hex)
                    }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    if let r = line.range(of: "URI=\"") {
                        let rest = line[r.upperBound...]
                        initURI = rest.split(separator: "\"").first.map(String.init)
                    }
                } else if line.hasPrefix("#EXTINF:") {
                    let v = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                    pendingDuration = Double(v)
                } else if !line.hasPrefix("#"), !line.isEmpty {
                    segs.append((line, pendingDuration ?? 0))
                    pendingDuration = nil
                }
            }
            guard let initURI = initURI, !segs.isEmpty else { continue }
            // Only AES-128 with an explicit IV is what ReMynd writes; anything
            // else is a format we have not seen and should not guess at.
            if encrypted && iv == nil { continue }
            out.append(HLSSource(tier: tier, width: w, playlist: pl, initURI: initURI,
                                 iv: iv ?? [UInt8](repeating: 0, count: 16), segments: segs))
        }
        return out
    }

    /// The cheapest tier that still meets the requested output width.
    func hlsSource(minWidth: Int) -> HLSSource? {
        let sources = hlsSources()
        let enough = sources.filter { $0.width >= minWidth }.sorted { $0.width < $1.width }
        return enough.first ?? sources.sorted { $0.width > $1.width }.first
    }
}

/// Loopback ports the ReMynd app is listening on. Discovered once.
var remyndPorts: [Int]? = nil
func discoverRemyndPorts() -> [Int] {
    if let cached = remyndPorts { return cached }
    var ports: [Int] = []
    if let env = ProcessInfo.processInfo.environment["REMYND_HLS_PORT"], let p = Int(env) {
        ports.append(p)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "ReMynd"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = cols.dropFirst(8).first,
                  let colon = name.lastIndex(of: ":"),
                  let port = Int(name[name.index(after: colon)...]) else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
    }
    remyndPorts = ports
    return ports
}

func httpGET(_ url: URL, timeout: TimeInterval) -> Data? {
    var result: Data? = nil
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, http.statusCode == 200 { result = data }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}

var hlsKeyPort: Int? = nil
var hlsKeyCache: [String: [UInt8]] = [:]
var hlsKeyFailure: String? = nil

/// The unwrapped 16-byte AES key for a chunk, from the running app.
func hlsKey(chunkName: String) -> [UInt8]? {
    if let k = hlsKeyCache[chunkName] { return k }
    let ports = hlsKeyPort.map { [$0] } ?? discoverRemyndPorts()
    if ports.isEmpty {
        hlsKeyFailure = "ReMynd is not running — older recordings are encrypted and only the app can unlock them"
        return nil
    }
    let path = "/\(chunkName)/_segs_/enc.key"
    for port in ports {
        guard let url = URL(string: "http://127.0.0.1:\(port)" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
              let data = httpGET(url, timeout: 2), data.count == 16 else { continue }
        hlsKeyPort = port
        let key = [UInt8](data)
        hlsKeyCache[chunkName] = key
        return key
    }
    hlsKeyFailure = "ReMynd is running but did not hand over the key for \(chunkName)"
    return nil
}

func aes128CBCDecrypt(_ data: Data, key: [UInt8], iv: [UInt8]) -> Data? {
    let capacity = data.count + kCCBlockSizeAES128
    var out = Data(count: capacity)
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { i in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, i.baseAddress, data.count,
                    o.baseAddress, capacity, &moved)
        }
    }
    guard status == kCCSuccess else { return nil }
    out.count = moved
    return out
}

let scratchDir: URL = {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("remynd-frames-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()
func removeScratch() { try? FileManager.default.removeItem(at: scratchDir) }

/// Decrypt init + segments[0...upTo] into one fragmented MP4 we can open.
/// Returns the file and the seconds of media it covers.
func materializeHLS(chunk: Chunk, source: HLSSource, upToSecond: Double) -> (URL, Double)? {
    guard let key = hlsKey(chunkName: chunk.name) else { return nil }
    var acc = 0.0
    var last = -1
    for (i, s) in source.segments.enumerated() {
        last = i
        acc += s.duration
        if acc > upToSecond { break }
    }
    guard last >= 0 else { return nil }

    let outURL = scratchDir.appendingPathComponent("\(chunk.name)-\(source.tier).mp4")
    guard let handle = (FileManager.default.createFile(atPath: outURL.path, contents: nil)
                        ? try? FileHandle(forWritingTo: outURL) : nil) else { return nil }
    defer { try? handle.close() }

    let uris = [source.initURI] + source.segments[0...last].map(\.uri)
    for uri in uris {
        let f = chunk.dir.appendingPathComponent(uri)
        guard let enc = try? Data(contentsOf: f),
              let dec = aes128CBCDecrypt(enc, key: key, iv: source.iv) else {
            hlsKeyFailure = "could not decrypt \(uri) in \(chunk.name)"
            return nil
        }
        handle.write(dec)
    }
    return (outURL, acc)
}


// ---------------------------------------------------------------------------
// One display, not the whole desk
//
// With several displays attached, ReMynd records ONE canvas: every display
// laid out as macOS arranges them (4270x1187 = a 1710x1107 laptop beside a
// 2560x1080 monitor). Showing that canvas whole shrinks the display the user
// was working on to a third of the image, and a display that was asleep or
// lid-closed arrives as a slab of pure black beside it.
//
// So each frame is cut down to one display:
//   1. the layout comes from ScreenSetup (NSScreen coordinates, bottom-left
//      origin), and is only trusted when its bounding box has the canvas's
//      shape — a display unplugged mid-chunk must not re-slice a canvas that
//      still has the old shape;
//   2. displays that are blank (nothing captured) are dropped;
//   3. if more than one still has content, the one holding the focused window
//      wins. The window rect comes from OCRSurfaceInterval (CG-global points,
//      top-left origin, the main display's top edge at y=0). The mouse is NOT
//      used: it is routinely parked on the other display while typing.
// If none of that settles it, the whole canvas is shown, as before.
// ---------------------------------------------------------------------------

struct ScreenLayout { let epoch: Double; let frames: [CGRect] }
struct WindowSpan { let start: Double; let end: Double; let rect: CGRect }

/// "epoch|x,y,w,h;x,y,w,h" per line, from ScreenSetup.
func loadScreenLayouts(_ path: String) -> [ScreenLayout] {
    guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [ScreenLayout] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let e = Double(parts[0]) else { continue }
        var rects: [CGRect] = []
        for r in parts[1].split(separator: ";") {
            let v = r.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if v.count == 4, v[2] > 0, v[3] > 0 { rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
        }
        if !rects.isEmpty { out.append(ScreenLayout(epoch: e, frames: rects)) }
    }
    return out.sorted { $0.epoch < $1.epoch }
}

/// "start|end|x|y|w|h" per line, from OCRSurfaceInterval.
func loadWindowSpans(_ path: String) -> [WindowSpan] {
    guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [WindowSpan] = []
    for line in text.split(separator: "\n") {
        let v = line.split(separator: "|").compactMap { Double($0) }
        guard v.count == 6, v[4] > 0, v[5] > 0 else { continue }
        out.append(WindowSpan(start: v[0], end: v[1], rect: CGRect(x: v[2], y: v[3], width: v[4], height: v[5])))
    }
    return out.sorted { $0.start < $1.start }
}

func bboxOf(_ rects: [CGRect]) -> CGRect { rects.dropFirst().reduce(rects[0]) { $0.union($1) } }
func area(_ r: CGRect) -> Double { r.isNull || r.isEmpty ? 0 : Double(r.width * r.height) }

/// Canvas size from the chunk folder name: "...-4270x1187" (maybe "-unreadable" after).
func canvasSize(chunkName: String) -> CGSize? {
    for part in chunkName.split(separator: "-").reversed() {
        let wh = part.split(separator: "x")
        if wh.count == 2, let w = Double(wh[0]), let h = Double(wh[1]), w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
    }
    return nil
}

/// Display rects in canvas pixels (top-left origin) for a frame at `epoch`.
func displayRects(at epoch: Double, canvas: CGSize, layouts: [ScreenLayout])
    -> (rects: [CGRect], layout: ScreenLayout, scale: Double)? {
    guard canvas.width > 0, canvas.height > 0, !layouts.isEmpty else { return nil }
    func fit(_ l: ScreenLayout) -> Double? {
        let b = bboxOf(l.frames)
        guard b.width > 0, b.height > 0 else { return nil }
        let s = Double(canvas.width / b.width)
        return abs(Double(b.height) * s - Double(canvas.height)) <= max(2, Double(canvas.height) * 0.01) ? s : nil
    }
    var chosen: (ScreenLayout, Double)? = nil
    for l in layouts.reversed() where l.epoch <= epoch {
        if let s = fit(l) { chosen = (l, s); break }
    }
    if chosen == nil {
        for l in layouts where l.epoch > epoch { if let s = fit(l) { chosen = (l, s); break } }
    }
    guard let (layout, s) = chosen else { return nil }
    let b = bboxOf(layout.frames)
    let rects = layout.frames.map { f in
        CGRect(x: Double(f.minX - b.minX) * s, y: Double(b.maxY - f.maxY) * s,
               width: Double(f.width) * s, height: Double(f.height) * s).integral
    }
    return (rects, layout, s)
}

/// A CG-global window rect (top-left origin, main display's top at y=0) in canvas pixels.
func windowCanvasRect(_ w: CGRect, layout: ScreenLayout, scale s: Double) -> CGRect {
    let b = bboxOf(layout.frames)
    let main = layout.frames.first(where: { $0.minX == 0 && $0.minY == 0 }) ?? layout.frames[0]
    let nsMaxY = main.maxY - w.minY
    return CGRect(x: Double(w.minX - b.minX) * s, y: Double(b.maxY - nsMaxY) * s,
                  width: Double(w.width) * s, height: Double(w.height) * s)
}

/// True when a region holds nothing: an uncaptured display is exactly zero.
func isBlank(_ img: CGImage, region: CGRect) -> Bool {
    guard let sub = img.cropping(to: region) else { return false }
    let side = 96
    var px = [UInt8](repeating: 0, count: side * side)
    let drew: Bool = px.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
    }
    guard drew else { return false }
    let lit = px.reduce(0) { $0 + ($1 > 6 ? 1 : 0) }
    return lit * 1000 < px.count * 5          // under 0.5% of samples above near-black
}

/// Which part of the decoded image to keep: (rect in image pixels, display index, display count).
/// nil means keep the whole canvas.
func chooseDisplay(img: CGImage, epoch: Double, canvas: CGSize,
                   layouts: [ScreenLayout], windows: [WindowSpan]) -> (CGRect, Int, Int)? {
    guard let d = displayRects(at: epoch, canvas: canvas, layouts: layouts), d.rects.count > 1 else { return nil }
    let k = Double(img.width) / Double(canvas.width)
    let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let inImage = d.rects.map { r in
        CGRect(x: Double(r.minX) * k, y: Double(r.minY) * k,
               width: Double(r.width) * k, height: Double(r.height) * k).integral.intersection(bounds)
    }
    let lit = inImage.indices.filter { area(inImage[$0]) > 0 && !isBlank(img, region: inImage[$0]) }
    if lit.count == 1 { return (inImage[lit[0]], lit[0], d.rects.count) }
    guard lit.count > 1 else { return nil }
    if let w = windows.last(where: { $0.start - 1 <= epoch && epoch <= $0.end + 1 }) {
        let wr = windowCanvasRect(w.rect, layout: d.layout, scale: d.scale)
        let best = lit.max { area(d.rects[$0].intersection(wr)) < area(d.rects[$1].intersection(wr)) }!
        if area(d.rects[best].intersection(wr)) > 0 { return (inImage[best], best, d.rects.count) }
    }
    return nil
}

/// Scale so the longest edge is at most `maxEdge`.
func scaledToFit(_ img: CGImage, maxEdge: Int) -> CGImage {
    let longest = max(img.width, img.height)
    guard maxEdge > 0, longest > maxEdge else { return img }
    let f = Double(maxEdge) / Double(longest)
    let w = max(1, Int((Double(img.width) * f).rounded()))
    let h = max(1, Int((Double(img.height) * f).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? img
}


/// Reads frames.pts (preferred) or frames.log (fallback) into an absolute timeline.
func loadFrames(chunkDir: URL) -> [Frame] {
    let ptsURL = chunkDir.appendingPathComponent("frames.pts")
    if let data = try? Data(contentsOf: ptsURL), data.count >= 16 {
        var values: [UInt64] = []
        values.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { raw in
            let n = raw.count / 8
            for i in 0..<n {
                values.append(raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
            }
        }
        guard let first = values.first, first > 0 else { return loadFramesLog(chunkDir: chunkDir) }
        _ = first
        return values.enumerated().map { (i, v) in
            Frame(index: i, epoch: Double(v) / PTS_TIMESCALE)
        }
    }
    return loadFramesLog(chunkDir: chunkDir)
}

/// frames.log: "04.09.2026 03:34:22.4480 #     0"  — dd.MM.yyyy HH:mm:ss.SSSS in UTC.
func loadFramesLog(chunkDir: URL) -> [Frame] {
    let logURL = chunkDir.appendingPathComponent("frames.log")
    guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
    var out: [Frame] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "#", maxSplits: 1)
        guard parts.count == 2,
              let idx = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              let epoch = parseLogDate(String(parts[0]).trimmingCharacters(in: .whitespaces))
        else { continue }
        out.append(Frame(index: idx, epoch: epoch))
    }
    return out
}

func parseLogDate(_ s: String) -> Double? {
    // dd.MM.yyyy HH:mm:ss.SSSS
    let halves = s.split(separator: " ")
    guard halves.count == 2 else { return nil }
    let d = halves[0].split(separator: ".")
    let t = halves[1].split(separator: ":")
    guard d.count == 3, t.count == 3,
          let day = Int(d[0]), let mon = Int(d[1]), let yr = Int(d[2]),
          let hh = Int(t[0]), let mm = Int(t[1]) else { return nil }
    let secParts = t[2].split(separator: ".")
    guard let ss = Int(secParts[0]) else { return nil }
    var frac = 0.0
    if secParts.count > 1, let f = Double(secParts[1]) {
        frac = f / pow(10, Double(secParts[1].count))
    }
    var c = DateComponents()
    c.year = yr; c.month = mon; c.day = day
    c.hour = hh; c.minute = mm; c.second = ss
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    guard let date = cal.date(from: c) else { return nil }
    return date.timeIntervalSince1970 + frac
}

/// Chunk folders are named so that lexical order == chronological order, which
/// lets us skip reading frames.log for the hundreds of chunks that can't match.
func discoverChunks(recordings: URL, from: Double, to: Double) -> [Chunk] {
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: recordings, includingPropertiesForKeys: nil) else { return [] }
    let dirs = items
        .filter { $0.hasDirectoryPath && $0.lastPathComponent.first?.isNumber == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    // Coarse prefilter on the folder-name start time, keeping one chunk of
    // slack on the left so a range starting mid-chunk still finds its home.
    let fmtStart: (URL) -> Double? = { url in
        let name = url.lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return nil }
        let datePart = String(name[name.startIndex..<dash])          // yyyy.MM.dd
        let rest = String(name[name.index(after: dash)...])           // HH.mm.ss.SSSS-WxH
        guard let dash2 = rest.lastIndex(of: "-") else { return nil }
        let timePart = String(rest[rest.startIndex..<dash2])
        let d = datePart.split(separator: ".")
        let t = timePart.split(separator: ".")
        guard d.count == 3, t.count >= 3,
              let yr = Int(d[0]), let mon = Int(d[1]), let day = Int(d[2]),
              let hh = Int(t[0]), let mm = Int(t[1]), let ss = Int(t[2]) else { return nil }
        var c = DateComponents()
        c.year = yr; c.month = mon; c.day = day
        c.hour = hh; c.minute = mm; c.second = ss
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)?.timeIntervalSince1970
    }

    var candidates: [URL] = []
    var previous: URL? = nil
    for dir in dirs {
        guard let s = fmtStart(dir) else { continue }
        if s > to { break }
        if s >= from {
            if let p = previous, candidates.last != p { candidates.append(p) }
            candidates.append(dir)
        }
        previous = dir
    }
    // A range wholly inside one chunk matches no start time; take the last one before it.
    if candidates.isEmpty, let p = previous { candidates.append(p) }

    return candidates.compactMap { dir in
        let frames = loadFrames(chunkDir: dir)
        guard !frames.isEmpty else { return nil }
        let c = Chunk(dir: dir, name: dir.lastPathComponent, frames: frames)
        guard c.end >= from, c.start <= to else { return nil }
        return c
    }
}

// MARK: - Perceptual dedupe

/// 64-bit average hash. Two frames of a motionless screen collapse to the same
/// value, which is what keeps a 10-minute window from costing 200 images.
func averageHash(_ image: CGImage) -> UInt64 {
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side)
    let space = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: &pixels, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: side,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
    var hash: UInt64 = 0
    for (i, p) in pixels.enumerated() where Int(p) > mean {
        hash |= (1 << UInt64(i))
    }
    return hash
}

func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func isoLocal(_ epoch: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone.current
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

// MARK: - Arguments

struct Options {
    var profile: String = ""
    var ranges: [(Double, Double)] = []
    var prefer: String = "motion"     // motion | even
    var maxFrames: Int = 12
    var out: String = ""
    var width: Int = 1280
    var quality: String = "high"
    var dedupeDistance: Int = 6      // 0 disables
    var json: Bool = false
    var report: Bool = false         // final human-readable report (remynd-vision)
    var spansFile: String = ""       // "start|end|App" lines: frontmost-app timeline
    var note: String = ""
    var cropDisplay: Bool = false    // cut each frame to one display (see "One display")
    var screensFile: String = ""
    var windowsFile: String = ""
}

/// Frontmost-app spans handed over by remynd-vision, one "start|end|App" per line.
func loadSpans(_ path: String) -> [(Double, Double, String)] {
    guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [(Double, Double, String)] = []
    for line in text.split(separator: "\n") {
        let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3, let a = Double(f[0]), let b = Double(f[1]) else { continue }
        out.append((a, b, String(f[2])))
    }
    return out
}

struct FrameOut { let path: String; let epoch: Double; let chunk: String; let index: Int; var display: Int? = nil; var displays: Int? = nil }

/// Writes the final result: each frame labelled with the app that was frontmost.
///
/// This used to be a python3 heredoc inside remynd-vision. /usr/bin/python3 is
/// an Xcode shim, and an Xcode update that leaves the license unaccepted makes
/// every shim exit 69 — which took every frame request down with it. The
/// labelling is trivial, so it lives here now and the frame path needs nothing
/// but bash and this binary.
func emitResult(_ o: Options, frames: [FrameOut], considered: Int, deduped: Int,
                unreadable: Int, reason: String?) {
    let spans = loadSpans(o.spansFile)
    func appAt(_ t: Double) -> String {
        for (a, b, name) in spans where t >= a && t <= b { return name }
        return ""
    }
    var note = o.note
    if frames.isEmpty, let r = reason, !r.isEmpty { note = note.isEmpty ? r : note + ". " + r }

    if o.json {
        let rows: [[String: Any]] = frames.map { f -> [String: Any] in
            var r: [String: Any] = ["path": f.path, "time": isoLocal(f.epoch), "epoch": f.epoch,
                                    "chunk": f.chunk, "frame": f.index, "app": appAt(f.epoch)]
            if let d = f.display, let n = f.displays { r["display"] = d + 1; r["displays"] = n }
            return r
        }
        var obj: [String: Any] = ["frames": rows, "note": note, "considered": considered,
                                  "deduped": deduped, "unreadable": unreadable]
        if let r = reason, !r.isEmpty { obj["reason"] = r }
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
           let text = String(data: d, encoding: .utf8) { print(text) }
        return
    }
    if frames.isEmpty {
        print("No frames: \((reason?.isEmpty == false ? reason : nil) ?? "no distinct frames in that window")")
        return
    }
    if !note.isEmpty { print("note: \(note)") }
    print("\(frames.count) frame(s) — \(considered) captured, \(deduped) dropped as near-identical\n")
    for f in frames {
        let app = appAt(f.epoch)
        print("\(isoLocal(f.epoch))\(app.isEmpty ? "" : "  [\(app)]")\n  \(f.path)")
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("remynd-frames: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func parseArgs() -> Options {
    var o = Options()
    var pendingFrom: Double = 0
    var pendingTo: Double = 0
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func next(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--profile": o.profile = next("--profile")
        case "--from": pendingFrom = Double(next("--from")) ?? 0
        case "--to": pendingTo = Double(next("--to")) ?? 0
        case "--prefer": o.prefer = next("--prefer")
        case "--ranges":
            // "from:to,from:to" — lets the caller hand us only the stretches
            // where the app under test was actually frontmost.
            for pair in next("--ranges").split(separator: ",") {
                let ab = pair.split(separator: ":")
                if ab.count == 2, let a = Double(ab[0]), let b = Double(ab[1]), b > a {
                    o.ranges.append((a, b))
                }
            }
        case "--max": o.maxFrames = Int(next("--max")) ?? 12
        case "--out": o.out = next("--out")
        case "--width": o.width = Int(next("--width")) ?? 1280
        case "--quality": o.quality = next("--quality")
        case "--dedupe": o.dedupeDistance = Int(next("--dedupe")) ?? 6
        case "--json": o.json = true
        case "--report": o.report = true
        case "--spans": o.spansFile = next("--spans")
        case "--note": o.note = next("--note")
        case "--display-crop": o.cropDisplay = next("--display-crop") != "off"
        case "--screens": o.screensFile = next("--screens")
        case "--windows": o.windowsFile = next("--windows")
        case "-h", "--help":
            print("""
            remynd-frames --profile <ReMynd profile> --out <dir>
                          (--from <epoch> --to <epoch> | --ranges from:to,from:to)
                          [--max N] [--width px] [--quality high|half|small]
                          [--dedupe N] [--prefer motion|even] [--json]
            """)
            exit(0)
        default: fail("unknown argument \(args[i])")
        }
        i += 1
    }
    if pendingFrom > 0 && pendingTo > pendingFrom {
        o.ranges.append((pendingFrom, pendingTo))
    }
    if o.profile.isEmpty { fail("--profile is required") }
    if o.out.isEmpty { fail("--out is required") }
    if o.ranges.isEmpty { fail("need --from/--to or --ranges") }
    o.ranges.sort { $0.0 < $1.0 }
    return o
}

// MARK: - Main

let opts = parseArgs()
let screenLayouts = loadScreenLayouts(opts.screensFile)
let windowSpans = loadWindowSpans(opts.windowsFile)

let recordings = URL(fileURLWithPath: opts.profile).appendingPathComponent("Recordings")
guard FileManager.default.fileExists(atPath: recordings.path) else {
    fail("no Recordings folder at \(recordings.path)")
}

let spanFrom = opts.ranges.first!.0
let spanTo = opts.ranges.map(\.1).max()!
let chunks = discoverChunks(recordings: recordings, from: spanFrom, to: spanTo)
if chunks.isEmpty {
    if opts.json || opts.report { emitResult(opts, frames: [], considered: 0, deduped: 0, unreadable: 0, reason: "no recording covers that range") }
    else { FileHandle.standardError.write("remynd-frames: no recording covers that range\n".data(using: .utf8)!) }
    exit(0)
}

let outDir = URL(fileURLWithPath: opts.out)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Collect every candidate frame in range, then sample evenly. Sampling before
// extraction keeps us from decoding hundreds of frames to throw them away.
struct Candidate { let chunk: Chunk; let frame: Frame }
var candidates: [Candidate] = []
func inRange(_ t: Double) -> Bool {
    for (a, b) in opts.ranges where t >= a && t <= b { return true }
    return false
}
for c in chunks {
    for f in c.frames where inRange(f.epoch) {
        candidates.append(Candidate(chunk: c, frame: f))
    }
}
candidates.sort { $0.frame.epoch < $1.frame.epoch }

if candidates.isEmpty {
    if opts.json || opts.report { emitResult(opts, frames: [], considered: 0, deduped: 0, unreadable: 0, reason: "recording exists but captured no frames in that range") }
    exit(0)
}

// Oversample by 3x so perceptual dedupe still has room to reach --max distinct frames.
let budget = min(candidates.count, max(opts.maxFrames * 3, opts.maxFrames))
var sampled: [Candidate] = []
if candidates.count <= budget {
    sampled = candidates
} else if opts.prefer == "motion" {
    // ReMynd captures faster while the screen is changing, so the tightest
    // inter-frame gaps mark the moments something actually moved — an
    // animation playing, a window opening. Those are the frames worth having;
    // an idle screen is what the even sampler would waste the budget on.
    var scored: [(Int, Double)] = []
    for i in candidates.indices {
        let t = candidates[i].frame.epoch
        let before = i > 0 ? t - candidates[i - 1].frame.epoch : .greatestFiniteMagnitude
        let after = i < candidates.count - 1 ? candidates[i + 1].frame.epoch - t : .greatestFiniteMagnitude
        scored.append((i, min(before, after)))
    }
    scored.sort { $0.1 < $1.1 }
    let picked = scored.prefix(budget).map(\.0).sorted()
    sampled = picked.map { candidates[$0] }
} else {
    let step = Double(candidates.count - 1) / Double(budget - 1)
    for k in 0..<budget {
        sampled.append(candidates[Int((Double(k) * step).rounded())])
    }
}

// One generator per movie file; opening an asset is not free.
struct Decoder {
    let generator: AVAssetImageGenerator
    let fps: Double
    let duration: Double
}

/// AVFoundation's loaders are async; this is a CLI, so block on them.
func awaitValue<T>(_ work: @escaping () async throws -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    var result: T? = nil
    Task {
        result = try? await work()
        sem.signal()
    }
    sem.wait()
    return result
}

var decoders: [String: Decoder?] = [:]
func decoder(for chunk: Chunk) -> Decoder? {
    if let cached = decoders[chunk.name] { return cached }
    func build() -> Decoder? {
        // Cropping to one display needs the canvas at full resolution first:
        // downscaling the whole desk and then cropping leaves a 2560px display
        // about 940px wide.
        var decodeWidth = opts.width
        if opts.cropDisplay, let canvas = canvasSize(chunkName: chunk.name),
           (displayRects(at: chunk.start, canvas: canvas, layouts: screenLayouts)?.rects.count ?? 0) > 1
            || (displayRects(at: chunk.end, canvas: canvas, layouts: screenLayouts)?.rects.count ?? 0) > 1 {
            decodeWidth = max(opts.width, Int(canvas.width))
        }
        var movie = chunk.movie(quality: opts.quality)
        var hlsDuration: Double? = nil
        if movie == nil, let src = chunk.hlsSource(minWidth: decodeWidth) {
            // Decrypt only as far as the latest frame we will ask for.
            let needed = sampled.filter { $0.chunk.name == chunk.name }.map { $0.frame.index }.max() ?? 0
            let fpsGuess = Double(chunk.frames.count) / max(0.001, src.segments.reduce(0) { $0 + $1.duration })
            let upTo = Double(needed + 1) / (fpsGuess > 0 ? fpsGuess : 60)
            if let (url, covered) = materializeHLS(chunk: chunk, source: src, upToSecond: upTo) {
                movie = url
                hlsDuration = covered
            }
        }
        guard let movie = movie else { return nil }
        let asset = AVURLAsset(url: movie)
        guard let track = awaitValue({ try await asset.loadTracks(withMediaType: .video) })?.first
        else { return nil }
        // A live chunk is still being written, so duration is whatever was
        // readable when we opened it — seeking past it throws "Cannot Open".
        var duration = awaitValue({ CMTimeGetSeconds(try await asset.load(.duration)) }) ?? 0
        if let h = hlsDuration, h > 0 { duration = min(duration > 0 ? duration : h, h) }
        let rate = awaitValue({ Double(try await track.load(.nominalFrameRate)) }) ?? 0
        let fps = rate > 0 ? rate : 60
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.maximumSize = CGSize(width: decodeWidth, height: decodeWidth)
        return Decoder(generator: g, fps: fps, duration: duration)
    }
    let built = build()
    decoders[chunk.name] = built
    return built
}

struct Emitted {
    let path: String
    let epoch: Double
    let chunk: String
    let index: Int
    var display: Int? = nil
    var displays: Int? = nil
}

var emitted: [Emitted] = []
var lastHash: UInt64? = nil
var skippedDuplicates = 0
var unreadable = 0

for cand in sampled {
    if emitted.count >= opts.maxFrames { break }
    guard let dec = decoder(for: cand.chunk) else { unreadable += 1; continue }
    let offset = cand.frame.offset(fps: dec.fps)
    if dec.duration > 0 && offset > dec.duration { unreadable += 1; continue }
    let time = CMTime(value: Int64((offset * PTS_TIMESCALE).rounded()),
                      timescale: Int32(PTS_TIMESCALE))
    guard let decoded = try? dec.generator.copyCGImage(at: time, actualTime: nil) else {
        unreadable += 1
        continue
    }
    var cg = decoded
    var shownDisplay: (Int, Int)? = nil
    if opts.cropDisplay, let canvas = canvasSize(chunkName: cand.chunk.name),
       let pick = chooseDisplay(img: decoded, epoch: cand.frame.epoch, canvas: canvas,
                                layouts: screenLayouts, windows: windowSpans),
       let cropped = decoded.cropping(to: pick.0) {
        cg = cropped
        shownDisplay = (pick.1, pick.2)
    }
    cg = scaledToFit(cg, maxEdge: opts.width)

    if opts.dedupeDistance > 0 {
        let h = averageHash(cg)
        if let prev = lastHash, hamming(prev, h) < opts.dedupeDistance {
            skippedDuplicates += 1
            continue
        }
        lastHash = h
    }

    let stamp = isoLocal(cand.frame.epoch)
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: " ", with: "-")
    let name = String(format: "frame-%02d_%@.png", emitted.count + 1, stamp)
    let url = outDir.appendingPathComponent(name)
    guard writePNG(cg, to: url) else { continue }
    emitted.append(Emitted(path: url.path, epoch: cand.frame.epoch,
                           chunk: cand.chunk.name, index: cand.frame.index,
                           display: shownDisplay?.0, displays: shownDisplay?.1))
}

if opts.json || opts.report {
    removeScratch()
    emitResult(opts,
               frames: emitted.map { FrameOut(path: $0.path, epoch: $0.epoch, chunk: $0.chunk, index: $0.index, display: $0.display, displays: $0.displays) },
               considered: candidates.count, deduped: skippedDuplicates, unreadable: unreadable,
               reason: emitted.isEmpty ? hlsKeyFailure : nil)
} else {
    if emitted.isEmpty, let why = hlsKeyFailure {
        FileHandle.standardError.write(("remynd-frames: " + why + "\n").data(using: .utf8)!)
    }
    removeScratch()
    for e in emitted {
        print("\(isoLocal(e.epoch))\t\(e.path)")
    }
    if emitted.isEmpty {
        FileHandle.standardError.write("remynd-frames: decoded no frames\n".data(using: .utf8)!)
    }
}
