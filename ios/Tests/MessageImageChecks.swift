import Foundation

@main
struct MessageImageChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TincallMessageImageChecks-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let store = try CallRecordStore(directory: root)
        var message = CallMessage(turnID: UUID(), role: .user, text: "")
        var record = CallRecord(roleID: UUID(), roleName: "Synthetic", startedAt: Date().addingTimeInterval(-1), endedAt: Date(), messages: [message])
        try store.save(record)
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        message.images = try store.saveImages(recordID: record.id, messageID: message.id, images: [jpeg])
        record.messages = [message]
        try store.save(record)
        let persisted = try CallRecordStore(directory: root).records[0]
        let assets = persisted.messages[0].images!
        let data = try assets.map { try Data(contentsOf: store.imageURL($0, recordID: record.id, messageID: message.id)) }
        let inputs = try ConnectorMessageImage.inputs(assets: assets, data: data)
        let retry = try ConnectorMessageImage.inputs(assets: assets, data: data)
        let firstBytes = try JSONEncoder().encode(inputs)
        let retryBytes = try JSONEncoder().encode(retry)
        precondition(firstBytes == retryBytes)
        precondition(inputs[0].id == assets[0].id && inputs[0].mime_type == "image/jpeg")
        precondition(inputs[0].data_base64 == jpeg.base64EncodedString() && !inputs[0].data_base64.contains("\n"))
        try rejects { _ = try ConnectorMessageImage.inputs(assets: assets, data: []) }
        try rejects { try ConnectorMessageImage.validate(Data(repeating: 0, count: 5 * 1024 * 1024 + 1), mimeType: "image/jpeg") }
        try rejects { try ConnectorMessageImage.validate(jpeg, mimeType: "image/png") }
        try rejects { _ = try ConnectorMessageImage.inputs(assets: Array(repeating: assets[0], count: 5), data: Array(repeating: jpeg, count: 5)) }

        let document = CloudSyncDocument(call: persisted)
        let wire = CloudSyncWireDocument(document, images: [inputs[0].id: inputs[0]])
        let encoded = try JSONEncoder().encode(wire)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var call = json["call"] as! [String: Any]
        var messages = call["messages"] as! [[String: Any]]
        precondition(messages.count == 1 && messages[0]["text"] as? String == "")
        let imageJSON = (messages[0]["images"] as! [[String: Any]])[0]
        precondition(Set(imageJSON.keys) == Set(["id", "mime_type", "data_base64"]))
        precondition(!String(decoding: encoded, as: UTF8.self).contains("relativePath"))
        try rejects { _ = try JSONEncoder().encode(CloudSyncWireDocument(document)) }

        // The connector persists references, not the inline file or the phone path.
        messages[0]["images"] = [["id": assets[0].id.uuidString, "mime_type": "image/jpeg", "bytes": jpeg.count]]
        call["messages"] = messages; json["call"] = call
        let referenceJSON = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(CloudSyncWireDocument.self, from: referenceJSON).document.validated(recordID: record.id)
        precondition(restored.call == CloudSyncDocument.textOnly(persisted))
        precondition(restored.imageReferences?.first?.bytes == jpeg.count)
        let journal = try JSONDecoder().decode(CloudSyncDocument.self, from: JSONEncoder().encode(restored))
        precondition(journal == restored)
        let referenceWire = try JSONEncoder().encode(CloudSyncWireDocument(restored))
        precondition(!String(decoding: referenceWire, as: UTF8.self).contains("data_base64"))
        let target = try CallRecordStore(directory: root.appendingPathComponent("restored"))
        try target.installImage(jpeg, asset: assets[0], recordID: record.id, messageID: message.id)
        try target.save(restored.call)
        let url = try target.imageURL(assets[0], recordID: record.id, messageID: message.id)
        try rejects { try target.installImage(Data([0xff, 0xd8, 0xff, 0, 1]), asset: assets[0], recordID: record.id, messageID: message.id) }
        let installed = try Data(contentsOf: url)
        precondition(installed == jpeg)
        try target.delete(recordID: record.id)
        precondition(!fm.fileExists(atPath: url.path))

        // PNG references keep their type through cloud restore and local folder backup.
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        messages[0]["images"] = [["id": assets[0].id.uuidString, "mime_type": "image/png", "bytes": png.count]]
        call["messages"] = messages; json["call"] = call
        let pngDocument = try JSONDecoder().decode(CloudSyncWireDocument.self, from: JSONSerialization.data(withJSONObject: json)).document.validated(recordID: record.id)
        let pngAsset = pngDocument.call.messages[0].images![0]
        try target.installImage(png, asset: pngAsset, recordID: record.id, messageID: message.id)
        try target.save(pngDocument.call)
        let exported = try target.exportRecord(record.id)
        let package = root.appendingPathComponent("png-package")
        try fm.createDirectory(at: package.appendingPathComponent("media"), withIntermediateDirectories: true)
        try exported.manifest.write(to: package.appendingPathComponent("record.json"))
        for (name, file) in exported.media { try fm.copyItem(at: file, to: package.appendingPathComponent("media").appendingPathComponent(name)) }
        let imported = try target.importRecord(from: package, asIndependentCopy: true).record
        let importedPNG = try Data(contentsOf: target.imageURL(imported.messages[0].images![0], recordID: imported.id, messageID: message.id))
        precondition(importedPNG == png && imported.messages[0].images![0].mimeType == "image/png")
        let failure = ExternalCallFailure(status: 413, code: "image_too_large")
        precondition(failure.localizedDescription.contains("image_too_large") && failure.localizedDescription.contains("413"))

        messages[0]["images"] = [["id": assets[0].id.uuidString, "mime_type": "image/jpeg", "bytes": 0]]
        call["messages"] = messages; json["call"] = call
        try rejects { _ = try JSONDecoder().decode(CloudSyncWireDocument.self, from: JSONSerialization.data(withJSONObject: json)).document.validated(recordID: record.id) }
        // Legacy text-only backups still round-trip without adding an images field.
        record.messages[0].images = nil
        let legacyWire = try JSONEncoder().encode(CloudSyncWireDocument(CloudSyncDocument(call: record)))
        let legacy = try JSONDecoder().decode(CloudSyncWireDocument.self, from: legacyWire).document.validated(recordID: record.id)
        precondition(legacy.call == CloudSyncDocument.textOnly(record))
        precondition(!String(decoding: legacyWire, as: UTF8.self).contains("\"images\""))
        print("PASS: image wire format, stable retry UUID, limits, backup references, legacy text, immutable restore and record deletion")
    }

    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation(); preconditionFailure("Invalid image operation must fail") }
        catch is TincallError { }
    }
}
