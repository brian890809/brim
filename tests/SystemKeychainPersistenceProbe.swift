// Opt-in integration check, compiled with the production storage implementation.
// Only a UUID-scoped synthetic account is touched. Never prints credential data.
import Foundation

@main
struct SystemKeychainPersistenceProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, ["create", "read", "update", "remove"].contains(args[1]),
              UUID(uuidString: args[2]) != nil else { exit(2) }
        let account = "persistence-test-" + args[2]
        let fixture = Data(String(repeating: "synthetic-not-a-login\n", count: 500).utf8)
        let store = ClaudePersistentSecrets()
        do {
            switch args[1] {
            case "create", "update": try store.write(fixture, service: ClaudePersistentSecrets.vault, account: account, interactive: false)
            case "read":
                guard try store.read(service: ClaudePersistentSecrets.vault, account: account, interactive: false) == fixture else { exit(4) }
            default: try store.remove(service: ClaudePersistentSecrets.vault, account: account, interactive: false)
            }
            #if SECOND_BUILD
            print("Build B: \(args[1]) passed")
            #else
            print("Build A: \(args[1]) passed")
            #endif
        } catch {
            print("Synthetic operation failed: \((error as? ClaudeAccountError)?.errorDescription ?? "storage error")")
            exit(5)
        }
    }
}
