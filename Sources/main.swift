import SwiftUI
import AppKit
import UserNotifications

// MARK: - Shell

@discardableResult
func sh(_ cmd: String) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // Login shell so gh/git are found the same way as in Terminal.
    p.arguments = ["-lc", cmd]
    var e = ProcessInfo.processInfo.environment
    e["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (e["PATH"] ?? "")
    p.environment = e
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Picks the Vietnamese string when the system's preferred language is Vietnamese, English otherwise.
let isVietnamese = Locale.preferredLanguages.first?.hasPrefix("vi") ?? false
func t(_ en: String, _ vi: String) -> String { isVietnamese ? vi : en }

let configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh-switcher")

// MARK: - Model

/// The gh account switches freely; the global git identity is one fixed pair the
/// user sets here, and it is put back after every switch.
@MainActor
final class Store: ObservableObject {
    @Published var accounts: [String] = []
    @Published var active: String = ""
    @Published var gitName: String = ""
    @Published var gitEmail: String = ""
    @Published var avatars: [String: NSImage] = [:]
    @Published var busy: String?
    @Published var lastError: String?

    let avatarDir = configDir.appendingPathComponent("avatars")
    let defaults = UserDefaults.standard

    var savedName: String { defaults.string(forKey: "gitName") ?? "" }
    var savedEmail: String { defaults.string(forKey: "gitEmail") ?? "" }

    init() {
        readGit()
        // First launch: remember whatever git global is set to now.
        if savedName.isEmpty && savedEmail.isEmpty {
            defaults.set(gitName, forKey: "gitName")
            defaults.set(gitEmail, forKey: "gitEmail")
        }
        refresh()
        Task { await loadAvatars() }
        watchHosts()
    }

    /// Reads gh's hosts.yml for the list of logged-in accounts and the active one.
    func readHosts() -> (users: [String], active: String) {
        let path = NSHomeDirectory() + "/.config/gh/hosts.yml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ([], "") }
        var users: [String] = []
        var active = ""
        var inGitHub = false, inUsers = false
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if indent == 0 { inGitHub = line.hasPrefix("github.com:"); inUsers = false; continue }
            guard inGitHub else { continue }
            if indent == 4 {
                inUsers = line.hasPrefix("users:")
                if line.hasPrefix("user:") {
                    active = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            } else if indent == 8 && inUsers && line.hasSuffix(":") {
                users.append(String(line.dropLast()))
            }
        }
        return (users, active)
    }

    func readGit() {
        gitName = sh("git config --global user.name").out
        gitEmail = sh("git config --global user.email").out
    }

    func refresh() {
        readHostsAndNotify()
        readGit()
    }

    /// Single place where the active account changes, whether the switch came from
    /// this app or from `gh auth switch` in a terminal, so each change notifies once.
    func readHostsAndNotify() {
        let h = readHosts()
        let previous = active
        let users = h.users.sorted()
        if users != accounts {
            accounts = users
            Task { await loadAvatars() }
        }
        active = h.active
        if !previous.isEmpty, h.active != previous, !h.active.isEmpty {
            notifySwitched(to: h.active, avatarFile: avatarDir.appendingPathComponent("\(h.active).png"))
        }
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// gh rewrites hosts.yml in place, so watch the file itself. If it is ever
    /// replaced or deleted, re-open it (retrying until it exists again).
    func watchHosts() {
        watcher?.cancel()
        watcher = nil
        let path = NSHomeDirectory() + "/.config/gh/hosts.yml"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.watchHosts() }
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let replaced = !(src?.data.intersection([.rename, .delete]).isEmpty ?? true)
                // Debounce: one switch produces several events.
                self.pending?.cancel()
                let work = DispatchWorkItem { MainActor.assumeIsolated { self.readHostsAndNotify() } }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                if replaced { self.watchHosts() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    var gitMatchesSaved: Bool { gitName == savedName && gitEmail == savedEmail }

    /// Saves the identity and writes it to git config --global.
    func setGit(name: String, email: String) {
        defaults.set(name, forKey: "gitName")
        defaults.set(email, forKey: "gitEmail")
        applySavedGit()
    }

    func applySavedGit() {
        if !savedName.isEmpty { sh("git config --global user.name \(q(savedName))") }
        if !savedEmail.isEmpty { sh("git config --global user.email \(q(savedEmail))") }
        readGit()
    }

    func switchTo(_ login: String) {
        guard login != active else { return }
        busy = login
        lastError = nil
        Task.detached {
            let r = sh("gh auth switch -h github.com -u \(q(login))")
            let err: String? = r.code == 0 ? nil : r.out
            await MainActor.run {
                self.applySavedGit()
                self.busy = nil
                self.lastError = err
                self.refresh()
            }
        }
    }

    /// Avatars are cached on disk; the cache is used first and refreshed daily.
    func loadAvatars(force: Bool = false) async {
        try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        for login in accounts {
            let file = avatarDir.appendingPathComponent("\(login).png")
            if !force, avatars[login] == nil, let img = NSImage(contentsOf: file) {
                avatars[login] = img
            }
            if !force, avatars[login] != nil,
               let mod = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(mod) < 86_400 { continue }
            guard let url = URL(string: "https://github.com/\(login).png?size=160"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { continue }
            try? data.write(to: file)
            avatars[login] = img
        }
    }

    func addAccount() {
        let script = """
        tell application "Terminal"
            activate
            do script "gh auth login -h github.com -p https -w"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

// MARK: - Notifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // Show the banner even while the panel (our app) is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

func setUpNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = NotificationDelegate.shared
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func notifySwitched(to login: String, avatarFile: URL) {
    let content = UNMutableNotificationContent()
    content.title = t("Switched to \(login)", "Đã chuyển sang \(login)")
    content.body = t("GitHub CLI is now using \(login)", "GitHub CLI đang dùng tài khoản \(login)")
    // The system takes ownership of attachment files, so hand it a copy.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    if (try? FileManager.default.copyItem(at: avatarFile, to: tmp)) != nil,
       let att = try? UNNotificationAttachment(identifier: "avatar", url: tmp) {
        content.attachments = [att]
    }
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
}

// MARK: - Images

func circular(_ image: NSImage, size: CGFloat) -> NSImage {
    let out = NSImage(size: NSSize(width: size, height: size))
    out.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSBezierPath(ovalIn: rect).addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    return out
}

struct Avatar: View {
    let image: NSImage?
    let login: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.2))
                    Text(login.prefix(1).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Panel
// Styled after the system Wi‑Fi / Bluetooth menus: bold title, small section
// headers, menu-item rows with a soft hover highlight, checkmark for the active item.

struct Panel: View {
    @ObservedObject var store: Store
    @AppStorage("showName") private var showName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GitHub")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            SectionHeader(t("Accounts", "Tài khoản"))
            ForEach(store.accounts, id: \.self) { login in
                AccountRow(store: store, login: login)
            }

            MenuDivider()
            SectionHeader("Git global")
            GitIdentityRow(store: store)
            if !store.gitMatchesSaved {
                MenuItem(t("Restore", "Khôi phục") + " \(store.savedName) <\(store.savedEmail)>") { store.applySavedGit() }
            }

            if let err = store.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }

            MenuDivider()
            ToggleRow(title: t("Show username in menu bar", "Hiện tên trên thanh menu"), isOn: $showName)

            MenuDivider()
            MenuItem(t("Add Account…", "Thêm tài khoản…")) { store.addAccount() }
            MenuItem(t("Refresh", "Làm mới")) {
                store.refresh()
                Task { await store.loadAvatars(force: true) }
            }
            MenuDivider()
            MenuItem(t("Quit GitHub Switcher", "Thoát GitHub Switcher")) { NSApp.terminate(nil) }
        }
        .padding(5)
        .frame(width: 300)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }
}

struct Highlight: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? Color.primary.opacity(0.09) : .clear)
        )
    }
}

struct MenuItem: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(Highlight(on: hover))
        .onHover { hover = $0 }
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

struct AccountRow: View {
    @ObservedObject var store: Store
    let login: String
    @State private var hover = false

    var isActive: Bool { login == store.active }

    var body: some View {
        HStack(spacing: 8) {
            Avatar(image: store.avatars[login], login: login, size: 26)
            Text(login).font(.system(size: 13))
            Spacer(minLength: 4)
            if store.busy == login {
                ProgressView().controlSize(.mini)
            } else if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { store.switchTo(login) }
        .modifier(Highlight(on: hover))
        .onHover { hover = $0 }
    }
}

/// Shows the global git identity; click to edit it in place.
struct GitIdentityRow: View {
    @ObservedObject var store: Store
    @State private var hover = false
    @State private var editing = false
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.gitName.isEmpty ? t("user.name not set", "Chưa đặt user.name") : store.gitName)
                        .font(.system(size: 13))
                    Text(store.gitEmail.isEmpty ? t("user.email not set", "Chưa đặt user.email") : store.gitEmail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if hover || editing {
                    Text(editing ? t("Close", "Đóng") : t("Edit", "Sửa"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { editing ? (editing = false) : startEdit() }
            .modifier(Highlight(on: hover && !editing))
            .onHover { hover = $0 }

            if editing { editor }
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField("Name", text: $name, prompt: Text("user.name"))
                TextField("Email", text: $email, prompt: Text("user.email"))
            }
            .controlSize(.small)
            .font(.system(size: 12))
            Text(t("Switching accounts never changes this.", "Đổi tài khoản không làm thay đổi giá trị này."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(t("Cancel", "Huỷ")) { editing = false }
                    .controlSize(.small)
                Button(t("Save", "Lưu")) {
                    store.setGit(name: name.trimmingCharacters(in: .whitespaces),
                                 email: email.trimmingCharacters(in: .whitespaces))
                    editing = false
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || email.isEmpty)
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    func startEdit() {
        name = store.savedName.isEmpty ? store.gitName : store.savedName
        email = store.savedEmail.isEmpty ? store.gitEmail : store.savedEmail
        editing = true
    }
}

// MARK: - App

@main
struct GitHubSwitcherApp: App {
    @StateObject private var store = Store()
    @AppStorage("showName") private var showName = true

    init() { setUpNotifications() }

    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            if let img = store.avatars[store.active] {
                Image(nsImage: circular(img, size: 18))
            } else {
                Image(systemName: "person.crop.circle")
            }
            if showName { Text(store.active) }
        }
        .menuBarExtraStyle(.window)
    }
}
