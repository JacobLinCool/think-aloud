import HuggingFace
import XCTest
@testable import ThinkAloud

final class ModelDownloadFailureTests: XCTestCase {
    private func response(_ status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit")),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ))
    }

    func testHTTPStatusIsReadFromHubResponseErrors() throws {
        let rejected = HTTPClientError.responseError(response: try response(401), detail: "Invalid response")
        XCTAssertEqual(ModelDownloadFailure.httpStatus(in: rejected), 401)

        let undecodable = HTTPClientError.decodingError(response: try response(500), detail: "bad json")
        XCTAssertEqual(ModelDownloadFailure.httpStatus(in: undecodable), 500)
    }

    func testNonHTTPFailuresHaveNoStatus() {
        XCTAssertNil(ModelDownloadFailure.httpStatus(in: HTTPClientError.requestError("malformed")))
        XCTAssertNil(ModelDownloadFailure.httpStatus(in: URLError(.notConnectedToInternet)))
    }

    /// An auth refusal and a server error must not read the same — that sameness is what sent a
    /// stale-token failure off to debug the network.
    func testAuthRefusalReadsDifferentlyFromServerError() {
        let refused = ASRError.modelDownloadRejected(status: 403).errorDescription
        let unavailable = ASRError.modelDownloadRejected(status: 503).errorDescription

        XCTAssertEqual(refused?.contains("403"), true)
        XCTAssertEqual(unavailable?.contains("503"), true)
        XCTAssertNotEqual(refused, unavailable)
    }
}
