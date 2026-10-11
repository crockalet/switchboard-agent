//
//  Shell.swift
//  switchboard-agent
//

import Foundation

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentError.commandFailed(
                detail.isEmpty ? "\(launchPath) \(arguments.joined(separator: " "))" : detail,
                process.terminationStatus
            )
        }
        return output
    }

    /// Like `run`, but a non-zero exit is an answer rather than an error —
    /// `launchctl list` exits non-zero for a label it does not know.
    static func capture(_ launchPath: String, _ arguments: [String]) -> String? {
        try? run(launchPath, arguments)
    }
}

enum Probe {
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func isListening(port: Int, timeout: TimeInterval = 0.12) -> Bool {
        guard let port = UInt16(exactly: port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

/// Commands the agent launched itself, tracked by pidfile so a restart of the
/// agent does not orphan them.
final class SupervisedProcesses: @unchecked Sendable {
    static let shared = SupervisedProcesses()

    private let lock = NSLock()
    private var running: [String: Process] = [:]

    private var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/switchboard", isDirectory: true)
    }

    private func pidfile(_ id: String) -> URL {
        stateDirectory.appendingPathComponent("\(id).pid")
    }

    func pid(for id: String) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        if let process = running[id], process.isRunning { return process.processIdentifier }
        guard let text = try? String(contentsOf: pidfile(id), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Probe.isAlive(pid) ? pid : nil
    }

    func start(_ service: ServiceConfig) throws {
        guard let command = service.command else {
            throw AgentError.misconfigured("\(service.id) has no command")
        }
        if pid(for: service.id) != nil { return }

        let process = Process()
        // Through a login shell, so the command resolves the same way it would
        // if the user typed it — PATH included.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let full = ([command] + (service.args ?? [])).joined(separator: " ")
        process.arguments = ["-lc", full]

        if let cwd = service.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if let extra = service.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        }

        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let logURL = stateDirectory.appendingPathComponent("\(service.id).log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()

        lock.lock()
        running[service.id] = process
        lock.unlock()

        try? String(process.processIdentifier).write(to: pidfile(service.id), atomically: true, encoding: .utf8)
    }

    func stop(_ id: String) throws {
        guard let pid = pid(for: id) else { return }
        kill(pid, SIGTERM)

        lock.lock()
        running[id] = nil
        lock.unlock()

        try? FileManager.default.removeItem(at: pidfile(id))
    }
}
