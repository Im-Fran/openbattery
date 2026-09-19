import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSL

enum DeviceError: LocalizedError, Equatable {
    /// No usbmuxd to talk to. Expected in the sandboxed App Store build, where
    /// connecting to a unix socket outside the container is denied.
    case transportUnavailable
    /// The payload is for the log, never for the message: a port number and a
    /// result code tell the person reading it nothing they can act on.
    case muxRefused(String)
    case malformedReply
    /// lockdownd hangs up after every error it reports, so a closed connection
    /// is part of the conversation rather than an exception.
    case disconnected
    /// The device accepted the connection and then said nothing. A locked or
    /// sleeping phone does this, and it is the most common failure of all.
    case timedOut
    /// macOS has no pair record for this device: nobody has tapped Trust yet.
    case notPaired
    /// Whatever lockdownd itself complained about; the code stays out of the
    /// message and in the case.
    case lockdown(String)

    /// The sandbox is why the App Store build cannot reach usbmuxd. Anything
    /// else is a Mac that is not offering the socket, and telling that person to
    /// download the app they are already running would be a dead end.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// No string here ends in "try again": the window re-reads every few seconds
    /// on its own, and there is no Try Again button to hunt for. Each one names
    /// the step only a person can take.
    var errorDescription: String? {
        switch self {
        case .transportUnavailable where Self.isSandboxed:
            return "The App Store version can't read connected devices. "
                + "Download OpenBattery from GitHub to read an iPhone or iPad."
        case .transportUnavailable:
            return "This Mac isn't offering access to connected devices. "
                + "Reconnect the device, or restart the Mac if it keeps happening."
        case .muxRefused:
            return "Couldn't connect to the device. Reconnect it."
        case .malformedReply:
            return "Couldn't make sense of this device's battery reading."
        case .disconnected:
            return "The device stopped responding. Reconnect it."
        case .timedOut:
            return "The device didn't answer. Unlock it."
        case .notPaired:
            // The step that produces the Trust prompt comes first: nothing ever
            // asks a device that is only on Wi-Fi.
            return "Connect the device by USB, then unlock it and tap Trust."
        case .lockdown(let code):
            switch code {
            case "PasswordProtected": return "Unlock the device to read its battery."
            case "InvalidHostID", "InvalidPairRecord": return "Trust this Mac on the device again."
            case "PairingProhibitedOverThisConnection": return "Connect the device by USB once."
            default: return "The device refused the request. Reconnect it."
            }
        }
    }
}

/// usbmux frames its plists in a 16-byte little-endian header; lockdown and
/// every service above it use a 4-byte big-endian length. One connection speaks
/// both: it starts as usbmux and becomes a lockdown pipe once `Connect` lands.
enum PlistFraming {
    case usbmux
    case lockdown
}

/// One request/response connection to usbmuxd, or through it to a device.
final class PlistConnection {
    private static let socketPath = "/var/run/usbmuxd"

    let channel: Channel
    private let handler: PlistHandler
    /// How long one request may wait. Carried by the connection so a test can
    /// use a short one.
    private let deadline: TimeAmount
    private var framing: PlistFraming = .usbmux
    private var tag: UInt32 = 0

    private init(channel: Channel, handler: PlistHandler, deadline: TimeAmount) {
        self.channel = channel
        self.handler = handler
        self.deadline = deadline
    }

