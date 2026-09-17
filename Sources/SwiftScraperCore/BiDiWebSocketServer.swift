import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class BiDiWebSocketServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let dispatcher: BiDiDispatcher
    private let hub = BiDiWebSocketHub()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    init(host: String, port: Int, dispatcher: BiDiDispatcher) {
        self.host = host
        self.port = port
        self.dispatcher = dispatcher
    }

    func start() throws {
        let hub = self.hub
        let dispatcher = self.dispatcher
        let bindHost = self.host

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, requestHead in
                        let allowed = BiDiAccessGuard.allowsUpgrade(
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
                        channel.pipeline.addHandler(
                            BiDiWebSocketFrameHandler(dispatcher: dispatcher, hub: hub)
                        )
                    }
                )

                let upgradeConfiguration: NIOHTTPServerUpgradeSendableConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgradeConfiguration
                )
            }

        channel = try bootstrap.bind(host: host, port: port).wait()
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

private final class BiDiWebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let dispatcher: BiDiDispatcher
    private let hub: BiDiWebSocketHub
    private let clientSession = BiDiClientSession()

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
        hub.remove(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
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
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)

        Task { @MainActor [dispatcher] in
            let responseText: String

            do {
                let request = try JSONDecoder().decode(BiDiRequest.self, from: Data(text.utf8))
                let response = await dispatcher.handle(request, clientSession: clientSession)
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
