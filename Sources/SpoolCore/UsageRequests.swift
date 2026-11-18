import Foundation

/// Builds requests only; no networking happens here.
public enum UsageRequests {
    public static func claude(token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        r.httpMethod = "GET"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public static func codex(_ auth: CodexAuth) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        r.httpMethod = "GET"
        r.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(auth.accountId, forHTTPHeaderField: "chatgpt-account-id")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }
}
