import Foundation

struct LiteLLMSpendData {
    let spend: Double
    let maxBudget: Double?
    let budgetDuration: String?      // e.g. "24h", as returned by the API
    let budgetResetAt: Date?

    var percentage: Int {
        guard let maxBudget, maxBudget > 0 else { return 0 }
        return Int((spend / maxBudget) * 100)
    }
    var remaining: Double? {
        maxBudget.map { max($0 - spend, 0) }
    }
}

struct LiteLLMDailyActivity {
    let date: String
    let spend: Double
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let successfulRequests: Int
    let failedRequests: Int
    let apiRequests: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
}

@MainActor
class LiteLLMManager: ObservableObject {
    @Published var spend: LiteLLMSpendData?
    @Published var dailyActivity: LiteLLMDailyActivity?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    private let config: LiteLLMConfig

    /// `user_id` + session API key obtained from `POST /v2/login`. Cached in
    /// memory ONLY (never written to Keychain/UserDefaults/disk) and reused
    /// across refreshes until a data call rejects it with 401/403 — logging
    /// in on every refresh would create a new LiteLLM session key each time.
    private var cachedSession: LiteLLMSession?

    struct LiteLLMSession {
        let userID: String
        let key: String
    }

    init(config: LiteLLMConfig = .shared) {
        self.config = config
    }

    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    var statusEmoji: String {
        guard let spend else { return "❓" }
        let pct = spend.percentage
        if pct >= 90 { return "🔴" }
        if pct >= 70 { return "🟡" }
        return "🟢"
    }

    func refresh() async {
        await refreshWithRetry(retriesRemaining: 5)
    }

