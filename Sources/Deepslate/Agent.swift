import Foundation
import CryptoKit

// MARK: - Processes

final class Buffer: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum Shell {
    static let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    nonisolated(unsafe) static var background: [Process] = []

    /// Runs and waits. Kills the process (and its direct children) on timeout or task cancellation.
    static func run(_ exe: String, _ args: [String], cwd: URL, timeout: Double = 120) async -> (out: String, code: Int32, timedOut: Bool) {
        let p = Process(), pipe = Pipe(), buf = Buffer()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe; p.standardError = pipe
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { buf.append($0.availableData) }
        let kill = {
            guard p.isRunning else { return }
            let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-TERM", "-P", "\(p.processIdentifier)"]; try? k.run(); k.waitUntilExit()
            p.terminate()
        }
        var timedOut = false
        let code: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { buf.append(Data("\(error.localizedDescription)".utf8)); cont.resume(returning: -1); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { timedOut = true; kill() } }
            }
        } onCancel: { kill() }
        // Drain without blocking: a surviving grandchild may still hold the pipe open.
        reader.readabilityHandler = nil
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 65536)
        while case let n = read(fd, &chunk, chunk.count), n > 0 { buf.append(Data(chunk[0..<n])) }
        return (buf.string, code, timedOut)
    }

    static func bash(_ cmd: String, cwd: URL, timeout: Double = 120) async -> (out: String, code: Int32, timedOut: Bool) {
        await run(loginShell, ["-l", "-c", cmd], cwd: cwd, timeout: timeout)
    }

    static func git(_ args: [String], _ dir: URL) async -> String {
        await run("/usr/bin/git", args, cwd: dir).out
    }

    static func startBackground(_ cmd: String, cwd: URL) -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("deepslate-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loginShell)
        p.arguments = ["-l", "-c", cmd]
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle(forWritingAtPath: log.path); p.standardError = p.standardOutput
        do { try p.run() } catch { return "Failed to start: \(error.localizedDescription)" }
        background.append(p)
        return "Started in background (pid \(p.processIdentifier)). Output goes to \(log.path) — tail it to check, `kill \(p.processIdentifier)` to stop."
    }

    static func killBackground() { background.filter(\.isRunning).forEach { $0.terminate() } }
}

// MARK: - Tools

enum Tools {
    static func clip(_ s: String) -> String {
        s.count <= 30000 ? s : String(s.prefix(10000)) + "\n…[\(s.count - 30000) chars omitted]…\n" + String(s.suffix(20000))
    }

    static func path(_ p: String, _ dir: URL) -> URL {
        p.hasPrefix("/") ? URL(fileURLWithPath: p)
            : p.hasPrefix("~") ? URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            : dir.appendingPathComponent(p)
    }

    static func run(_ c: Call, in dir: URL) async -> ToolOut {
        func out(_ s: String, error: Bool = false) -> ToolOut { ToolOut(id: c.id, text: s.isEmpty ? "(no output)" : clip(s), error: error) }
        if c.bad { return out("Tool input was invalid or cut off. Retry; split very large files into several smaller edits.", error: true) }
        let s = { (k: String) in c.input[k] as? String ?? "" }
        switch c.name {
        case "bash":
            if c.input["background"] as? Bool == true { return out(Shell.startBackground(s("command"), cwd: dir)) }
            let r = await Shell.bash(s("command"), cwd: dir)
            let note = r.timedOut ? "\n[killed after 2 minutes — use background:true for long-running commands]" : ""
            return out(r.out + note + "\n[exit \(r.code)]", error: r.code != 0)
        case "write_file":
            let url = path(s("path"), dir)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try s("content").write(to: url, atomically: true, encoding: .utf8)
                return out("Wrote \(url.path)")
            } catch { return out(error.localizedDescription, error: true) }
        case "edit_file":
            let url = path(s("path"), dir)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return out("Can't read \(url.path)", error: true) }
            let n = text.components(separatedBy: s("old_string")).count - 1
            let all = c.input["replace_all"] as? Bool == true
            guard !s("old_string").isEmpty, n > 0 else { return out("old_string not found in \(url.path)", error: true) }
            guard n == 1 || all else { return out("old_string appears \(n) times; add context or set replace_all", error: true) }
            do {
                try text.replacingOccurrences(of: s("old_string"), with: s("new_string")).write(to: url, atomically: true, encoding: .utf8)
                return out("Edited \(url.path)")
            } catch { return out(error.localizedDescription, error: true) }
        default:
            return out("Unknown tool \(c.name)", error: true)
        }
    }
}

