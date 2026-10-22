import Foundation

@main
struct CredentialMetadataChecks {
    static func main() throws {
        let id = UUID()
        let store = CredentialStore()
        defer {
            try? store.delete(connectionID: id)
            try? store.delete(connectionID: id, field: .apiSecret)
        }

        let missing = try store.savedAt(connectionID: id)
        precondition(missing == nil)
        try store.write("synthetic-metadata-key", connectionID: id)
        let first = try store.savedAt(connectionID: id)
        precondition(first != nil)

        // Reading an existing credential or the other field must not refresh its timestamp.
        let value = try store.read(connectionID: id)
        precondition(value == "synthetic-metadata-key")
        try store.write("synthetic-metadata-secret", connectionID: id, field: .apiSecret)
        let secretDate = try store.savedAt(connectionID: id, field: .apiSecret)
        precondition(secretDate != nil)
        let reopened = try CredentialStore().savedAt(connectionID: id)
        precondition(reopened == first)

        Thread.sleep(forTimeInterval: 1.1)
        try store.write("synthetic-replacement-key", connectionID: id)
        let updated = try store.savedAt(connectionID: id)
        precondition(updated! > first!)
        let unchangedSecret = try store.savedAt(connectionID: id, field: .apiSecret)
        precondition(unchangedSecret == secretDate)

        try store.delete(connectionID: id)
        let deleted = try store.savedAt(connectionID: id)
        precondition(deleted == nil)
        print("PASS: missing credential, saved time, metadata reads, independent fields, replacement, deletion")
    }
}
