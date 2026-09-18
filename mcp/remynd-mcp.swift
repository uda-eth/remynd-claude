// remynd-mcp — ReMynd's screen history as an MCP server.
//
// Speaks both standard transports from the one binary:
//
//   remynd-mcp                 stdio, for clients that launch a subprocess
//                              (Claude Desktop, Cursor, VS Code, Gemini CLI)
//   remynd-mcp --http [--port] Streamable HTTP on 127.0.0.1, for clients that
//                              want an endpoint — and, behind the user's own
//                              tunnel, for ChatGPT
//
// Retrieval is NOT reimplemented here. Every tool shells into the `remynd` CLI,
// which is the same code the Claude Code hooks use and the same code the
// accuracy suite grades. A second implementation would be a second set of
// timezone and rowid bugs; this way there is one.
//
// Written against MCP revision 2026-07-28, with the initialize-based lifecycle
// of earlier revisions still handled, because that is what shipping clients
// actually send today.
//
// No third-party dependencies. Foundation and Network only.

import Foundation
import Network
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Locating the CLI
// ---------------------------------------------------------------------------

/// Where the retrieval CLI lives. Checked in order; the first hit wins.
/// The app-bundle path is listed first so a copy shipped inside ReMynd.app is
/// preferred over a stale one a user installed months ago.
let cliCandidates: [String] = [
    // An explicit override, first. NSHomeDirectory() ignores an overridden
    // HOME, so without this there is no way to point the server at a different
    // CLI — which meant the stdout/stderr handling could not be tested against
    // a stub, and an unusual install had no escape hatch either.
    ProcessInfo.processInfo.environment["REMYND_CLI"] ?? "",
    Bundle.main.bundlePath + "/Contents/Resources/remynd",
    NSHomeDirectory() + "/.remynd-sync/core/remynd",
    NSHomeDirectory() + "/.remynd-sync/bin/remynd",
    "/usr/local/bin/remynd",
]

func locateCLI() -> String? {
    cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Runs the CLI and returns its combined output.
///
/// Arguments are passed as an array, never interpolated into a shell string —
/// a search query is arbitrary user text and must not be able to become a
/// command.
func runCLI(_ args: [String], timeout: TimeInterval = 30) -> (out: String, ok: Bool) {
    guard let cli = locateCLI() else {
        return ("ReMynd's retrieval CLI is not installed. Install it from https://remyndai.com/claude/install.sh", false)
    }
    return runScript(cli, args, timeout: timeout)
}

/// Runs one of ReMynd's bash tools (the CLI, or the frame extractor) and
/// returns its stdout. Same pipe discipline for both — see the comments.
func runScript(_ script: String, _ args: [String], timeout: TimeInterval = 30) -> (out: String, ok: Bool) {
    let label = (script as NSString).lastPathComponent
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")

    // Clients launch an MCP server with a minimal environment — Claude Desktop
    // passes no LANG at all. Window titles and OCR text are full of multibyte
    // characters, and under the C locale the text pipeline cannot decode them
    // and produces nothing. That presented as "reconstruct_day returns no
    // results" while the identical command worked from a terminal.
    if env["LC_ALL"] == nil && env["LANG"] == nil {
        env["LANG"] = "en_US.UTF-8"
    }
    p.environment = env

    // Separate pipes, deliberately.
    //
    // These used to be the SAME pipe, so a warning on stderr was spliced into
    // the middle of the results. BSD awk aborts a record with "illegal byte
    // sequence" and echoes a byte-truncated copy of it — invalid UTF-8 — which
    // made the strict decode below return nil for the whole run. A day with
    // 1,703 bytes of perfectly good output reported "No results", and the
    // report that followed spent its hypotheses on the database.
    //
    // Diagnostics are not data. Keep them apart, and never let one destroy the
    // other.
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    do { try p.run() } catch {
        return ("Could not run the ReMynd CLI: \(error.localizedDescription)", false)
    }

    // Read before waiting: a pipe that fills up deadlocks a process that is
    // still writing to it. With two pipes that applies to BOTH — draining
    // stdout while stderr fills would deadlock just as surely, so stderr is
    // drained on its own thread.
    var errData = Data()
    let errLock = NSLock()
    let drain = Thread {
        let d = errPipe.fileHandleForReading.readDataToEndOfFile()
        errLock.lock(); errData = d; errLock.unlock()
    }
    drain.start()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()

    // Enforce the timeout. It used to be an unused parameter, which meant a
    // wedged query could hang the client forever with no way to tell why.
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
        p.terminate()
        return ("The ReMynd query timed out after \(Int(timeout))s. Try a narrower time range.", false)
    }
    p.waitUntilExit()

    // Lossy on purpose. String(data:encoding:) returns nil for the WHOLE
    // buffer if a single byte is malformed — one bad byte anywhere and the
    // answer becomes "no results". Screen history is OCR of arbitrary text;
    // malformed bytes are a matter of when, not if. Decoding lossily replaces
    // the bad byte with U+FFFD and keeps the other 1,700.
    let text = String(decoding: data, as: UTF8.self)
    for _ in 0..<50 where drain.isExecuting { usleep(10_000) }
    errLock.lock(); let errText = String(decoding: errData, as: UTF8.self); errLock.unlock()

    // Never report emptiness as if it were an answer. An empty result with a
    // zero exit is a real "nothing found"; anything else is a fault, and the
    // model needs to see which so it can react instead of guessing.
    let complaint = errText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if p.terminationStatus != 0 {
            // Name the tool that failed and pass on what it said. A bare "the
            // CLI failed (exit 69)" hid an unaccepted Xcode license: the frame
            // script's /usr/bin/python3 is an Xcode shim, and the reason was on
            // stderr the whole time.
            return ("\(label) failed (exit \(p.terminationStatus)) and produced no output"
                    + (complaint.isEmpty ? ". " : ": " + String(complaint.prefix(4000)) + " ")
                    + "Command: \(label) \(args.joined(separator: " "))", false)
        }
        // Distinguish "nothing matched" from "something went wrong and I still
        // have nothing". Saying "matched nothing" when the CLI was complaining
        // the whole time is what sent this bug hunting through the database.
        if !complaint.isEmpty {
            return ("No output for: \(label) \(args.joined(separator: " ")), but it reported: "
                    + String(complaint.prefix(4000)), false)
        }
        return ("No results for: \(label) \(args.joined(separator: " ")). "
                + "The query ran cleanly and matched nothing — check sync_status for what is recorded.", true)
    }
    return (text, p.terminationStatus == 0)
}

// ---------------------------------------------------------------------------
// Result size
//
// A tool result is not a file. `screen_text_in_range` over a whole day returned
// 876,307 characters in real use and blew past the client's limit, which turns
// a useful answer into an error and wastes the round trip. Cap it, and say what
// was cut and how to ask for less.
// ---------------------------------------------------------------------------
let MAX_RESULT_CHARS = 24_000

func capped(_ text: String, hint: String) -> String {
    guard text.count > MAX_RESULT_CHARS else { return text }
    let head = String(text.prefix(MAX_RESULT_CHARS))
    // Cut at a line boundary so the tail is never a half-line.
    let trimmed = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
    let droppedLines = text.split(separator: "\n").count - trimmed.split(separator: "\n").count
    return trimmed + "\n\n[Truncated: \(droppedLines) more lines, "
         + "\(text.count - trimmed.count) more characters. \(hint)]"
}

// ---------------------------------------------------------------------------
// Tools
//
// The descriptions are load-bearing. A coding agent gets a skill file that
// teaches retrieval strategy; an MCP client gets only these strings. Every
// lesson the skill learned the hard way has to survive in them — especially
// that a timestamp records when something was SEEN, and that search returns a
// cursor whose substance you fetch separately.
// ---------------------------------------------------------------------------

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let run: ([String: Any]) -> (String, Bool)

    /// Optional: a result in ChatGPT's connector shape.
    ///
    /// Most tools answer with prose, which every client renders. ChatGPT's
    /// connector contract is stricter for `search` and `fetch` — it wants
    /// `structuredContent` with named fields, and it only turns a result into
    /// a citation when that result carries a non-empty `url`. A tool that sets
    /// this gets both: the structured object AND the same object JSON-encoded
    /// in the text content, which is what OpenAI's own reference servers emit.
    var structured: (([String: Any]) -> [String: Any]?)? = nil

    /// Optional: a result made of arbitrary content blocks (text AND images).
    ///
    /// `run` returns prose. A moment revealed as pixels is a list of blocks —
    /// caption, image, caption, image — and the image blocks are what a chat
    /// client renders inline. Returns (blocks, isError).
    var content: (([String: Any]) -> ToolContent)? = nil

    /// Optional: the tool's `_meta`. MCP Apps reads `_meta.ui` from here — the
    /// view that renders the result, and who may call the tool.
    var meta: [String: Any]? = nil
}

/// A result made of content blocks, with optional structuredContent. For MCP
/// Apps hosts, structuredContent goes to the view and is kept out of the
/// model's context.
struct ToolContent {
    var blocks: [[String: Any]]
    var isError: Bool
    var structured: [String: Any]? = nil
}

