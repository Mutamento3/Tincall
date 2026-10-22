import Foundation

/// Owns local file validation, staging and transfer. CloudSyncStore owns consent and the durable journal.
@MainActor
final class CloudRecordTransfer {
    struct Conflict: LocalizedError {
        let recordID: UUID
        let message: String
        var errorDescription: String? { message }
    }

    private let records: CallRecordStore
    private let client: CloudSyncClient

    init(records: CallRecordStore, client: CloudSyncClient) {
        self.records = records
        self.client = client
    }

    func prepareBackup(_ local: CallRecord, document: CloudSyncDocument) throws -> (document: CloudSyncDocument, uploads: [CloudSyncMedia]) {
        var document = document
        for asset in local.audioAssets {
            if let media = document.media.first(where: { $0.asset.id == asset.id }) {
                guard try audioMatches(asset, media: media, recordID: local.id) else {
                    throw Conflict(recordID: local.id, message: String(localized: "本机录音与云端版本不同，未自动覆盖。请检查后手动处理。"))
                }
            } else if document.media.contains(where: { $0.asset.messageID == asset.messageID && $0.asset.segmentIndex == asset.segmentIndex }) {
                throw Conflict(recordID: local.id, message: String(localized: "本机录音与云端版本不同，未自动覆盖。请检查后手动处理。"))
            }
        }
        var uploads: [CloudSyncMedia] = []
        for asset in local.audioAssets where !document.media.contains(where: { $0.asset.id == asset.id }) {
            let file = try records.audioURL(asset, recordID: local.id)
            let bytes = try Self.mediaSize(file)
            let media = CloudSyncMedia(object_id: UUID(), asset: asset, bytes: bytes)
            uploads.append(media); document.media.append(media)
        }
        if !uploads.isEmpty { _ = try document.validated(recordID: local.id) }
        return (document, uploads)
    }

    func upload(_ media: CloudSyncMedia, recordID: UUID, connection: ConnectionProfile) async throws {
        guard let local = records.records.first(where: { $0.id == recordID }),
              let asset = local.audioAssets.first(where: { $0.id == media.asset.id }), asset == media.asset else {
            throw TincallError(message: String(localized: "待备份的本机录音已改变或被删除，请保留文件后再继续"))
        }
        let file = try records.audioURL(asset, recordID: local.id)
        guard try Self.mediaSize(file) == media.bytes else { throw TincallError(message: String(localized: "待备份录音大小已改变，未上传")) }
        try await client.upload(connection: connection, recordID: local.id, media: media, file: file)
    }

    func images(in document: CloudSyncDocument?, recordID: UUID) throws -> [UUID: ConnectorMessageImage] {
        var images: [UUID: ConnectorMessageImage] = [:]
        if let document {
            for message in document.call.messages {
                let assets = (message.images ?? []).filter { asset in
                    !((document.imageReferences ?? []).contains { $0.id == asset.id && $0.mime_type == asset.mimeType })
                }
                let data = try assets.map { try Data(contentsOf: records.imageURL($0, recordID: recordID, messageID: message.id)) }
                for image in try ConnectorMessageImage.inputs(assets: assets, data: data) { images[image.id] = image }
            }
        }
        return images
    }

