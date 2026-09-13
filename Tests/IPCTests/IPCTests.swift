import XCTest
@testable import WorkshopIPC
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

final class IPCTests: XCTestCase {
    private var dir: String!
    private var server: IPCServer!
    private var service: CollaborationService!

    override func setUp() async throws {
        dir = NSTemporaryDirectory() + "ws-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socketPath = dir + "/s.sock"
        XCTAssertLessThan(socketPath.utf8.count, 100)

        let adapters = EngineerID.allCases.map {
            FakeAdapter(engineer: $0, delayPerDelta: .zero) as EngineerAdapter
        }
        service = try await CollaborationService(databasePath: dir + "/db.sqlite",
                                                 adapters: adapters)
        let svc = service!
        server = try IPCServer(socketPath: socketPath)
        server.handler = { method, params, _ in
            switch method {
            case WorkshopProtocol.health:
                return .object([
                    "status": .string("ok"),
                    "protocol_version": .number(Double(WorkshopProtocol.version)),
                ])
            case WorkshopProtocol.createTask:
                let request = try (params ?? .object([:])).decode(as: CreateTaskRequest.self)
                return try .from(try await svc.createTask(request))
            case WorkshopProtocol.listTasks:
                return try .from(try await svc.listTasks())
            default:
                throw WorkshopError.methodNotFound(method)
            }
        }
        server.replayEvents = { _ in [] }
        try server.start()
        Task {
            for await event in await svc.makeEventStream() {
                self.server.broadcastEvent(event)
            }
        }
        await service.start()
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func client() async throws -> WorkshopClient {
        let c = WorkshopClient(socketPath: dir + "/s.sock")
        try await c.connect()
        return c
    }

    /// Raw socket for malformed input.
    private func rawConnect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array((dir + "/s.sock").utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[pathBytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(ok, 0)
        return fd
    }

    private func rawSend(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                sent += write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
            }
        }
    }

    private func rawReadLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while line.count < IPCServer.maxLineBytes + 4096 {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte[0] == 0x0A { return line }
            line.append(byte[0])
        }
        return line
    }

    func testHealthRoundtrip() async throws {
        let c = try await client()
        let result = try await c.call(WorkshopProtocol.health)
        XCTAssertEqual(result["status"]?.stringValue, "ok")
        XCTAssertEqual(result["protocol_version"]?.intValue, 1)
        await c.disconnect()
    }

    func testInvalidJSONThenValidCall() async throws {
        let fd = try rawConnect()
        defer { Darwin.close(fd) }
        rawSend(fd, Data("this is not json\n".utf8))
        let line = try XCTUnwrap(rawReadLine(fd))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: line)
        XCTAssertEqual(response.error?.code, WorkshopProtocol.ErrorCode.parseError)
        // Connection stays open; a valid call succeeds.
        rawSend(fd, Data((#"{"jsonrpc":"2.0","id":9,"method":"workshop.health"}"# + "\n").utf8))
        let line2 = try XCTUnwrap(rawReadLine(fd))
        let response2 = try JSONDecoder().decode(JSONRPCResponse.self, from: line2)
        XCTAssertEqual(response2.id?.intValue, 9)
        XCTAssertEqual(response2.result?["status"]?.stringValue, "ok")
    }

    func testOverLimitLine() async throws {
        let fd = try rawConnect()
        defer { Darwin.close(fd) }
        let big = Data(repeating: UInt8(ascii: "a"), count: 5 * 1024 * 1024)
        rawSend(fd, big)
        rawSend(fd, Data("\n".utf8))
        let line = try XCTUnwrap(rawReadLine(fd))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: line)
        XCTAssertEqual(response.error?.code, WorkshopProtocol.ErrorCode.parseError)
        // Still usable.
        rawSend(fd, Data((#"{"jsonrpc":"2.0","id":1,"method":"workshop.health"}"# + "\n").utf8))
        let line2 = try XCTUnwrap(rawReadLine(fd))
        let ok = try JSONDecoder().decode(JSONRPCResponse.self, from: line2)
        XCTAssertEqual(ok.result?["status"]?.stringValue, "ok")
    }

    func testUnknownMethod() async throws {
        let c = try await client()
        do {
            _ = try await c.call("workshop.doesNotExist")
            XCTFail("expected error")
        } catch let error as WorkshopClient.RemoteError {
            XCTAssertEqual(error.code, WorkshopProtocol.ErrorCode.methodNotFound)
        }
        await c.disconnect()
    }

    func testSubscribeReceivesEventAfterCreateTask() async throws {
        let c = try await client()
        let stream = await c.makeNotificationStream()
        _ = try await c.call(WorkshopProtocol.subscribe,
                             params: .object(["after_seq": .number(0)]))
        let request = CreateTaskRequest(idempotencyKey: "ipc-1", title: "IPC task",
                                      objective: "hello", phase: .execution,
                                      participants: [.devin])
        _ = try await c.call(WorkshopProtocol.createTask, params: try .from(request))
        var sawEvent = false
        for await notification in stream {
            if notification.method == WorkshopProtocol.eventNotification,
               notification.params?["type"]?.stringValue == "task.created" {
                sawEvent = true
                break
            }
        }
        XCTAssertTrue(sawEvent)
        await c.disconnect()
    }
}
