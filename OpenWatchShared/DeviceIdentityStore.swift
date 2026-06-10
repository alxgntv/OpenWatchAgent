import CryptoKit
import Foundation
import Security

nonisolated public struct DeviceIdentityMaterial: Sendable, Equatable {
    public let deviceId: String
    public let publicKeyBase64URL: String
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(deviceId: String, publicKeyBase64URL: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.deviceId = deviceId
        self.publicKeyBase64URL = publicKeyBase64URL
        self.privateKey = privateKey
    }

    public static func == (lhs: DeviceIdentityMaterial, rhs: DeviceIdentityMaterial) -> Bool {
        lhs.deviceId == rhs.deviceId && lhs.publicKeyBase64URL == rhs.publicKeyBase64URL
    }

    public func sign(payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Base64URL.encode(signature)
    }

    /// Raw Ed25519 seed for Keychain persistence (same module only).
    var privateKeyRawRepresentation: Data {
        privateKey.rawRepresentation
    }
}

/// Stable Ed25519 device identity for Gateway pairing.
/// Stored in Keychain so Xcode reinstall-over-existing keeps the same device id.
/// Deleting the app from the phone still creates a new identity (iOS clears Keychain).
nonisolated public enum DeviceIdentityStore {
    private static let service = "com.openwatchagent.deviceIdentity"
    private static let deviceIdKey = "deviceId"
    private static let publicKeyKey = "publicKey"
    private static let privateKeyKey = "privateKey"

    private static let legacyDeviceIdKey = "openwatch.deviceId"
    private static let legacyPublicKeyKey = "openwatch.devicePublicKey"
    private static let legacyPrivateKeyKey = "openwatch.devicePrivateKey"

    public static func loadOrCreate() throws -> DeviceIdentityMaterial {
        if let material = loadFromKeychain() {
            AppLog.info("Loaded device identity from Keychain id=\(material.deviceId.prefix(8))...")
            return material
        }

        if let migrated = migrateFromUserDefaults() {
            saveToKeychain(migrated)
            clearLegacyUserDefaults()
            AppLog.info("Migrated device identity to Keychain id=\(migrated.deviceId.prefix(8))...")
            return migrated
        }

        let material = createNewIdentity()
        saveToKeychain(material)
        AppLog.info("Created new device identity id=\(material.deviceId.prefix(8))...")
        return material
    }

    private static func createNewIdentity() -> DeviceIdentityMaterial {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicRaw = privateKey.publicKey.rawRepresentation
        let publicKeyBase64URL = Base64URL.encode(publicRaw)
        let deviceId = SHA256.hash(data: publicRaw).compactMap { String(format: "%02x", $0) }.joined()
        return DeviceIdentityMaterial(
            deviceId: deviceId,
            publicKeyBase64URL: publicKeyBase64URL,
            privateKey: privateKey
        )
    }

    private static func migrateFromUserDefaults() -> DeviceIdentityMaterial? {
        guard
            let deviceId = UserDefaults.standard.string(forKey: legacyDeviceIdKey),
            let publicKey = UserDefaults.standard.string(forKey: legacyPublicKeyKey),
            let privateRaw = UserDefaults.standard.data(forKey: legacyPrivateKeyKey),
            let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateRaw)
        else {
            return nil
        }
        return DeviceIdentityMaterial(deviceId: deviceId, publicKeyBase64URL: publicKey, privateKey: privateKey)
    }

    private static func clearLegacyUserDefaults() {
        UserDefaults.standard.removeObject(forKey: legacyDeviceIdKey)
        UserDefaults.standard.removeObject(forKey: legacyPublicKeyKey)
        UserDefaults.standard.removeObject(forKey: legacyPrivateKeyKey)
    }

    private static func loadFromKeychain() -> DeviceIdentityMaterial? {
        guard
            let deviceIdString = loadString(key: deviceIdKey),
            let publicKey = loadString(key: publicKeyKey),
            let privateRaw = loadData(key: privateKeyKey),
            let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateRaw)
        else {
            return nil
        }
        return DeviceIdentityMaterial(
            deviceId: deviceIdString,
            publicKeyBase64URL: publicKey,
            privateKey: privateKey
        )
    }

    private static func saveToKeychain(_ material: DeviceIdentityMaterial) {
        saveString(key: deviceIdKey, value: material.deviceId)
        saveString(key: publicKeyKey, value: material.publicKeyBase64URL)
        saveData(key: privateKeyKey, value: material.privateKeyRawRepresentation)
    }

    private static func saveString(key: String, value: String) {
        saveData(key: key, value: Data(value.utf8))
    }

    private static func saveData(key: String, value: Data) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadString(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadData(key: String) -> Data? {
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
        return data
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

nonisolated public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated public enum DeviceAuthPayloadBuilder {
    public static func buildV2(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String?,
        nonce: String
    ) -> String {
        [
            "v2",
            deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
        ].joined(separator: "|")
    }
}
