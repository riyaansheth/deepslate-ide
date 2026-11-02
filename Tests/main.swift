// Run: ./Tests/run.sh — exercises tools, shell timeout, checkpoints, handoff parsing, cost math.
import Foundation

func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { exit(1) } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deepslate-test-\(UUID().uuidString.prefix(6))")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// Tools
var r = await Tools.run(Call(id: "1", name: "write_file", input: ["path": "a/b.txt", "content": "hello world"]), in: dir)
check(!r.error && (try? String(contentsOf: dir.appendingPathComponent("a/b.txt"), encoding: .utf8)) == "hello world", "write_file")
r = await Tools.run(Call(id: "2", name: "edit_file", input: ["path": "a/b.txt", "old_string": "world", "new_string": "there"]), in: dir)
check(!r.error && (try? String(contentsOf: dir.appendingPathComponent("a/b.txt"), encoding: .utf8)) == "hello there", "edit_file")
r = await Tools.run(Call(id: "3", name: "edit_file", input: ["path": "a/b.txt", "old_string": "nope", "new_string": "x"]), in: dir)
check(r.error, "edit_file missing string is an error")
r = await Tools.run(Call(id: "4", name: "bash", input: ["command": "echo $PWD; exit 3"]), in: dir)
check(r.error && r.text.contains(dir.lastPathComponent) && r.text.contains("[exit 3]"), "bash cwd + exit code")
r = await Tools.run(Call(id: "5", name: "bash", input: ["command": "x"], bad: true), in: dir)
check(r.error, "truncated tool input is rejected")

let t0 = Date()
let slow = await Shell.bash("echo start; sleep 30", cwd: dir, timeout: 1)
check(slow.timedOut && Date().timeIntervalSince(t0) < 5 && slow.out.contains("start"), "timeout kills and keeps output")

let cancelled = Task { await Shell.bash("sleep 30", cwd: dir) }
try? await Task.sleep(nanoseconds: 300_000_000); cancelled.cancel()
let t1 = Date(); _ = await cancelled.value
check(Date().timeIntervalSince(t1) < 3, "cancel (Esc) kills the command")

r = await Tools.run(Call(id: "6", name: "bash", input: ["command": "echo bg-ok", "background": true]), in: dir)
try? await Task.sleep(nanoseconds: 1_500_000_000)
let log = r.text.components(separatedBy: "Output goes to ").last!.components(separatedBy: " —").first!
check((try? String(contentsOfFile: log, encoding: .utf8))?.contains("bg-ok") == true, "background command logs")

// Checkpoints: restore removes new files and reverts edits
let cp = await Checkpoint.snapshot(dir)
check(cp != nil, "snapshot")
try! "changed".write(to: dir.appendingPathComponent("a/b.txt"), atomically: true, encoding: .utf8)
try! "new".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
await Checkpoint.restore(cp!, dir)
check((try? String(contentsOf: dir.appendingPathComponent("a/b.txt"), encoding: .utf8)) == "hello there", "restore reverts edit")
check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path), "restore removes new file")

// Handoff parsing
let cc = Handoff.entry("Claude Code", ["type": "assistant", "message": ["content": [["type": "text", "text": "Done."], ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]]])
check(cc == "Assistant: Done.\n[tool Bash] {\"command\":\"ls\"}", "claude code line")
check(Handoff.entry("Claude Code", ["type": "user", "message": ["content": "<command-name>/usage</command-name>"]]) == nil, "skips command wrappers")
let cx = Handoff.entry("Codex", ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "fix the bug"]]]])
check(cx == "User: fix the bug", "codex line")
let found = Handoff.list()
print("     found \(found.count) local sessions; newest: \(found.first.map { "\($0.source) — \($0.title)" } ?? "none")")
if let h = found.first { check(await h.render(folder: dir).contains("<previous_session>"), "render handoff") }

// Cost
var u = Usage(); u.input = 1_000_000; u.output = 1_000_000
check(abs(u.cost("claude-opus-5-5") - 24) < 0.001, "opus 5.5 pricing")
check(abs(u.cost("claude-opus-5") - 30) < 0.001, "opus 5 pricing (no prefix clash)")
check(abs(u.cost("gpt-5") - 11.25) < 0.001, "gpt-5 pricing")

try? FileManager.default.removeItem(at: dir)
print("all checks passed")
