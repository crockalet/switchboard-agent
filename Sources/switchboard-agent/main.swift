//
//  main.swift
//  switchboard-agent
//
//  The half of Switchboard that runs commands. The droplet talks to it over
//  loopback and never spawns anything itself.
//

import Foundation

func usage() -> Never {
    print("""
    switchboard-agent — the control half of Switchboard

    Usage:
      switchboard-agent serve            Serve the control API on 127.0.0.1
      switchboard-agent list             Print the configured services and their status
      switchboard-agent start <id>       Start one service
      switchboard-agent stop <id>        Stop one service
      switchboard-agent restart <id>     Restart one service
      switchboard-agent logs <id> [n]    Print the last n lines of a service's log
      switchboard-agent config path      Print the config file path
      switchboard-agent config example   Print a starter config

    Config: ~/.config/switchboard/services.json (override with SWITCHBOARD_CONFIG)
    """)
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

let config: AgentConfig
do {
    config = try AgentConfig.load()
} catch {
    FileHandle.standardError.write(Data("Could not read \(AgentConfig.configURL.path): \(error)\n".utf8))
    exit(1)
}

let controller = ServiceController(config: config)

func service(named id: String) throws -> ServiceConfig {
    guard let match = config.services.first(where: { $0.id == id }) else {
        throw AgentError.unknownService(id)
    }
    return match
}

func payload(for state: ServiceState) -> [String: Any] {
    var actions = ["start", "stop", "restart"]
    if state.config.kind == .launchd && state.config.label == nil { actions = [] }
    if state.config.kind == .command && state.config.command == nil { actions = [] }

    var entry: [String: Any] = [
        "id": state.config.id,
        "name": state.config.name,
        "status": state.status.rawValue,
        "actions": actions
    ]
    if let port = state.config.port { entry["port"] = port }
    if let url = state.config.url { entry["url"] = url }
    if let pid = state.pid { entry["pid"] = Int(pid) }
    return entry
}

switch command {
case "serve":
    let server = HTTPServer(port: config.port) { request in
        // Split the query off before the path segments, or the last segment
        // comes through as "logs?lines=50".
        let pieces = request.path.split(separator: "?", maxSplits: 1)
        let segments = (pieces.first ?? "").split(separator: "/").map(String.init)
        let query: [String: String] = pieces.count > 1
            ? pieces[1].split(separator: "&").reduce(into: [:]) { result, pair in
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
            }
            : [:]

        switch (request.method, segments) {
        case ("GET", ["v1", "health"]):
            return .json(["ok": true, "services": config.services.count])

        case ("GET", ["v1", "services"]):
            return .json(["services": controller.states().map(payload(for:))])

        case ("GET", let parts) where parts.count == 4 && parts[0] == "v1" && parts[1] == "services" && parts[3] == "logs":
            do {
                let target = try service(named: parts[2])
                let lines = query["lines"].flatMap(Int.init) ?? 200
                let tail = LogReader.tail(target, lines: min(max(lines, 1), 2000))
                var body: [String: Any] = ["id": target.id, "lines": tail.lines]
                // A service with no resolvable log path is a real answer, not
                // an error: the droplet says so rather than showing an empty pane.
                body["path"] = tail.path.map { $0 as Any } ?? (NSNull() as Any)
                return .json(body)
            } catch {
                return .json(["ok": false, "message": "\(error)"], status: 404)
            }

        case ("POST", let parts) where parts.count == 4 && parts[0] == "v1" && parts[1] == "services":
            let id = parts[2]
            let action = parts[3]
            do {
                let target = try service(named: id)
                switch action {
                case "start": try controller.start(target)
                case "stop": try controller.stop(target)
                case "restart": try controller.restart(target)
                default: return .json(["ok": false, "message": "Unknown action \(action)"], status: 400)
                }
                return .json(["ok": true])
            } catch {
                return .json(["ok": false, "message": "\(error)"], status: 400)
            }

        default:
            return .json(["ok": false, "message": "Not found"], status: 404)
        }
    }

    print("switchboard-agent listening on http://127.0.0.1:\(config.port) — \(config.services.count) service(s)")
    do {
        try server.run()
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

case "list":
    if config.services.isEmpty {
        print("No services configured. Try: switchboard-agent config example")
    }
    for state in controller.states() {
        let mark = state.status == .running ? "●" : "○"
        let port = state.config.port.map { ":\($0)" } ?? ""
        print("\(mark)  \(state.config.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(state.status.rawValue)\(port)")
    }

case "logs":
    guard arguments.count >= 2 else { usage() }
    do {
        let target = try service(named: arguments[1])
        let tail = LogReader.tail(target, lines: arguments.count > 2 ? Int(arguments[2]) ?? 50 : 50)
        if let path = tail.path {
            FileHandle.standardError.write(Data("— \(path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("— no log path for \(target.id)\n".utf8))
        }
        tail.lines.forEach { print($0) }
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

case "start", "stop", "restart":
    guard arguments.count >= 2 else { usage() }
    do {
        let target = try service(named: arguments[1])
        switch command {
        case "start": try controller.start(target)
        case "stop": try controller.stop(target)
        default: try controller.restart(target)
        }
        print("\(command) \(target.id): ok")
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

case "config":
    let sub = arguments.count > 1 ? arguments[1] : "path"
    if sub == "path" {
        print(AgentConfig.configURL.path)
    } else {
        print("""
        {
          "port": 7878,
          "services": [
            {
              "id": "baguette",
              "name": "Baguette",
              "kind": "launchd",
              "label": "com.example.baguette-serve",
              "port": 8421,
              "url": "https://sim.localhost"
            },
            {
              "id": "docs",
              "name": "Docs site",
              "kind": "command",
              "command": "pnpm",
              "args": ["dev"],
              "workingDirectory": "/Users/you/repos/docs",
              "port": 3000
            }
          ]
        }
        """)
    }

default:
    usage()
}
