import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class BiDiWebSocketServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let dispatcher: BiDiDispatcher
    private let token: String
    private let hub = BiDiWebSocketHub()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    init(host: String, port: Int, dispatcher: BiDiDispatcher, token: String) {
        self.host = host
        self.port = port
        self.dispatcher = dispatcher
        self.token = token
    }

    var listeningPort: Int? { channel?.localAddress?.port }

    func start() throws {
        let hub = self.hub
        let dispatcher = self.dispatcher
        let bindHost = try BiDiAccessGuard.loopbackHost(self.host)
        let token = self.token
        guard token.utf8.count == 64 else {
            throw ScraperError.invalidArgument("BiDi requires a 256-bit hexadecimal token")
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard hub.admit(channel) else { return channel.close() }
                let gate = BiDiHandshakeDeadline(hub: hub)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 16 * 1024,
                    shouldUpgrade: { channel, requestHead in
                        let allowed = requestHead.headers["Authorization"].count == 1
                            && requestHead.headers["Host"].count == 1
                            && BiDiAuthentication.accepts(requestHead.headers.first(name: "Authorization"), token: token)
                            && BiDiAccessGuard.allowsUpgrade(
                            uri: requestHead.uri,
                            origin: requestHead.headers.first(name: "Origin"),
                            host: requestHead.headers.first(name: "Host"),
                            bindHost: bindHost
                        )

                        guard allowed else {
                            channel.close(promise: nil)
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        gate.authenticated()
                        return channel.pipeline.addHandler(
                            BiDiWebSocketFrameHandler(dispatcher: dispatcher, hub: hub)
                        )
                    }
                )

                let upgradeConfiguration: NIOHTTPServerUpgradeSendableConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )

                return channel.pipeline.addHandler(gate).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfiguration)
                }
            }

        channel = try bootstrap.bind(host: bindHost, port: port).wait()
    }

    func stop() {
        if let channel {
            try? channel.close().wait()
        }

        try? group.syncShutdownGracefully()
    }

    func broadcast(_ event: BiDiEvent) {
        hub.broadcast(event)
    }
}

/// Counts TCP connections (including unauthenticated ones), and bounds handshake time.
private final class BiDiHandshakeDeadline: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let hub: BiDiWebSocketHub
    private var deadline: Scheduled<Void>?

    init(hub: BiDiWebSocketHub) { self.hub = hub }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }

    func authenticated() { deadline?.cancel(); deadline = nil }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated()
        hub.release(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class BiDiWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let dispatcher: BiDiDispatcher
    private let hub: BiDiWebSocketHub
    private let clientSession = BiDiClientSession()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private static let maxRequests = 8
    private static let maxResponseBytes = 8 * 1024 * 1024

    init(dispatcher: BiDiDispatcher, hub: BiDiWebSocketHub) {
        self.dispatcher = dispatcher
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        hub.add(context.channel, session: clientSession)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        hub.remove(context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        hub.remove(context.channel)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            guard frame.fin else { context.close(promise: nil); return }
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes) else {
                sendError("invalid message", message: "Unable to decode text frame", context: context)
                return
            }

            handleText(text, context: context)
        case .ping:
            sendPong(frame, context: context)
        case .connectionClose:
            context.close(promise: nil)
        default:
            sendError("invalid message", message: "Only text frames are supported", context: context)
        }
    }

    private func handleText(_ text: String, context: ChannelHandlerContext) {
        guard tasks.count < Self.maxRequests else { context.close(promise: nil); return }
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let taskID = UUID()

        tasks[taskID] = Task { @MainActor [dispatcher] in
            defer {
                loopBoundContext.eventLoop.execute { self.tasks.removeValue(forKey: taskID) }
            }
            guard !Task.isCancelled else { return }
            let responseText: String

            do {
                let request = try JSONDecoder().decode(BiDiRequest.self, from: Data(text.utf8))
                let response = await dispatcher.handle(request, clientSession: clientSession)
                guard !Task.isCancelled else { return }
                let responseData = try JSONEncoder().encode(response)
                responseText = String(data: responseData, encoding: .utf8) ?? "{}"
            } catch {
                let response = BiDiResponse.failure(
                    id: -1,
                    error: "invalid message",
                    message: error.localizedDescription
                )
                let responseData = try? JSONEncoder().encode(response)
                responseText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }

            loopBoundContext.eventLoop.execute {
                self.sendText(responseText, context: loopBoundContext.value)
            }
        }
    }

    private func sendText(_ text: String, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        guard text.utf8.count <= Self.maxResponseBytes, context.channel.isWritable else {
            context.close(promise: nil)
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.writeAndFlush(
            wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)),
            promise: nil
        )
    }

    private func sendPong(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        let data = frame.unmaskedData
        context.writeAndFlush(
            wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: data)),
            promise: nil
        )
    }

    private func sendError(_ error: String, message: String, context: ChannelHandlerContext) {
        let response = BiDiResponse.failure(id: -1, error: error, message: message)
        let responseData = try? JSONEncoder().encode(response)
        let responseText = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        sendText(responseText, context: context)
    }
}

private final class BiDiWebSocketHub: @unchecked Sendable {
    private struct Connection {
        let channel: Channel
        let session: BiDiClientSession
    }

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var admitted: Set<ObjectIdentifier> = []

    func admit(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard admitted.count < 4 else { return false }
        admitted.insert(ObjectIdentifier(channel))
        return true
    }

    func release(_ channel: Channel) {
        lock.lock()
        admitted.remove(ObjectIdentifier(channel))
        lock.unlock()
    }

    func add(_ channel: Channel, session: BiDiClientSession) {
        lock.lock()
        connections[ObjectIdentifier(channel)] = Connection(channel: channel, session: session)
        lock.unlock()
    }

    func remove(_ channel: Channel) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(channel))
        lock.unlock()
    }

    func broadcast(_ event: BiDiEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        lock.lock()
        let activeChannels = connections.values
            .filter { $0.session.isSubscribed(to: event) }
            .map(\.channel)
        lock.unlock()

        for channel in activeChannels {
            channel.eventLoop.execute {
                guard channel.isActive else {
                    self.remove(channel)
                    return
                }

                guard text.utf8.count <= 8 * 1024 * 1024, channel.isWritable else {
                    channel.close(promise: nil)
                    return
                }

                var buffer = channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                channel.writeAndFlush(
                    WebSocketFrame(fin: true, opcode: .text, data: buffer),
                    promise: nil
                )
            }
        }
    }
}
