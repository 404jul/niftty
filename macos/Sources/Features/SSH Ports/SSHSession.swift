import Foundation

enum SSHSessionStore {
    /// Session files always live under `~/.local/state/niftty/ssh-sessions`
    /// regardless of XDG_STATE_HOME: this runs in the app's environment,
    /// which cannot observe shell rc exports like XDG_STATE_HOME, so the
    /// path must match what `+ssh` computes from HOME in the shell.
    static func stateURL(pid: Int) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/niftty/ssh-sessions", isDirectory: true)
            .appendingPathComponent(String(pid))
    }

    static func isActive(pid: Int) -> Bool {
        FileManager.default.fileExists(atPath: stateURL(pid: pid).path)
    }

    struct Tunnel: Identifiable, Equatable {
        var localHost: String
        var localPort: UInt16
        var remoteHost: String
        var remotePort: UInt16

        var id: String { "\(localHost):\(localPort)->\(remoteHost):\(remotePort)" }
        var host: String { "\(localHost):\(localPort)" }
        var remote: String { "\(remoteHost):\(remotePort)" }
    }

    struct List: Equatable {
        var destination: String
        var tunnels: [Tunnel]
    }

    static func list(pid: Int) throws -> List {
        let output = try run(pid: pid, arguments: ["--list"])
        var destination = ""
        var tunnels: [Tunnel] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let tag = fields.first else { continue }
            if tag == "D", fields.count >= 2 {
                destination = String(fields[1])
            } else if tag == "T", fields.count >= 5,
                      let localPort = UInt16(fields[2]),
                      let remotePort = UInt16(fields[4]) {
                tunnels.append(.init(
                    localHost: String(fields[1]),
                    localPort: localPort,
                    remoteHost: String(fields[3]),
                    remotePort: remotePort
                ))
            }
        }
        return .init(destination: destination, tunnels: tunnels)
    }

    static func add(pid: Int, local: UInt16?, remote: UInt16) throws {
        var arguments = ["--add", "--remote=\(remote)"]
        if let local {
            arguments.append("--local=\(local)")
        }
        _ = try run(pid: pid, arguments: arguments)
    }

    static func cancel(pid: Int, local: UInt16, remote: UInt16) throws {
        _ = try run(pid: pid, arguments: [
            "--cancel",
            "--local=\(local)",
            "--remote=\(remote)",
        ])
    }

    private static func run(pid: Int, arguments: [String]) throws -> String {
        guard let executable = Bundle.main.executableURL else {
            throw Error.executableUnavailable
        }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["+ssh-forward", "--pid=\(pid)"] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.commandFailed(err?.isEmpty == false ? err! : "Port forward failed")
        }
        return output
    }

    enum Error: LocalizedError {
        case executableUnavailable
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .executableUnavailable:
                "Niftty executable is unavailable"
            case .commandFailed(let message):
                message
            }
        }
    }
}
