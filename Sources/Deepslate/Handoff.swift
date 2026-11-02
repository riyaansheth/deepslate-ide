import Foundation

/// Picks up where a Claude Code or Codex session left off: transcript tail + current git state, as plain text.
struct Handoff: Identifiable {
    let id = UUID()
    let source: String, file: URL, cwd: String, date: Date, title: String

    static func list() -> [Handoff] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [("Claude Code", home.appendingPathComponent(".claude/projects")), ("Codex", home.appendingPathComponent(".codex/sessions"))]
        var files: [(String, URL, Date)] = []
        for (source, root) in roots {
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            while let url = e?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((source, url, date))
            }
        }
        return files.sorted { $0.2 > $1.2 }.prefix(25).compactMap { source, url, date in
            let lines = lines(url, maxBytes: 256_000)
            let cwd = lines.lazy.compactMap { ($0["cwd"] ?? ($0["payload"] as? JSON)?["cwd"]) as? String }.first ?? ""
            let title = lines.lazy.compactMap { entry(source, $0) }.first { $0.hasPrefix("User: ") }.map { String($0.dropFirst(6).prefix(60)) }
            return title.map { Handoff(source: source, file: url, cwd: cwd, date: date, title: $0) }
        }
    }

    static func lines(_ url: URL, maxBytes: Int = .max) -> [JSON] {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: maxBytes) else { return [] }
        return String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { API.json(String($0)) }
    }

    /// One transcript line per user/assistant message or tool call; nil for everything else.
    static func entry(_ source: String, _ j: JSON) -> String? {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.hasPrefix("<") ? nil : t  // skip injected context / command wrappers
        }
        if source == "Codex" {
            let p = j["payload"] as? JSON ?? j
            switch p["type"] as? String {
            case "message":
                let role = p["role"] as? String
                guard role == "user" || role == "assistant" else { return nil }
                let text = (p["content"] as? [JSON] ?? []).compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
                return clean(text).map { (role == "user" ? "User: " : "Assistant: ") + $0 }
            case "function_call":
                return "[tool \(p["name"] as? String ?? "")] " + String((p["arguments"] as? String ?? "").prefix(300))
            default: return nil
            }
        }
        guard let type = j["type"] as? String, type == "user" || type == "assistant", j["isMeta"] as? Bool != true,
              let m = j["message"] as? JSON else { return nil }
        let prefix = type == "user" ? "User: " : "Assistant: "
        if let s = m["content"] as? String { return clean(s).map { prefix + $0 } }
        let parts = (m["content"] as? [JSON] ?? []).compactMap { b -> String? in
            switch b["type"] as? String {
            case "text": return (b["text"] as? String).flatMap(clean).map { prefix + $0 }
            case "tool_use": return "[tool \(b["name"] as? String ?? "")] " + String(API.string(b["input"] ?? [:]).prefix(300))
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func render(folder: URL) async -> String {
        var transcript = Self.lines(file).compactMap { Self.entry(source, $0) }.joined(separator: "\n\n")
        if transcript.count > 40000 { transcript = "…\n" + String(transcript.suffix(40000)) }
        let status = await Shell.git(["status", "--short", "--branch"], folder)
        var diff = await Shell.git(["diff", "HEAD"], folder)
        if diff.count > 20000 { diff = String(diff.prefix(20000)) + "\n…[diff truncated]" }
        return """
        I was working on this in \(source) and hit my plan limit. Below is the end of that session \
        (\(date.formatted(date: .abbreviated, time: .shortened)), folder \(cwd)) and the current git state. \
        Pick up where it left off.

        <previous_session>
        \(transcript)
        </previous_session>

        <git_status>
        \(status)
        </git_status>

        <git_diff>
        \(diff)
        </git_diff>
        """
    }
}