/// Reads a string argument, accepting common aliases.
///
/// Models reach for the names they know: `start`/`end` for a range, `day` for a
/// date. Rejecting those wastes a whole round trip telling them the name they
/// should have used — cheaper to accept the obvious synonyms.
func str(_ args: [String: Any], _ key: String, aliases: [String] = []) -> String? {
    for k in [key] + aliases {
        if let v = args[k] as? String, !v.isEmpty { return v }
    }
    return nil
}
func int(_ args: [String: Any], _ key: String) -> Int? {
    if let i = args[key] as? Int { return i }
    if let d = args[key] as? Double { return Int(d) }
    if let s = args[key] as? String { return Int(s) }
    return nil
}


// ---------------------------------------------------------------------------
// ChatGPT's connector contract
//
// ChatGPT will register any MCP server, but its default connector path looks
// for two tools by name — `search` and `fetch` — with a fixed result shape:
// search returns {id, title, url} rows, fetch turns one of those ids back into
// {id, title, text, url}. Servers that expose only their own tool names work
// in developer mode and nowhere else.
//
// So ReMynd exposes both. They are a thin shell over the same screen history
// the named tools read; the unit of a "result" is one focused window, because
// a word that sat on screen for ten minutes matches hundreds of OCR rows
// inside a single window and returning those as hundreds of documents is
// noise.
//
// On `url`: there are no web URLs to cite here — this is screen history, not
// a document store, and the browser-visit table is empty on a normal install.
// The id is minted as a remynd:// deep link instead. ReMynd registers that
// scheme, so the link is well-formed and stable, and ChatGPT will cite it.
// ---------------------------------------------------------------------------

private let momentDateOut: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM, HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
private let momentDateIn: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// `2026-08-19 19:01:24` <-> `2026-08-19T19:01:24`. The id travels through JSON
/// and back; keeping it free of spaces keeps it usable in a URL path too.
func momentID(fromTimestamp ts: String) -> String { ts.replacingOccurrences(of: " ", with: "T") }
func momentTimestamp(fromID id: String) -> String {
    // Decode first, then strip: ChatGPT may hand the url back percent-encoded,
    // in which case the scheme prefix is unrecognisable until it is decoded.
    var t = id.removingPercentEncoding ?? id
    if let r = t.range(of: "remynd://moment/") { t.removeSubrange(t.startIndex..<r.upperBound) }
    t = t.replacingOccurrences(of: "T", with: " ")
    // Accept a bare minute; the CLI wants seconds.
    let parts = t.split(separator: ":")
    if parts.count == 2 { t += ":00" }
    return t.trimmingCharacters(in: .whitespaces)
}

func momentTitle(app: String, window: String, timestamp: String) -> String {
    let when = momentDateIn.date(from: timestamp).map { momentDateOut.string(from: $0) } ?? timestamp
    let what = window.isEmpty ? app : (app.isEmpty ? window : "\(app) — \(window)")
    return what.isEmpty ? "Screen at \(when)" : "\(what) · \(when)"
}

func momentSearch(_ query: String, limit: Int) -> [[String: Any]] {
    let r = runCLI(["moments", query, String(limit)])
    guard r.ok else { return [] }
    var out: [[String: Any]] = []
    for line in r.out.split(separator: "\n") {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 4, !f[0].isEmpty else { continue }
        let id = momentID(fromTimestamp: f[0])
        out.append([
            "id": id,
            "title": momentTitle(app: f[1], window: f[2], timestamp: f[0]),
            "url": "remynd://moment/\(id)",
            // Not part of the contract, but ChatGPT shows it and it is the
            // difference between picking the right moment and guessing.
            "snippet": String(f[3].prefix(240))
        ])
    }
    return out
}


/// Bring an object inside the client's size limit, then encode it.
///
/// Two traps, both of which look like a broken server rather than a long
/// answer. First: truncating the ENCODED json stops it mid-string, and it no
/// longer parses. Second: capping only the encoded copy leaves the full text
/// in `structuredContent`, which is the half ChatGPT actually reads — so the
/// cap has to land on the object, and the encoding follows from it.
func cappedObject(_ obj: [String: Any]) -> [String: Any] {
    guard let text = obj["text"] as? String else { return obj }
    let overhead = jsonString(obj).count - text.count
    let room = MAX_RESULT_CHARS - overhead - 200
    guard room > 0, text.count > room else { return obj }
    var out = obj
    out["text"] = String(text.prefix(room))
        + "\n\n[truncated — this moment ran long; search for a tighter one]"
    return out
}

func momentFetch(_ rawID: String) -> [String: Any]? {
    let ts = momentTimestamp(fromID: rawID)
    let r = runCLI(["moment", ts])
    guard r.ok else { return nil }

    // First line is "<app>\t<window>", then a blank line, then the text.
    var app = "", window = ""
    var body = r.out
    if let nl = r.out.firstIndex(of: "\n") {
        let head = String(r.out[r.out.startIndex..<nl]).components(separatedBy: "\t")
        if head.count >= 2 { app = head[0]; window = head[1] }
        body = String(r.out[r.out.index(after: nl)...])
    }
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }

    let id = momentID(fromTimestamp: ts)
    return ["id": id,
            "title": momentTitle(app: app, window: window, timestamp: ts),
            "text": body,
            "url": "remynd://moment/\(id)",
            "metadata": ["source": "remynd-screen-history", "app": app, "window": window, "local_time": ts]]
}

// ---------------------------------------------------------------------------
// Revealing a moment as pixels
//
// Text answers "what was on screen". It cannot show it. `show_moment` pulls
// the real frames out of ReMynd's recording for a chosen instant and returns
// them as image content blocks, so the client renders the actual screen in
// the chat rather than a description of it.
//
// Extraction is not reimplemented here either: it shells into `remynd-vision`
// (the same extractor the Claude Code hooks use), which resolves the window,
// honours `sync_exclude` before anything is decoded, and hands back PNGs. This
// side only re-encodes them as JPEG at chat width, because a 1400px PNG of a
// screen is half a megabyte and base64 makes it worse; the same frame as JPEG
// is a fifth of that and reads identically.
// ---------------------------------------------------------------------------

let visionCandidates = [
    NSHomeDirectory() + "/.remynd-sync/bin/remynd-vision",
    "/usr/local/bin/remynd-vision",
]
func locateVision() -> String? {
    visionCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// The user's kill switch for pixels, separate from text: `vision_enabled=0`
/// in ~/.remynd-sync/config. Text retrieval keeps working when this is off.
func visionDisabledByConfig() -> Bool {
    let cfg = NSHomeDirectory() + "/.remynd-sync/config"
    guard let text = try? String(contentsOfFile: cfg, encoding: .utf8) else { return false }
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("vision_enabled=") {
            let v = t.dropFirst("vision_enabled=".count).trimmingCharacters(in: .whitespaces)
            return v == "0" || v.lowercased() == "false" || v.lowercased() == "no"
        }
    }
    return false
}

let FRAME_MAX_EDGE = 1568        // what a vision model is downscaled to anyway
let FRAME_JPEG_QUALITY = 0.82
let FRAME_MAX_COUNT = 4

/// Re-encode a PNG on disk as base64 JPEG no wider than `maxEdge`.
func jpegBase64(pngPath: String, maxEdge: Int, quality: Double) -> (data: String, width: Int, height: Int, bytes: Int)? {
    let url = URL(fileURLWithPath: pngPath) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
    return ((out as Data).base64EncodedString(), img.width, img.height, out.length)
}

private let momentSecondsIn: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
private let momentCaptionOut: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM, HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// Parse a local time the model is likely to hand us: "YYYY-MM-DD HH:MM[:SS]",
/// with a "T" tolerated, or a remynd://moment/ id.
func parseLocalMoment(_ raw: String) -> Date? {
    let ts = momentTimestamp(fromID: raw)      // handles T, remynd://, bare minute
    return momentSecondsIn.date(from: ts)
}

