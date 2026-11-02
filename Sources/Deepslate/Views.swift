import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - Window

struct ContentView: View {
    let folder: URL
    @StateObject private var session: Session
    @ObservedObject private var updater = Updater.shared
    @Local private var selection: URL?
    @Local private var tree = 0

    init(folder: URL) {
        self.folder = folder
        _session = StateObject(wrappedValue: Session(folder: folder))
    }

    var body: some View {
        NavigationSplitView {
            FileTree(root: folder, selection: $selection).id(tree)
                .navigationSplitViewColumnWidth(min: 160, ideal: 220)
                .toolbar { Button { tree += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        } content: {
            EditorPane(folder: folder, file: selection, session: session)
                .navigationSplitViewColumnWidth(min: 300, ideal: 560)
        } detail: {
            ChatPane(s: session)
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        }
        .toolbar {
            if let url = updater.url { Link("Update available", destination: url) }
            Text(String(format: "$%.2f", session.cost)).monospacedDigit().foregroundStyle(.secondary)
                .help("Spent in this window. Warns at $\(Int(session.warnAt)), stops at $\(Int(session.cap)).")
            ModelMenu(s: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .keysChanged)) { _ in session.loadModels() }
    }
}

struct ModelMenu: View {
    @ObservedObject var s: Session
    var body: some View {
        Menu(s.model.isEmpty ? "Model" : s.model) {
            ForEach(Provider.allCases, id: \.self) { p in
                Section(p.name) {
                    let list = s.models[p] ?? []
                    if list.isEmpty { Text(Keychain.get(p) == nil ? "No key — add one in Settings" : "Loading…") }
                    ForEach(list, id: \.self) { m in
                        Button { s.pick(p, m) } label: { s.model == m ? Label(m, systemImage: "checkmark") : Label(m, systemImage: "") }
                    }
                }
            }
        }
        .disabled(s.running)
    }
}

// MARK: - Files

final class FileNode: Identifiable {
    let url: URL, isDir: Bool
    var id: URL { url }
    init(_ url: URL) {
        self.url = url
        isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    lazy var children: [FileNode]? = isDir ? FileNode.list(url) : nil

    static func list(_ dir: URL) -> [FileNode] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { ![".git", ".DS_Store"].contains($0.lastPathComponent) }
            .map(FileNode.init)
            .sorted { $0.isDir != $1.isDir ? $0.isDir : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
}

struct FileTree: View {
    let root: URL
    @Binding var selection: URL?
    @Local private var nodes: [FileNode] = []
    var body: some View {
        List(nodes, children: \.children, selection: $selection) { n in
            Label(n.url.lastPathComponent, systemImage: n.isDir ? "folder" : "doc")
        }
        .onAppear { nodes = FileNode.list(root) }
    }
}

// MARK: - Editor / diff

struct EditorPane: View {
    let folder: URL
    let file: URL?
    @ObservedObject var session: Session
    @Local private var text = ""
    @Local private var saved = ""
    @Local private var editable = false
    @Local private var showDiff = false
    @Local private var diff = AttributedString()

    var isFile: Bool { file.map { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true) } ?? false }

    var body: some View {
        Group {
            if showDiff {
                ScrollView([.vertical, .horizontal]) {
                    Text(diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            } else if isFile {
                TextBox(text: $text).disabled(!editable)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc.text", description: Text("Pick a file on the left, or switch to Diff to see all changes."))
            }
        }
        .navigationTitle(file?.lastPathComponent ?? folder.lastPathComponent)
        .navigationSubtitle(text != saved ? "Edited" : "")
        .toolbar {
            Picker("View", selection: $showDiff) { Text("Edit").tag(false); Text("Diff").tag(true) }.pickerStyle(.segmented)
            Button("Save", action: save).keyboardShortcut("s").disabled(text == saved || !editable)
        }
        .task(id: file) { load(); await loadDiff() }
        .task(id: showDiff) { await loadDiff() }
        .onChange(of: session.filesChanged) {
            if text == saved { load() }
            Task { await loadDiff() }
        }
    }

    func load() {
        guard isFile, let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
              let s = try? String(contentsOf: file, encoding: .utf8) else {
            text = isFile ? "(binary or too large to show)" : ""; saved = text; editable = false; return
        }
        text = s; saved = s; editable = true
    }

    func save() {
        guard let file else { return }
        do { try text.write(to: file, atomically: true, encoding: .utf8); saved = text } catch { NSSound.beep() }
    }

    func loadDiff() async {
        guard showDiff else { return }
        var args = ["diff", "HEAD"]
        if isFile, let file { args += ["--", file.path] }
        var raw = await Shell.git(args, folder)
        if raw.contains("fatal:") { raw = "Not a git repository — no diff to show." }
        if raw.isEmpty { raw = "No uncommitted changes." }
        var out = AttributedString()
        for line in raw.prefix(300_000).split(separator: "\n", omittingEmptySubsequences: false) {
            var a = AttributedString(line + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") { a.foregroundColor = .green }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { a.foregroundColor = .red }
            else if line.hasPrefix("@@") { a.foregroundColor = .blue }
            out += a
        }
        diff = out
    }
}

// MARK: - Chat

struct ChatPane: View {
    @ObservedObject var s: Session
    @Local private var input = ""
    @Local private var images: [Img] = []
    @Local private var sessions: [Handoff] = []
    @Local private var offer: Handoff?

    var body: some View {
        VStack(spacing: 0) {
            banners
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if s.turns.isEmpty && Keychain.get(.anthropic) == nil && Keychain.get(.openai) == nil {
                            KeyField().padding(.vertical)
                        }
                        ForEach(s.turns) { t in TurnView(t: t) { restore(t) } }
                        if s.running {
                            if s.live.isEmpty { ProgressView().controlSize(.small) } else { Text(markdown(s.live)).textSelection(.enabled) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .onChange(of: s.turns.count) { proxy.scrollTo("end") }
                .onChange(of: s.live) { proxy.scrollTo("end") }
            }
            Divider()
            composer
        }
        .task {
            sessions = Handoff.list()
            offer = sessions.first { $0.cwd == s.folder.path }
        }
        .toolbar {
            Menu {
                if sessions.isEmpty { Text("No Claude Code or Codex sessions found") }
                ForEach(sessions) { h in
                    Button("\(h.source): \(h.title) — \(h.date.formatted(.relative(presentation: .named)))") { take(h) }
                }
            } label: { Label("Continue a session", systemImage: "arrow.uturn.forward") }
            .help("Continue a Claude Code or Codex session")
        }
    }

    @ViewBuilder var banners: some View {
        if let h = offer, s.turns.isEmpty, s.handoff == nil {
            Banner(text: "Continue your \(h.source) session “\(h.title)” from \(h.date.formatted(.relative(presentation: .named)))?") {
                Button("Continue") { take(h) }; Button("Dismiss") { offer = nil }
            }
        }
        switch s.banner {
        case .warn:
            Banner(text: "You've spent over $\(Int(s.warnAt)) in this window.") { Button("OK") { s.banner = nil } }
        case .capped:
            Banner(text: "Stopped at your $\(Int(s.cap)) limit.") { Button("Continue to $\(Int(s.cap * 2))") { s.continuePastCap() } }
        case .rateLimited:
            Banner(text: "\(s.provider.name) is rate-limiting you.") {
                if Keychain.get(s.provider.other) != nil { Button("Switch to \(s.provider.other.name)") { s.switchProvider() } }
                Button("Retry") { s.start() }
            }
        case .error(let msg):
            Banner(text: msg) { Button("Retry") { s.start() }; Button("Dismiss") { s.banner = nil } }
        case nil: EmptyView()
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let h = s.handoff {
                HStack { Label(h.label, systemImage: "arrow.uturn.forward").font(.caption); Button("✕") { s.handoff = nil }.buttonStyle(.plain) }
            }
            if !images.isEmpty {
                HStack { ForEach(images.indices, id: \.self) { i in Thumb(img: images[i]).onTapGesture { images.remove(at: i) } } }
            }
            HStack(alignment: .bottom) {
                Button { attach() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("Attach images")
                TextBox(text: $input, font: .systemFont(ofSize: 13), onSubmit: submit, onEscape: s.stop) { data in
                    if let i = makeImg(data) { images.append(i) }
                }
                .frame(minHeight: 36, maxHeight: 140)
                if s.running {
                    Button(action: s.stop) { Image(systemName: "stop.circle.fill") }.buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: []).help("Stop (Esc)")
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless)
                }
            }
        }
        .padding(8)
        .dropDestination(for: URL.self) { urls, _ in
            let found = urls.compactMap { (try? Data(contentsOf: $0)).flatMap(makeImg) }
            images += found
            return !found.isEmpty
        }
    }

    func submit() {
        guard !s.running else { return }
        s.send(input.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
        input = ""; images = []
    }

    func take(_ h: Handoff) {
        offer = nil
        Task { s.handoff = ("Continuing \(h.source): \(h.title)", await h.render(folder: s.folder)) }
    }

    func restore(_ t: Turn) {
        Task { if let text = await s.restore(to: t) { input = text } }
    }

    func attach() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        images += p.urls.compactMap { (try? Data(contentsOf: $0)).flatMap(makeImg) }
    }
}

struct Banner<Buttons: View>: View {
    let text: String
    @ViewBuilder let buttons: Buttons
    var body: some View {
        HStack { Text(text).font(.callout).lineLimit(3); Spacer(); buttons }
            .padding(8).background(.yellow.opacity(0.15))
    }
}

struct TurnView: View {
    let t: Turn
    let onRestore: () -> Void
    var body: some View {
        if t.user {
            ForEach(t.outs, id: \.id) { o in
                DisclosureGroup {
                    Text(String(o.text.prefix(4000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text(o.error ? "Error" : "Output").font(.caption).foregroundStyle(o.error ? .red : .secondary) }
            }
            if !t.text.isEmpty || !t.images.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { ForEach(t.images.indices, id: \.self) { Thumb(img: t.images[$0]) } }
                    Text(t.text.count > 600 ? String(t.text.suffix(600)) : t.text).textSelection(.enabled)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contextMenu { if t.checkpoint != nil { Button("Restore files to before this message", action: onRestore) } }
            }
        } else {
            if !t.text.isEmpty { Text(markdown(t.text)).textSelection(.enabled) }
            ForEach(t.calls, id: \.id) { c in
                Text(describe(c)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    func describe(_ c: Call) -> String {
        let s = { (k: String) in c.input[k] as? String ?? "" }
        switch c.name {
        case "bash": return "$ " + s("command") + (c.input["background"] as? Bool == true ? "  &" : "")
        case "write_file": return "✎ write " + s("path")
        case "edit_file": return "✎ edit " + s("path")
        default: return c.name
        }
    }
}

struct Thumb: View {
    let img: Img
    var body: some View {
        if let d = Data(base64Encoded: img.b64), let ns = NSImage(data: d) {
            Image(nsImage: ns).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Any image data → JPEG, longest side ≤ 1568px (what both providers recommend; keeps requests small).
func makeImg(_ data: Data) -> Img? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceCreateThumbnailWithTransform: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: 1568] as CFDictionary),
          let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
    return Img(mime: "image/jpeg", b64: jpeg.base64EncodedString())
}

// MARK: - Plain-text NSTextView (no smart quotes; Enter / Esc / image paste hooks)

struct TextBox: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var onSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onImage: ((Data) -> Void)? = nil

    final class View: NSTextView {
        var box: TextBox?
        override func keyDown(with e: NSEvent) {
            if let submit = box?.onSubmit, e.keyCode == 36, !e.modifierFlags.contains(.shift), !hasMarkedText() { submit() } else { super.keyDown(with: e) }
        }
        override func cancelOperation(_ sender: Any?) { if let esc = box?.onEscape { esc() } else { super.cancelOperation(sender) } }
        override func paste(_ sender: Any?) {
            let pb = NSPasteboard.general
            if let onImage = box?.onImage, pb.string(forType: .string) == nil,
               let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { onImage(data) } else { super.paste(sender) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var box: TextBox
        init(_ box: TextBox) { self.box = box }
        func textDidChange(_ n: Notification) { box.text = (n.object as! NSTextView).string }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = View()
        tv.isRichText = false; tv.allowsUndo = true; tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false; tv.isContinuousSpellCheckingEnabled = false
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.delegate = context.coordinator
        let sv = NSScrollView(); sv.documentView = tv; sv.hasVerticalScroller = true; sv.drawsBackground = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! View
        context.coordinator.box = self; tv.box = self
        tv.font = font
        tv.isEditable = context.environment.isEnabled
        if tv.string != text { tv.string = text }
    }
}

// MARK: - Keys & settings

extension Notification.Name { static let keysChanged = Notification.Name("keysChanged") }

struct KeyField: View {
    @Local private var key = ""
    @Local private var note = ""
    @Local private var tick = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Paste a Claude (sk-ant-…) or OpenAI (sk-…) API key", text: $key)
                .onChange(of: key) { save() }.onSubmit(save)
            ForEach(Provider.allCases, id: \.self) { p in
                HStack {
                    Image(systemName: Keychain.get(p) == nil ? "circle" : "checkmark.circle.fill")
                    Text("\(p.name) key \(Keychain.get(p) == nil ? "not set" : "saved in Keychain")")
                    if Keychain.get(p) != nil { Button("Remove") { Keychain.set(p, nil); changed() } }
                }.id(tick)
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
    func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count > 30, let p = Provider.detect(k) else { return }
        Keychain.set(p, k); key = ""; note = "Saved your \(p.name) key."; changed()
    }
    func changed() { tick += 1; NotificationCenter.default.post(name: .keysChanged, object: nil) }
}

struct SettingsView: View {
    @AppStorage("warnAt") private var warnAt = 5.0
    @AppStorage("stopAt") private var stopAt = 20.0
    var body: some View {
        Form {
            Section("API keys") { KeyField() }
            Section("Spending per window") {
                TextField("Warn at", value: $warnAt, format: .currency(code: "USD"))
                TextField("Stop at", value: $stopAt, format: .currency(code: "USD"))
                Text("When it stops, you can continue to double the limit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 460)
    }
}

/// The macOS 27 SDK turns `@State` into a macro whose plugin ships only with Xcode; the typealias
/// reaches the same property wrapper so the app builds with Command Line Tools alone.
typealias Local = SwiftUI.State
