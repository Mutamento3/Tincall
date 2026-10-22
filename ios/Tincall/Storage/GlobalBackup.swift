import Foundation

/// A folder backup of public configuration, contacts, call text and retained audio.
/// Credentials are never read from Keychain by this format.
enum GlobalBackup {
    private struct Manifest: Codable {
        let format: String
        let version: Int
        let configuration: LocalConfigurationStore.Configuration
        let recordIDs: [UUID]
    }

    struct RecordExport: Sendable {
        let id: UUID
        let manifest: Data
        let media: [String: URL]
    }

    struct Export: Sendable {
        let manifest: Data
        let records: [RecordExport]
    }

    struct ImportResult {
        let connections: Int
        let contacts: Int
        let records: Int
        let skippedRecords: Int
        var temporaryCleanupFailed = false
    }

    @MainActor static func export(configuration: LocalConfigurationStore, records: CallRecordStore) throws -> Export {
        let manifest = try JSONEncoder().encode(Manifest(format: "Tincall", version: 1,
            configuration: configuration.backupConfiguration(), recordIDs: records.records.map(\.id)))
        var exports: [RecordExport] = []
        for record in records.records {
            let exported = try records.exportRecord(record.id)
            exports.append(RecordExport(id: record.id, manifest: exported.manifest, media: exported.media))
        }
        return Export(manifest: manifest, records: exports)
    }

    @MainActor static func importFolder(_ folder: URL, configuration: LocalConfigurationStore, records: CallRecordStore) throws -> ImportResult {
        let fm = FileManager.default
        try checkDirectory(folder)
        let manifestURL = folder.appendingPathComponent("backup.json")
        let manifestSize = try fileSize(manifestURL)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw TincallError(message: String(localized: "不是有效的Tincall全局备份文件夹")) }
        guard manifest.format == "Tincall", manifest.version == 1 else { throw TincallError(message: String(localized: "不支持此全局备份版本")) }
        guard Set(manifest.recordIDs).count == manifest.recordIDs.count else { throw TincallError(message: String(localized: "全局备份记录清单无效")) }
        let plan = try configuration.prepareImport(manifest.configuration)
        let recordDirectory = folder.appendingPathComponent("records", isDirectory: true)
        try checkDirectory(recordDirectory)
        let children = try fm.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard Set(children.map(\.lastPathComponent)) == Set(manifest.recordIDs.map(\.uuidString)), children.count == manifest.recordIDs.count else {
            throw TincallError(message: String(localized: "全局备份记录与清单不完整"))
        }
        var requiredBytes = Int64(manifestSize)
        let packages = try manifest.recordIDs.map { id -> URL in
            let package = recordDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try checkDirectory(package)
            requiredBytes += Int64(try fileSize(package.appendingPathComponent("record.json")))
            let media = package.appendingPathComponent("media", isDirectory: true)
            try checkDirectory(media)
            for url in try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                requiredBytes += Int64(try fileSize(url))
            }
            return package
        }
        try records.checkAvailableSpace(requiredBytes: requiredBytes)
        let staging = fm.temporaryDirectory.appendingPathComponent("TincallImport-\(UUID().uuidString)", isDirectory: true)
        var installed: [CallRecord] = []
        do {
            let staged = try CallRecordStore(directory: staging)
            for package in packages {
                let imported = try staged.importRecord(from: package)
                guard imported.imported else { continue }
                var record = imported.record
                record.roleID = plan.roleIDs[record.roleID] ?? record.roleID
                record.externalConnectionID = record.externalConnectionID.flatMap { plan.connectionIDs[$0] }
                try staged.save(record)
            }
            installed = try records.installImportedRecords(from: staged, deduplicate: true)
            do { try configuration.commitImport(plan) }
            catch {
                do { try records.rollbackImportedRecords(installed) }
                catch { throw TincallError(message: String(localized: "配置导入未保存，部分新记录清理失败；原有数据保留。")) }
                throw error
            }
        } catch {
            if fm.fileExists(atPath: staging.path) {
                do { try fm.removeItem(at: staging) }
                catch { throw TincallError(message: String(localized: "导入未完成，临时副本清理失败；原有数据保留。")) }
            }
            throw error
        }
        var result = ImportResult(connections: plan.addedConnections, contacts: plan.addedRoles,
                                  records: installed.count, skippedRecords: packages.count - installed.count)
        do { try fm.removeItem(at: staging) }
        catch { result.temporaryCleanupFailed = true }
        return result
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw TincallError(message: String(localized: "备份文件缺失、为空或包含符号链接"))
        }
        return size
    }

    private static func checkDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw TincallError(message: String(localized: "请选择本地备份文件夹")) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw TincallError(message: String(localized: "备份目录无效或包含符号链接")) }
    }
}