    /// `path` and `deadline` have defaults because only tests ever pass them.
    static func connectToUSBMux(group: EventLoopGroup, path: String = socketPath,
                                deadline: TimeAmount = .seconds(10)) async throws -> PlistConnection {
        let handler = PlistHandler()
        do {
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in channel.pipeline.addHandler(handler) }
                .connect(unixDomainSocketPath: path)
                .get()
            return PlistConnection(channel: channel, handler: handler, deadline: deadline)
        } catch {
            throw DeviceError.transportUnavailable
        }
    }

    func useLockdownFraming() async throws {
        framing = .lockdown
        let handler = self.handler
        try await channel.eventLoop.submit { handler.framing = .lockdown }.get()
    }

    /// Everything thrown out of here is a `DeviceError`: this is the boundary
    /// the UI reads, and a raw NIO or plist error reaching it would leave the
    /// window with no message to show.
    func send(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: payload,
                                                            format: .xml, options: 0) else {
            throw DeviceError.malformedReply
        }
        var out = channel.allocator.buffer(capacity: body.count + 16)
        switch framing {
        case .usbmux:
            tag += 1
            out.writeInteger(UInt32(16 + body.count), endianness: .little)
            out.writeInteger(UInt32(1), endianness: .little)  // protocol version
            out.writeInteger(UInt32(8), endianness: .little)  // a plist payload
            out.writeInteger(tag, endianness: .little)
        case .lockdown:
            out.writeInteger(UInt32(body.count), endianness: .big)
        }
        out.writeData(body)

        // Registered before the write so a reply can never arrive first.
        let promise = channel.eventLoop.makePromise(of: [String: Any].self)
        let handler = self.handler
        let channel = self.channel
        try await channel.eventLoop.submit { handler.enqueue(promise) }.get()

        // A device that accepts the connection and then says nothing — locked,
        // asleep, or behind a stalled usbmuxd — would otherwise leave this
        // waiting for ever, and the poll behind it stuck with a spinner that
        // never resolves or explains itself.
        // ponytail: one deadline for every request on this connection. Generous
        // for a cable and for a phone on the same network; if a slow request
        // ever needs longer, give that one call its own.
        let deadline = channel.eventLoop.scheduleTask(in: self.deadline) {
            handler.timeOutPending()
            channel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in deadline.cancel() }

        do {
            try await channel.writeAndFlush(out).get()
        } catch {
            // Otherwise the enqueued promise sits there until the deadline fires
            // and latches a timeout on a connection that already failed.
            deadline.cancel()
            channel.close(promise: nil)
            // Writing to a channel that is already closed says nothing about
            // why it closed. The reason it closed for does.
            let latched = try? await channel.eventLoop.submit { handler.failure }.get()
            throw (latched as? DeviceError) ?? DeviceError.disconnected
        }
        // EventLoopFuture.get() ignores task cancellation, so closing the window
        // has to close the channel to unblock it.
        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// Mutual TLS over a connection already carrying plists, which is why NIOSSL
    /// is here: lockdown negotiates the session in the clear and only then
    /// upgrades, and nothing in Network.framework can upgrade a live stream.
    func startTLS(hostCertificatePEM: String, hostKeyPEM: String) async throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = [
            .certificate(try NIOSSLCertificate(bytes: Array(hostCertificatePEM.utf8), format: .pem))
        ]
        configuration.privateKey = .privateKey(
            try NIOSSLPrivateKey(bytes: Array(hostKeyPEM.utf8), format: .pem)
        )
        // The device presents a self-signed certificate: the pair record is what
        // establishes trust here, not a public certificate authority.
        // ponytail: unverified peer, as libimobiledevice does it. Pinning the
        // record's DeviceCertificate does not work through trustRoots — it is a
        // leaf and BoringSSL will not anchor a chain on it — so verifying it
        // needs a custom verification callback comparing the presented
        // certificate. Worth adding if these readings ever drive a decision;
        // today the worst a LAN impostor achieves is a wrong percentage.
        configuration.certificateVerification = .none
        configuration.minimumTLSVersion = .tlsv1
        // lockdownd drops the connection mid-handshake when offered TLS 1.3.
        configuration.maximumTLSVersion = .tlsv12

        let channel = self.channel
        do {
            let context = try NIOSSLContext(configuration: configuration)
            let ssl = try NIOSSLClientHandler(context: context, serverHostname: nil)
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(ssl, position: .first)
            }.get()
        } catch {
            // A refused handshake means the credentials macOS holds are no
            // longer the ones the device trusts, which is a re-trust, not a
            // reconnect.
            throw DeviceError.lockdown("InvalidPairRecord")
        }
    }

    func close() async {
        try? await channel.close()
    }
}

/// Reassembles frames and hands each one to the oldest waiting request.
/// Everything here runs on the channel's event loop.
private final class PlistHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var framing: PlistFraming = .usbmux
    private var buffer = ByteBuffer()
    private var pending: [EventLoopPromise<[String: Any]>] = []
    /// Why this connection died, kept so a later write failure can report the
    /// cause rather than the symptom. Read on the event loop only.
    private(set) var failure: Error?

    func enqueue(_ promise: EventLoopPromise<[String: Any]>) {
        if let failure {
            promise.fail(failure)
        } else {
            pending.append(promise)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let frame = nextFrame() {
            guard !pending.isEmpty else { continue }
            let promise = pending.removeFirst()
            do {
                let plist = try PropertyListSerialization.propertyList(from: frame, options: [],
                                                                      format: nil)
                guard let dictionary = plist as? [String: Any] else {
                    throw DeviceError.malformedReply
                }
                promise.succeed(dictionary)
            } catch {
                promise.fail(error)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(with: DeviceError.disconnected)
    }

    /// Called from the deadline in `PlistConnection.send`. Only promises still
    /// waiting are failed, so a reply that landed first keeps its result.
    func timeOutPending() {
        guard !pending.isEmpty else { return }
        fail(with: DeviceError.timedOut)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: error)
        context.close(promise: nil)
    }

    private func fail(with error: Error) {
        // First wins: a timeout closes the channel, and the close that follows
        // must not rewrite "the device didn't answer, unlock it" into "reconnect
        // it" — the recoveries are different.
        guard failure == nil else { return }
        failure = error
        let waiting = pending
        pending = []
        waiting.forEach { $0.fail(error) }
    }

    private func nextFrame() -> Data? {
        switch framing {
        case .usbmux:
            // The length counts the header itself.
            guard let total: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .little),
                  total >= 16, buffer.readableBytes >= Int(total) else { return nil }
            buffer.moveReaderIndex(forwardBy: 16)
            let body = buffer.readData(length: Int(total) - 16)
            buffer.discardReadBytes()
            return body
        case .lockdown:
            guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .big),
                  buffer.readableBytes >= Int(length) + 4 else { return nil }
            buffer.moveReaderIndex(forwardBy: 4)
            let body = buffer.readData(length: Int(length))
            buffer.discardReadBytes()
            return body
        }
    }
}
