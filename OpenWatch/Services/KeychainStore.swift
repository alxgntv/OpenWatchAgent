import Foundation
import Security

nonisolated enum KeychainStore {
    private static let service = "com.alexeyignatov.OpenWatch.gateway"

    static func saveGatewaySession(url: URL, deviceToken: String?, bootstrapToken: String?) {
        save(key: "gatewayURL", value: url.absoluteString)
        if let deviceToken {
            save(key: "deviceToken", value: deviceToken)
        } else {
            delete(key: "deviceToken")
        }
        if let bootstrapToken {
            save(key: "bootstrapToken", value: bootstrapToken)
        } else {
            delete(key: "bootstrapToken")
        }
        AppLog.info("Saved gateway session to Keychain")
    }

    static func saveGatewayURLForLockedAccess(_ url: URL) {
        save(key: "gatewayURL", value: url.absoluteString)
        AppLog.info("Saved gateway URL to Keychain for locked access")
    }

    static func loadGatewayURL() -> URL? {
        guard let raw = load(key: "gatewayURL") else { return nil }
        return URL(string: raw)
    }

    static func loadDeviceToken() -> String? {
        load(key: "deviceToken")
    }

    static func loadBootstrapToken() -> String? {
        load(key: "bootstrapToken")
    }

    static func saveOperatorSession(token: String, scopes: [String]) {
        save(key: "operatorToken", value: token)
        save(key: "operatorScopes", value: scopes.joined(separator: ","))
        AppLog.info("Saved operator token to Keychain scopes=\(scopes.joined(separator: ","))")
    }

    static func loadOperatorToken() -> String? {
        load(key: "operatorToken")
    }

    static func loadOperatorScopes() -> [String] {
        guard let raw = load(key: "operatorScopes"), !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { String($0) }
    }

    static func clear() {
        delete(key: "gatewayURL")
        delete(key: "deviceToken")
        delete(key: "bootstrapToken")
        delete(key: "operatorToken")
        delete(key: "operatorScopes")
        AppLog.info("Cleared gateway Keychain session")
    }

    // ─── Ariadne's Thread [AT-0039] ─────────────────────
    // What: Treat the iPhone as paired only when it has gateway URL + operator token.
    // Why:  WSS chat/probe uses the operator token; some hello-ok payloads do not persist a deviceToken.
    // Date: 2026-06-07
    // Related: [AT-0038] AppModel.publishGatewayProbeToWatch, GatewayJobClient.openOperatorSocket
    // ─────────────────────────────────────────────────────
    static var isPaired: Bool {
        loadGatewayURL() != nil && loadOperatorToken() != nil
    }

    // ─── Ariadne's Thread [AT-0043] ─────────────────────
    // What: Re-save existing gateway credentials with AfterFirstUnlock accessibility.
    // Why:  Locked/background WatchConnectivity wake must read operatorToken to open the iPhone WSS tunnel.
    // Date: 2026-06-07
    // Related: GatewayJobClient.openOperatorSocket, WatchConnectivityPhoneService.didReceiveUserInfo
    // ─────────────────────────────────────────────────────
    static func migrateExistingItemsForLockedAccess() {
        let keys = ["gatewayURL", "deviceToken", "bootstrapToken", "operatorToken", "operatorScopes"]
        for key in keys {
            guard let value = load(key: key) else { continue }
            save(key: key, value: value)
            AppLog.info("Migrated Keychain item for locked access key=\(key)")
        }
    }

    private static func save(key: String, value: String) {
        let data = Data(value.utf8)
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
