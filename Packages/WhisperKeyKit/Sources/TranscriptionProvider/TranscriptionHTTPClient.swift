import Foundation

enum TranscriptionHTTPClient {
    static func data(
        for request: URLRequest,
        urlSession: URLSession,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await urlSession.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                throw TranscriptionError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw TranscriptionError.unknown
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds.rounded(.up))
    }
}
