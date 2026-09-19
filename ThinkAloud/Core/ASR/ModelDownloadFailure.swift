import Foundation
import HuggingFace

/// Pulls the HTTP status out of a Hub failure.
///
/// `downloadSnapshot` throws `HTTPClientError.responseError` as soon as the Hub answers non-2xx,
/// i.e. *before* `resolveOrDownloadModel` reaches its post-download validation. So an auth failure
/// leaves the freshly created (empty) model directory behind and surfaces as a plain HTTP error —
/// which we would otherwise report as "check your connection and available storage".
enum ModelDownloadFailure {
    static func httpStatus(in error: Error) -> Int? {
        guard let httpError = error as? HTTPClientError else { return nil }
        switch httpError {
        case .responseError(let response, _), .decodingError(let response, _):
            return response.statusCode
        case .requestError, .unexpectedError:
            return nil
        }
    }
}