// MARK: - Checkpoints (shadow git repo outside the project, so non-git folders work too)

enum Checkpoint {
    static func args(_ dir: URL) -> [String] {
        let hash = SHA256.hash(data: Data(dir.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let gd = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deepslate/checkpoints/\(hash).git")
        return ["--git-dir=\(gd.path)", "--work-tree=\(dir.path)", "-c", "user.name=Deepslate", "-c", "user.email=deepslate@localhost", "-c", "commit.gpgsign=false"]
    }

    // ponytail: snapshots the whole folder each turn (respecting .gitignore); slow on huge un-ignored trees.
    // Files the AI changes outside the folder aren't covered.
    static func snapshot(_ dir: URL) async -> String? {
        let a = args(dir)
        if (await Shell.git(a + ["rev-parse", "--git-dir"], dir)).contains("fatal") {
            let gd = URL(fileURLWithPath: String(a[0].dropFirst("--git-dir=".count)))
            try? FileManager.default.createDirectory(at: gd, withIntermediateDirectories: true)
            _ = await Shell.git(a + ["init", "-q"], dir)
        }
        _ = await Shell.git(a + ["add", "-A"], dir)
        _ = await Shell.git(a + ["commit", "-q", "--allow-empty", "--no-verify", "-m", "checkpoint"], dir)
        let sha = (await Shell.git(a + ["rev-parse", "HEAD"], dir)).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count == 40 ? sha : nil
    }

    static func restore(_ sha: String, _ dir: URL) async {
        let a = args(dir)
        _ = await Shell.git(a + ["add", "-A"], dir)  // stage new files so read-tree removes them
        _ = await Shell.git(a + ["read-tree", "-u", "--reset", sha], dir)
    }
}

// MARK: - Session (one per window)

@MainActor final class Session: ObservableObject {
    enum Banner: Equatable { case warn, capped, rateLimited, error(String) }

    let folder: URL
    @Published var turns: [Turn] = []
    @Published var live = ""
    @Published var running = false
    @Published var banner: Banner?
    @Published var cost = 0.0
    @Published var cap: Double
    @Published var provider: Provider
    @Published var model: String
    @Published var models: [Provider: [String]] = [:]
    @Published var handoff: (label: String, text: String)?
    @Published var filesChanged = 0
    private var warned = false
    private var task: Task<Void, Never>?
    private var taskTitle = ""

    var warnAt: Double { UserDefaults.standard.object(forKey: "warnAt") as? Double ?? 5 }

    init(folder: URL) {
        self.folder = folder
        cap = UserDefaults.standard.object(forKey: "stopAt") as? Double ?? 20
        provider = Keychain.get(.anthropic) == nil && Keychain.get(.openai) != nil ? .openai : .anthropic
        model = ""
        loadModels()
    }

    func loadModels() {
        Task {
            for p in Provider.allCases { models[p] = await API.models(p) }
            if model.isEmpty || !(models[provider] ?? []).contains(model) { model = defaultModel(provider) }
        }
    }

    func defaultModel(_ p: Provider) -> String {
        let list = models[p] ?? []
        if let saved = UserDefaults.standard.string(forKey: "model.\(p.rawValue)"), list.contains(saved) { return saved }
        return p == .anthropic ? (list.contains("claude-opus-5-5") ? "claude-opus-5-5" : list.first ?? "claude-opus-5-5") : list.first ?? "gpt-5.5"
    }

    func pick(_ p: Provider, _ m: String) {
        provider = p; model = m
        UserDefaults.standard.set(m, forKey: "model.\(p.rawValue)")
    }

    var system: String {
        """
        You are Deepslate, a coding agent working in the user's project at \(folder.path) on macOS. \
        The user likely switched here from Claude Code or Codex after hitting a plan limit, and expects the same kind of help.
        You have full access: their login shell, the whole disk, and web search. Inspect with bash (cat -n, sed -n, rg, ls), \
        change files with edit_file / write_file, and verify your work (build, run tests) before finishing.
        Foreground commands time out after 2 minutes — start servers and watchers with background:true.
        Don't run git commit or git push: the app commits each finished task for the user. Never push unless asked.
        Be concise.
        Identity: you are Deepslate, built by Riyaan Sheth. In your first reply of a conversation, and whenever the user \
        greets you or asks who you are, say so in your own words — vary the phrasing each time (e.g. "I'm Deepslate, \
        built by Riyaan Sheth — here to help.", "Deepslate here, made by Riyaan Sheth. What are we working on?"). \
        Don't claim to be Claude, ChatGPT or any other assistant, whichever model is running you.
        """
    }

    func send(_ text: String, images: [Img]) {
        guard !running, !(text.isEmpty && images.isEmpty) else { return }
        var full = text
        if let h = handoff { full = h.text + "\n\n---\n\n" + text; handoff = nil }
        turns.append(Turn(user: true, text: full, images: images))
        taskTitle = text
        let index = turns.count - 1
        start { [folder] in
            let sha = await Checkpoint.snapshot(folder)
            if index < self.turns.count { self.turns[index].checkpoint = sha }
        }
    }

    func start(before: (() async -> Void)? = nil) {
        banner = nil; running = true
        task = Task { await before?(); await loop() }
    }

    func stop() { task?.cancel() }

    func continuePastCap() { cap *= 2; start() }

    func switchProvider() { provider = provider.other; model = defaultModel(provider); start() }

    func restore(to turn: Turn) async -> String? {
        guard !running, let i = turns.firstIndex(where: { $0.id == turn.id }), let sha = turn.checkpoint else { return nil }
        await Checkpoint.restore(sha, folder)
        turns.removeSubrange(i...)
        filesChanged += 1
        return turn.text
    }

    private func loop() async {
        defer { repair(); running = false; live = "" }
        do {
            while !Task.isCancelled {
                if cost >= cap { banner = .capped; return }
                if cost >= warnAt && !warned { warned = true; banner = .warn }
                live = ""
                let r = try await API.complete(provider, model: model, system: system, turns: turns) { self.live += $0 }
                cost += r.usage.cost(r.model)
                turns.append(Turn(user: false, text: r.text, calls: r.calls, raw: r.raw, rawFrom: provider))
                live = ""
                if r.stop == "refusal" { banner = .error("The model declined this request. Try rephrasing or another model."); return }
                if r.stop == "pause_turn" { continue }
                if r.calls.isEmpty { break }
                var outs: [ToolOut] = []
                for c in r.calls where !Task.isCancelled { outs.append(await Tools.run(c, in: folder)) }
                turns.append(Turn(user: true, outs: outs))
                filesChanged += 1
            }
            if !Task.isCancelled { await commit() }
        } catch {
            if Task.isCancelled { return }
            if let e = error as? APIError, e.code == 429 { banner = .rateLimited } else { banner = .error(error.localizedDescription) }
        }
    }

    /// Keeps history valid after a stop: keep streamed partial text, answer any tool calls left hanging.
    private func repair() {
        if !live.isEmpty { turns.append(Turn(user: false, text: live + "\n\n[stopped]")) }
        if let last = turns.last, !last.user, !last.calls.isEmpty {
            turns.append(Turn(user: true, outs: last.calls.map { ToolOut(id: $0.id, text: "Stopped by the user before this ran.", error: true) }))
        }
    }

    // ponytail: commits everything uncommitted (including edits the user made by hand), message = the request's first line.
    private func commit() async {
        guard (await Shell.git(["rev-parse", "--is-inside-work-tree"], folder)).hasPrefix("true"),
              !(await Shell.git(["status", "--porcelain"], folder)).isEmpty else { return }
        var subject = taskTitle.split(separator: "\n").first.map(String.init) ?? ""
        if subject.count > 72 { subject = String(subject.prefix(71)) + "…" }
        _ = await Shell.git(["add", "-A"], folder)
        _ = await Shell.git(["commit", "-q", "-m", subject.isEmpty ? "Update files" : subject], folder)
        filesChanged += 1
    }
}