/// Build the content blocks for one moment. Pure orchestration: extractor →
/// JPEG → blocks. Every failure is a text block that says what happened, so the
/// model can react (widen the window, drop the app filter) instead of guessing.
func showOneMoment(_ a: [String: Any], label: String? = nil, withTrailer: Bool = true) -> MomentResult {
    // A bad argument or a missing extractor is an error the model should react
    // to; "nothing recorded there" is a clean answer, not an error.
    func fail(_ msg: String, isError: Bool = true) -> MomentResult {
        MomentResult(blocks: [["type": "text", "text": msg]], isError: isError)
    }

    guard let atRaw = str(a, "at", aliases: ["time", "timestamp", "when", "moment", "id"]) else {
        return fail("Provide `at` as a local time, \"YYYY-MM-DD HH:MM:SS\" (or up to three `moments`) — take it from a search_screen_history, reconstruct_day or screen_text_in_range result.")
    }
    guard let at = parseLocalMoment(atRaw) else {
        return fail("Could not read `at` = \"\(atRaw)\". Use local time as \"YYYY-MM-DD HH:MM:SS\".")
    }
    if visionDisabledByConfig() {
        return fail("Screen frames are switched off in ReMynd's agent settings (vision_enabled=0). Text retrieval still works; the user can turn frames on in ~/.remynd-sync/config.")
    }
    guard let vision = locateVision() else {
        return fail("This ReMynd install has no frame extractor (remynd-vision), so moments can only be described, not shown. Install it from https://remyndai.com/claude/install.sh")
    }

    let halfWindow = max(5, min(600, int(a, "window_seconds") ?? 30))
    let count = max(1, min(FRAME_MAX_COUNT, int(a, "max_frames") ?? 2))
    let app = str(a, "app", aliases: ["application"])

    let outDir = NSTemporaryDirectory() + "remynd-mcp-frames-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: outDir) }

    let from = momentSecondsIn.string(from: at.addingTimeInterval(-Double(halfWindow)))
    let to   = momentSecondsIn.string(from: at.addingTimeInterval(Double(halfWindow)))
    var args = ["--from", from, "--to", to, "--max", String(count),
                "--width", String(FRAME_MAX_EDGE), "--prefer", count == 1 ? "even" : "motion",
                "--all-apps", "--out", outDir, "--json"]
    if let app = app, !app.isEmpty { args += ["--app", app] }

    let r = runScript(vision, args, timeout: 60)
    guard r.ok, let data = r.out.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return fail("The frame extractor did not return a manifest for \(from) – \(to). " + String(r.out.prefix(300)))
    }
    let found = (obj["frames"] as? [[String: Any]]) ?? []
    if found.isEmpty {
        var why = "No recorded frames within ±\(halfWindow)s of \(momentSecondsIn.string(from: at))"
        if let app = app, !app.isEmpty { why += " while \(app) was frontmost" }
        if let note = obj["note"] as? String, !note.isEmpty { why += " (\(note))" }
        else if let reason = obj["reason"] as? String, !reason.isEmpty { why += " (\(reason))" }
        why += ". ReMynd may have been paused, the Mac asleep, or the app excluded from agent access. Try a wider window_seconds, drop the app filter, or check sync_status."
        return fail(why, isError: false)
    }

    // One caption per frame, then the frame. The caption carries what the
    // model needs to talk about the picture — app, window, exact second —
    // without OCR, which is the point of showing it. Each frame also gets a
    // record for the MCP Apps viewer, which draws it large in the chat.
    var out = MomentResult(blocks: [], isError: false)
    for f in found {
        guard let path = f["path"] as? String,
              let jpg = jpegBase64(pngPath: path, maxEdge: FRAME_MAX_EDGE, quality: FRAME_JPEG_QUALITY) else { continue }
        let when = (f["time"] as? String).flatMap { momentSecondsIn.date(from: $0) }.map { momentCaptionOut.string(from: $0) }
                   ?? (f["time"] as? String ?? "")
        let appName = (f["app"] as? String) ?? ""
        var window = ""
        if let t = f["time"] as? String {
            let m = runCLI(["moment", t], timeout: 10)
            if m.ok, let nl = m.out.firstIndex(of: "\n") {
                let head = String(m.out[m.out.startIndex..<nl]).components(separatedBy: "\t")
                if head.count >= 2 { window = head[1] }
            }
        }
        let what = window.isEmpty ? appName : (appName.isEmpty ? window : "\(appName) — \(window)")
        let head = "\(what.isEmpty ? "Screen" : what) · \(when)"
        out.blocks.append(["type": "text", "text": label.map { "\($0) — \(head)" } ?? head])
        out.blocks.append(["type": "image", "data": jpg.data, "mimeType": "image/jpeg"])

        let epoch = (f["epoch"] as? Double) ?? at.timeIntervalSince1970
        let id = String(Int64((epoch * 1000).rounded()))
        cacheFrame(id, (jpg.data, jpg.width, jpg.height))
        var record: [String: Any] = ["id": id, "what": what.isEmpty ? "Screen" : what, "when": when,
                                     "width": jpg.width, "height": jpg.height]
        if let label = label { record["label"] = label }
        if let t = f["time"] as? String { record["time"] = t }
        out.frames.append(record)
    }
    guard !out.frames.isEmpty else {
        return fail("Frames were found for \(from) – \(to) but none could be decoded. Try again, or check that ReMynd's recording is readable.")
    }
    if withTrailer {
        let n = out.frames.count
        out.blocks.append(["type": "text", "text":
            "\(n) frame\(n == 1 ? "" : "s") from the user's own screen recording, \(from) – \(to) local. "
            + "These are the real pixels that were on screen; describe what is visible and point the user at it."])
    }
    return out
}