    /// Re-evaluate Store policy around each suspension and before publishing the staged record.
    func installText(_ document: CloudSyncDocument, connection: ConnectionProfile, validate: () throws -> Void) async throws {
        try validate()
        let original = records.records.first { $0.id == document.call.id }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TincallCloudImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = try CallRecordStore(directory: staging)
        for message in document.call.messages {
            for asset in message.images ?? [] {
                try validate()
                guard let reference = document.imageReferences?.first(where: { $0.id == asset.id }) else {
                    throw TincallError(message: String(localized: "云端消息图片引用缺失，未恢复记录"))
                }
                let destination = staging.appendingPathComponent(asset.id.uuidString)
                try await client.downloadImage(connection: connection, recordID: document.call.id, image: reference, destination: destination)
                try Task.checkCancellation()
                try validate()
                try staged.installImage(Data(contentsOf: destination), asset: asset, recordID: document.call.id, messageID: message.id)
                try FileManager.default.removeItem(at: destination)
            }
        }
        // Download every image before publishing any restored text or replacing a local record.
        try Task.checkCancellation()
        try validate()
        let local = records.records.first { $0.id == document.call.id }
        guard local == original else { throw TincallError(message: String(localized: "下载图片期间本机记录已改变，请刷新后再恢复")) }
        var value = CloudSyncDocument.textOnly(document.call)
        value.externalConnectionID = local?.externalConnectionID
        if value.summaryStatus == .pending || value.summaryStatus == .generating { value.summaryStatus = .failed }
        value.audioAssets = (local?.audioAssets ?? []).filter { asset in value.messages.contains { $0.id == asset.messageID } }
        if local != nil {
            for message in value.messages {
                for asset in message.images ?? [] {
                    let source = try staged.imageURL(asset, recordID: value.id, messageID: message.id)
                    try records.installImage(Data(contentsOf: source), asset: asset, recordID: value.id, messageID: message.id)
                }
            }
            try records.save(value)
        } else {
            try staged.save(value)
            try records.installImportedRecords(from: staged)
        }
    }

    func preserveLocalCopy(_ local: CallRecord) throws {
        let exported = try records.exportRecord(local.id)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("TincallCloudCopy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try exported.manifest.write(to: package.appendingPathComponent("record.json"), options: .atomic)
        for (name, source) in exported.media { try FileManager.default.copyItem(at: source, to: media.appendingPathComponent(name)) }
        _ = try records.importRecord(from: package, asIndependentCopy: true)
    }

    func restoreMedia(_ connection: ConnectionProfile, document: CloudSyncDocument, validate: () throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TincallCloudAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for media in document.media {
            try Task.checkCancellation()
            try validate()
            guard let local = records.records.first(where: { $0.id == document.call.id }) else { throw TincallError(message: String(localized: "本机记录已删除，停止恢复录音")) }
            guard CloudSyncDocument.textOnly(local) == document.call else { throw TincallError(message: String(localized: "本机文字已改变，请刷新后再恢复录音")) }
            if let existing = local.audioAssets.first(where: { $0.id == media.asset.id }) {
                guard try audioMatches(existing, media: media, recordID: local.id) else {
                    throw Conflict(recordID: local.id, message: String(localized: "本机录音与云端版本不同，未自动覆盖。请检查后手动处理。"))
                }
                continue
            }
            guard !local.audioAssets.contains(where: { $0.messageID == media.asset.messageID && $0.segmentIndex == media.asset.segmentIndex }) else {
                throw Conflict(recordID: local.id, message: String(localized: "此消息的本机录音与云端版本不同，未覆盖本机录音"))
            }
            let destination = temporary.appendingPathComponent(media.object_id.uuidString).appendingPathExtension(media.fileExtension)
            try await client.download(connection: connection, recordID: local.id, media: media, destination: destination)
            try Task.checkCancellation()
            try validate()
            guard let current = records.records.first(where: { $0.id == local.id }),
                  CloudSyncDocument.textOnly(current) == document.call else {
                throw TincallError(message: String(localized: "本机文字已改变或删除，停止恢复录音"))
            }
            _ = try records.saveAudio(recordID: local.id, segment: VoiceAudioSegment(id: media.asset.id,
                messageID: media.asset.messageID, segmentIndex: media.asset.segmentIndex, fileURL: destination, duration: media.asset.duration))
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func audioMatches(_ asset: CallAudioAsset, media: CloudSyncMedia, recordID: UUID) throws -> Bool {
        guard asset.id == media.asset.id, asset.messageID == media.asset.messageID,
              asset.segmentIndex == media.asset.segmentIndex, asset.duration == media.asset.duration,
              URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased() == media.fileExtension else { return false }
        return try Self.mediaSize(records.audioURL(asset, recordID: recordID)) == media.bytes
    }

    private static func mediaSize(_ file: URL) throws -> Int {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= CloudSyncClient.maximumMediaBytes else { throw TincallError(message: String(localized: "录音文件无效或超过 512 MB，未上传")) }
        return size
    }
}
