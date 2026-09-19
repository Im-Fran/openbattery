import NIOCore
import NIOPosix
import XCTest

/// The two things about the transport that can fail silently: a device that
/// accepts a connection and never answers, and the frame header that everything
/// else rides on.
final class PlistChannelTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!
    private var server: Channel!
    private var path: String!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        // Short and in /tmp: a unix socket path is capped at about 104 bytes and
        // the sandboxed temporary directory is longer than that.
        path = "/tmp/openbattery-test-\(UInt32.random(in: 0..<1_000_000)).sock"
    }

    override func tearDown() {
        try? server?.close().wait()
        try? FileManager.default.removeItem(atPath: path)
        try? group.syncShutdownGracefully()
        super.tearDown()
    }

    private func startServer(answering: Bool) throws {
        server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                answering ? channel.pipeline.addHandler(StubUSBMux())
                          : channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(unixDomainSocketPath: path)
            .wait()
    }

    func testASilentDeviceFailsTheRequestInsteadOfHangingForEver() async throws {
        try startServer(answering: false)
        let connection = try await PlistConnection.connectToUSBMux(group: group, path: path,
                                                                  deadline: .milliseconds(200))
        do {
            _ = try await connection.send(["MessageType": "ListDevices"])
            XCTFail("a device that never answers must not leave the read pending")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .timedOut)
        }

        // The close that follows the timeout must not rewrite the reason: the
        // recovery for a silent device is to unlock it, not to reconnect it.
        do {
            _ = try await connection.send(["MessageType": "ListDevices"])
            XCTFail("a connection that timed out must stay failed")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testAMissingSocketIsReportedAsAnUnsupportedTransport() async {
        // What the sandboxed App Store build sees: nothing listening at all.
        do {
            _ = try await PlistConnection.connectToUSBMux(group: group,
                                                          path: "/tmp/openbattery-absent.sock")
            XCTFail("connecting to nothing must fail")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .transportUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testARequestRoundTripsThroughTheUSBMuxHeader() async throws {
        try startServer(answering: true)
        let connection = try await PlistConnection.connectToUSBMux(group: group, path: path,
                                                                  deadline: .seconds(5))
        let reply = try await connection.send(["MessageType": "ListDevices"])
        // The stub only answers requests whose 16-byte header it could parse and
        // whose payload was a plist, so a reply at all proves the framing.
        XCTAssertEqual(reply["MessageType"] as? String, "Result")
        XCTAssertEqual(reply["Number"] as? Int, 0)
        XCTAssertEqual(reply["EchoedMessageType"] as? String, "ListDevices")
    }
}

/// Stands in for usbmuxd: parses one frame the way usbmuxd does and answers it.
private final class StubUSBMux: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard let total: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .little),
              total >= 16, buffer.readableBytes >= Int(total) else { return }
        guard let version: UInt32 = buffer.getInteger(at: buffer.readerIndex + 4,
                                                      endianness: .little),
              let message: UInt32 = buffer.getInteger(at: buffer.readerIndex + 8,
                                                      endianness: .little),
              let tag: UInt32 = buffer.getInteger(at: buffer.readerIndex + 12,
                                                  endianness: .little),
              version == 1, message == 8 else { return }

        buffer.moveReaderIndex(forwardBy: 16)
        guard let body = buffer.readData(length: Int(total) - 16),
              let request = try? PropertyListSerialization.propertyList(from: body, options: [],
                                                                       format: nil)
                  as? [String: Any] else { return }
        buffer.discardReadBytes()

        let reply: [String: Any] = [
            "MessageType": "Result",
            "Number": 0,
            "EchoedMessageType": request["MessageType"] as? String ?? "",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: reply,
                                                            format: .xml, options: 0) else { return }
        var out = context.channel.allocator.buffer(capacity: data.count + 16)
        out.writeInteger(UInt32(16 + data.count), endianness: .little)
        out.writeInteger(UInt32(1), endianness: .little)
        out.writeInteger(UInt32(8), endianness: .little)
        out.writeInteger(tag, endianness: .little)
        out.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}
