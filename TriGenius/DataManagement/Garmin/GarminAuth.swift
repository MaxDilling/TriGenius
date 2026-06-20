import Foundation

// MARK: - Garmin Authentication
//
// Native Swift port of the improved `garmin_health_data` login flow:
//   portal/mobile JSON SSO sign-in (with optional MFA) → CAS service ticket →
//   DI OAuth2 token exchange (diauth.garmin.com). API calls use a DI Bearer
//   token. Tokens are persisted in UserDefaults (per the agreed design — note:
//   not encrypted).
//
// Garmin has no public API; these endpoints are reverse-engineered and mirror
// the `garmin_health_data` reference implementation. Two important details:
//   • Cloudflare's WAF returns 429 if the credential POST follows the sign-in
//     page GET too quickly. A random 30–45s delay between the two mimics
//     natural browser behavior and avoids the block. Login therefore visibly
//     takes ~30–45 seconds.
//   • Swift cannot do TLS-fingerprint impersonation (curl_cffi), so we use the
//     plain-requests strategies: portal web first, mobile SSO as fallback.

// MARK: - Token model

nonisolated struct GarminTokens: Codable {
    // DI OAuth2 bearer used for connectapi calls.
    var accessToken: String
    var refreshToken: String
    // Client ID that minted the token; needed for refresh.
    var clientId: String
    var expiresAt: Date

    // Refresh 15 minutes before the JWT's own expiry (matches the reference).
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-900) }
}

// MARK: - Errors

enum GarminAuthError: LocalizedError {
    case mfaRequired
    case invalidCredentials
    case ticketNotFound
    case tooManyRequests
    case oauthExchangeFailed(String)
    case notAuthenticated
    case network(String)

    var errorDescription: String? {
        switch self {
        case .mfaRequired:
            return "Garmin requires an MFA code. Please enter the code you received by email/app."
        case .invalidCredentials:
            return "Login failed. Please check your email and password."
        case .ticketNotFound:
            return "Garmin login: ticket could not be read (the flow may have changed)."
        case .tooManyRequests:
            return "Garmin temporarily blocked the login (rate limit). Please wait a few minutes and try again."
        case .oauthExchangeFailed(let detail):
            return "Token exchange failed: \(detail)"
        case .notAuthenticated:
            return "Not connected to Garmin. Please sign in from Settings."
        case .network(let detail):
            return "Network error: \(detail)"
        }
    }
}

// MARK: - Garmin Auth

