//
//  LogReader.swift
//  switchboard-agent
//
//  Finding and tailing a service's log. The point of doing this here rather
//  than in the droplet is that neither kind of service has to be told where its
//  log is: a launchd job already declared it in its plist, and a supervised
//  command was given one by this agent.
//

import Foundation

struct LogReader {
    /// How much of the tail to read. A log nothing rotates can reach
    /// gigabytes, so this seeks from the end rather than reading the file.
    static let maxTailBytes = 256 * 1024

    private static var supervisedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/switchboard", isDirectory: true)
    }

    /// Where a service's output actually lands.
    static func path(for service: ServiceConfig) -> URL? {
        // An explicit override wins: some services log somewhere of their own
        // choosing and neither default finds it.
        if let explicit = service.logPath, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }

        switch service.kind {
        case .command:
            return supervisedDirectory.appendingPathComponent("\(service.id).log")
        case .launchd:
            guard let label = service.label else { return nil }
            return launchdLogPath(label: label)
        }
    }

    /// Reads `StandardOutPath` out of the job's own plist, falling back to
    /// `StandardErrorPath`. A job that redirects neither has no log to show.
    private static func launchdLogPath(label: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist"),
            URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
        ]

        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any]
            else { continue }

            for key in ["StandardOutPath", "StandardErrorPath"] {
                if let path = dictionary[key] as? String, !path.isEmpty {
                    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                }
            }
        }
        return nil
    }

    /// The last `lines` lines, or an empty array when there is no log yet —
    /// which is normal for a service that has not run since it was configured.
    static func tail(_ service: ServiceConfig, lines: Int) -> (path: String?, lines: [String]) {
        guard let url = path(for: service) else { return (nil, []) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (url.path, []) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        try? handle.seek(toOffset: offset)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (url.path, []) }
        let text = String(decoding: data, as: UTF8.self)

        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Seeking to a byte offset usually lands mid-line; that partial first
        // line is not a line anyone wants to read.
        if offset > 0, !all.isEmpty { all.removeFirst() }
        if all.last?.isEmpty == true { all.removeLast() }

        return (url.path, Array(all.suffix(max(1, lines))))
    }
}
