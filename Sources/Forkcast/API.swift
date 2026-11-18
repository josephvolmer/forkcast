import Foundation
import ForkcastCore
import Network

/// Minimal HTTP/1.1 JSON API on 127.0.0.1 (loopback only).
/// Reads need no auth; anything that changes state needs the token in ~/Library/Application Support/Forkcast/api.json.
/// Requests with a browser Origin, or a Host other than localhost, are rejected (CSRF / DNS-rebinding protection).
final class APIServer {
    private let engine: Engine
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "forkcast.api", qos: .userInitiated, attributes: .concurrent)
    private(set) var port: UInt16 = APIConfig.defaultPort
    private(set) var token = ""
    private(set) var error: String?

    init(engine: Engine) { self.engine = engine }

    func start() {
        if let d = try? Data(contentsOf: APIConfig.file), let info = try? JSONDecoder().decode(APIConfig.Info.self, from: d) {
            token = info.token
            port = info.port
        } else {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        for candidate in [port] + (1...20).map({ APIConfig.defaultPort + $0 }) {
            if listen(on: candidate) { port = candidate; break }
        }
        let info = APIConfig.Info(port: port, token: token)
        if let d = try? JSONEncoder().encode(info) {
            try? d.write(to: APIConfig.file, options: .atomic)
            chmod(APIConfig.file.path, 0o600)
        }
    }

    private func listen(on p: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: p), let l = try? NWListener(using: params, on: nwPort) else { return false }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        l.stateUpdateHandler = { st in
            switch st {
            case .ready: ok = true; ready.signal()
            case .failed: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        if ok { listener = l } else { l.cancel() }
        return ok
    }

    // MARK: Connection handling

    private struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()
        var segments: [String] { path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) } }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf) {
                self.handle(req) { status, body in self.respond(c, status, body) }
            } else if done || err != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func parse(_ buf: Data) -> Request? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var r = Request()
        r.method = String(first[0]).uppercased()
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        r.path = comps?.path ?? target
        for q in comps?.queryItems ?? [] { r.query[q.name] = q.value ?? "" }
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            r.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(r.headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buf.count - bodyStart >= len else { return nil }
        r.body = buf.subdata(in: bodyStart..<(bodyStart + len))
        return r
    }

    private func respond(_ c: NWConnection, _ status: Int, _ body: Data) {
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Routing

    private typealias Reply = (Int, Data) -> Void

    private func ok<T: Encodable>(_ v: T, _ reply: Reply, status: Int = 200) {
        reply(status, (try? JSON.encoder.encode(v)) ?? Data("{}".utf8))
    }
    private func fail(_ status: Int, _ msg: String, _ reply: Reply) { ok(APIError(msg), reply, status: status) }

    private func decode<T: Decodable>(_ t: T.Type, _ body: Data) throws -> T {
        do { return try JSON.decoder.decode(t, from: body.isEmpty ? Data("{}".utf8) : body) }
        catch { throw ExprError(message: "bad JSON body: \(error.localizedDescription)") }
    }

    private func handle(_ r: Request, reply: @escaping Reply) {
        // Security checks.
        if let origin = r.headers["origin"], origin != "null" { return fail(403, "browser requests are not allowed", reply) }
        if let host = r.headers["host"] {
            let h = host.split(separator: ":").first.map(String.init) ?? host
            guard ["127.0.0.1", "localhost", "[::1]"].contains(h) else { return fail(403, "bad Host header", reply) }
        }
        if r.method != "GET" {
            let auth = r.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") } ?? r.headers["x-forkcast-token"]
            guard auth == token else { return fail(401, "missing or wrong token (see \(APIConfig.file.path))", reply) }
        }
        do {
            try route(r, reply)
        } catch let e as ExprError {
            fail(400, e.message, reply)
        } catch {
            fail(500, "\(error)", reply)
        }
    }

    private func since(_ s: String?) -> Date {
        guard let s, !s.isEmpty else { return Date().addingTimeInterval(-86400) }
        if let d = parseDuration(s), s.last.map({ "smhd".contains($0) }) == true { return Date().addingTimeInterval(-d) }
        if let ts = Double(s) { return Date(timeIntervalSince1970: ts) }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? Date().addingTimeInterval(-86400)
    }

    private func route(_ r: Request, _ reply: @escaping Reply) throws {
        let seg = r.segments
        let m = r.method
        switch (m, seg.first ?? "") {
        case ("GET", ""):
            ok(["endpoints": [
                "GET /status", "GET /processes?group_by=job|app|tree&limit=N", "GET /headroom[?group=g]",
                "GET /jobs[?group=g]", "GET /jobs/<name>", "GET /groups", "GET /groups/<g>/eta",
                "POST /jobs/register", "POST /jobs/<name>/progress", "POST /jobs/<name>/beat", "POST /jobs/<name>/exit",
                "POST /jobs/<name>/start", "DELETE /jobs/<name>", "POST /groups/<g>/pause", "POST /groups/<g>/resume",
                "GET /events?since=<ts|1h>&types=a,b", "GET /changes?since=<ts|1h>", "GET /wait?until=<expr>&timeout=<s|3h>",
                "GET /guards", "POST /guards", "DELETE /guards/<name>", "GET /history?metric=<m>&range=24h&step=60s",
                "GET /metrics",
            ]], reply)

        case ("GET", "status"):
            engine.sync { () }   // marks API demand (enables per-process network sampling)
            ok(engine.latestStatus, reply)

        case ("GET", "processes"):
            let by = r.query["group_by"] ?? "job"
            guard ["job", "app", "tree"].contains(by) else { throw ExprError(message: "group_by must be job, app or tree") }
            ok(engine.processes(groupBy: by, limit: Int(r.query["limit"] ?? "") ?? 200), reply)

        case ("GET", "headroom"):
            ok(engine.headroomFor(r.query["group"]), reply)

        case ("GET", "jobs") where seg.count == 1:
            var js = engine.jobList()
            if let g = r.query["group"] { js = js.filter { $0.group == g } }
            ok(js, reply)
        case ("GET", "jobs") where seg.count == 2:
            guard let j = engine.job(seg[1]) else { return fail(404, "no job '\(seg[1])'", reply) }
            ok(j, reply)
        case ("POST", "jobs") where seg.count == 2 && seg[1] == "register":
            ok(try engine.register(decode(RegisterRequest.self, r.body)), reply, status: 201)
        case ("POST", "jobs") where seg.count == 3:
            let name = seg[1]
            switch seg[2] {
            case "progress": ok(try engine.progress(name, decode(ProgressRequest.self, r.body)), reply)
            case "beat": ok(try engine.beat(name), reply)
            case "exit": ok(try engine.exitJob(name, decode(ExitRequest.self, r.body)), reply)
            case "start":
                struct S: Codable { var pid: Int32 }
                ok(try engine.startQueued(name, pid: decode(S.self, r.body).pid), reply)
            default: fail(404, "unknown job action '\(seg[2])'", reply)
            }
        case ("DELETE", "jobs") where seg.count == 2:
            engine.forget(seg[1]) ? ok(["forgotten": seg[1]], reply) : fail(404, "no job '\(seg[1])'", reply)

        case ("GET", "groups") where seg.count == 1:
            ok(engine.allETAs(), reply)
        case ("GET", "groups") where seg.count == 3 && seg[2] == "eta":
            guard let e = engine.groupETA(seg[1]) else { return fail(404, "no registered jobs in group '\(seg[1])'", reply) }
            ok(e, reply)
        case ("POST", "groups") where seg.count == 3 && (seg[2] == "pause" || seg[2] == "resume"):
            let (done, msg) = engine.apiPause(seg[1], resume: seg[2] == "resume")
            struct R: Codable { var ok: Bool; var message: String }
            ok(R(ok: done, message: msg), reply, status: done ? 200 : 404)

        case ("GET", "events"):
            let types = (r.query["types"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            ok(engine.events(since: since(r.query["since"]), until: r.query["until"].map { since($0) } ?? .distantFuture,
                             types: types, limit: Int(r.query["limit"] ?? "") ?? 500), reply)

        case ("GET", "changes"):
            let from = since(r.query["since"])
            let evs = engine.events(since: from, types: ["job", "crash", "alert", "guard", "group", "headroom"], limit: 1000)
            struct Changes: Codable {
                var since: Date; var started: [String]; var finished: [String]; var failed: [String]; var stale: [String]
                var crashed: [String]; var alerts: [String]; var events: [EventInfo]
            }
            func subj(_ t: [String]) -> [String] { Array(Set(evs.filter { t.contains($0.type) }.compactMap(\.subject))).sorted() }
            ok(Changes(since: from, started: subj(["job.registered", "job.started"]), finished: subj(["job.finished", "job.exited"]),
                       failed: subj(["job.failed", "job.crashed"]), stale: subj(["job.stale"]), crashed: subj(["crash"]),
                       alerts: evs.filter { $0.type == "alert.fired" }.map(\.message), events: evs), reply)

        case ("GET", "wait"):
            guard let expr = r.query["until"], !expr.isEmpty else { throw ExprError(message: "missing ?until=<expression>") }
            let timeout = r.query["timeout"].flatMap(parseDuration) ?? 3600
            engine.wait(expr, timeout: min(timeout, 7 * 86400)) { [weak self] res in
                switch res {
                case let .success(w): self?.ok(w, reply)
                case let .failure(e): self?.fail(400, e.message, reply)
                }
            }

        case ("GET", "guards"):
            ok(engine.guardList(), reply)
        case ("POST", "guards"):
            var g = try decode(GuardRule.self, r.body)
            if g.forSeconds == nil, let f = r.query["for"] { g.forSeconds = parseDuration(f) }
            ok(try engine.addGuard(g), reply, status: 201)
        case ("DELETE", "guards") where seg.count == 2:
            engine.deleteGuard(seg[1]) ? ok(["deleted": seg[1]], reply) : fail(404, "no guard '\(seg[1])'", reply)

        case ("GET", "metrics"):
            ok(Metric.allCases.map(\.apiName), reply)
        case ("GET", "history"):
            guard let name = r.query["metric"], let metric = Metric.allCases.first(where: { $0.apiName == name }) else {
                throw ExprError(message: "metric must be one of: \(Metric.allCases.map(\.apiName).joined(separator: ", "))")
            }
            let range = parseDuration(r.query["range"] ?? "24h") ?? 86400
            let step = parseDuration(r.query["step"] ?? "60s") ?? 60
            ok(engine.history(metric: metric, rangeSeconds: range, stepSeconds: step), reply)

        default:
            fail(m == "GET" || m == "POST" || m == "DELETE" ? 404 : 405, "no route for \(m) \(r.path)", reply)
        }
    }
}
