import Foundation
import Security

/// A single-use runner registration. The blob never touches disk and never
/// appears in an argument list.
public struct JitConfig: Sendable {
    public let runnerName: String
    public let encodedConfig: String
}

public enum GitHubError: Error, CustomStringConvertible {
    case noPrivateKey
    case badPrivateKey(String)
    case api(status: Int, body: String, operation: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .noPrivateKey:
            "No GitHub App private key is stored. Add it on the Credentials page; it is kept in the "
            + "Keychain, never in forge.json."
        case .badPrivateKey(let detail):
            "The stored GitHub App key could not be used: \(detail)"
        case .api(let status, let body, let operation):
            // GitHub's own message, verbatim. Guessing what a 401 means wastes
            // far more time than reading what GitHub actually said.
            "Could not \(operation) (\(status)). GitHub said:\n\(body)"
        case .malformedResponse(let detail):
            "Unexpected response from GitHub: \(detail)"
        }
    }
}

/// Turns a GitHub App private key into short-lived credentials, and mints the
/// single-use JIT config every runner registers with.
///
/// There is no long-lived registration token anywhere in this product, and no
/// `config.sh` step: a JIT config IS the configuration, valid for one job.
public actor GitHubAppService {
    private let logBus: LogBus
    private let secretStore: SecretStore
    private let session: URLSession

    private var cachedToken: String?
    private var cachedTokenExpiry: Date = .distantPast

    public var apiBaseUrl = "https://api.github.com"

    public init(logBus: LogBus, secretStore: SecretStore, session: URLSession = .shared) {
        self.logBus = logBus
        self.secretStore = secretStore
        self.session = session
    }

    /// Signs an app JWT. `iat` is backdated 60 seconds to absorb clock skew,
    /// which GitHub otherwise rejects as a token issued in the future, and `exp`
    /// is 9 minutes, inside GitHub's 10-minute maximum.
    public nonisolated func createAppJwt(appId: String, privateKeyPem: String) throws -> String {
        guard privateKeyPem.contains("PRIVATE KEY") else {
            throw GitHubError.badPrivateKey("it is not a PEM private key")
        }

        let now = Int(Date().timeIntervalSince1970)
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let payload = #"{"iat":\#(now - 60),"exp":\#(now + 540),"iss":"\#(appId)"}"#

        let signingInput = Self.base64Url(Data(header.utf8)) + "." + Self.base64Url(Data(payload.utf8))

        // RSA signing goes through the Security framework. CryptoKit exposes no
        // RSA on Apple platforms, so SecKey is the supported path — and it is
        // the same primitive the OS uses, rather than a bundled reimplementation.
        let key = try Self.secKey(fromPem: privateKeyPem)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error) as Data? else {
            let detail = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error"
            throw GitHubError.badPrivateKey("signing failed: \(detail)")
        }

        return signingInput + "." + Self.base64Url(signature)
    }

    /// Parses a PEM private key into a SecKey.
    ///
    /// GitHub App keys are PKCS#1 ("BEGIN RSA PRIVATE KEY"). A PKCS#8 key
    /// ("BEGIN PRIVATE KEY") wraps the same PKCS#1 structure behind a fixed
    /// 26-byte header for RSA, which is stripped here so both forms work —
    /// people do convert their keys, and failing on one form is a confusing bug.
    nonisolated static func secKey(fromPem pem: String) throws -> SecKey {
        let base64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard var der = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            throw GitHubError.badPrivateKey("the PEM body is not valid base64")
        }

        if pem.contains("BEGIN PRIVATE KEY") {
            // PKCS#8 RSA header: SEQUENCE, version, rsaEncryption OID, NULL,
            // OCTET STRING. 26 bytes before the embedded PKCS#1 key.
            let pkcs8HeaderLength = 26
            guard der.count > pkcs8HeaderLength else {
                throw GitHubError.badPrivateKey("the PKCS#8 key is too short to contain a key")
            }
            der = der.dropFirst(pkcs8HeaderLength)
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let detail = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown error"
            throw GitHubError.badPrivateKey("could not parse the key: \(detail)")
        }

        return key
    }

    nonisolated static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// An installation access token, cached for 50 minutes. GitHub issues them
    /// for 60; the margin means a token never expires mid-use.
    public func installationToken(config: ForgeConfig) async throws -> String {
        if let cachedToken, Date() < cachedTokenExpiry { return cachedToken }

        guard let privateKey = await secretStore.read("githubAppPrivateKey") else {
            throw GitHubError.noPrivateKey
        }

        let jwt = try createAppJwt(appId: config.github.appId, privateKeyPem: privateKey)

        let (data, response) = try await send(
            path: "/app/installations/\(config.github.installationId)/access_tokens",
            method: "POST", token: jwt, body: nil)

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.api(status: response.statusCode,
                                  body: String(decoding: data, as: UTF8.self),
                                  operation: "mint an installation token")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw GitHubError.malformedResponse("the token response contained no token")
        }

        await logBus.registerSecret(token)
        cachedToken = token
        cachedTokenExpiry = Date().addingTimeInterval(50 * 60)
        await logBus.info("github", "minted an installation token (cached 50 minutes)")

        return token
    }

    /// Mints a JIT config for one runner. The returned blob is the runner's whole
    /// configuration and is valid for exactly one job.
    public func generateJitConfig(
        config: ForgeConfig, repo: String, runnerClass: RunnerClass
    ) async throws -> JitConfig {
        let token = try await installationToken(config: config)

        let shortHost = String(
            ProcessInfo.processInfo.hostName
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                .prefix(16)
        ).lowercased()

        let suffix = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let runnerName = "forge-\(runnerClass.classId)-\(shortHost)-\(suffix)"

        let configured = config.runners.first { $0.classId == runnerClass.classId }
        let labels = (configured?.labels.isEmpty == false) ? configured!.labels : runnerClass.labels

        let payload: [String: Any] = [
            "name": runnerName,
            "runner_group_id": 1,
            "labels": labels,
        ]

        let (data, response) = try await send(
            path: "/repos/\(config.github.owner)/\(repo)/actions/runners/generate-jitconfig",
            method: "POST", token: token,
            body: try JSONSerialization.data(withJSONObject: payload))

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.api(status: response.statusCode,
                                  body: String(decoding: data, as: UTF8.self),
                                  operation: "generate a JIT config")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blob = json["encoded_jit_config"] as? String else {
            throw GitHubError.malformedResponse("the response contained no encoded_jit_config")
        }

        await logBus.registerSecret(blob)
        // The LENGTH only. The value must never reach a log.
        await logBus.info("github", "minted a JIT config for \(runnerName) (\(blob.count) bytes)")

        return JitConfig(runnerName: runnerName, encodedConfig: blob)
    }

    /// Verifies the App key by asking GitHub who we are.
    public func testAppCredentials(config: ForgeConfig) async throws -> String {
        guard let privateKey = await secretStore.read("githubAppPrivateKey") else {
            throw GitHubError.noPrivateKey
        }

        let jwt = try createAppJwt(appId: config.github.appId, privateKeyPem: privateKey)
        let (data, response) = try await send(path: "/app", method: "GET", token: jwt, body: nil)

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.api(status: response.statusCode,
                                  body: String(decoding: data, as: UTF8.self),
                                  operation: "GET /app")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["slug"] as? String) ?? "(the app has no slug)"
    }

    /// Checks repository access, reporting 200/404/403 distinctly.
    public func verifyRepositoryAccess(config: ForgeConfig, repo: String) async throws -> String {
        let token = try await installationToken(config: config)
        let (_, response) = try await send(
            path: "/repos/\(config.github.owner)/\(repo)", method: "GET", token: token, body: nil)

        switch response.statusCode {
        case 200: return "OK — the installation can see this repository."
        case 404: return "404 — either the repository does not exist, or the App is not installed on it. "
                       + "GitHub returns 404 rather than 403 for repositories you cannot see at all."
        case 403: return "403 — the App is installed but lacks permission. It needs Administration: "
                       + "read & write to register self-hosted runners."
        default: return "\(response.statusCode)"
        }
    }

    /// Retries 5xx and secondary-rate-limit 403s with exponential backoff.
    func send(path: String, method: String, token: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let maxAttempts = 4

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: URL(string: apiBaseUrl + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("RunnerForge/1.0", forHTTPHeaderField: "User-Agent")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubError.malformedResponse("not an HTTP response")
            }

            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let retryable = http.statusCode >= 500 || (http.statusCode == 403 && retryAfter != nil)

            if !retryable || attempt == maxAttempts { return (data, http) }

            let delay = retryAfter ?? pow(2.0, Double(attempt))
            await logBus.warning("github",
                "\(http.statusCode) from \(path); retrying in \(Int(delay))s (attempt \(attempt)/\(maxAttempts))")
            try? await Task.sleep(for: .seconds(delay))
        }

        throw GitHubError.malformedResponse("retry loop exhausted")
    }
}
