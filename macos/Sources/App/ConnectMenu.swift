import AppKit

/// Parses hostnames out of an OpenSSH client config file.
enum SSHConfig {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config")

    /// All non-wildcard hosts from `~/.ssh/config` (following `Include`
    /// directives), sorted case-insensitively.
    static func hosts() -> [String] {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        var visited: Set<String> = []
        var hosts: [String] = []
        parse(
            url: configURL,
            base: sshDir,
            depth: 0,
            visited: &visited,
            hosts: &hosts)

        var seen: Set<String> = []
        return hosts
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    private static func parse(
        url: URL,
        base: URL,
        depth: Int,
        visited: inout Set<String>,
        hosts: inout [String]
    ) {
        guard depth <= 5 else { return }
        let path = url.standardizedFileURL.path
        guard visited.insert(path).inserted else { return }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(where: \.isWhitespace) else { continue }
            let keyword = line[..<separator].lowercased()
            let rest = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            switch keyword {
            case "host":
                for name in rest.split(whereSeparator: \.isWhitespace) {
                    let name = String(name)
                    guard !name.contains("*"), !name.contains("?") else { continue }
                    hosts.append(name)
                }
            case "include":
                for include in rest.split(whereSeparator: \.isWhitespace) {
                    var path = String(include)
                    if !path.hasPrefix("/") {
                        path = base.appendingPathComponent(path).path
                    }
                    parse(
                        url: URL(fileURLWithPath: path),
                        base: base,
                        depth: depth + 1,
                        visited: &visited,
                        hosts: &hosts)
                }
            default:
                continue
            }
        }
    }
}

/// Owns the Connect menu: SSH hosts from `~/.ssh/config` plus the active
/// SSH port forwards. Rebuilt from scratch every time the menu opens.
final class ConnectMenuController: NSObject, NSMenuDelegate {
    private let ghostty: Ghostty.App

    lazy var menuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Connect", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }()

    private let menu: NSMenu

    /// Last-known port forwards, rendered instantly so opening the menu never
    /// blocks on spawning `+ssh-forward --list` subprocesses.
    private var cachedPorts: [PortGroup] = []

    private struct PortGroup {
        let destination: String
        let tunnels: [SSHSessionStore.Tunnel]
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.menu = NSMenu(title: "Connect")
        super.init()
        self.menu.delegate = self
        refreshPortsCache()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hosts = SSHConfig.hosts()
        if hosts.isEmpty {
            let empty = NSMenuItem(
                title: "No Hosts in ~/.ssh/config",
                action: nil,
                keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for host in hosts {
                let item = NSMenuItem(
                    title: host,
                    action: #selector(openHost(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = host
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let ports = NSMenuItem(title: "Ports", action: nil, keyEquivalent: "")
        let portsMenu = NSMenu(title: "Ports")
        fillPortsMenu(portsMenu)
        ports.submenu = portsMenu
        menu.addItem(ports)

        menu.addItem(.separator())

        let useNiftty = NSMenuItem(
            title: "Use Niftty for SSH",
            action: #selector(toggleUseNiftty(_:)),
            keyEquivalent: "")
        useNiftty.target = self
        useNiftty.state = ghostty.config.sshMenuUseNiftty ? .on : .off
        menu.addItem(useNiftty)

        menu.addItem(.separator())

        let openConfig = NSMenuItem(
            title: "Open SSH Config",
            action: #selector(openSSHConfig(_:)),
            keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reloadConfig = NSMenuItem(
            title: "Reload SSH Config",
            action: #selector(reloadSSHConfig(_:)),
            keyEquivalent: "")
        reloadConfig.target = self
        menu.addItem(reloadConfig)

        // Refresh the tunnel cache off-main; the submenu hot-swaps when it lands.
        refreshPortsCache()
    }

    // MARK: - Ports

    private func refreshPortsCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ports = Self.collectSessions()
            DispatchQueue.main.async {
                guard self.cachedPorts.map(\.tunnels) != ports.map(\.tunnels) else { return }
                self.cachedPorts = ports
                self.rebuildPortsSubmenu()
            }
        }
    }

    /// Groups all live session tunnels by destination. Blocks: run off-main.
    private static func collectSessions() -> [PortGroup] {
        let sessionsDir = SSHSessionStore.stateURL(pid: 0).deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil)) ?? []

        var byDestination: [String: [SSHSessionStore.Tunnel]] = [:]
        var seen: Set<String> = []
        for entry in entries {
            guard let pid = Int(entry.lastPathComponent) else { continue }
            guard let list = try? SSHSessionStore.list(pid: pid) else { continue }
            for tunnel in list.tunnels
            where seen.insert("\(list.destination)|\(tunnel.id)").inserted {
                byDestination[list.destination, default: []].append(tunnel)
            }
        }
        return byDestination
            .sorted { $0.key < $1.key }
            .map { PortGroup(destination: $0.key, tunnels: $0.value) }
    }

    private func fillPortsMenu(_ menu: NSMenu) {
        if cachedPorts.isEmpty {
            let empty = NSMenuItem(title: "No Active Ports", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for session in cachedPorts {
            let item = NSMenuItem(title: session.destination, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: session.destination)
            for tunnel in session.tunnels {
                guard let url = URL(string: "http://\(tunnel.localHost):\(tunnel.localPort)")
                else { continue }
                let tunnelItem = NSMenuItem(
                    title: "\(tunnel.host) → \(tunnel.remote)",
                    action: #selector(openPort(_:)),
                    keyEquivalent: "")
                tunnelItem.target = self
                tunnelItem.representedObject = url
                submenu.addItem(tunnelItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func rebuildPortsSubmenu() {
        guard let portsItem = menu.items.first(where: { $0.title == "Ports" }),
              let submenu = portsItem.submenu else { return }
        submenu.removeAllItems()
        fillPortsMenu(submenu)
        menu.update()
    }

    // MARK: - Actions

    @objc private func openHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }

        var config = Ghostty.SurfaceConfiguration()
        if ghostty.config.sshMenuUseNiftty {
            let exe = Bundle.main.executableURL?.path ?? "niftty"
            config.command = "\(Ghostty.Shell.quote(exe)) +ssh \(Ghostty.Shell.quote(host))"
        } else {
            config.command = "ssh \(Ghostty.Shell.quote(host))"
        }

        _ = TerminalController.newTab(
            ghostty,
            from: TerminalController.preferredParent?.window,
            withBaseConfig: config)
    }

    @objc private func openPort(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSSHConfig(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(SSHConfig.configURL)
    }

    @objc private func reloadSSHConfig(_ sender: NSMenuItem) {
        menuNeedsUpdate(menu)
    }

    @objc private func toggleUseNiftty(_ sender: NSMenuItem) {
        let newValue = !ghostty.config.sshMenuUseNiftty
        do {
            let path = ghostty.configFilePath
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            let updated = SettingsFileEditor.replacingSettings(
                in: existing,
                values: ["ssh-menu-use-niftty": newValue ? "true" : "false"],
                orderedNames: [])
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            ghostty.reloadConfig()
            sender.state = newValue ? .on : .off
        } catch {
            AppDelegate.logger.error("Failed to toggle ssh-menu-use-niftty: \(error)")
            sender.state = ghostty.config.sshMenuUseNiftty ? .on : .off
        }
    }
}
