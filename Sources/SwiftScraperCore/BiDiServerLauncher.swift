import AppKit
import Darwin
import Foundation

@MainActor
public final class BiDiServerLauncher {
    private let configuration: BiDiServerConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?
    private var host: BiDiWebViewHost?
    private var server: BiDiWebSocketServer?
    private var authentication: BiDiAuthentication?
    private var startupTask: Task<Void, Never>?
    private var shuttingDown = false
    private var signalSources: [DispatchSourceSignal] = []
    private var previousSignalHandlers: [(Int32, sig_t?)] = []

    public init(configuration: BiDiServerConfiguration) {
        self.configuration = configuration
        self.logger = StderrLogger(verbose: configuration.verbose)
    }

    public func run() -> Int32 {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(configuration.visibility.activationPolicy)
        application.finishLaunching()

        runLoop = CFRunLoopGetCurrent()
        installSignalHandlers()
        defer { removeSignalHandlers() }

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                self.beginStartup()
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            beginStartup()
        }

        CFRunLoopRun()
        stop()
        return exitCode
    }

    private func beginStartup() {
        guard !shuttingDown else { return }
        startupTask = Task { @MainActor in
            do {
                try await self.start()
            } catch {
                guard !self.shuttingDown else { return }
                self.exitCode = 1
                self.logger.error(error.localizedDescription)
                self.stopApplicationLoop()
            }
        }
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            let previous = Darwin.signal(number, SIG_IGN)
            previousSignalHandlers.append((number, previous))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.shuttingDown else { return }
                    self.shuttingDown = true
                    self.exitCode = 128 + number
                    self.startupTask?.cancel()
                    self.stopApplicationLoop()
                }
            }
            signalSources.append(source)
            source.resume()
        }
    }

    private func removeSignalHandlers() {
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        for (number, previous) in previousSignalHandlers { Darwin.signal(number, previous) }
        previousSignalHandlers.removeAll()
    }

    private func start() async throws {
        try Task.checkCancellation()
        _ = try BiDiAccessGuard.loopbackHost(configuration.host)
        let authentication = try BiDiAuthentication()
        logger.info(
            "BiDi server starting: ws://\(configuration.host):\(configuration.port)/session",
            force: true
        )

        let host = BiDiWebViewHost(configuration: configuration, logger: logger)
        let dispatcher = BiDiDispatcher(host: host)
        let server = BiDiWebSocketServer(
            host: configuration.host,
            port: configuration.port,
            dispatcher: dispatcher,
            token: authentication.token
        )

        host.eventSink = { [weak server] event in
            server?.broadcast(event)
        }

        // Retain resources before awaiting navigation so signals during startup can clean up.
        self.host = host
        self.server = server
        self.authentication = authentication

        logger.info("BiDi token file: \(authentication.fileURL.path)", force: true)

        try await host.start()
        try Task.checkCancellation()
        try server.start()
        try authentication.publish(
            host: BiDiAccessGuard.loopbackHost(configuration.host),
            port: server.listeningPort ?? configuration.port
        )

        logger.info(
            "BiDi server listening: ws://\(configuration.host):\(configuration.port)/session",
            force: true
        )
    }

    private func stop() {
        shuttingDown = true
        startupTask?.cancel()
        startupTask = nil
        authentication?.removeFiles()
        server?.stop()
        host?.stop()
        server = nil
        authentication = nil
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
