import Foundation

public protocol CollectorHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCollectorHTTPClient: CollectorHTTPClient {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        return (data, response)
    }
}

enum HTTPValidation {
    static func checked(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectorError.invalidCredential }
        guard (200..<300).contains(response.statusCode) else { throw ConnectorError.provider("Provider request failed (HTTP \(response.statusCode)).") }
    }
}