    private func refreshWithRetry(retriesRemaining: Int, backoffSeconds: UInt64 = 2, forceRelogin: Bool = false) async {
        guard let email = config.email, !email.isEmpty, let proxyBaseURL = config.proxyURL else {
            error = LiteLLMError.notConfigured.localizedDescription
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let password = try config.readPasswordFromKeychain()
            let session = try await currentSession(email: email, password: password, baseURL: proxyBaseURL, forceRelogin: forceRelogin)

            async let spendTask = fetchSpend(baseURL: proxyBaseURL, session: session)
            async let activityTask = fetchDailyActivity(baseURL: proxyBaseURL, session: session)
            let (spendResult, activityResult) = try await (spendTask, activityTask)
            spend = spendResult
            dailyActivity = activityResult
            lastUpdated = Date()
        } catch let keychainError as KeychainError {
            if retriesRemaining > 0 && keychainError.isRetryable {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1, backoffSeconds: backoffSeconds)
                return
            }
            error = keychainError.localizedDescription
        } catch let liteLLMError as LiteLLMError {
            // Cached session key rejected: drop it and log in again, once,
            // within this same refresh pass.
            if case .apiError(let code) = liteLLMError, (code == 401 || code == 403), !forceRelogin {
                cachedSession = nil
                await refreshWithRetry(retriesRemaining: retriesRemaining, backoffSeconds: backoffSeconds, forceRelogin: true)
                return
            }
            if retriesRemaining > 0 && liteLLMError.isRetryable {
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1, backoffSeconds: backoffSeconds * 2)
                return
            }
            error = liteLLMError.localizedDescription
        } catch let urlError as URLError {
            if retriesRemaining > 0 && urlError.isRetryable {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1, backoffSeconds: backoffSeconds)
                return
            }
            error = urlError.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Returns the cached session, or logs in once and caches the result.
    /// `forceRelogin` bypasses the cache after a 401/403 invalidated it.
    private func currentSession(email: String, password: String, baseURL: URL, forceRelogin: Bool) async throws -> LiteLLMSession {
        if !forceRelogin, let cachedSession { return cachedSession }
        let session = try await login(email: email, password: password, baseURL: baseURL)
        cachedSession = session
        return session
    }

    private func login(email: String, password: String, baseURL: URL) async throws -> LiteLLMSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": email, "password": password])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiteLLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw httpResponse.statusCode == 401
                ? LiteLLMError.invalidCredentials
                : LiteLLMError.apiError(statusCode: httpResponse.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String else {
            throw LiteLLMError.invalidResponse
        }
        return try Self.decodeSession(fromJWT: token)
    }

    /// Decodes the (unverified) payload segment of the LiteLLM login JWT to
    /// pull `user_id` and `key` — a session-scoped API key. The signature is
    /// never checked: the app trusts the token only because it arrived over
    /// TLS directly from the proxy URL the user configured. The token has no
    /// `exp` claim — validity is determined reactively by a 401/403 from a
    /// data endpoint, not by inspecting this payload.
    private static func decodeSession(fromJWT token: String) throws -> LiteLLMSession {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { throw LiteLLMError.invalidResponse }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = json["user_id"] as? String,
              let key = json["key"] as? String else {
            throw LiteLLMError.invalidResponse
        }
        return LiteLLMSession(userID: userID, key: key)
    }

    private func fetchSpend(baseURL: URL, session: LiteLLMSession) async throws -> LiteLLMSpendData {
        var components = URLComponents(url: baseURL.appendingPathComponent("user/info"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: session.userID)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiteLLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LiteLLMError.apiError(statusCode: httpResponse.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userInfo = root["user_info"] as? [String: Any] else {
            throw LiteLLMError.invalidResponse
        }

        return LiteLLMSpendData(
            spend: userInfo["spend"] as? Double ?? 0,
            maxBudget: userInfo["max_budget"] as? Double,
            budgetDuration: userInfo["budget_duration"] as? String,
            budgetResetAt: parseDate(userInfo["budget_reset_at"] as? String)
        )
    }

    private func fetchDailyActivity(baseURL: URL, session: LiteLLMSession) async throws -> LiteLLMDailyActivity {
        let today = Self.dateOnlyFormatter.string(from: Date())

        var components = URLComponents(url: baseURL.appendingPathComponent("user/daily/activity"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: today),
            URLQueryItem(name: "end_date", value: today),
            URLQueryItem(name: "page_size", value: "1000"),
            URLQueryItem(name: "page", value: "1"),
            // Minutes offset the reference shell implementation uses; LiteLLM
            // doesn't document its exact meaning, but it was validated
            // empirically (2026-09-16) to return the correct day's data.
            URLQueryItem(name: "timezone", value: "240"),
            // Explicit filter: the session key from /v2/login is an
            // "internal_user" UI key, not pre-scoped to this user the way
            // the old personal API key was — must filter server-side.
            URLQueryItem(name: "user_id", value: session.userID)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiteLLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LiteLLMError.apiError(statusCode: httpResponse.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiteLLMError.invalidResponse
        }

        guard let results = json["results"] as? [[String: Any]], let first = results.first,
              let metrics = first["metrics"] as? [String: Any] else {
            return LiteLLMDailyActivity(
                date: today, spend: 0, promptTokens: 0, completionTokens: 0, totalTokens: 0,
                successfulRequests: 0, failedRequests: 0, apiRequests: 0,
                cacheReadInputTokens: 0, cacheCreationInputTokens: 0
            )
        }

        return LiteLLMDailyActivity(
            date: first["date"] as? String ?? today,
            spend: metrics["spend"] as? Double ?? 0,
            promptTokens: metrics["prompt_tokens"] as? Int ?? 0,
            completionTokens: metrics["completion_tokens"] as? Int ?? 0,
            totalTokens: metrics["total_tokens"] as? Int ?? 0,
            successfulRequests: metrics["successful_requests"] as? Int ?? 0,
            failedRequests: metrics["failed_requests"] as? Int ?? 0,
            apiRequests: metrics["api_requests"] as? Int ?? 0,
            cacheReadInputTokens: metrics["cache_read_input_tokens"] as? Int ?? 0,
            cacheCreationInputTokens: metrics["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum LiteLLMError: LocalizedError {
    case notConfigured
    case invalidResponse
    case invalidCredentials
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "LiteLLM is not configured. Enter your email and Proxy URL in Settings."
        case .invalidResponse: return "Invalid response from the LiteLLM proxy"
        case .invalidCredentials: return "Invalid LiteLLM email or password"
        case .apiError(let code):
            if code == 401 || code == 403 { return "LiteLLM session expired or unauthorized" }
            if code == 404 { return "User not found in LiteLLM" }
            if code == 429 { return "Rate limited by the LiteLLM proxy. Retrying…" }
            return "LiteLLM proxy error (code: \(code))"
        }
    }

    var isRetryable: Bool {
        if case .apiError(let code) = self { return [429, 500, 502, 503].contains(code) }
        return false
    }
}