actor GarminAuth {

    static let shared = GarminAuth()

    // SSO host + DI OAuth2 endpoints (mirror garmin_health_data constants).
    private let ssoHost = "https://sso.garmin.com"
    private let diTokenURL = "https://diauth.garmin.com/di-oauth2-service/oauth/token"
    private let diGrantType = "https://connectapi.garmin.com/di-oauth2-service/oauth/grant/service_ticket"
    // Newest accepted DI client ID first; the exchange tries each in order.
    private let diClientIds = [
        "GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2",
        "GARMIN_CONNECT_MOBILE_ANDROID_DI_2024Q4",
        "GARMIN_CONNECT_MOBILE_ANDROID_DI"
    ]

    // Cloudflare WAF anti-rate-limit delay bounds (seconds).
    private let loginDelayMin = 15.0
    private let loginDelayMax = 30.0

    // Native (Android app) UA headers used for DI token exchange + API calls.
    private let nativeUserAgent = "GCM-Android-5.23"
    private let nativeXGarminUserAgent =
        "com.garmin.android.apps.connectmobile/5.23; ; Google/sdk_gphone64_arm64/google; Android/33; Dalvik/2.1.0"

    private let tokenDefaultsKey = "garmin_tokens"

    private let session: URLSession
    private(set) var tokens: GarminTokens?

    // Pending MFA state captured between login() and resumeLogin(code:).
    private var pendingConfig: SSOConfig?
    private var pendingMFAMethod: String?

    private init() {
        // Use the ephemeral config's built-in (in-memory, session-isolated) cookie
        // storage. A freshly init'd `HTTPCookieStorage()` is NOT wired up to capture
        // response cookies, which previously left the SSO session empty and caused
        // the MFA verify to fail with SESSION_EXPIRED.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
        self.tokens = Self.loadTokens(key: tokenDefaultsKey)
    }

    var isAuthenticated: Bool { tokens != nil }

    /// Lightweight console logger for the login flow. Prefixed so it's easy to
    /// filter in the Xcode console / Console.app.
    private nonisolated func log(_ message: String) {
        print("[GarminAuth] \(message)")
    }

    /// Logs the cookie jar so we can confirm the SSO session is carried between
    /// the login POST and the MFA verify call.
    private func logCookies(_ label: String) {
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        let names = cookies.map { $0.name }.sorted().joined(separator: ", ")
        log("Cookies [\(label)]: \(cookies.count) → \(names)")
    }

    // MARK: - SSO flow configuration

    /// Per-strategy SSO endpoint configuration. The portal web flow is preferred
    /// (it's the endpoint connect.garmin.com itself uses); mobile SSO is the
    /// fallback. Both share the 30–45s Cloudflare delay.
    private struct SSOConfig {
        let signinPageURL: String
        let loginURL: String
        let mfaVerifyURL: String
        let clientId: String
        let serviceURL: String
        let userAgent: String
    }

    private var portalConfig: SSOConfig {
        SSOConfig(
            signinPageURL: "\(ssoHost)/portal/sso/en-US/sign-in",
            loginURL: "\(ssoHost)/portal/api/login",
            mfaVerifyURL: "\(ssoHost)/portal/api/mfa/verifyCode",
            clientId: "GarminConnect",
            serviceURL: "https://connect.garmin.com/app",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        )
    }

    private var mobileConfig: SSOConfig {
        SSOConfig(
            signinPageURL: "\(ssoHost)/mobile/sso/en_US/sign-in",
            loginURL: "\(ssoHost)/mobile/api/login",
            mfaVerifyURL: "\(ssoHost)/mobile/api/mfa/verifyCode",
            clientId: "GCM_ANDROID_DARK",
            serviceURL: "https://mobile.integration.garmin.com/gcm/android",
            userAgent: "Mozilla/5.0 (Linux; Android 13; sdk_gphone64_arm64 Build/TE1A.220922.025; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/132.0.0.0 Mobile Safari/537.36"
        )
    }

    // MARK: - Public API

    /// Begin login. Throws `GarminAuthError.mfaRequired` if a code is needed —
    /// the caller then collects the code and calls `resumeLogin(code:)`.
    /// Note: blocks for ~30–45s (Cloudflare anti-rate-limit delay).
    func login(email: String, password: String) async throws {
        pendingConfig = nil
        pendingMFAMethod = nil

        // Try portal web flow first, mobile SSO as a fallback. Invalid
        // credentials abort the whole chain; rate-limit / network errors fall
        // through to the next strategy.
        var lastError: Error = GarminAuthError.network("no strategy attempted")
        for config in [portalConfig, mobileConfig] {
            do {
                let ticket = try await attemptLogin(config: config, email: email, password: password)
                try await exchangeServiceTicket(ticket: ticket, serviceURL: config.serviceURL)
                return
            } catch GarminAuthError.mfaRequired {
                throw GarminAuthError.mfaRequired
            } catch GarminAuthError.invalidCredentials {
                throw GarminAuthError.invalidCredentials
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Complete login after an MFA challenge.
    func resumeLogin(code: String) async throws {
        guard let config = pendingConfig else { throw GarminAuthError.ticketNotFound }
        let method = pendingMFAMethod ?? "email"
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        log("MFA verify: method=\(method), code length=\(trimmedCode.count), flow=\(config.clientId)")
        logCookies("vor MFA-Verify")
        let body: [String: Any] = [
            "mfaMethod": method,
            "mfaVerificationCode": trimmedCode,
            "rememberMyBrowser": true,
            "reconsentList": [],
            "mfaSetup": false
        ]

        // Garmin routes the portal and mobile verify endpoints through different
        // rate-limit buckets, so try both (matching the reference's
        // complete_mfa_portal_web). The flow that issued the challenge goes first.
        var endpoints: [(url: String, params: [(String, String)], ua: String)] = [
            (config.mfaVerifyURL, loginParams(config), config.userAgent)
        ]
        if config.clientId != mobileConfig.clientId {
            endpoints.append((mobileConfig.mfaVerifyURL, loginParams(mobileConfig), mobileConfig.userAgent))
        }

        var rateLimited = false
        var lastDetail = ""
        for endpoint in endpoints {
            let (status, json) = try await postJSON(
                endpoint.url,
                query: endpoint.params,
                body: body,
                referer: config.signinPageURL,
                userAgent: endpoint.ua
            )
            if status == 429 {
                log("MFA verify \(endpoint.url) → 429")
                rateLimited = true
                continue
            }
            let type = (json?["responseStatus"] as? [String: Any])?["type"] as? String
            log("MFA verify \(endpoint.url) → HTTP \(status), responseStatus.type=\(type ?? "nil")")
            if type == "SUCCESSFUL", let ticket = json?["serviceTicketId"] as? String {
                pendingConfig = nil
                pendingMFAMethod = nil
                try await exchangeServiceTicket(ticket: ticket, serviceURL: config.serviceURL)
                return
            }
            // Capture the most specific reason for the final error message.
            if let type { lastDetail = "responseStatus=\(type)" }
            else { lastDetail = "HTTP \(status)" }
        }

        if rateLimited && lastDetail.isEmpty { throw GarminAuthError.tooManyRequests }
        throw GarminAuthError.oauthExchangeFailed("MFA-Verifizierung abgelehnt (\(lastDetail)). Code ggf. abgelaufen – neu anfordern.")
    }

    func logout() {
        tokens = nil
        pendingConfig = nil
        pendingMFAMethod = nil
        UserDefaults.standard.removeObject(forKey: tokenDefaultsKey)
        if let cookies = session.configuration.httpCookieStorage?.cookies {
            for c in cookies { session.configuration.httpCookieStorage?.deleteCookie(c) }
        }
    }

    /// Returns a valid bearer access token, refreshing via the DI refresh grant if needed.
    func validAccessToken() async throws -> String {
        guard let current = tokens else { throw GarminAuthError.notAuthenticated }
        if current.isExpired {
            try await refresh()
        }
        guard let token = tokens else { throw GarminAuthError.notAuthenticated }
        return token.accessToken
    }

    // MARK: - SSO login attempt

    private func loginParams(_ config: SSOConfig) -> [(String, String)] {
        [("clientId", config.clientId), ("locale", "en-US"), ("service", config.serviceURL)]
    }

    /// Runs one SSO strategy: GET sign-in page → 30–45s delay → POST credentials.
    /// Returns the CAS service ticket on success. Throws `.mfaRequired` (after
    /// stashing state for `resumeLogin`), `.invalidCredentials`, `.tooManyRequests`,
    /// or `.network`.
    private func attemptLogin(config: SSOConfig, email: String, password: String) async throws -> String {
        // Step 1: GET the sign-in page to establish session cookies.
        let getStatus = try await getPage(
            config.signinPageURL,
            query: [("clientId", config.clientId), ("service", config.serviceURL)],
            userAgent: config.userAgent
        )
        if getStatus == 429 { throw GarminAuthError.tooManyRequests }
        guard (200..<400).contains(getStatus) else {
            throw GarminAuthError.network("Sign-in-Seite HTTP \(getStatus)")
        }

        // Step 2: Cloudflare anti-rate-limit delay.
        let delay = Double.random(in: loginDelayMin...loginDelayMax)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        // Step 3: POST credentials as JSON.
        let body: [String: Any] = [
            "username": email,
            "password": password,
            "rememberMe": true,
            "captchaToken": ""
        ]
        let (status, json) = try await postJSON(
            config.loginURL,
            query: loginParams(config),
            body: body,
            referer: config.signinPageURL,
            userAgent: config.userAgent
        )
        if status == 429 { throw GarminAuthError.tooManyRequests }
        guard let json else {
            throw GarminAuthError.network("Login response was not JSON (HTTP \(status))")
        }

        let type = (json["responseStatus"] as? [String: Any])?["type"] as? String
        log("Login POST \(config.loginURL) → HTTP \(status), responseStatus.type=\(type ?? "nil")")
        logCookies("nach Login-POST")
        switch type {
        case "SUCCESSFUL":
            guard let ticket = json["serviceTicketId"] as? String else {
                throw GarminAuthError.ticketNotFound
            }
            return ticket
        case "MFA_REQUIRED":
            let mfaInfo = json["customerMfaInfo"] as? [String: Any]
            pendingMFAMethod = (mfaInfo?["mfaLastMethodUsed"] as? String) ?? "email"
            pendingConfig = config
            throw GarminAuthError.mfaRequired
        case "INVALID_USERNAME_PASSWORD":
            throw GarminAuthError.invalidCredentials
        default:
            if let err = json["error"] as? [String: Any], err["status-code"] as? String == "429" {
                throw GarminAuthError.tooManyRequests
            }
            // Non-2xx with a JSON error body is an infrastructure failure, not
            // necessarily bad credentials — let the next strategy try.
            if !(200..<300).contains(status) {
                throw GarminAuthError.network("Login HTTP \(status)")
            }
            throw GarminAuthError.invalidCredentials
        }
    }

    // MARK: - DI OAuth2 token exchange

    /// Exchange a CAS service ticket for a DI access + refresh token pair,
    /// trying each accepted client ID in order.
    private func exchangeServiceTicket(ticket: String, serviceURL: String) async throws {
        var hadAuthFailure = false
        var lastDetail = ""
        for clientId in diClientIds {
            let body: [(String, String)] = [
                ("client_id", clientId),
                ("service_ticket", ticket),
                ("grant_type", diGrantType),
                ("service_url", serviceURL)
            ]
            let (status, data) = try await postForm(
                diTokenURL,
                body: body,
                basicAuthClientId: clientId
            )
            if status == 429 { throw GarminAuthError.tooManyRequests }
            guard (200..<300).contains(status) else {
                let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                log("DI exchange clientId=\(clientId) → HTTP \(status): \(preview)")
                lastDetail = "HTTP \(status)"
                if status < 500 { hadAuthFailure = true }
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let refreshToken = json["refresh_token"] as? String else {
                let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                log("DI exchange clientId=\(clientId) → 200 but unparseable: \(preview)")
                lastDetail = "invalid token response"
                continue
            }
            log("DI exchange clientId=\(clientId) → success")
            let resolvedClientId = clientIdFromJWT(accessToken) ?? clientId
            storeTokens(accessToken: accessToken, refreshToken: refreshToken, clientId: resolvedClientId)
            return
        }
        if hadAuthFailure {
            throw GarminAuthError.oauthExchangeFailed("Ticket abgelehnt (\(lastDetail))")
        }
        throw GarminAuthError.oauthExchangeFailed(lastDetail.isEmpty ? "alle Client-IDs fehlgeschlagen" : lastDetail)
    }

    private func refresh() async throws {
        guard let current = tokens else { throw GarminAuthError.notAuthenticated }
        let body: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", current.clientId),
            ("refresh_token", current.refreshToken)
        ]
        let (status, data) = try await postForm(diTokenURL, body: body, basicAuthClientId: current.clientId)
        if status == 429 { throw GarminAuthError.tooManyRequests }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            // Refresh failed — drop tokens so the user is prompted to log in again.
            logout()
            throw GarminAuthError.oauthExchangeFailed("Token-Refresh fehlgeschlagen (HTTP \(status))")
        }
        // RFC 6749 §6: an omitted refresh_token means the existing one stays valid.
        let newRefresh = (json["refresh_token"] as? String) ?? current.refreshToken
        let resolvedClientId = clientIdFromJWT(accessToken) ?? current.clientId
        storeTokens(accessToken: accessToken, refreshToken: newRefresh, clientId: resolvedClientId)
    }

    private func storeTokens(accessToken: String, refreshToken: String, clientId: String) {
        let expiresAt = jwtExpiry(accessToken) ?? Date().addingTimeInterval(3600)
        let newTokens = GarminTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAt
        )
        tokens = newTokens
        Self.saveTokens(newTokens, key: tokenDefaultsKey)
    }

    // MARK: - HTTP helpers

    /// Browser-like GET used to prime SSO cookies. Returns the HTTP status.
    private func getPage(_ urlString: String, query: [(String, String)], userAgent: String) async throws -> Int {
        let full = urlString + (query.isEmpty ? "" : "?" + encodeQuery(query))
        guard let u = URL(string: full) else { throw GarminAuthError.network("bad url") }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        log("GET \(urlString) → HTTP \(status)")
        return status
    }

    /// JSON POST to an SSO API. Returns (status, decoded JSON object or nil).
    private func postJSON(
        _ urlString: String,
        query: [(String, String)],
        body: [String: Any],
        referer: String,
        userAgent: String
    ) async throws -> (Int, [String: Any]?) {
        let full = urlString + (query.isEmpty ? "" : "?" + encodeQuery(query))
        guard let u = URL(string: full) else { throw GarminAuthError.network("bad url") }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(ssoHost, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if json == nil {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            log("POST \(urlString) → HTTP \(status), non-JSON body: \(preview)")
        }
        return (status, json)
    }

    /// Form-encoded POST to the DI token endpoint. Returns (status, body data).
    private func postForm(
        _ urlString: String,
        body: [(String, String)],
        basicAuthClientId: String
    ) async throws -> (Int, Data) {
        guard let u = URL(string: urlString) else { throw GarminAuthError.network("bad url") }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        for (k, v) in nativeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(basicAuth(clientId: basicAuthClientId), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = encodeQuery(body).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    /// Native Android-app headers used for DI token exchange + authenticated API calls.
    nonisolated var nativeHeaders: [String: String] {
        [
            "User-Agent": nativeUserAgent,
            "X-Garmin-User-Agent": nativeXGarminUserAgent,
            "X-Garmin-Paired-App-Version": "10861",
            "X-Garmin-Client-Platform": "Android",
            "X-App-Ver": "10861",
            "X-Lang": "en",
            "X-GCExperience": "GC5",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    private func basicAuth(clientId: String) -> String {
        let raw = "\(clientId):"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    // MARK: - JWT helpers

    private func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4.
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func jwtExpiry(_ token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private func clientIdFromJWT(_ token: String) -> String? {
        jwtPayload(token)?["client_id"] as? String
    }

    // MARK: - Encoding

    private func encodeQuery(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private func percentEncode(_ s: String) -> String {
        // RFC 3986 unreserved set only.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Persistence

    private static func loadTokens(key: String) -> GarminTokens? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GarminTokens.self, from: data)
    }

    private static func saveTokens(_ tokens: GarminTokens, key: String) {
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
