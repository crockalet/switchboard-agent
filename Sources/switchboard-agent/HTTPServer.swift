//
//  HTTPServer.swift
//  switchboard-agent
//
//  A loopback-only HTTP/1.1 server. Small on purpose: the whole API is a list
//  and three verbs.
//

import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    /// Names lowercased: HTTP header names are case-insensitive.
    let headers: [String: String]
}

struct HTTPResponse {
    let status: Int
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return HTTPResponse(status: status, body: data)
    }
}

final class HTTPServer {
    private let port: Int
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "switchboard.agent.connections", attributes: .concurrent)

    init(port: Int, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func run() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AgentError.misconfigured("could not open a socket") }

        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        guard let port16 = UInt16(exactly: port), port16 > 0 else {
            close(listener)
            throw AgentError.misconfigured("port \(port) is not a valid port")
        }
        addr.sin_port = in_port_t(port16.bigEndian)
        // Loopback only. This binary starts and stops things; it has no
        // business being reachable from the network.
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(listener)
            throw AgentError.misconfigured("port \(port) is already in use")
        }
        guard listen(listener, 16) == 0 else {
            close(listener)
            throw AgentError.misconfigured("could not listen on port \(port)")
        }

        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            queue.async { [handler] in
                defer { close(client) }
                guard let request = Self.readRequest(client) else { return }
                let response = handler(request)
                Self.write(response, to: client)
            }
        }
    }

    private static func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }

        guard let text = String(bytes: buffer[0..<count], encoding: .utf8) else { return nil }
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        let lines = head.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for field in lines.dropFirst() {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let name = field[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    private static func write(_ response: HTTPResponse, to fd: Int32) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Bad Request"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
