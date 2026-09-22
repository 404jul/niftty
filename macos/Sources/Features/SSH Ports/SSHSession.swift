import Darwin
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
        guard FileManager.default.fileExists(atPath: stateURL(pid: pid).path) else { return false }
        // A session that died without cleanup leaves its state file behind.
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// The `user@host` destination recorded by the `niftty +ssh` session
    /// for the given pid, read straight from the session state file.
    /// Nil when the file is missing or malformed.
    static func destination(pid: Int) -> String? {
        // Format written by `+ssh`: "<version>\n<control path>\n<destination>\n<ssh>\n"
        // (v2 appends a mux key line).
        guard let data = try? Data(contentsOf: stateURL(pid: pid)),
              data.count <= 16 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3,
              lines[0] == "1" || lines[0] == "2",
              !lines[2].isEmpty else { return nil }
        return String(lines[2])
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
