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

    private func refreshWithRetry(retriesRemaining: Int, backoffSeconds: UInt64 = 2) async {
        guard let userID = config.userID, !userID.isEmpty, let proxyBaseURL = config.proxyURL else {
            error = LiteLLMError.notConfigured.localizedDescription
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let apiKey = try config.readAPIKeyFromKeychain()
            async let spendTask = fetchSpend(baseURL: proxyBaseURL, userID: userID, apiKey: apiKey)
            async let activityTask = fetchDailyActivity(baseURL: proxyBaseURL, apiKey: apiKey)
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

    private func fetchSpend(baseURL: URL, userID: String, apiKey: String) async throws -> LiteLLMSpendData {
        var components = URLComponents(url: baseURL.appendingPathComponent("spend/users"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiteLLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LiteLLMError.apiError(statusCode: httpResponse.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw LiteLLMError.invalidResponse
        }

        // The proxy may return either a single object or an array with one entry
        // per user_id — take the first element when it's an array.
        let entry: [String: Any]
        if let array = root as? [[String: Any]] {
            entry = array.first ?? [:]
        } else if let dict = root as? [String: Any] {
            entry = dict
        } else {
            throw LiteLLMError.invalidResponse
        }

        return LiteLLMSpendData(
            spend: entry["spend"] as? Double ?? 0,
            maxBudget: entry["max_budget"] as? Double,
            budgetDuration: entry["budget_duration"] as? String,
            budgetResetAt: parseDate(entry["budget_reset_at"] as? String)
        )
    }

    private func fetchDailyActivity(baseURL: URL, apiKey: String) async throws -> LiteLLMDailyActivity {
        let today = Self.dateOnlyFormatter.string(from: Date())

        var components = URLComponents(url: baseURL.appendingPathComponent("user/daily/activity"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: today),
            URLQueryItem(name: "end_date", value: today)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

        // Only decode the fields the app needs — the rest of the payload
        // (breakdown by model/key/etc.) is ignored, same approach as fetchUsage().
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
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "LiteLLM is not configured. Enter your Proxy URL and User ID in Settings."
        case .invalidResponse: return "Invalid response from the LiteLLM proxy"
        case .apiError(let code):
            if code == 401 || code == 403 { return "Invalid or unauthorized LiteLLM API key" }
            if code == 404 { return "User ID not found in LiteLLM" }
            if code == 429 { return "Rate limited by the LiteLLM proxy. Retrying…" }
            return "LiteLLM proxy error (code: \(code))"
        }
    }

    var isRetryable: Bool {
        if case .apiError(let code) = self { return [429, 500, 502, 503].contains(code) }
        return false
    }
}
