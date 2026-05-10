import AppKit
import Foundation

@MainActor
public final class BiDiServerLauncher {
    private let configuration: BiDiServerConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?
    private var host: BiDiWebViewHost?
    private var server: BiDiWebSocketServer?

    public init(configuration: BiDiServerConfiguration) {
        self.configuration = configuration
        self.logger = StderrLogger(verbose: configuration.verbose)
    }

    public func run() -> Int32 {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(configuration.visibility.activationPolicy)
        application.finishLaunching()

        runLoop = CFRunLoopGetCurrent()

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                Task { @MainActor in
                    do {
                        try await self.start()
                    } catch {
                        self.exitCode = 1
                        self.logger.error(error.localizedDescription)
                        self.stopApplicationLoop()
                    }
                }
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            Task { @MainActor in
                do {
                    try await self.start()
                } catch {
                    self.exitCode = 1
                    self.logger.error(error.localizedDescription)
                    self.stopApplicationLoop()
                }
            }
        }

        CFRunLoopRun()
        stop()
        return exitCode
    }

    private func start() async throws {
        logger.info(
            "BiDi server starting: ws://\(configuration.host):\(configuration.port)/session",
            force: true
        )

        let host = BiDiWebViewHost(configuration: configuration, logger: logger)
        let dispatcher = BiDiDispatcher(host: host)
        let server = BiDiWebSocketServer(
            host: configuration.host,
            port: configuration.port,
            dispatcher: dispatcher
        )

        host.eventSink = { [weak server] event in
            server?.broadcast(event)
        }

        try await host.start()
        try server.start()

        self.host = host
        self.server = server

        logger.info(
            "BiDi server listening: ws://\(configuration.host):\(configuration.port)/session",
            force: true
        )
    }

    private func stop() {
        server?.stop()
        host?.stop()
        server = nil
        host = nil
    }

    private func stopApplicationLoop() {
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }
}

private extension VisibilityMode {
    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .windowless:
            return .accessory
        case .hiddenWindow:
            return .accessory
        case .visibleWindow:
            return .regular
        }
    }
}
