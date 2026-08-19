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

// ---------------------------------------------------------------------------
// Locating the CLI
// ---------------------------------------------------------------------------

/// Where the retrieval CLI lives. Checked in order; the first hit wins.
/// The app-bundle path is listed first so a copy shipped inside ReMynd.app is
/// preferred over a stale one a user installed months ago.
let cliCandidates: [String] = [
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

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [cli] + args

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe

    do { try p.run() } catch {
        return ("Could not run the ReMynd CLI: \(error.localizedDescription)", false)
    }

    // Read before waiting: a pipe that fills up deadlocks a process that is
    // still writing to it.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    // Enforce the timeout. It used to be an unused parameter, which meant a
    // wedged query could hang the client forever with no way to tell why.
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
        p.terminate()
        return ("The ReMynd query timed out after \(Int(timeout))s. Try a narrower time range.", false)
    }
    p.waitUntilExit()

    let text = String(data: data, encoding: .utf8) ?? ""

    // Never report emptiness as if it were an answer. An empty result with a
    // zero exit is a real "nothing found"; anything else is a fault, and the
    // model needs to see which so it can react instead of guessing.
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if p.terminationStatus != 0 {
            return ("The ReMynd CLI failed (exit \(p.terminationStatus)) and produced no output. "
                    + "Command: remynd \(args.joined(separator: " "))", false)
        }
        return ("No results for: remynd \(args.joined(separator: " ")). "
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

let tools: [Tool] = [

    Tool(name: "search_screen_history",
         description: """
         Full-text search everything the user has seen on their screen — every app, page, document \
         and message, as read by OCR. Use this whenever the user refers to something they personally \
         saw, read, or did but cannot fully remember ("that article about X", "the error I hit last \
         week", "what was that tool called").

         Returns timestamped matches, most recent first. IMPORTANT: a timestamp records when the \
         text was ON SCREEN, not when the underlying event happened — an emailed reminder about a \
         meeting is stamped when it was read. Treat a match as a cursor: take a promising timestamp \
         and call screen_text_in_range around it to read what was actually there. If a search \
         returns nothing, try fewer or different words before concluding it never happened.
         """,
         schema: ["type": "object",
                  "properties": [
                     "query": ["type": "string", "description": "Words to search for. Multiple words are ANDed."],
                     "limit": ["type": "integer", "description": "Max matches to return. Default 40."]
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
         Rebuild a specific day from the user's screen history: what they worked on, ranked by time \
         actually spent, each with the hours it spanned, plus an hour-by-hour trail.

         Use for "what did I do on Tuesday", "what was I working on last Friday", or to summarise a \
         day. The date is the user's LOCAL date. Each activity comes with a time span — use it: to \
         say what actually happened inside an activity rather than just how long it lasted, call \
         screen_text_in_range over that span and read it. A day with no recording says so plainly; \
         that means the Mac was off, asleep or not recording, not that the user did nothing.
         """,
         schema: ["type": "object",
                  "properties": ["date": ["type": "string", "description": "Local date, YYYY-MM-DD."]],
                  "required": ["date"]],
         run: { a in
             guard let d = str(a, "date", aliases: ["day", "start", "from"]) else {
                 return ("Provide a `date` as YYYY-MM-DD.", false)
             }
             let r = runCLI(["day", d]); return (r.out, r.ok)
         }),

    Tool(name: "recent_activity",
         description: """
         What the user has been doing recently: the app and window they are in right now, what they \
         have worked on over the last couple of hours ranked by time, and the verbatim text that was \
         on screen in the last few minutes.

         Use to orient yourself at the start of a conversation, or for "what am I working on", \
         "what was I just reading", "where did I leave off".
         """,
         schema: ["type": "object",
                  "properties": ["minutes": ["type": "integer", "description": "How far back to read verbatim screen text. Default 30."]]],
         run: { a in
             var args = ["recent"]
             if let m = int(a, "minutes") { args.append(String(m)) }
             let r = runCLI(args); return (r.out, r.ok)
         }),

    Tool(name: "screen_text_in_range",
         description: """
         The verbatim text that was on the user's screen between two times — the substance behind an \
         activity. This is how you answer "what did I actually do in Gmail" rather than "you were in \
         Gmail for 82 minutes".

         Pair it with search_screen_history (which gives you a timestamp) or reconstruct_day (which \
         gives you an activity's span). Times are the user's LOCAL time.

         Keep the range tight — an hour reads well, a whole day does not and will be truncated.          Narrow first with search_screen_history or reconstruct_day's activity spans.

         The text is OCR, so it arrives as fragments with interface chrome mixed in and occasional \
         garbled words. Read across it and report what it means; do not quote it raw at the user. \
         Digits are the weak point — treat numbers read off the screen as leads, not facts. Where a \
         name or subject is too mangled to be sure of, leave it out rather than guess.
         """,
         schema: ["type": "object",
                  "properties": [
                     "from": ["type": "string", "description": "Local start time, e.g. \"2026-08-18 14:00\"."],
                     "to": ["type": "string", "description": "Local end time. Optional; defaults to now."]
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
         Where the user's time actually went over the last N days, by application. Use for "how much \
         time did I spend in Slack this month", "what am I spending my days on".

         Counts backwards from today only — it takes `days`, not a date range. For a specific day, \
         use reconstruct_day, which also ranks by what was being DONE rather than which app was \
         focused, because the window title carries the subject.
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

    Tool(name: "sync_status",
         description: """
         What ReMynd has recorded and how fresh it is: which profile is being read, how far back the \
         history goes, when the last capture happened, and whether credential redaction is on.

         Call this before telling the user that something is not in their history — it distinguishes \
         "no record of that" from "not recorded during that period at all".
         """,
         schema: ["type": "object", "properties": [:]],
         run: { _ in let r = runCLI(["status"]); return (r.out, r.ok) }),
]

// ---------------------------------------------------------------------------
// JSON-RPC
// ---------------------------------------------------------------------------

let SERVER_NAME = "remynd"
let SERVER_VERSION = "1.0.0"
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
    tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
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
        // Echo the client's protocol version when we support it, so older and
        // newer clients both get a version they can speak.
        let asked = params["protocolVersion"] as? String
        let version = (asked.map { SUPPORTED_PROTOCOLS.contains($0) } ?? false) ? asked! : DEFAULT_PROTOCOL
        return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                "result": [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": SERVER_NAME, "version": SERVER_VERSION],
                    "instructions": """
                    ReMynd is the user's own screen history — everything they have seen, read and \
                    done on this Mac, searchable. Reach for these tools whenever a question is about \
                    the user's own past rather than general knowledge. Prefer looking it up over \
                    asking them: they already told their computer, and this is how you read it back.
                    """
                ]]

    case "notifications/initialized", "initialized", "notifications/cancelled":
        return nil

    case "ping":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [:]]

    case "tools/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["tools": toolListPayload()]]

    case "resources/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["resources": []]]

    case "prompts/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["prompts": []]]

    case "tools/call":
        guard let name = params["name"] as? String,
              let tool = tools.first(where: { $0.name == name }) else {
            return errorResponse(id, -32602, "Unknown tool: \(params["name"] as? String ?? "?")")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let (raw, ok) = tool.run(args)
        let text = capped(raw, hint: tool.name == "screen_text_in_range"
                          ? "Ask for a narrower time range — an hour reads well, a whole day does not."
                          : "Narrow the query or lower the limit.")

        // A failed retrieval is reported as an error *result*, not a protocol
        // error: the model should see what went wrong and be able to adjust,
        // rather than the client treating it as a transport fault.
        return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                "result": ["content": [["type": "text", "text": text]],
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
                     json: ["jsonrpc": "2.0", "error": ["code": -32600, "message": "Unauthorized"]])
                return
            }
        }

        // Health check, so a tunnel or the app can probe without speaking MCP.
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

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

    private func send(_ conn: NWConnection, status: String, json: Any?) {
        var head = "HTTP/1.1 \(status)\r\n"
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
