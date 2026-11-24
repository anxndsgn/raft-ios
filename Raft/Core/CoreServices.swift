import Foundation

/// The core for one environment: session, HTTP client, auth and API. Built again when the
/// environment changes, so nothing (tokens, sockets) crosses deployments.
struct CoreServices: Sendable {
    let environment: RaftEnvironment
    let appInfo: AppInfo
    let session: SessionManager
    let http: RaftHTTPClient
    let auth: AuthService
    let api: RaftAPI

    static func make(
        environment: RaftEnvironment,
        appInfo: AppInfo = .current,
        secure: any SecureStore = KeychainStore(),
        urlSession: URLSession = .shared
    ) -> CoreServices {
        let transport = HTTPTransport(session: urlSession, appInfo: appInfo, environment: { environment })
        let session = SessionManager(
            environment: environment.kind,
            store: SessionVault(secure: secure),
            refresher: HTTPTokenRefresher(transport: transport)
        )
        let http = RaftHTTPClient(transport: transport, credentials: session)
        return CoreServices(
            environment: environment,
            appInfo: appInfo,
            session: session,
            http: http,
            auth: AuthService(client: http, session: session, appInfo: appInfo),
            api: RaftAPI(client: http)
        )
    }

    /// A realtime client for `serverId` on this environment's socket origin.
    func makeRealtime(serverId: String, connector: any WebSocketConnector = URLSessionWebSocketConnector()) -> RealtimeClient {
        RealtimeClient(
            config: .init(socketBaseURL: environment.socketBaseURL, serverId: serverId, appInfo: appInfo),
            tokens: session,
            connector: connector
        )
    }
}
