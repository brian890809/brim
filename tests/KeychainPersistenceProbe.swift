// Standalone, opt-in native integration check. Uses only one synthetic item
// under a caller-supplied unique service; never reads real account credentials.
import Foundation
import Security

let args = CommandLine.arguments
guard args.count == 3, ["create", "read", "remove"].contains(args[1]),
      args[2].hasPrefix("com.bchen.AgentUsage.PersistenceTest."),
      UUID(uuidString: String(args[2].dropFirst("com.bchen.AgentUsage.PersistenceTest.".count))) != nil else {
    fputs("Expected create/read/remove and a unique persistence-test service.\n", stderr); exit(2)
}
var previous = DarwinBoolean(false)
guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(3) }
defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: args[2], kSecAttrAccount as String: "synthetic-fixture",
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
let fixture = Data("not-a-real-login".utf8)
let status: OSStatus
switch args[1] {
case "create":
    var attributes = query
    attributes[kSecValueData as String] = fixture
    status = SecItemAdd(attributes as CFDictionary, nil)
case "read":
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status != errSecSuccess || result as? Data == fixture else { exit(4) }
default:
    status = SecItemDelete(query as CFDictionary)
}
guard status == errSecSuccess else { fputs("Keychain operation failed (\(status)); no interactive fallback.\n", stderr); exit(5) }
#if SECOND_BUILD
print("Build B: \(args[1]) passed without interaction")
#else
print("Build A: \(args[1]) passed without interaction")
#endif
