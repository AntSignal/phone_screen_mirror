// Upstream's DisplayGeometryTests (fed3fb9), ported to our WDAClient, whose
// probe asks /status first: a window-size reply sent before a rotation must
// not put the old shape's size back.

import Network
import XCTest
@testable import iMirror

final class DisplayGeometryTests: XCTestCase {
    private func start(_ server: GeometryServer) throws -> WDAClient {
        let ready = expectation(description: "server ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port).rawValue
        return WDAClient(base: URL(string: "http://127.0.0.1:\(port)")!)
    }

    func testARotationDropsTheCachedSizeAndIgnoresAnOlderProbe() throws {
        let server = try GeometryServer(deferWindowRequest: 2)
        defer { server.stop() }
        let settingsApplied = expectation(description: "orientation-aware video configured")
        server.onSettings = { settings in
            if settings["mjpegServerFramerate"] != nil {
                XCTAssertEqual(settings["mjpegFixOrientation"] as? Bool, true)
                settingsApplied.fulfill()
            }
        }
        let client = try start(server)
        let connected = expectation(description: "first size")
        client.connect { result in
            XCTAssertEqual(try? result.get(), CGSize(width: 390, height: 844))
            connected.fulfill()
        }
        wait(for: [connected, settingsApplied], timeout: 2)

        let oldProbeArrived = expectation(description: "old probe's size request pending")
        server.queue.sync { server.onDeferred = { oldProbeArrived.fulfill() } }
        let oldProbeFinished = expectation(description: "old probe returned")
        client.probe { health in
            XCTAssertEqual(health, .alive)
            oldProbeFinished.fulfill()
        }
        wait(for: [oldProbeArrived], timeout: 2)

        let refreshed = expectation(description: "rotated size")
        client.refreshDisplayGeometry { result in
            XCTAssertEqual(try? result.get(), CGSize(width: 844, height: 390))
            refreshed.fulfill()
        }
        XCTAssertNil(client.deviceSize, "the old shape's size must go at once")
        wait(for: [refreshed], timeout: 2)
        server.queue.sync { server.deferredResponse?() }
        wait(for: [oldProbeFinished], timeout: 2)
        XCTAssertEqual(client.deviceSize, CGSize(width: 844, height: 390),
                       "a reply sent before the rotation put the old size back")
    }

    /// Joining an agent's session while the phone rotates: the join's stale
    /// size reply must not make the app drop the session and create its own,
    /// which would end the agent's.
    func testARotationDuringAJoinKeepsTheJoinedSession() throws {
        let server = try GeometryServer(deferWindowRequest: 1)
        defer { server.stop() }
        let client = try start(server)
        let joinArrived = expectation(description: "join's size request pending")
        server.queue.sync { server.onDeferred = { joinArrived.fulfill() } }
        let probed = expectation(description: "probe returned")
        client.probe { health in
            XCTAssertEqual(health, .alive)
            probed.fulfill()
        }
        wait(for: [joinArrived], timeout: 2)
        XCTAssertEqual(client.sessionId, "test")
        let refreshed = expectation(description: "rotated size")
        client.refreshDisplayGeometry { _ in refreshed.fulfill() }
        wait(for: [refreshed], timeout: 2)
        server.queue.sync { server.deferredResponse?() }
        wait(for: [probed], timeout: 2)
        XCTAssertEqual(client.sessionId, "test")
        XCTAssertEqual(server.queue.sync { server.sessionsCreated }, 0)
    }
}

/// A tiny WDA: /status names session "test"; window-size request number
/// `deferWindowRequest` is held until the test releases it, and the ones
/// after it answer with the rotated size.
private final class GeometryServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.display-geometry")
    let listener: NWListener
    var onDeferred: (() -> Void)?
    var deferredResponse: (() -> Void)?
    var onSettings: (([String: Any]) -> Void)?
    private(set) var sessionsCreated = 0
    private let deferWindowRequest: Int
    private var windows = 0
    private var sockets: [NWConnection] = []

    init(deferWindowRequest: Int) throws {
        self.deferWindowRequest = deferWindowRequest
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] socket in
            guard let self else { socket.cancel(); return }
            self.sockets.append(socket)
            socket.start(queue: self.queue)
            self.receive(socket, accumulated: Data())
        }
    }

    private func receive(_ socket: NWConnection, accumulated: Data) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let bytes = accumulated + (data ?? Data())
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !done, error == nil { self.receive(socket, accumulated: bytes) }
                return
            }
            let parts = request.components(separatedBy: "\r\n\r\n")
            let lengthLine = parts[0].components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
            let expected = lengthLine.flatMap {
                Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
            } ?? 0
            if parts.dropFirst().joined(separator: "\r\n\r\n").utf8.count < expected {
                if !done, error == nil { self.receive(socket, accumulated: bytes) }
                return
            }
            self.answer(request, body: parts.last, on: socket)
        }
    }

    private func answer(_ request: String, body: String?, on socket: NWConnection) {
        if request.hasPrefix("GET /session/test/window/size ") {
            windows += 1
            let portrait = "{\"value\":{\"width\":390,\"height\":844}}"
            let landscape = "{\"value\":{\"width\":844,\"height\":390}}"
            if windows == deferWindowRequest {
                deferredResponse = { self.reply(socket, json: portrait) }
                onDeferred?()
            } else {
                reply(socket, json: windows < deferWindowRequest ? portrait : landscape)
            }
        } else if request.hasPrefix("GET /status ") {
            reply(socket, json: "{\"value\":{\"ready\":true},\"sessionId\":\"test\"}")
        } else if request.hasPrefix("POST /session ") {
            sessionsCreated += 1
            reply(socket, json: "{\"value\":{\"sessionId\":\"test\"}}")
        } else {
            if request.hasPrefix("POST /session/test/appium/settings "),
               let data = body?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let settings = json["settings"] as? [String: Any] {
                onSettings?(settings)
            }
            reply(socket, json: "{\"value\":{}}")
        }
    }

    private func reply(_ socket: NWConnection, json: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        socket.send(content: Data(response.utf8), completion: .contentProcessed { _ in socket.cancel() })
    }

    func stop() {
        queue.sync {
            deferredResponse = nil
            sockets.forEach { $0.cancel() }
            listener.cancel()
        }
    }
}
