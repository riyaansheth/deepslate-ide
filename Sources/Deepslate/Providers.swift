import Foundation
import Security

typealias JSON = [String: Any]

enum Provider: String, CaseIterable {
    case anthropic, openai
    var name: String { self == .anthropic ? "Claude" : "OpenAI" }
    var other: Provider { self == .anthropic ? .openai : .anthropic }
    static func detect(_ key: String) -> Provider? {
        key.hasPrefix("sk-ant-") ? .anthropic : key.hasPrefix("sk-") ? .openai : nil
    }
}

// MARK: - Conversation model (provider-neutral, plus each provider's raw blocks for lossless replay)

struct Img { let mime: String; let b64: String }
struct Call { var id: String; var name: String; var input: JSON; var bad = false }
struct ToolOut { var id: String; var text: String; var error = false }

struct Turn: Identifiable {
    let id = UUID()
    var user: Bool
    var text = ""
    var images: [Img] = []
    var calls: [Call] = []
    var outs: [ToolOut] = []
    var raw: [JSON]? = nil
    var rawFrom: Provider? = nil
    var checkpoint: String? = nil
}

struct APIError: LocalizedError {
    let code: Int; let body: String
    var errorDescription: String? {
        let msg = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? JSON)
            .flatMap { ($0["error"] as? JSON)?["message"] as? String }
        return "HTTP \(code): \(msg ?? String(body.prefix(300)))"
    }
}

// MARK: - Keys

@MainActor enum Keychain {
    static let service = "com.riyaansheth.deepslate"
    private static var cache: [Provider: String?] = [:]

    static func get(_ p: Provider) -> String? {
        if let hit = cache[p] { return hit }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true]
        var out: AnyObject?
        let key = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
            ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[p] = key
        return key
    }

    static func set(_ p: Provider, _ key: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue]
        SecItemDelete(q as CFDictionary)
        if let key {
            var add = q; add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cache[p] = key
    }
}

// MARK: - Cost

struct Usage {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, searches = 0

    // ponytail: hand-kept price table ($/1M tokens: input, output, cache read), first substring match wins.
    // Unknown models bill at the top row's rate so the counter errs high. Update when providers reprice.
    static let prices: [(String, Double, Double, Double)] = [
        ("fable", 10, 50, 0.25), ("mythos", 10, 50, 0.25),
        ("opus-5-5", 4, 20, 0.2), ("opus", 5, 25, 0.5),
        ("sonnet-5", 2, 10, 0.2), ("sonnet", 3, 15, 0.3),
        ("haiku-5", 0.1, 0.5, 0.01), ("haiku", 1, 5, 0.1),
        ("sol", 5, 30, 0.5), ("terra", 2.5, 15, 0.25), ("luna", 1, 6, 0.1), ("gpt-5.5", 5, 30, 0.5),
        ("nano", 0.05, 0.4, 0.005), ("mini", 0.25, 2, 0.025), ("gpt-5", 1.25, 10, 0.125),
    ]

    func cost(_ model: String) -> Double {
        let p = Self.prices.first { model.contains($0.0) } ?? ("", 10, 50, 1)
        return (Double(input) * p.1 + Double(cacheWrite) * p.1 * 1.25 + Double(cacheRead) * p.3 + Double(output) * p.2) / 1e6
            + Double(searches) * 0.01
    }
}

struct Reply { var text = ""; var calls: [Call] = []; var raw: [JSON] = []; var usage = Usage(); var model = ""; var stop = "" }

// MARK: - HTTP

