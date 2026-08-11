import CryptoKit
import Foundation
import OSLog

protocol HFHubClientProtocol: Sendable {
    func whoami() async throws -> HFHubClient.WhoAmI
    func createDatasetRepo(name: String, organization: String?, isPrivate: Bool) async throws
    func updateDatasetRepoVisibility(repoID: String, isPrivate: Bool) async throws
    func datasetRepoInfo(repoID: String) async throws -> HFHubClient.DatasetRepoInfo
    func preupload(repoID: String, files: [HFHubClient.PreuploadFileEntry], revision: String) async throws -> [HFHubClient.PreuploadResponseFile]
    func lfsBatch(repoID: String, objects: [HFHubClient.LFSObject], revision: String) async throws -> [HFHubClient.LFSUploadInstruction]
    func lfsUpload(instruction: HFHubClient.LFSUploadInstruction, fileURL: URL) async throws
    func lfsVerify(instruction: HFHubClient.LFSUploadInstruction) async throws
    func commit(repoID: String, operations: [HFHubClient.CommitOp], revision: String) async throws -> HFHubClient.CommitResult
}

/// Minimal Hugging Face Hub API client. Implements just the endpoints needed to push a
/// ThinkAloud dataset (whoami / create repo / preupload / LFS batch / S3 PUT / commit).
/// All requests authenticate with a personal access token.
actor HFHubClient: HFHubClientProtocol {
    enum HFError: Error, LocalizedError {
        case httpStatus(Int)
        case malformedResponse(String)
        case lfsError(String)
        case fileReadFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(401):
                return String(localized: "Your Hugging Face token is invalid or expired. Update the token and try again.")
            case .httpStatus(403):
                return String(localized: "Your Hugging Face account does not have permission to update this dataset. Check the token permissions and repository access.")
            case .httpStatus(404):
                return String(localized: "Hugging Face could not find this dataset repository. Check the destination and your repository access.")
            case .httpStatus(413):
                return String(localized: "The upload request is too large. Reduce the dataset size and try again.")
            case .httpStatus(429):
                return String(localized: "Hugging Face is receiving too many requests. Wait a moment, then try again.")
            case .httpStatus(let code) where (500...599).contains(code):
                return String(localized: "Hugging Face is temporarily unavailable. Try again later.")
            case .httpStatus:
                return String(localized: "Hugging Face could not complete the request. Check your connection and try again.")
            case .malformedResponse:
                return String(localized: "Hugging Face returned a response ThinkAloud could not understand. Try again; if the problem continues, check for an app update.")
            case .lfsError:
                return String(localized: "Hugging Face could not complete the large-file upload. Check your connection and try again.")
            case .fileReadFailed:
                return String(
                    localized: "ThinkAloud couldn’t read a file selected for upload. Restore the file or exclude audio, then try again."
                )
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ThinkAloud",
        category: "HuggingFace"
    )

    private let token: String
    private let session: URLSession
    private let base: URL

    init(
        token: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://huggingface.co")!
    ) {
        self.token = token
        self.session = session
        self.base = baseURL
    }

    // MARK: - whoami

    struct WhoAmI: Decodable, Sendable {
        let name: String
        let email: String?
        let type: String?
    }

    func whoami() async throws -> WhoAmI {
        let url = base.appendingPathComponent("api/whoami-v2")
        let (data, response) = try await get(url)
        try assertOK(response, data: data)
        return try JSONDecoder().decode(WhoAmI.self, from: data)
    }

    // MARK: - Create repo

    func createDatasetRepo(name: String, organization: String?, isPrivate: Bool) async throws {
        let url = base.appendingPathComponent("api/repos/create")
        var body: [String: Any] = [
            "type": "dataset",
            "name": name,
            "private": isPrivate
        ]
        if let organization { body["organization"] = organization }
        let (data, response) = try await post(url, json: body)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            // Already exists — fine, push will overwrite contents.
            return
        }
        try assertOK(response, data: data)
    }

    struct DatasetRepoInfo: Sendable, Equatable {
        let id: String
        let isPrivate: Bool
    }

    /// Applies visibility to both new and existing repos. `createDatasetRepo` is intentionally not
    /// trusted as proof because a 409 means an existing repo kept its previous visibility.
    func updateDatasetRepoVisibility(repoID: String, isPrivate: Bool) async throws {
        let url = base.appendingPathComponent("api/datasets/\(repoID)/settings")
        let (data, response) = try await put(
            url,
            json: ["visibility": isPrivate ? "private" : "public"]
        )
        try assertOK(response, data: data)
    }

    func datasetRepoInfo(repoID: String) async throws -> DatasetRepoInfo {
        let url = base.appendingPathComponent("api/datasets/\(repoID)")
        let (data, response) = try await get(url)
        try assertOK(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let isPrivate = object["private"] as? Bool else {
            throw HFError.malformedResponse("dataset info is missing id or private")
        }
        guard id.caseInsensitiveCompare(repoID) == .orderedSame else {
            throw HFError.malformedResponse("dataset info returned a different repository id")
        }
        return DatasetRepoInfo(id: id, isPrivate: isPrivate)
    }

    // MARK: - Preupload (dedup + LFS routing)

    struct PreuploadFileEntry: Sendable {
        let path: String
        let sampleBase64: String
        let size: Int
    }

    struct PreuploadResponseFile: Sendable {
        let path: String
        let uploadMode: String     // "regular" or "lfs"
        let shouldIgnore: Bool
    }

    func preupload(repoID: String, files: [PreuploadFileEntry], revision: String = "main") async throws -> [PreuploadResponseFile] {
        let url = base.appendingPathComponent("api/datasets/\(repoID)/preupload/\(revision)")
        let body: [String: Any] = [
            "files": files.map { [
                "path": $0.path,
                "sample": $0.sampleBase64,
                "size": $0.size
            ] }
        ]
        let (data, response) = try await post(url, json: body)
        try assertOK(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["files"] as? [[String: Any]] else {
            throw HFError.malformedResponse("preupload missing files[]")
        }
        return try arr.map { entry in
            guard let path = entry["path"] as? String,
                  let uploadMode = entry["uploadMode"] as? String,
                  ["regular", "lfs"].contains(uploadMode),
                  let shouldIgnore = entry["shouldIgnore"] as? Bool else {
                throw HFError.malformedResponse("preupload contains an invalid file entry")
            }
            return PreuploadResponseFile(
                path: path,
                uploadMode: uploadMode,
                shouldIgnore: shouldIgnore
            )
        }
    }

    // MARK: - LFS batch + S3 PUT + verify

    struct LFSObject: Sendable {
        let oid: String      // sha256 hex
        let size: Int
    }

    struct LFSUploadInstruction: Sendable {
        let oid: String
        let size: Int
        let uploadURL: URL
        let uploadHeaders: [String: String]
        let verifyURL: URL?
        let verifyHeaders: [String: String]
    }

    /// Asks HF where to PUT each LFS object. Objects already on the server come back with no
    /// "upload" action — caller can skip them.
    func lfsBatch(repoID: String, objects: [LFSObject], revision: String = "main") async throws -> [LFSUploadInstruction] {
        // Git LFS protocol path: <type>/<repo>.git/info/lfs/objects/batch
        let url = base.appendingPathComponent("datasets/\(repoID).git/info/lfs/objects/batch")
        let body: [String: Any] = [
            "operation": "upload",
            "transfers": ["basic"],
            "ref": ["name": "refs/heads/\(revision)"],
            "objects": objects.map { ["oid": $0.oid, "size": $0.size] }
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try assertOK(response, data: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["objects"] as? [[String: Any]] else {
            throw HFError.lfsError("batch response missing objects[]")
        }
        var instructions: [LFSUploadInstruction] = []
        for entry in arr {
            let oid = (entry["oid"] as? String) ?? ""
            let size = (entry["size"] as? Int) ?? 0
            if let err = entry["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "unknown"
                throw HFError.lfsError("oid=\(oid): \(msg)")
            }
            guard let actions = entry["actions"] as? [String: Any] else {
                // No actions → object already exists on server, skip.
                continue
            }
            guard let upload = actions["upload"] as? [String: Any],
                  let hrefStr = upload["href"] as? String,
                  let uploadURL = URL(string: hrefStr) else {
                throw HFError.lfsError("missing upload.href")
            }
            let uploadHeaders = (upload["header"] as? [String: String]) ?? [:]

            var verifyURL: URL?
            var verifyHeaders: [String: String] = [:]
            if let verify = actions["verify"] as? [String: Any],
               let vhref = verify["href"] as? String,
               let vurl = URL(string: vhref) {
                verifyURL = vurl
                verifyHeaders = (verify["header"] as? [String: String]) ?? [:]
            }

            instructions.append(LFSUploadInstruction(
                oid: oid,
                size: size,
                uploadURL: uploadURL,
                uploadHeaders: uploadHeaders,
                verifyURL: verifyURL,
                verifyHeaders: verifyHeaders
            ))
        }
        return instructions
    }

    /// PUTs raw bytes to the LFS upload URL (typically a presigned S3 URL).
    func lfsUpload(instruction: LFSUploadInstruction, fileURL: URL) async throws {
        var request = URLRequest(url: instruction.uploadURL)
        request.httpMethod = "PUT"
        for (k, v) in instruction.uploadHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // Use uploadTask(from: file) so large files stream rather than load into RAM.
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try assertOK(response, data: data)
    }

    /// Optional but recommended: tells HF the LFS object has been uploaded so it can register it.
    func lfsVerify(instruction: LFSUploadInstruction) async throws {
        guard let verifyURL = instruction.verifyURL else { return }
        var request = URLRequest(url: verifyURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        for (k, v) in instruction.verifyHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let body: [String: Any] = ["oid": instruction.oid, "size": instruction.size]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try assertOK(response, data: data)
    }

    // MARK: - Commit (NDJSON)

    enum CommitOp: Sendable {
        case header(summary: String, description: String?)
        case fileBase64(path: String, content: Data)
        case lfsFile(path: String, oid: String, size: Int)
        case deletedFile(path: String)
    }

    struct CommitResult: Sendable {
        let commitOid: String?
        let commitURL: String?
        let pullRequestURL: String?
    }

    func commit(repoID: String, operations: [CommitOp], revision: String = "main") async throws -> CommitResult {
        let url = base.appendingPathComponent("api/datasets/\(repoID)/commit/\(revision)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")

        var lines: [String] = []
        for op in operations {
            let dict: [String: Any]
            switch op {
            case .header(let summary, let description):
                var v: [String: Any] = ["summary": summary]
                if let description { v["description"] = description }
                dict = ["key": "header", "value": v]
            case .fileBase64(let path, let content):
                dict = [
                    "key": "file",
                    "value": [
                        "path": path,
                        "content": content.base64EncodedString(),
                        "encoding": "base64"
                    ] as [String: Any]
                ]
            case .lfsFile(let path, let oid, let size):
                dict = [
                    "key": "lfsFile",
                    "value": [
                        "path": path,
                        "oid": oid,
                        "size": size,
                        "algo": "sha256"
                    ] as [String: Any]
                ]
            case .deletedFile(let path):
                dict = ["key": "deletedFile", "value": ["path": path]]
            }
            let data = try JSONSerialization.data(withJSONObject: dict)
            guard let line = String(data: data, encoding: .utf8) else {
                throw HFError.malformedResponse("commit op encoding failed")
            }
            lines.append(line)
        }
        request.httpBody = Data(lines.joined(separator: "\n").utf8)

        let (data, response) = try await session.data(for: request)
        try assertOK(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commitOid = obj["commitOid"] as? String,
              let commitURL = obj["commitUrl"] as? String else {
            throw HFError.malformedResponse("commit response is missing commitOid or commitUrl")
        }
        return CommitResult(
            commitOid: commitOid,
            commitURL: commitURL,
            pullRequestURL: obj["pullRequestUrl"] as? String
        )
    }

    // MARK: - SHA256 streaming

    /// SHA256 hex + size over a file's contents, computed in 1 MB chunks so large WAVs don't load into RAM.
    nonisolated static func sha256Hex(fileURL: URL) throws -> (oid: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        var hasher = SHA256()
        var total = 0
        do {
            while true {
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: 1024 * 1024) ?? Data()
                }
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                total += chunk.count
            }
            try handle.close()
        } catch {
            do {
                try handle.close()
            } catch {
                logger.warning(
                    "Could not close \(fileURL.path, privacy: .private) after a read failure: \(error.localizedDescription, privacy: .private)"
                )
            }
            throw HFError.fileReadFailed(fileURL.path, error.localizedDescription)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }

    /// First-N-bytes sample as base64 (HF uses this for preupload dedup hint).
    nonisolated static func sampleBase64(fileURL: URL, bytes: Int = 512) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        do {
            let data = try handle.read(upToCount: bytes) ?? Data()
            try handle.close()
            return data.base64EncodedString()
        } catch {
            do {
                try handle.close()
            } catch {
                logger.warning(
                    "Could not close \(fileURL.path, privacy: .private) after a sample read failure: \(error.localizedDescription, privacy: .private)"
                )
            }
            throw HFError.fileReadFailed(fileURL.path, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    private func post(_ url: URL, json body: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: request)
    }

    private func put(_ url: URL, json body: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: request)
    }

    private func assertOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HFError.malformedResponse("not an HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.logger.error(
                "Hugging Face HTTP \(http.statusCode, privacy: .public). Response body: \(body, privacy: .private)"
            )
            throw HFError.httpStatus(http.statusCode)
        }
    }
}