/// show_moment entry point: one `at`, or up to three `moments` in a single call.
///
/// A recap usually rests on two or three moments. Asking for them one call at a
/// time is friction a model tends to skip, so one call can carry all of them,
/// each with a short label that becomes its caption.
func showMomentContent(_ a: [String: Any]) -> MomentResult {
    guard let list = a["moments"] as? [Any], !list.isEmpty else { return showOneMoment(a) }
    let items = Array(list.prefix(3))
    var out = MomentResult(blocks: [], isError: false)
    var errors = 0
    for (i, raw) in items.enumerated() {
        var m: [String: Any] = [:]
        if let d = raw as? [String: Any] { m = d } else if let t = raw as? String { m = ["at": t] }
        for k in ["app", "window_seconds"] where m[k] == nil { if let v = a[k] { m[k] = v } }
        m["max_frames"] = min(max(1, int(m, "max_frames") ?? int(a, "max_frames") ?? 1), 2)
        let label = (m["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let r = showOneMoment(m, label: label, withTrailer: false)
        if r.isError { errors += 1 }
        if !r.frames.isEmpty {
            out.blocks += r.blocks
            out.frames += r.frames
        } else {
            let why = (r.blocks.first?["text"] as? String) ?? "No frames."
            out.blocks.append(["type": "text", "text": "Moment \(i + 1)\(label.map { " (\($0))" } ?? ""): \(why)"])
        }
    }
    if !out.frames.isEmpty {
        out.blocks.append(["type": "text", "text":
            "Frames from the user's own screen recording, \(items.count) moment\(items.count == 1 ? "" : "s"). "
            + "These are the real pixels that were on screen; describe what is visible and tie each frame to the part of your answer it shows."])
    }
    out.isError = out.frames.isEmpty && errors == items.count
    return out
}

/// show_moment as a tool result: the blocks for the model, and for an MCP Apps
/// view a `frames` list naming each image block in order.
func showMomentToolContent(_ a: [String: Any]) -> ToolContent {
    let r = showMomentContent(a)
    var frames = r.frames
    for i in frames.indices { frames[i]["index"] = i }
    return ToolContent(blocks: r.blocks, isError: r.isError, structured: frames.isEmpty ? nil : ["frames": frames])
}

/// moment_frame — app-only. The viewer draws frames straight from the tool
/// result; this exists for a host that hands the view a result without the
/// image data, and for a conversation reopened after the server restarted.
func momentFrameContent(_ a: [String: Any]) -> ToolContent {
    guard let id = str(a, "id") else {
        return ToolContent(blocks: [["type": "text", "text": "Provide `id`."]], isError: true)
    }
    if let c = cachedFrame(id) {
        return ToolContent(blocks: [["type": "image", "data": c.data, "mimeType": "image/jpeg"]], isError: false,
                           structured: ["id": id, "width": c.width, "height": c.height])
    }
    guard let ms = Double(id), ms > 0 else {
        return ToolContent(blocks: [["type": "text", "text": "Unknown frame id."]], isError: true)
    }
    let when = momentSecondsIn.string(from: Date(timeIntervalSince1970: ms / 1000))
    let r = showOneMoment(["at": when, "window_seconds": 5, "max_frames": 1], withTrailer: false)
    if let img = r.blocks.first(where: { ($0["type"] as? String) == "image" }) {
        return ToolContent(blocks: [img], isError: false, structured: ["id": id])
    }
    return ToolContent(blocks: [["type": "text", "text": "That frame is no longer available."]], isError: true)
}

/// A next step appended to text results.
///
/// Models follow a concrete next step inside a tool result far more reliably
/// than a general instruction. Without it, a recap ended with "if you want, I
/// can pull the actual frames" instead of showing them. The example timestamp
/// is taken from the result itself, so it is a real, local, recorded moment.
func showMomentHint(tool: String, args: [String: Any], output: String) -> String? {
    func first(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let idx = m.numberOfRanges > 1 ? 1 : 0
        guard let r = Range(m.range(at: idx), in: text) else { return nil }
        return String(text[r])
    }
    let date = "\\d{4}-\\d{2}-\\d{2}"
    var example: String? = nil
    switch tool {
    case "search_screen_history":
        example = first("(\(date) \\d{2}:\\d{2}:\\d{2})", in: output)
    case "screen_text_in_range":
        if let d = str(args, "from", aliases: ["start", "begin", "since"]).flatMap({ first("^(\(date))", in: $0) }),
           let t = first("^(\\d{2}:\\d{2}:\\d{2})", in: output) { example = "\(d) \(t)" }
    case "reconstruct_day":
        if let d = str(args, "date", aliases: ["day", "start", "from"]).flatMap({ first("^(\(date))", in: $0) }),
           let t = first("(\\d{2}:\\d{2})–", in: output) { example = "\(d) \(t):00" }
    case "recent_activity":
        break
    default:
        return nil
    }
    var hint = "Next step: if your answer describes particular moments from this — a call, a meeting, a screen, "
        + "something the user saw or did — show the one to three that matter with show_moment in this same turn: "
        + "pass each moment's local time as `at`, or several at once as `moments` with a short `label` each"
    if let e = example { hint += " (for example at: \"\(e)\")" }
    hint += ". Show the frames alongside your answer rather than offering to pull them."
    return hint
}

// ---------------------------------------------------------------------------
// Moments, large and inline (MCP Apps)
//
// In Claude Desktop, image blocks in a tool result render inside the collapsed
// tool row as a thumbnail about 50px wide. MCP Apps (io.modelcontextprotocol/ui)
// is the supported way to put rich content in the conversation itself: the tool
// names a ui:// HTML resource in `_meta.ui.resourceUri`, the host renders it in
// a sandboxed iframe, and sends it the tool result over postMessage. The viewer
// (mcp/moment-viewer.html, embedded below) lays the frames out at the full
// width of the chat column.
//
// The image blocks stay in the result: the model needs to see the frames, and
// the viewer draws from those same blocks, so nothing is sent twice.
// structuredContent only names each frame. Hosts without MCP Apps ignore all of
// this and keep showing the tool row.
// ---------------------------------------------------------------------------

struct MomentResult {
    var blocks: [[String: Any]]
    var isError: Bool
    var frames: [[String: Any]] = []     // one record per image block, in order
}

let VIEWER_URI = "ui://remynd/moment-viewer.html"
let VIEWER_MIME = "text/html;profile=mcp-app"

/// Set from the client's initialize: did it advertise MCP Apps support?
var clientSupportsUI = false

var frameCache: [String: (data: String, width: Int, height: Int)] = [:]
var frameCacheOrder: [String] = []
let frameCacheLock = NSLock()
func cacheFrame(_ id: String, _ v: (data: String, width: Int, height: Int)) {
    frameCacheLock.lock(); defer { frameCacheLock.unlock() }
    if frameCache[id] == nil { frameCacheOrder.append(id) }
    frameCache[id] = v
    while frameCacheOrder.count > 24 { frameCache.removeValue(forKey: frameCacheOrder.removeFirst()) }
}
func cachedFrame(_ id: String) -> (data: String, width: Int, height: Int)? {
    frameCacheLock.lock(); defer { frameCacheLock.unlock() }
    return frameCache[id]
}

/// A small, content-free event log (~/.remynd-sync/state/mcp-events.log): which
/// client connected and what it advertised, which tools and resources it asked
/// for. Claude Desktop's own log hides initialize params, and this is how a
/// viewer that "doesn't show up" gets diagnosed without touching the screen.
let EVENTS_LOG = NSHomeDirectory() + "/.remynd-sync/state/mcp-events.log"
func logClientEvent(_ line: String) {
    let text = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (EVENTS_LOG as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: EVENTS_LOG))?[.size] as? Int, size > 256_000 {
        try? fm.removeItem(atPath: EVENTS_LOG)
    }
    if let h = FileHandle(forWritingAtPath: EVENTS_LOG) {
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
        try? text.write(toFile: EVENTS_LOG, atomically: true, encoding: .utf8)
    }
}

let MOMENT_VIEWER_HTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>ReMynd moments</title>
<style>
  :root {
    --fg: var(--color-text-primary, #1f1e1d);
    --muted: var(--color-text-secondary, #6b6a68);
    --line: var(--color-border-primary, rgba(31, 30, 29, 0.14));
    --skeleton: rgba(127, 127, 127, 0.12);
    --font: var(--font-sans, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif);
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --fg: var(--color-text-primary, #ecebe8);
      --muted: var(--color-text-secondary, #a6a39e);
      --line: var(--color-border-primary, rgba(236, 235, 232, 0.16));
    }
  }
  :root[data-theme="dark"] {
    --fg: var(--color-text-primary, #ecebe8);
    --muted: var(--color-text-secondary, #a6a39e);
    --line: var(--color-border-primary, rgba(236, 235, 232, 0.16));
  }
  html, body { margin: 0; padding: 0; background: transparent; color: var(--fg); font-family: var(--font); }
  main { display: flex; flex-direction: column; gap: 20px; padding: 2px 0 4px; }
  figure { margin: 0; min-width: 0; }
  figcaption {
    display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 10px;
    margin: 0 0 8px; font-size: 13px; line-height: 1.4;
  }
  .label { font-weight: 600; }
  .meta { color: var(--muted); overflow-wrap: anywhere; }
  .shot {
    display: block; width: 100%; margin: 0; padding: 0; font: inherit; appearance: none;
    border: 1px solid var(--line); border-radius: 12px; overflow: hidden; background: #0b0b0b; cursor: default;
  }
  .can-zoom .shot { cursor: zoom-in; }
  .fullscreen .shot { cursor: zoom-out; }
  .shot img { display: block; width: 100%; height: auto; }
  .skeleton {
    width: 100%; aspect-ratio: 16 / 7; border-radius: 12px; border: 1px solid var(--line);
    background: linear-gradient(90deg, var(--skeleton), rgba(127, 127, 127, 0.22), var(--skeleton));
    background-size: 200% 100%; animation: sheen 1.4s ease-in-out infinite;
  }
  @keyframes sheen { from { background-position: 200% 0; } to { background-position: -200% 0; } }
  @media (prefers-reduced-motion: reduce) { .skeleton { animation: none; } }
  .status { font-size: 13px; color: var(--muted); padding: 6px 0; }
  .fullscreen main { padding: 16px; }
</style>
</head>
<body>
<main id="root"><div class="status">Pulling frames from your ReMynd recording…</div></main>
<script>
(function () {
  "use strict";
  var root = document.getElementById("root");
  var nextId = 1;
  var pending = {};
  var hostContext = {};
  var displayMode = "inline";

  function post(msg) { msg.jsonrpc = "2.0"; window.parent.postMessage(msg, "*"); }
  function request(method, params) {
    var id = nextId++;
    post({ id: id, method: method, params: params || {} });
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
      setTimeout(function () {
        if (pending[id]) { delete pending[id]; reject(new Error("timeout: " + method)); }
      }, 30000);
    });
  }
  function notify(method, params) { post({ method: method, params: params || {} }); }

  window.addEventListener("message", function (event) {
    if (event.source !== window.parent) return;
    var m = event.data;
    if (!m || m.jsonrpc !== "2.0") return;
    if (m.id !== undefined && m.method === undefined) {
      var p = pending[m.id];
      if (!p) return;
      delete pending[m.id];
      if (m.error) p.reject(new Error(m.error.message || "error")); else p.resolve(m.result);
      return;
    }
    if (m.id !== undefined && m.method) {
      if (m.method === "ui/resource-teardown" || m.method === "ping") post({ id: m.id, result: {} });
      else post({ id: m.id, error: { code: -32601, message: "Method not found: " + m.method } });
      return;
    }
    switch (m.method) {
      case "ui/notifications/tool-input": onInput((m.params && m.params.arguments) || {}); break;
      case "ui/notifications/tool-result": onResult(m.params || {}); break;
      case "ui/notifications/tool-cancelled": setStatus("Cancelled."); break;
      case "ui/notifications/host-context-changed": applyContext(m.params || {}); break;
    }
  });

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function setStatus(text) { root.replaceChildren(el("div", "status", text)); reportSize(); }

  function applyContext(ctx) {
    for (var k in ctx) hostContext[k] = ctx[k];
    var vars = hostContext.styles && hostContext.styles.variables;
    if (vars) for (var v in vars) if (vars[v]) document.documentElement.style.setProperty(v, vars[v]);
    if (hostContext.theme) document.documentElement.setAttribute("data-theme", hostContext.theme);
    var modes = hostContext.availableDisplayModes || [];
    document.body.classList.toggle("can-zoom", modes.indexOf("fullscreen") >= 0);
    if (hostContext.displayMode) {
      displayMode = hostContext.displayMode;
      document.body.classList.toggle("fullscreen", displayMode === "fullscreen");
    }
    reportSize();
  }

  // While the frames are being pulled: one placeholder per requested moment.
  function onInput(args) {
    if (root.querySelector("img")) return;
    var moments = Array.isArray(args.moments) ? args.moments.slice(0, 3) : [args];
    var frag = document.createDocumentFragment();
    moments.forEach(function (m) {
      var fig = el("figure");
      var cap = el("figcaption");
      cap.append(el("span", "label", (m && m.label) || "Finding the moment…"));
      fig.append(cap, el("div", "skeleton"));
      frag.append(fig);
    });
    root.replaceChildren(frag);
    reportSize();
  }

  // The frames arrive inside the tool result: caption text, then the image.
  // structuredContent.frames names each image block in order. If a host hands
  // over a result without the image data, the frame is fetched by id through
  // the app-only moment_frame tool.
  function onResult(result) {
    var sc = result.structuredContent || {};
    var frames = Array.isArray(sc.frames) ? sc.frames : [];
    var images = (result.content || []).filter(function (b) { return b && b.type === "image" && b.data; });
    if (!frames.length && !images.length) {
      var t = (result.content || []).filter(function (b) { return b && b.type === "text"; })[0];
      setStatus(t ? t.text : "No frames for that moment.");
      return;
    }
    var list = frames.length ? frames : images.map(function (_, i) { return { index: i }; });
    var frag = document.createDocumentFragment();
    list.forEach(function (f, i) {
      var fig = el("figure");
      var cap = el("figcaption");
      if (f.label) cap.append(el("span", "label", f.label));
      var meta = [f.what, f.when].filter(Boolean).join(" · ");
      if (meta) cap.append(el("span", "meta", meta));
      var btn = el("button", "shot");
      btn.type = "button";
      var img = document.createElement("img");
      img.alt = f.label || f.what || "Screen frame";
      if (f.width && f.height) { img.width = f.width; img.height = f.height; }
      img.addEventListener("load", reportSize);
      var block = images[f.index != null ? f.index : i];
      if (block) img.src = "data:" + (block.mimeType || "image/jpeg") + ";base64," + block.data;
      else if (f.id) fetchFrame(f.id, img);
      btn.append(img);
      btn.addEventListener("click", toggleFullscreen);
      fig.append(cap, btn);
      frag.append(fig);
    });
    root.replaceChildren(frag);
    reportSize();
  }

  function fetchFrame(id, img) {
    request("tools/call", { name: "moment_frame", arguments: { id: id } }).then(function (r) {
      var b = ((r && r.content) || []).filter(function (x) { return x.type === "image" && x.data; })[0];
      if (b) img.src = "data:" + (b.mimeType || "image/jpeg") + ";base64," + b.data;
      else img.alt = "Frame unavailable";
    }).catch(function () { img.alt = "Frame unavailable"; });
  }

  function toggleFullscreen() {
    var modes = hostContext.availableDisplayModes || [];
    if (modes.indexOf("fullscreen") < 0) return;
    var want = displayMode === "fullscreen" ? "inline" : "fullscreen";
    request("ui/request-display-mode", { mode: want }).then(function (r) {
      applyContext({ displayMode: (r && r.mode) || want });
    }).catch(function () {});
  }

  var lastHeight = 0;
  function reportSize() {
    var h = Math.ceil(document.documentElement.getBoundingClientRect().height);
    if (h > 0 && h !== lastHeight) { lastHeight = h; notify("ui/notifications/size-changed", { height: h }); }
  }
  if (window.ResizeObserver) new ResizeObserver(reportSize).observe(document.documentElement);

  request("ui/initialize", {
    appInfo: { name: "ReMynd moments", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
    protocolVersion: "2026-01-26"
  }).then(function (res) {
    applyContext((res && res.hostContext) || {});
    notify("ui/notifications/initialized", {});
  }).catch(function () {
    notify("ui/notifications/initialized", {});
  });
})();
</script>
</body>
</html>
"""#

// ---------------------------------------------------------------------------
// Calls — what was said
//
// ReMynd records call audio (Zoom, Meet, Teams…) and transcribes it on the Mac,
// with speaker diarization, into Recordings/Extras/extras.db. None of it is in
// app.db, so every screen tool is deaf to it: a meeting looks unrecorded while
// its full transcript sits on disk. These tools shell into the CLI's `calls`,
// `call` and `heard`, which also merge the two copies that two running builds
// make of one meeting.
// ---------------------------------------------------------------------------

private let callDayFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// How many days `remynd calls` must look back to cover a whole local date.
func daysBack(toLocalDate s: String) -> Int? {
    guard let d = callDayFormat.date(from: String(s.prefix(10))) else { return nil }
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: Date()).day ?? 0
    return min(3650, max(1, days + 2))
}

/// `remynd calls` output, one record per call: its line plus the indented lines under it.
func callRecords(days: Int) -> (records: [String], ok: Bool, raw: String) {
    let r = runCLI(["calls", String(days)], timeout: 30)
    var recs: [String] = []
    for line in r.out.components(separatedBy: "\n") {
        if line.range(of: #"^  \d{4}-\d{2}-\d{2}  "#, options: .regularExpression) != nil {
            recs.append(line)
        } else if line.hasPrefix("      "), !recs.isEmpty {
            recs[recs.count - 1] += "\n" + line
        }
    }
    return (recs, r.ok, r.out)
}

/// The CLI's own next-step hints name CLI commands; say the tool names instead.
func mcpCallWording(_ s: String) -> String {
    s.replacingOccurrences(of: "Full transcript:  remynd call <id>        Audio file:  remynd call <id> --audio",
                           with: "Read what was said: call_transcript with call set to the id in brackets. Search every call: search_calls.")
     .replacingOccurrences(of: "Read one in full:  remynd call <id>",
                           with: "Read the conversation around a hit: call_transcript with call set to its id and from a minute before the hit.")
     .replacingOccurrences(of: "remynd calls 90", with: "list_calls with days: 90")
}

let CALL_PAGE_CHARS = 20_000
let CALL_CAVEAT = "Speaker labels come from on-device diarization and are about 85% reliable; \"?\" means unlabelled. "
    + "Names and jargon are often misheard (\"MCP\" can come out as \"NCP\"). "
    + "Check a quote against the lines around it before attributing it to someone."

func listCallsText(_ a: [String: Any]) -> (String, Bool) {
    if let date = str(a, "date", aliases: ["day"]) {
        guard let days = daysBack(toLocalDate: date) else { return ("`date` must be a local date, YYYY-MM-DD.", false) }
        let c = callRecords(days: days)
        guard c.ok else { return (mcpCallWording(c.raw), false) }
        let day = String(date.prefix(10))
        let hits = c.records.filter { $0.hasPrefix("  \(day)  ") }
        if hits.isEmpty {
            return ("No calls were recorded on \(day). A meeting ReMynd did not hear can still show up in reconstruct_day as a Zoom or Meet window.", true)
        }
        return ("# Calls on \(day)\n\n" + hits.joined(separator: "\n")
                + "\n\nRead what was said: call_transcript with call set to the id in brackets.", true)
    }
    let days = max(1, min(3650, int(a, "days") ?? 14))
    let c = callRecords(days: days)
    return (mcpCallWording(c.raw), c.ok)
}

/// "10:24", "10:24:05" or "2026-09-14 10:24" → "HH:MM:SS" for comparing transcript lines.
func normalizeClock(_ raw: String, end: Bool) -> String? {
    guard let m = raw.range(of: #"\d{1,2}:\d{2}(:\d{2})?"#, options: .regularExpression) else { return nil }
    var t = String(raw[m])
    if t.split(separator: ":").count == 2 { t += end ? ":59" : ":00" }
    if t.split(separator: ":")[0].count == 1 { t = "0" + t }
    return t
}

func callTranscriptText(_ a: [String: Any]) -> (String, Bool) {
    guard let sel = str(a, "call", aliases: ["id", "call_id", "title", "name"]) else {
        return ("Provide `call`: an id from list_calls or search_calls, \"last\" for the most recent call, or a fragment of its title or a participant's name.", false)
    }
    let r = runCLI(["call", sel], timeout: 30)
    guard r.ok else {
        // A fragment that matches several calls is a choice to make, not a
        // failure: hand the model the candidates, most recent first.
        if let pick = r.out.range(of: "matches ") , r.out.contains("pick one by id") {
            let list = String(r.out[pick.lowerBound...])
                .components(separatedBy: " Command: ").first ?? ""
            return ("\"\(sel)\" " + list.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\nMost recent first. Call call_transcript again with one id as `call`.", true)
        }
        return (mcpCallWording(r.out), false)
    }
    let lines = r.out.components(separatedBy: "\n")
    let isUtterance: (String) -> Bool = { $0.range(of: #"^\d{2}:\d{2}:\d{2}  "#, options: .regularExpression) != nil }
    guard let first = lines.firstIndex(where: isUtterance) else { return (mcpCallWording(r.out), true) }
    let header = lines[..<first].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    var body = lines[first...].filter(isUtterance)

    let fromT = str(a, "from", aliases: ["start"]).flatMap { normalizeClock($0, end: false) }
    let toT = str(a, "to", aliases: ["end"]).flatMap { normalizeClock($0, end: true) }
    if let f = fromT { body = body.filter { String($0.prefix(8)) >= f } }
    if let t = toT { body = body.filter { String($0.prefix(8)) <= t } }
    let ranged = fromT != nil || toT != nil
    let total = body.count
    let offset = max(0, int(a, "offset") ?? 0)

    // A call runs 25–45k characters, past what one tool result should carry.
    // Page it, and say exactly how to get the next page.
    var text = header + "\n\n"
    if total == 0 {
        text += ranged ? "No transcript lines between \(fromT ?? "the start") and \(toT ?? "the end") of this call."
                       : "This call has no transcript lines."
    } else if offset >= total {
        text += "offset \(offset) is past the end: this \(ranged ? "range" : "call") has \(total) transcript lines."
    } else {
        var budget = CALL_PAGE_CHARS - header.count - CALL_CAVEAT.count
        var page: [String] = []
        var i = offset
        while i < total {
            let cost = body[i].count + 1
            if cost > budget && !page.isEmpty { break }
            page.append(body[i]); budget -= cost; i += 1
        }
        let span = ranged ? " between \(fromT ?? "the start") and \(toT ?? "the end")" : ""
        text += "Transcript lines \(offset + 1)–\(i) of \(total)\(span):\n\n" + page.joined(separator: "\n")
        if i < total {
            text += "\n\n[continues — call call_transcript again with the same call and offset: \(i) for the next page, or narrow it with from/to]"
        }
    }
    return (text + "\n\n" + CALL_CAVEAT, true)
}

func searchCallsText(_ a: [String: Any]) -> (String, Bool) {
    guard let raw = str(a, "query", aliases: ["q", "text", "words"]) else { return ("Provide a `query`.", false) }
    // The transcript index is SQLite FTS. Punctuation there is syntax — a hyphen
    // or a colon turns into an operator and the query silently matches nothing,
    // which reads as "never said". Keep words and quoted phrases only.
    let cleaned = String(raw.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "\"" ? $0 : " " })
        .split(separator: " ").joined(separator: " ")
    guard !cleaned.isEmpty else { return ("Provide words to search for.", false) }
    let limit = max(1, min(100, int(a, "limit") ?? 20))
    let r = runCLI(["heard", cleaned, String(limit)], timeout: 30)
    return (mcpCallWording(r.out), r.ok)
}

let tools: [Tool] = [

    Tool(name: "search_screen_history",
         description: """
         Full-text search of everything the user has seen on screen, as read by OCR. Use it whenever they refer to something they saw, read or did but cannot fully remember.
         
         A timestamp records when text was ON SCREEN, not when the event happened. Treat a hit as a cursor: read around it with screen_text_in_range. Words said out loud are not in this index — use search_calls.
         """,
         schema: ["type": "object",
                  "properties": [
                     "query": ["type": "string", "description": "Words to find; multiple are ANDed."],
                     "limit": ["type": "integer", "description": "Max matches. Default 40."]
                  ],
                  "required": ["query"]],
         run: { a in
             guard let q = str(a, "query") else { return ("Provide a `query`.", false) }
             var args = ["search", q]
             if let l = int(a, "limit") { args.append(String(l)) }
             let r = runCLI(args); return (r.out, r.ok)
         }),

    Tool(name: "reconstruct_day",
         description: """
         What the user worked on during one local day, ranked by time actually spent, each with its span, plus an hour-by-hour trail. Use for "what did I do on Tuesday".
         
         Read what happened inside an activity with screen_text_in_range over its span. Calls recorded that day are listed first with their ids; what was said on them is in call_transcript.
         """,
         schema: ["type": "object",
                  "properties": ["date": ["type": "string", "description": "Local date, YYYY-MM-DD."]],
                  "required": ["date"]],
         run: { a in
             guard let d = str(a, "date", aliases: ["day", "start", "from"]) else {
                 return ("Provide a `date` as YYYY-MM-DD.", false)
             }
             let r = runCLI(["day", d])
             // The day view is built from screen history, which cannot hear. Name
             // that day's calls up front so a meeting is never read as silence.
             guard r.ok, let back = daysBack(toLocalDate: d) else { return (r.out, r.ok) }
             let day = String(d.prefix(10))
             let calls = callRecords(days: back).records.filter { $0.hasPrefix("  \(day)  ") }
             guard !calls.isEmpty else { return (r.out, r.ok) }
             let section = "## Calls recorded that day — audio, transcribed\n\n"
                 + "The screen history below cannot hear. What was said on these calls is in call_transcript "
                 + "(call: the id in brackets).\n\n" + calls.joined(separator: "\n")
             var parts = r.out.components(separatedBy: "\n")
             if let head = parts.first, head.hasPrefix("# ") {
                 parts.removeFirst()
                 return (head + "\n\n" + section + "\n" + parts.joined(separator: "\n"), true)
             }
             return (section + "\n\n" + r.out, true)
         }),

    Tool(name: "recent_activity",
         description: """
         What the user is doing right now and has done in the last couple of hours: current app and window, recent work ranked by time, and the verbatim text just on screen. Use to orient at the start of a conversation, or for "where did I leave off".
         """,
         schema: ["type": "object",
                  "properties": ["minutes": ["type": "integer", "description": "Minutes back. Default 30."]]],
         run: { a in
             var args = ["recent"]
             if let m = int(a, "minutes") { args.append(String(m)) }
             let r = runCLI(args); return (r.out, r.ok)
         }),

    Tool(name: "screen_text_in_range",
         description: """
         The verbatim text on the user's screen between two LOCAL times — the substance behind an activity, not just its duration.
         
         Narrow first with search_screen_history or a reconstruct_day span; an hour reads well, a whole day is truncated. The text is OCR: fragments and garbled words, digits least reliable. Report what it means rather than quoting it raw, and leave out anything too mangled to be sure of.
         """,
         schema: ["type": "object",
                  "properties": [
                     "from": ["type": "string", "description": "Local start, \"YYYY-MM-DD HH:MM\"."],
                     "to": ["type": "string", "description": "Local end. Defaults to now."]
                  ],
                  "required": ["from"]],
         run: { a in
             guard let f = str(a, "from", aliases: ["start", "begin", "since"]) else {
                 return ("Provide `from` as \"YYYY-MM-DD HH:MM\".", false)
             }
             var args = ["text", f]
             if let t = str(a, "to", aliases: ["end", "until"]) { args.append(t) }
             let r = runCLI(args); return (r.out, r.ok)
         }),

    Tool(name: "time_by_activity",
         description: """
         How much of the user's time went to each application over the last N days. The only tool that measures duration — screen text cannot.
         
         Counts back from today and takes `days`, not a date range. For one specific day use reconstruct_day, which ranks by what was being done rather than which app was focused.
         """,
         schema: ["type": "object",
                  "properties": ["days": ["type": "integer", "description": "How many days back. Default 7."]]],
         run: { a in
             // This tool counts backwards from today; it cannot take a range.
             // Silently returning the last 7 days when asked about one specific
             // day is worse than refusing — the caller believes the number.
             if str(a, "start", aliases: ["from", "begin"]) != nil || str(a, "end", aliases: ["to", "until"]) != nil {
                 return ("time_by_activity only counts backwards from today, using `days`. "
                         + "For a specific date or range, use reconstruct_day, which ranks what was "
                         + "actually worked on and gives each activity its time span.", false)
             }
             var args = ["apps"]
             if let d = int(a, "days") { args.append(String(d)) }
             let r = runCLI(args); return (r.out, r.ok)
         }),

    Tool(name: "search",
         description: """
         Search everything the user has seen on screen. Returns matching moments, one per app window, each with an id, the window, and a snippet. Call `fetch` with an id to read that moment.
         
         A timestamp records when the text was ON SCREEN, not when the event happened.
         """,
         schema: ["type": "object",
                  "properties": ["query": ["type": "string", "description": "What to look for."]],
                  "required": ["query"]],
         run: { a in
             guard let q = str(a, "query") else { return ("Provide a `query`.", false) }
             let rows = momentSearch(q, limit: int(a, "limit") ?? 20)
             if rows.isEmpty { return ("(no matches — try fewer or different words)", true) }
             return (jsonString(["results": rows]), true)
         },
         structured: { a in
             guard let q = str(a, "query") else { return nil }
             return ["results": momentSearch(q, limit: int(a, "limit") ?? 20)]
         }),

    Tool(name: "fetch",
         description: """
         Read what was on the user's screen at one moment, given an id from `search`. Returns the verbatim text around that moment and which app and window it was. OCR, so digits are the weak point — treat numbers read off a screen as leads, not facts.
         """,
         schema: ["type": "object",
                  "properties": ["id": ["type": "string", "description": "An id returned by `search`."]],
                  "required": ["id"]],
         run: { a in
             guard let raw = str(a, "id", aliases: ["identifier", "document_id", "documentId", "url"])
                 else { return ("Provide an `id` from a `search` result.", false) }
             let doc = momentFetch(raw)
             guard let d = doc else { return ("No screen history at that moment.", false) }
             return (jsonString(d), true)
         },
         structured: { a in
             guard let raw = str(a, "id", aliases: ["identifier", "document_id", "documentId", "url"])
                 else { return nil }
             return momentFetch(raw)
         }),

    Tool(name: "list_calls",
         description: """
         Calls and meetings ReMynd recorded and transcribed on this Mac: date, time, length, app, title, participants, line and speaker counts, and the call id in brackets. The screen tools cannot hear, so this is where meetings live.
         """,
         schema: ["type": "object",
                  "properties": [
                     "date": ["type": "string", "description": "One local day, YYYY-MM-DD."],
                     "days": ["type": "integer", "description": "Days back. Default 14."]
                  ]],
         run: listCallsText),

    Tool(name: "call_transcript",
         description: """
         What was said on a call: the diarized transcript, one timestamped line per utterance with its speaker. Use for "what did X say about Y", a recap, or anything said out loud.
         
         `call` takes an id from list_calls or search_calls, "last", or a title or participant fragment. Speaker labels are about 85% reliable and names are often misheard, so check a quote against the lines around it before attributing it.
         """,
         schema: ["type": "object",
                  "properties": [
                     "call": ["type": "string", "description": "Call id, \"last\", or a title/participant fragment."],
                     "from": ["type": "string", "description": "Optional. Start time within the call, e.g. \"10:24\"."],
                     "to": ["type": "string", "description": "Optional. Local time within the call to stop at."],
                     "offset": ["type": "integer", "description": "Optional. Line to start from (from the previous page)."]
                  ],
                  "required": ["call"]],
         run: callTranscriptText),

    Tool(name: "search_calls",
         description: """
         Full-text search across every call transcript — words people said out loud, as opposed to what was on screen. Returns matching lines newest first with the time, speaker, call title and id.
         
         It returns at most 100 lines, newest first, and takes no date range: to reach a specific day, use list_calls for that date and then call_transcript. Open the conversation around a hit with call_transcript, `from` a minute or two before it.
         """,
         schema: ["type": "object",
                  "properties": [
                     "query": ["type": "string", "description": "Words to find in what was said."],
                     "limit": ["type": "integer", "description": "Max matches. Default 20."]
                  ],
                  "required": ["query"]],
         run: searchCallsText),

    Tool(name: "show_moment",
         description: """
         Reveal a moment from the user's screen as the real frames — the actual pixels, returned as images you and the user both see.
         
         Costly, so spend it where it counts: the one or two headline moments an answer is really about, shown in the same turn without asking first. Do NOT call it to check a fact or to confirm what something said — the screen text already came back from the search tools. Skip it for pure numbers, and for recaps beyond their single headline moment.
         
         Locate the moment first, then pass its local timestamp as `at`, or up to three as `moments` with a short `label` each. Frames come from a ±window around `at` (default 30s, 2 frames); `app` keeps to one application. Recordings older than the current hour need the ReMynd app running, and some segments cannot be decrypted — a failure here is not an answer, so say what the text shows instead. A frame is the raw screen and is not redacted: never read a password or key out of one.
         """,
         schema: ["type": "object",
                  "properties": [
                     "at": ["type": "string", "description": "Local \"YYYY-MM-DD HH:MM:SS\"; bare HH:MM accepted."],
                     "app": ["type": "string", "description": "Only frames while this app was frontmost (substring)."],
                     "window_seconds": ["type": "integer", "description": "Seconds either side of `at`. Default 30, max 600."],
                     "max_frames": ["type": "integer", "description": "Frames to return, 1–4. Default 2."],
                     "moments": ["type": "array", "maxItems": 3,
                                 "description": "Up to three moments instead of `at`.",
                                 "items": ["type": "object",
                                           "properties": [
                                              "at": ["type": "string", "description": "Local time, \"YYYY-MM-DD HH:MM:SS\"."],
                                              "label": ["type": "string", "description": "Short caption."],
                                              "app": ["type": "string", "description": "Optional app filter for this moment."]
                                           ],
                                           "required": ["at"]]]
                  ]],
         run: { _ in ("show_moment returns image content; this client did not request it.", false) },
         content: showMomentToolContent,
         meta: ["ui": ["resourceUri": VIEWER_URI]]),

    Tool(name: "moment_frame",
         description: "Used by ReMynd's moment viewer to reload a frame it is displaying. Not for answering questions: use show_moment.",
         schema: ["type": "object",
                  "properties": ["id": ["type": "string", "description": "A frame id from a show_moment result."]],
                  "required": ["id"]],
         run: { _ in ("moment_frame returns image content.", false) },
         content: momentFrameContent,
         meta: ["ui": ["resourceUri": VIEWER_URI, "visibility": ["app"]]]),

    Tool(name: "sync_status",
         description: """
         What ReMynd has recorded and how fresh it is: the profile being read, how far back history goes, the last capture, and whether credential redaction is on. Call it before telling the user something is not in their history — it separates "no record of that" from "not recording then".
         """,
         schema: ["type": "object", "properties": [:]],
         run: { _ in let r = runCLI(["status"]); return (r.out, r.ok) }),
]

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

let SERVER_NAME = "remynd"
let SERVER_VERSION = "1.4.0"
let SUPPORTED_PROTOCOLS = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
let DEFAULT_PROTOCOL = "2025-06-18"

func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

func errorResponse(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
    var r: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
    r["id"] = id ?? NSNull()
    return r
}

func toolListPayload() -> [[String: Any]] {
    tools.compactMap { t in
        let visibility = ((t.meta?["ui"] as? [String: Any])?["visibility"] as? [String]) ?? ["model", "app"]
        // An MCP Apps host hides app-only tools from its model itself. A client
        // without MCP Apps would hand them straight to the model, so don't list them.
        if !visibility.contains("model") && !clientSupportsUI { return nil }
        var d: [String: Any] = ["name": t.name, "description": t.description, "inputSchema": t.schema]
        if let m = t.meta { d["_meta"] = m }
        return d
    }
}

/// Handles one JSON-RPC message. Returns nil for notifications, which take no
/// reply on either transport.
func handle(_ msg: [String: Any]) -> [String: Any]? {
    let id = msg["id"]
    guard let method = msg["method"] as? String else {
        return errorResponse(id, -32600, "Invalid request: no method")
    }
    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {

    case "initialize":
        let clientCaps = params["capabilities"] as? [String: Any] ?? [:]
        let extensions = clientCaps["extensions"] as? [String: Any] ?? [:]
        clientSupportsUI = extensions["io.modelcontextprotocol/ui"] != nil
        let clientInfo = params["clientInfo"] as? [String: Any] ?? [:]
        logClientEvent("initialize client=\(clientInfo["name"] ?? "?")/\(clientInfo["version"] ?? "?") protocol=\(params["protocolVersion"] ?? "?") ui=\(clientSupportsUI) extensions=\(extensions.keys.sorted()) capabilities=\(clientCaps.keys.sorted())")
        // Echo the client's protocol version when we support it, so older and
        // newer clients both get a version they can speak.
        let asked = params["protocolVersion"] as? String
        let version = (asked.map { SUPPORTED_PROTOCOLS.contains($0) } ?? false) ? asked! : DEFAULT_PROTOCOL
        return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                "result": [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false]],
                    "serverInfo": ["name": SERVER_NAME, "version": SERVER_VERSION],
                    "instructions": """
                    ReMynd is the user's own screen history — everything they have seen, read and \
                    done on this Mac, searchable. Reach for these tools whenever a question is about \
                    the user's own past rather than general knowledge. Prefer looking it up over \
                    asking them: they already told their computer, and this is how you read it back.

                    Show the moments, don't only describe them. Whenever your answer rests on \
                    particular moments — the most important thing they did, a call or meeting, \
                    something they saw or read, a message, a design, a decision, an error — call \
                    show_moment for the one to three moments that matter most, in the same turn, and \
                    refer to what the frames show. A recap of a day or week still gets frames of its \
                    headline moments. Do this without asking, and never end an answer by offering to \
                    pull frames. Skip frames only for pure numbers (time per app, counts), when \
                    nothing specific was found, or when the user asks for text only.

                    Calls and meetings have their own record. ReMynd transcribes call audio on the \
                    Mac, so for anything said out loud — what someone said, what was agreed, a \
                    meeting recap, a quote — use list_calls, search_calls and call_transcript. The \
                    screen tools cannot hear: never conclude that a conversation was not captured \
                    from screen history alone.
                    """
                ]]

    case "notifications/initialized", "initialized", "notifications/cancelled":
        return nil

    case "ping":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [:]]

    case "tools/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["tools": toolListPayload()]]

    case "resources/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["resources": [[
            "uri": VIEWER_URI, "name": "ReMynd moment viewer", "mimeType": VIEWER_MIME,
            "description": "Shows frames from the user's screen recording large, inline in the conversation."
        ]]]]

    case "resources/read":
        let uri = params["uri"] as? String ?? ""
        logClientEvent("resources/read \(uri)")
        guard uri == VIEWER_URI else { return errorResponse(id, -32002, "Resource not found: \(uri)") }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["contents": [[
            "uri": VIEWER_URI, "mimeType": VIEWER_MIME, "text": MOMENT_VIEWER_HTML,
            "_meta": ["ui": ["prefersBorder": false]]
        ]]]]

    case "prompts/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["prompts": []]]

    case "tools/call":
        guard let name = params["name"] as? String,
              let tool = tools.first(where: { $0.name == name }) else {
            return errorResponse(id, -32602, "Unknown tool: \(params["name"] as? String ?? "?")")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        // ChatGPT's `search`/`fetch` want structuredContent, and the same
        // object JSON-encoded in the text content for clients that only read
        // content. Emitting one without the other works in exactly one client.
        if let build = tool.structured, let raw = build(args) {
            let obj = cappedObject(raw)
            return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                    "result": ["structuredContent": obj,
                               "content": [["type": "text", "text": jsonString(obj)]],
                               "isError": false]]
        }

        // Tools that answer with pixels return their own content blocks.
        if let build = tool.content {
            let r = build(args)
            var result: [String: Any] = ["content": r.blocks, "isError": r.isError]
            if let structured = r.structured { result["structuredContent"] = structured }
            let images = r.blocks.filter { ($0["type"] as? String) == "image" }.count
            logClientEvent("tools/call \(tool.name) images=\(images) isError=\(r.isError)")
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        }

        let (raw, ok) = tool.run(args)
        let text = capped(raw, hint: tool.name == "screen_text_in_range"
                          ? "Ask for a narrower time range — an hour reads well, a whole day does not."
                          : "Narrow the query or lower the limit.")

        // A failed retrieval is reported as an error *result*, not a protocol
        // error: the model should see what went wrong and be able to adjust,
        // rather than the client treating it as a transport fault.
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if ok, let hint = showMomentHint(tool: tool.name, args: args, output: text) {
            content.append(["type": "text", "text": hint])
        }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                "result": ["content": content,
                           "isError": !ok]]

    default:
        return errorResponse(id, -32601, "Method not found: \(method)")
    }
}

// ---------------------------------------------------------------------------
// stdio transport — newline-delimited JSON-RPC on the standard streams
// ---------------------------------------------------------------------------

func runStdio() {
    // Line-buffered stdout so clients see replies immediately.
    setvbuf(stdout, nil, _IOLBF, 0)

    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print(jsonString(errorResponse(nil, -32700, "Parse error")))
            continue
        }
        if let reply = handle(obj) {
            print(jsonString(reply))
        }
    }
}

// ---------------------------------------------------------------------------
// Streamable HTTP transport
//
// The spec is explicit about the security requirements here, and they exist
// because a local HTTP server is reachable from any web page the user has open:
//
//   • Origin MUST be validated (403 on mismatch) to stop DNS rebinding
//   • local servers SHOULD bind 127.0.0.1 rather than 0.0.0.0
//   • connections SHOULD be authenticated
//
// All three are enforced below.
// ---------------------------------------------------------------------------

final class HTTPTransport {
    let port: UInt16
    let token: String?
    private var listener: NWListener?

    init(port: UInt16, token: String?) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let params = NWParameters.tcp
        // Loopback only. A tunnel that wants to expose this must terminate on
        // the machine and forward to localhost, so the endpoint is never bound
        // to a public interface itself.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                          port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        // NOTE: the port comes from requiredLocalEndpoint above. Passing `on:`
        // as well makes NWListener reject the parameters with EINVAL — the two
        // ways of specifying a port are mutually exclusive.
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: .global())
        listener = l

        FileHandle.standardError.write(
            "remynd-mcp listening on http://127.0.0.1:\(port)/mcp\(token == nil ? " (no auth)" : "")\n"
                .data(using: .utf8)!)
        dispatchMain()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global())
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }

            // Wait for the full request: headers, then Content-Length bytes.
            guard let headerEnd = self.range(of: "\r\n\r\n", in: buf) else {
                if done { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }
            let headerText = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let bodyStart = headerEnd.upperBound
            let contentLength = self.header(headerText, "content-length").flatMap { Int($0) } ?? 0
            let have = buf.count - bodyStart

            if have < contentLength {
                if done { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }

            let body = buf[bodyStart..<(bodyStart + contentLength)]
            self.respond(conn, headerText: headerText, body: Data(body))
        }
    }

    private func respond(_ conn: NWConnection, headerText: String, body: Data) {
        let requestLine = headerText.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        let path = parts.count > 1 ? parts[1] : "/"

        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        // OAuth discovery, answered BEFORE the auth check.
        //
        // ChatGPT probes /.well-known/oauth-* to work out how to authenticate.
        // Returning 401 there tells it "auth is required but I won't say how",
        // and it gives up. A clean 404 lets discovery conclude there is no
        // OAuth to negotiate, which is correct: this endpoint authenticates by
        // the token embedded in its URL. ChatGPT does not accept Bearer
        // headers, so the URL is the only channel available.
        if route.hasPrefix("/.well-known/") {
            send(conn, status: "404 Not Found",
                 json: ["error": "no OAuth metadata: this endpoint authenticates via the token in its URL"])
            return
        }

        // CORS preflight, also before auth — a browser-based client will send
        // OPTIONS with no credentials and must not be met with a 401.
        if method == "OPTIONS" {
            send(conn, status: "204 No Content", json: nil)
            return
        }

        // 1. Origin validation — MUST, per spec. A browser page on any origin
        //    can POST to localhost; without this it could read the user's
        //    entire screen history.
        if let origin = header(headerText, "origin"), !originAllowed(origin) {
            send(conn, status: "403 Forbidden",
                 json: ["jsonrpc": "2.0", "error": ["code": -32600, "message": "Origin not allowed"]])
            return
        }

        // 2. Authentication — a bearer token, when one was issued.
        //
        // Accepted either as an Authorization header or as an `?auth=` query
        // parameter. The query form exists because connector UIs (ChatGPT,
        // Claude's custom connectors) take a URL and give you nowhere to put a
        // custom header; carrying the token in the URL is the established
        // pattern for those clients. It is weaker — URLs end up in logs — so
        // the header is preferred wherever the client allows one.
        if let token {
            let headerAuth = header(headerText, "authorization") ?? ""
            let queryAuth = Self.queryValue("auth", in: path)
            guard headerAuth == "Bearer \(token)" || queryAuth == token else {
                send(conn, status: "401 Unauthorized",
                     json: ["jsonrpc": "2.0", "error": ["code": -32600, "message": "Unauthorized"]],
                     extraHeaders: ["WWW-Authenticate": "Bearer realm=\"remynd\", error=\"invalid_token\""])
                return
            }
        }

        // Health check, so a tunnel or the app can probe without speaking MCP.
        if method == "GET" && route.hasPrefix("/health") {
            send(conn, status: "200 OK", json: ["ok": true, "server": SERVER_NAME, "version": SERVER_VERSION])
            return
        }

        // This revision removed the GET stream endpoint and DELETE session
        // teardown; both are answered honestly rather than silently ignored.
        if method == "GET" || method == "DELETE" {
            send(conn, status: "405 Method Not Allowed",
                 json: ["jsonrpc": "2.0", "error": ["code": -32601, "message": "This server implements POST only"]])
            return
        }

        guard method == "POST" else {
            send(conn, status: "400 Bad Request",
                 json: ["jsonrpc": "2.0", "error": ["code": -32600, "message": "Expected POST"]])
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            send(conn, status: "400 Bad Request",
                 json: ["jsonrpc": "2.0", "error": ["code": -32700, "message": "Parse error"]])
            return
        }

        guard let reply = handle(obj) else {
            // A notification the server accepted takes 202 with no body.
            send(conn, status: "202 Accepted", json: nil)
            return
        }
        send(conn, status: "200 OK", json: reply)
    }

    /// Only same-machine origins are acceptable for a loopback server.
    private func originAllowed(_ origin: String) -> Bool {
        let o = origin.lowercased()
        if o == "null" { return true }               // file:// and some native clients
        return o.hasPrefix("http://127.0.0.1")
            || o.hasPrefix("http://localhost")
            || o.hasPrefix("https://127.0.0.1")
            || o.hasPrefix("https://localhost")
    }

    /// Extracts a query parameter from a request target such as
    /// `/mcp?auth=abc123`.
    static func queryValue(_ name: String, in target: String) -> String? {
        guard let q = target.firstIndex(of: "?") else { return nil }
        let query = String(target[target.index(after: q)...])
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == name {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    private func header(_ text: String, _ name: String) -> String? {
        for line in text.split(separator: "\r\n").dropFirst() {
            let bits = line.split(separator: ":", maxSplits: 1).map(String.init)
            if bits.count == 2, bits[0].lowercased() == name {
                return bits[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func range(of needle: String, in data: Data) -> Range<Data.Index>? {
        data.range(of: needle.data(using: .utf8)!)
    }

    private func send(_ conn: NWConnection, status: String, json: Any?,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        // A browser-based client needs these to talk to the endpoint at all.
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name\r\n"
        head += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        var bodyData = Data()
        if let json {
            bodyData = jsonString(json).data(using: .utf8) ?? Data()
            head += "Content-Type: application/json\r\n"
        }
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        head += "X-Accel-Buffering: no\r\n\r\n"

        var out = head.data(using: .utf8)!
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

var useHTTP = false
var port: UInt16 = 8787
var token: String? = ProcessInfo.processInfo.environment["REMYND_MCP_TOKEN"]

var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    switch argv[i] {
    case "--http": useHTTP = true
    case "--port": if i + 1 < argv.count, let p = UInt16(argv[i + 1]) { port = p; i += 1 }
    case "--token": if i + 1 < argv.count { token = argv[i + 1]; i += 1 }
    case "--version": print("\(SERVER_NAME) \(SERVER_VERSION)"); exit(0)
    case "--help", "-h":
        print("""
        remynd-mcp — your ReMynd screen history as an MCP server

          remynd-mcp                       stdio (for Claude Desktop, Cursor, VS Code, Gemini CLI)
          remynd-mcp --http [--port 8787]  Streamable HTTP on 127.0.0.1
          remynd-mcp --token <secret>      require Authorization: Bearer <secret> on HTTP
          remynd-mcp --version

        Read-only. Reads the same local database the ReMynd app records into.
        """)
        exit(0)
    default: break
    }
    i += 1
}

if useHTTP {
    // Held in a variable deliberately: the listener's connection handler
    // captures `self` weakly, so a transport created as a temporary would be
    // deallocated the instant start() returned and every incoming connection
    // would be silently dropped.
    let transport = HTTPTransport(port: port, token: token)
    do { try transport.start() }
    catch {
        FileHandle.standardError.write("remynd-mcp: could not listen on \(port): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
} else {
    runStdio()
}
