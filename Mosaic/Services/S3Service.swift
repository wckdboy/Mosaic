import CryptoKit
import Foundation
import Security

// Connection metadata is harmless to persist; credentials live only in Keychain.
struct S3Connection: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var endpoint: String
    var bucket: String
    var region: String
    var pathStyle = true
}

struct S3Credentials: Codable, Sendable {
    var accessKey: String
    var secretKey: String
    var sessionToken: String = ""
}

enum CloudError: LocalizedError {
    case invalidEndpoint, missingCredentials
    case response(Int)
    case invalidListing
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Use an HTTPS endpoint without a path, query, or embedded credentials, and enter a bucket and region."
        case .missingCredentials: "This connection needs its credentials again. Remove it and reconnect."
        case .response(let code):
            "The server returned HTTP \(code). Check the endpoint, region, bucket, and read permissions."
        case .invalidListing: "The server did not return a valid S3 listing."
        case .keychain: "Credentials could not be saved securely on this device."
        }
    }
}

// Keychain records never synchronize to iCloud and remain accessible after first unlock
// so an already authorized video can keep playing while the device is locked.
enum CloudKeychain {
    static func save(_ credentials: S3Credentials, id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.wckd.mosaic.s3",
            kSecAttrAccount as String: id.uuidString,
        ]
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw CloudError.keychain(result) }
        } else if status != errSecSuccess {
            throw CloudError.keychain(status)
        }
    }
    static func read(id: UUID) throws -> S3Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.wckd.mosaic.s3",
            kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { throw CloudError.missingCredentials }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }
    static func delete(id: UUID) throws {
        let status = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.wckd.mosaic.s3",
                kSecAttrAccount as String: id.uuidString,
            ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudError.keychain(status)
        }
    }
}

// AWS Signature V4 is isolated and deterministic so canonical encoding can be tested
// against AWS's published vectors. Signed URLs are short-lived and never persisted.
enum S3Signer {
    static func encode(_ value: String, preserveSlash: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) || (preserveSlash && byte == 47)
            {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func url(
        connection: S3Connection, credentials: S3Credentials, key: String? = nil,
        query: [String: String] = [:], date: Date = Date(), expires: Int = 3600
    ) throws -> URL {
        guard var parts = URLComponents(string: connection.endpoint), parts.scheme == "https",
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/", !connection.bucket.isEmpty, !connection.region.isEmpty,
            !connection.bucket.contains("/"), !credentials.accessKey.isEmpty, !credentials.secretKey.isEmpty
        else { throw CloudError.invalidEndpoint }
        if !connection.pathStyle { parts.host = "\(connection.bucket).\(host)" }
        let path = (connection.pathStyle ? "/\(connection.bucket)" : "") + "/" + (key ?? "")
        parts.percentEncodedPath = encode(path, preserveSlash: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(connection.region)/s3/aws4_request"
        var parameters = query
        parameters["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256"
        parameters["X-Amz-Credential"] = "\(credentials.accessKey)/\(scope)"
        parameters["X-Amz-Date"] = timestamp
        parameters["X-Amz-Expires"] = String(min(604800, max(1, expires)))
        parameters["X-Amz-SignedHeaders"] = "host"
        if !credentials.sessionToken.isEmpty { parameters["X-Amz-Security-Token"] = credentials.sessionToken }
        let canonicalQuery = parameters.map { (encode($0.key), encode($0.value)) }.sorted { $0.0 < $1.0 }.map
        { "\($0)=\($1)" }.joined(separator: "&")
        let canonicalHost = (parts.host ?? host) + (parts.port.map { ":\($0)" } ?? "")
        let canonical =
            "GET\n\(parts.percentEncodedPath)\n\(canonicalQuery)\nhost:\(canonicalHost)\n\nhost\nUNSIGNED-PAYLOAD"
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash)"
        func hmac(_ key: Data, _ message: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
        }
        let signing = hmac(
            hmac(hmac(hmac(Data("AWS4\(credentials.secretKey)".utf8), day), connection.region), "s3"),
            "aws4_request")
        let signature = hmac(signing, stringToSign).map { String(format: "%02x", $0) }.joined()
        parts.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        guard let url = parts.url else { throw CloudError.invalidEndpoint }
        return url
    }
}

struct S3Object: Identifiable, Sendable {
    let key: String
    let size: Int64
    let modified: Date
    var id: String { key }
    var name: String { (key as NSString).lastPathComponent }
}

struct S3Page: Sendable {
    var objects: [S3Object] = []
    var folders: [String] = []
    var nextToken: String?
}

// Paginated, delimiter-based listing avoids downloading or indexing an entire bucket.
actor S3Service {
    static let shared = S3Service()
    func list(connection: S3Connection, prefix: String, token: String? = nil) async throws -> S3Page {
        let credentials = try CloudKeychain.read(id: connection.id)
        var query = ["list-type": "2", "delimiter": "/", "prefix": prefix, "max-keys": "200"]
        if let token { query["continuation-token"] = token }
        let url = try S3Signer.url(connection: connection, credentials: credentials, query: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CloudError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try S3ListingParser.parse(data)
    }
    func mediaURL(connection: S3Connection, key: String) throws -> URL {
        try S3Signer.url(
            connection: connection, credentials: CloudKeychain.read(id: connection.id), key: key,
            expires: 21600)
    }
}

// XMLParser handles escaped filenames. External entities are disabled; S3 responses
// must never be able to make the parser read local files or fetch additional URLs.
final class S3ListingParser: NSObject, XMLParserDelegate {
    private var page = S3Page()
    private var text = ""
    private var path: [String] = []
    private var key = ""
    private var size: Int64 = 0
    private var modified = Date.distantPast
    private var rootSeen = false
    static func parse(_ data: Data) throws -> S3Page {
        let delegate = S3ListingParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.rootSeen else { throw CloudError.invalidListing }
        return delegate.page
    }
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        path.append(elementName)
        text = ""
        if elementName == "ListBucketResult" { rootSeen = true }
        if elementName == "Contents" {
            key = ""
            size = 0
            modified = .distantPast
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if path.contains("Contents") {
            switch elementName {
            case "Key": key = text
            case "Size": size = Int64(text) ?? 0
            case "LastModified":
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                modified = format.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? .distantPast
            case "Contents":
                if !key.hasSuffix("/") {
                    page.objects.append(S3Object(key: key, size: size, modified: modified))
                }
            default: break
            }
        }
        if elementName == "Prefix", path.contains("CommonPrefixes") { page.folders.append(text) }
        if elementName == "NextContinuationToken", !text.isEmpty { page.nextToken = text }
        path.removeLast()
        text = ""
    }
}
