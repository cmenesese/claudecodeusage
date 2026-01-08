import Foundation
import Security

struct UsageData {
    let sessionUtilization: Double
    let sessionResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let sonnetUtilization: Double?
    let sonnetResetsAt: Date?
    
    var sessionPercentage: Int { Int(sessionUtilization) }
    var weeklyPercentage: Int { Int(weeklyUtilization) }
    var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }
}

@MainActor
class UsageManager: ObservableObject {
    @Published var usage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var updateAvailable: String?

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    static let githubRepo = "richhickson/claudecodeusage"

    var statusEmoji: String {
        guard let usage = usage else { return "❓" }
        let maxUtil = max(usage.sessionUtilization, usage.weeklyUtilization)
        if maxUtil >= 90 { return "🔴" }
        if maxUtil >= 70 { return "🟡" }
        return "🟢"
    }
    
    func refresh() async {
        isLoading = true
        error = nil
        
        defer { isLoading = false }
        
        do {
            guard let token = try getAccessToken() else {
                error = "Not logged in to Claude Code"
                return
            }
            
            let data = try await fetchUsage(token: token)
            usage = data
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func getAccessToken() throws -> String? {
        // Query Keychain for Claude Code credentials
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Parse JSON to extract accessToken
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        
        return accessToken
    }
    
    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsage/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw UsageError.apiError(statusCode: httpResponse.statusCode)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        let fiveHour = json?["five_hour"] as? [String: Any]
        let sevenDay = json?["seven_day"] as? [String: Any]
        let sonnetOnly = json?["sonnet_only"] as? [String: Any]
        
        return UsageData(
            sessionUtilization: fiveHour?["utilization"] as? Double ?? 0,
            sessionResetsAt: parseDate(fiveHour?["resets_at"] as? String),
            weeklyUtilization: sevenDay?["utilization"] as? Double ?? 0,
            weeklyResetsAt: parseDate(sevenDay?["resets_at"] as? String),
            sonnetUtilization: sonnetOnly?["utilization"] as? Double,
            sonnetResetsAt: parseDate(sonnetOnly?["resets_at"] as? String)
        )
    }
    
    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                if isNewerVersion(latestVersion, than: Self.currentVersion) {
                    updateAvailable = latestVersion
                }
            }
        } catch {
            // Silently fail - update check is not critical
        }
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}

enum UsageError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code):
            return "API error: \(code)"
        }
    }
}
