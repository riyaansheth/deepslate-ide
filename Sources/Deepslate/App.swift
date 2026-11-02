import SwiftUI
import AppKit

@main
struct DeepslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            if let url {
                ContentView(folder: url).navigationTitle(url.lastPathComponent)
            } else {
                Welcome(url: $url)
            }
        }
        .commands { CommandGroup(after: .newItem) { OpenFolderCommand() } }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Task { await Updater.shared.check() } }
    func applicationWillTerminate(_ n: Notification) { Shell.killBackground() }
}

func pickFolder() -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Open"
    return p.runModal() == .OK ? p.url : nil
}

struct OpenFolderCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Folder…") { if let u = pickFolder() { openWindow(value: u) } }.keyboardShortcut("o")
    }
}

struct Welcome: View {
    @Binding var url: URL?
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Deepslate").font(.largeTitle.bold())
            Text("Keep coding when your Claude or ChatGPT plan runs out.").foregroundStyle(.secondary)
            Button("Open Folder…") { url = pickFolder() }.keyboardShortcut("o").controlSize(.large)
            KeyField().frame(width: 380)
            if let u = updater.url { Link("A new version is available", destination: u) }
        }
        .padding(40).frame(minWidth: 520, minHeight: 420)
    }
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "riyaansheth/deepslate-ide"
    @Published var url: URL?

    func check() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!),
              let j = try? JSONSerialization.jsonObject(with: d) as? JSON,
              let tag = (j["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
              tag.compare(current, options: .numeric) == .orderedDescending,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        url = page
    }
}
