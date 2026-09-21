//
//  ServiceController.swift
//  switchboard-agent
//

import Foundation

enum ServiceStatus: String {
    case running, stopped, unknown
}

struct ServiceState {
    let config: ServiceConfig
    let status: ServiceStatus
    let pid: pid_t?
}

/// Runs the commands. This is the whole reason the agent exists as a separate
/// binary: a droplet is native code inside Droppy with no capability that
/// describes spawning a process, so the spawning lives out here.
struct ServiceController {
    let config: AgentConfig

    private var uid: uid_t { getuid() }

    // MARK: - Status

    func state(of service: ServiceConfig) -> ServiceState {
        // A port probe beats asking the supervisor: launchd will happily say a
        // job is loaded while the thing inside it is failing to bind.
        if let port = service.port {
            let listening = Probe.isListening(port: port)
            return ServiceState(
                config: service,
                status: listening ? .running : .stopped,
                pid: listening ? launchdPID(of: service) : nil
            )
        }

        switch service.kind {
        case .launchd:
            let pid = launchdPID(of: service)
            return ServiceState(config: service, status: pid != nil ? .running : .stopped, pid: pid)
        case .command:
            let pid = SupervisedProcesses.shared.pid(for: service.id)
            let alive = pid.map { Probe.isAlive($0) } ?? false
            return ServiceState(config: service, status: alive ? .running : .stopped, pid: alive ? pid : nil)
        }
    }

    func states() -> [ServiceState] {
        config.services.map(state(of:))
    }

    private func launchdPID(of service: ServiceConfig) -> pid_t? {
        guard service.kind == .launchd, let label = service.label else { return nil }
        // `launchctl list <label>` prints a plist-ish block whose PID key is
        // absent when the job is loaded but not running.
        guard let output = Shell.capture("/bin/launchctl", ["list", label]), !output.isEmpty else { return nil }
        for line in output.split(separator: "\n") where line.contains("\"PID\"") {
            let digits = line.filter(\.isNumber)
            if let pid = pid_t(digits), pid > 0 { return pid }
        }
        return nil
    }

    // MARK: - Actions

    func start(_ service: ServiceConfig) throws {
        switch service.kind {
        case .launchd:
            guard let label = service.label else { throw AgentError.misconfigured("\(service.id) has no launchd label") }
            try Shell.run("/bin/launchctl", ["kickstart", "gui/\(uid)/\(label)"])
        case .command:
            try SupervisedProcesses.shared.start(service)
        }
    }

    func stop(_ service: ServiceConfig) throws {
        switch service.kind {
        case .launchd:
            guard let label = service.label else { throw AgentError.misconfigured("\(service.id) has no launchd label") }
            // `kill` stops the running job without unloading it, so `start`
            // still works afterwards. `bootout` would remove it entirely.
            try Shell.run("/bin/launchctl", ["kill", "SIGTERM", "gui/\(uid)/\(label)"])
        case .command:
            try SupervisedProcesses.shared.stop(service.id)
        }
    }

    func restart(_ service: ServiceConfig) throws {
        switch service.kind {
        case .launchd:
            guard let label = service.label else { throw AgentError.misconfigured("\(service.id) has no launchd label") }
            // -k kills the running instance first; without it kickstart is a
            // no-op on an already-running job.
            try Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])
        case .command:
            try? SupervisedProcesses.shared.stop(service.id)
            try SupervisedProcesses.shared.start(service)
        }
    }
}

enum AgentError: Error, CustomStringConvertible {
    case misconfigured(String)
    case commandFailed(String, Int32)
    case unknownService(String)

    var description: String {
        switch self {
        case .misconfigured(let detail): return detail
        case .commandFailed(let command, let code): return "\(command) exited \(code)"
        case .unknownService(let id): return "No service named \(id)"
        }
    }
}
