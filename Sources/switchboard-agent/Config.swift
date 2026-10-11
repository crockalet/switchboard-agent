//
//  Config.swift
//  switchboard-agent
//
//  The configuration Switchboard itself must not carry. Everything here names
//  a command or a launchd label, which is exactly the part that cannot live in
//  a reviewed, signed droplet bundle.
//

import Foundation
import Security

/// How the agent starts and stops one service.
enum ServiceKind: String, Codable {
    /// A launchd agent, addressed by label. The flags live in the plist, so the
    /// agent never has to know them.
    case launchd
    /// A command the agent spawns and supervises itself.
    case command
}

struct ServiceConfig: Codable {
    let id: String
    let name: String
    let kind: ServiceKind

    /// `launchd` only: the job label, for example `com.you.thing`.
    var label: String?

    /// `command` only: the executable and its arguments. This is where a
    /// service's own flags go — `baguette serve --allowed-hosts sim.localhost`
    /// is a command and two arguments, not something Switchboard knows about.
    var command: String?
    var args: [String]?
    var workingDirectory: String?
    var environment: [String: String]?

    /// Optional. When present, liveness is "something is listening here",
    /// which is truer than "the supervisor thinks it is up".
    var port: Int?

    /// Optional. The URL a person would open, usually the portless one.
    var url: String?

    /// Optional override for where this service logs. Rarely needed: a
    /// `launchd` job's path is read from its plist and a `command` gets one
    /// from this agent.
    var logPath: String?
}

struct AgentConfig: Codable {
    var port: Int
    var services: [ServiceConfig]

    static let defaultPort = 7878

    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["SWITCHBOARD_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/switchboard/services.json")
    }

    static func load() throws -> AgentConfig {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentConfig(port: defaultPort, services: [])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentConfig.self, from: data)
    }

    func save() throws {
        let url = AgentConfig.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}

/// The shared secret the droplet sends as `X-Switchboard-Token`. A file of its
/// own, so the agent never rewrites the user's services.json; always at the
/// default location, because that is where the droplet looks.
enum AgentToken {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/switchboard/token")
    }

    /// The existing token, or a new one written at 0600.
    static func loadOrCreate() throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentError.misconfigured("could not generate a token")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AgentError.misconfigured("could not write \(url.path)")
        }
        return token
    }

    /// Constant time, so the comparison does not leak a matching prefix.
    static func matches(_ candidate: String?, _ token: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