@MainActor enum API {
    static let tools: [(String, String, JSON)] = [
        ("bash", "Run a command in the user's login shell, in the project folder. You have full access to the machine. Foreground commands time out after 2 minutes; use background:true for servers, watchers and other long jobs (returns a log file path).",
         ["type": "object", "properties": ["command": ["type": "string"], "background": ["type": "boolean"]], "required": ["command"]]),
        ("write_file", "Create or overwrite a file. Paths are relative to the project folder unless absolute.",
         ["type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]], "required": ["path", "content"]]),
        ("edit_file", "Replace an exact string in a file. old_string must appear exactly once unless replace_all is true.",
         ["type": "object", "properties": ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"], "replace_all": ["type": "boolean"]], "required": ["path", "old_string", "new_string"]]),
    ]

    nonisolated static func json(_ s: String) -> JSON? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? JSON }
    nonisolated static func string(_ j: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: j)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func request(_ url: String, _ headers: [String: String], body: JSON? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 600)
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    static func sse(_ req: URLRequest, _ onEvent: (JSON) throws -> Void) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var body = ""; for try await l in bytes.lines { body += l }
            throw APIError(code: code, body: body)
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let s = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if s == "[DONE]" { break }
            if let j = json(s) { try onEvent(j) }
        }
    }

    static func models(_ p: Provider) async -> [String] {
        guard let key = Keychain.get(p) else { return [] }
        let req = p == .anthropic
            ? request("https://api.anthropic.com/v1/models?limit=1000", ["x-api-key": key, "anthropic-version": "2023-06-01"])
            : request("https://api.openai.com/v1/models", ["authorization": "Bearer \(key)"])
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let data = (try? JSONSerialization.jsonObject(with: d) as? JSON)?["data"] as? [JSON] else { return [] }
        if p == .anthropic { return data.compactMap { $0["id"] as? String } }
        let skip = ["audio", "realtime", "image", "tts", "transcribe", "search", "embedding", "instruct"]
        return data.sorted { ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0) }
            .compactMap { $0["id"] as? String }
            .filter { id in (id.hasPrefix("gpt-") || id.range(of: #"^o\d"#, options: .regularExpression) != nil) && !skip.contains { id.contains($0) } }
    }

    static func complete(_ p: Provider, model: String, system: String, turns: [Turn], onText: (String) -> Void) async throws -> Reply {
        guard let key = Keychain.get(p) else { throw APIError(code: 0, body: "No \(p.name) API key — add one in Settings (⌘,).") }
        return p == .anthropic
            ? try await anthropic(key, model, system, turns, onText)
            : try await openai(key, model, system, turns, onText)
    }

    // MARK: Anthropic Messages API

    static func anthropic(_ key: String, _ model: String, _ system: String, _ turns: [Turn], _ onText: (String) -> Void) async throws -> Reply {
        let messages: [JSON] = turns.map { t in
            if t.user {
                var c: [JSON] = t.outs.map { ["type": "tool_result", "tool_use_id": $0.id, "content": $0.text, "is_error": $0.error] }
                c += t.images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mime, "data": $0.b64]] }
                if !t.text.isEmpty { c.append(["type": "text", "text": t.text]) }
                return ["role": "user", "content": c]
            }
            if t.rawFrom == .anthropic, let raw = t.raw, !raw.isEmpty { return ["role": "assistant", "content": raw] }
            var c: [JSON] = t.text.isEmpty ? [] : [["type": "text", "text": t.text]]
            c += t.calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
            return ["role": "assistant", "content": c.isEmpty ? [["type": "text", "text": "(no output)"]] : c]
        }
        let modern = model.range(of: #"(opus|sonnet|fable)-(5|4-[678])"#, options: .regularExpression) != nil
        var tools: [JSON] = Self.tools.map { ["name": $0.0, "description": $0.1, "input_schema": $0.2, "eager_input_streaming": true] }
        tools.append(["type": modern ? "web_search_20260209" : "web_search_20250305", "name": "web_search"])
        var body: JSON = ["model": model, "max_tokens": 64000, "system": system, "messages": messages, "tools": tools,
                          "stream": true, "cache_control": ["type": "ephemeral"]]
        if modern { body["output_config"] = ["effort": "high"] }
        var headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        if ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model) {
            body["fallbacks"] = "default"  // server-side retry on another model if safety classifiers decline
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }

        var r = Reply(), blocks: [Int: JSON] = [:], partial: [Int: String] = [:], bad = Set<Int>()
        try await sse(request("https://api.anthropic.com/v1/messages", headers, body: body)) { e in
            let i = e["index"] as? Int ?? -1
            switch e["type"] as? String {
            case "message_start":
                let m = e["message"] as? JSON
                r.model = m?["model"] as? String ?? model
                let u = m?["usage"] as? JSON ?? [:]
                r.usage.input = u["input_tokens"] as? Int ?? 0
                r.usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
                r.usage.cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
            case "content_block_start":
                blocks[i] = e["content_block"] as? JSON
            case "content_block_delta":
                guard let d = e["delta"] as? JSON, var b = blocks[i] else { return }
                switch d["type"] as? String {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    b["text"] = (b["text"] as? String ?? "") + t; onText(t)
                case "thinking_delta": b["thinking"] = (b["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta": b["signature"] = d["signature"]
                case "input_json_delta": partial[i, default: ""] += d["partial_json"] as? String ?? ""
                case "citations_delta": b["citations"] = (b["citations"] as? [Any] ?? []) + [d["citation"] ?? [:]]
                default: break
                }
                blocks[i] = b
            case "content_block_stop":
                if let p = partial[i] {
                    if let input = p.isEmpty ? [:] : json(p) { blocks[i]?["input"] = input } else { bad.insert(i) }
                }
            case "message_delta":
                if let s = (e["delta"] as? JSON)?["stop_reason"] as? String { r.stop = s }
                let u = e["usage"] as? JSON ?? [:]
                if let o = u["output_tokens"] as? Int { r.usage.output = o }
                if let n = (u["server_tool_use"] as? JSON)?["web_search_requests"] as? Int { r.usage.searches = n }
            case "error":
                throw APIError(code: 0, body: string(e))
            default: break
            }
        }
        var ordered = blocks.keys.sorted().map { (i: $0, b: blocks[$0]!) }
        // After a mid-stream fallback, only text from before the last fallback marker may be echoed back.
        if let fb = ordered.lastIndex(where: { $0.b["type"] as? String == "fallback" }) {
            ordered = ordered.enumerated().filter { $0.offset > fb || $0.element.b["type"] as? String == "text" }.map(\.element)
        }
        r.raw = ordered.map(\.b)
        r.text = ordered.compactMap { $0.b["type"] as? String == "text" ? $0.b["text"] as? String : nil }.joined()
        r.calls = ordered.filter { $0.b["type"] as? String == "tool_use" }.map {
            Call(id: $0.b["id"] as? String ?? "", name: $0.b["name"] as? String ?? "", input: $0.b["input"] as? JSON ?? [:],
                 bad: bad.contains($0.i) || r.stop == "max_tokens")
        }
        return r
    }

    // MARK: OpenAI Responses API

    static func openai(_ key: String, _ model: String, _ system: String, _ turns: [Turn], _ onText: (String) -> Void) async throws -> Reply {
        var input: [JSON] = []
        for t in turns {
            if t.user {
                input += t.outs.map { ["type": "function_call_output", "call_id": $0.id, "output": $0.text] }
                var c: [JSON] = t.images.map { ["type": "input_image", "image_url": "data:\($0.mime);base64,\($0.b64)"] }
                if !t.text.isEmpty { c.append(["type": "input_text", "text": t.text]) }
                if !c.isEmpty { input.append(["role": "user", "content": c]) }
            } else if t.rawFrom == .openai, let raw = t.raw {
                input += raw
            } else {
                if !t.text.isEmpty { input.append(["role": "assistant", "content": t.text]) }
                input += t.calls.map { ["type": "function_call", "call_id": $0.id, "name": $0.name, "arguments": string($0.input)] }
            }
        }
        var tools: [JSON] = Self.tools.map { ["type": "function", "name": $0.0, "description": $0.1, "parameters": $0.2] }
        tools.append(["type": "web_search"])
        var body: JSON = ["model": model, "instructions": system, "input": input, "tools": tools, "stream": true, "store": false]
        if model.hasPrefix("gpt-5") || model.range(of: #"^o\d"#, options: .regularExpression) != nil {
            body["reasoning"] = ["effort": "high"]
            body["include"] = ["reasoning.encrypted_content"]  // lets us replay reasoning with store:false
        }

        var r = Reply(model: model)
        try await sse(request("https://api.openai.com/v1/responses", ["authorization": "Bearer \(key)"], body: body)) { e in
            switch e["type"] as? String {
            case "response.output_text.delta":
                onText(e["delta"] as? String ?? "")
            case "response.completed", "response.incomplete":
                let resp = e["response"] as? JSON ?? [:]
                r.stop = e["type"] as! String == "response.completed" ? "end_turn" : "max_tokens"
                r.model = resp["model"] as? String ?? model
                r.raw = resp["output"] as? [JSON] ?? []
                let u = resp["usage"] as? JSON ?? [:]
                r.usage.cacheRead = (u["input_tokens_details"] as? JSON)?["cached_tokens"] as? Int ?? 0
                r.usage.input = (u["input_tokens"] as? Int ?? 0) - r.usage.cacheRead
                r.usage.output = u["output_tokens"] as? Int ?? 0
            case "response.failed", "error":
                throw APIError(code: 0, body: string(e["response"] ?? e))
            default: break
            }
        }
        for item in r.raw {
            switch item["type"] as? String {
            case "message":
                r.text += (item["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.joined()
            case "function_call":
                let args = item["arguments"] as? String ?? ""
                r.calls.append(Call(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "",
                                    input: json(args) ?? [:], bad: json(args) == nil))
            case "web_search_call": r.usage.searches += 1
            default: break
            }
        }
        return r
    }
}
