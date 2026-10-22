import CoreText
import Foundation
import Observation
import UIKit

/// Fonts are local to Tincall and registered only for this process, never system-wide.
@MainActor @Observable
final class CaptionFontStore {
    static let shared = CaptionFontStore()
    static let selectionKey = "call.captionFont"

    struct Entry: Identifiable {
        let id: String
        var title: String
        let fileURL: URL
    }

    private(set) var fonts: [Entry] = []
    private(set) var loadingError: String?
    private let directory: URL?
    @ObservationIgnored private var displayNames: [String: String] = [:]

    init(directory: URL? = nil) {
        do {
            let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Tincall/CaptionFonts", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.directory = root
        } catch {
            self.directory = nil
            loadingError = error.localizedDescription
        }
        guard let directory = self.directory else { return }
        let namesURL = directory.appendingPathComponent("font-names.json")
        if FileManager.default.fileExists(atPath: namesURL.path) {
            do { displayNames = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: namesURL)) }
            catch { loadingError = String(localized: "字体名称无法读取：\(error.localizedDescription)") }
        }
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.creationDateKey])
                .filter({ ["ttf", "otf"].contains($0.pathExtension.lowercased()) })
                .sorted(by: {
                    let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return first == second ? $0.lastPathComponent < $1.lastPathComponent : first < second
                }) {
                do { fonts += try register(url) }
                catch { loadingError = String(localized: "部分字幕字体无法读取：\(error.localizedDescription)") }
            }
            let orderURL = directory.appendingPathComponent("font-order.json")
            if FileManager.default.fileExists(atPath: orderURL.path) {
                let order = try JSONDecoder().decode([String].self, from: Data(contentsOf: orderURL))
                let available = fonts
                fonts = order.compactMap { id in available.first { $0.id == id } }
                    + available.filter { !order.contains($0.id) }
            } else if !fonts.isEmpty {
                // Earlier imports have no saved order; use local copy creation dates once.
                try saveOrder(fonts.map(\.id))
            }
        } catch { loadingError = error.localizedDescription }
    }

    func rename(_ id: String, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FontError(message: String(localized: "请填写字体名称")) }
        guard let directory, let index = fonts.firstIndex(where: { $0.id == id }) else {
            throw FontError(message: String(localized: "字体不可用，请重新打开页面"))
        }
        var next = displayNames
        next[id] = title
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("font-names.json"), options: .atomic)
        displayNames = next
        fonts[index].title = title
    }

    func remove(_ id: String) throws {
        guard let directory, let font = fonts.first(where: { $0.id == id }) else {
            throw FontError(message: String(localized: "字体不可用，请重新打开页面"))
        }
        // Unregister before removing the file so it can be imported again in this process.
        var unregisterError: Unmanaged<CFError>?
        guard CTFontManagerUnregisterFontsForURL(font.fileURL as CFURL, .process, &unregisterError) else {
            let failure = unregisterError?.takeRetainedValue()
            throw FontError(message: failure.map { CFErrorCopyDescription($0) as String }
                ?? String(localized: "字体移除失败"))
        }
        // A failed file removal must leave the list and current selection untouched.
        do { try FileManager.default.removeItem(at: font.fileURL) }
        catch {
            do { _ = try register(font.fileURL) }
            catch { throw FontError(message: String(localized: "删除失败，且字体重新加载失败：\(error.localizedDescription)")) }
            throw error
        }
        let removedIDs = fonts.filter { $0.fileURL == font.fileURL }.map(\.id)
        fonts.removeAll { $0.fileURL == font.fileURL }
        for id in removedIDs { displayNames.removeValue(forKey: id) }
        if let selection = UserDefaults.standard.string(forKey: Self.selectionKey), removedIDs.contains(selection) {
            UserDefaults.standard.set("", forKey: Self.selectionKey)
        }
        do {
            try JSONEncoder().encode(displayNames).write(to: directory.appendingPathComponent("font-names.json"), options: .atomic)
            try saveOrder(fonts.map(\.id))
        } catch {
            throw FontError(message: String(localized: "字体已删除，但列表信息保存失败：\(error.localizedDescription)"))
        }
    }

    func font(named name: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        guard fonts.contains(where: { $0.id == name }), let font = UIFont(name: name, size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return font
    }

    func importFont(from source: URL) throws {
        guard let directory else { throw FontError(message: String(localized: "字幕字体目录不可用")) }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard ["ttf", "otf"].contains(source.pathExtension.lowercased()) else {
            throw FontError(message: String(localized: "请选择 TTF 或 OTF 字体文件"))
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw FontError(message: String(localized: "请选择有效的字体文件"))
        }
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let entries = try descriptors(at: destination)
            guard !entries.contains(where: { entry in fonts.contains(where: { $0.id == entry.id }) }) else {
                throw FontError(message: String(localized: "这个字体已经导入过了"))
            }
            let imported = try register(destination)
            try saveOrder((fonts + imported).map(\.id))
            fonts += imported
        } catch {
            do { try FileManager.default.removeItem(at: destination) }
            catch { throw FontError(message: String(localized: "导入失败，且临时字体清理失败：\(error.localizedDescription)")) }
            throw error
        }
    }

    private func descriptors(at url: URL) throws -> [Entry] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw FontError(message: String(localized: "无法读取字体，请确认文件是有效的 TTF 或 OTF"))
        }
        return try descriptors.map { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.isEmpty else { throw FontError(message: String(localized: "字体缺少有效名称")) }
            let title = displayNames[name]
                ?? (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? name)
            return Entry(id: name, title: title, fileURL: url)
        }
    }

    private func register(_ url: URL) throws -> [Entry] {
        let entries = try descriptors(at: url)
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let failure = error?.takeRetainedValue()
            // Reloading a store in the same process need not register the same font twice.
            guard let failure, CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue,
                  entries.allSatisfy({ UIFont(name: $0.id, size: 18) != nil }) else {
                throw FontError(message: failure.map { CFErrorCopyDescription($0) as String }
                    ?? String(localized: "字体注册失败"))
            }
        }
        return entries
    }

    private func saveOrder(_ ids: [String]) throws {
        guard let directory else { throw FontError(message: String(localized: "字幕字体目录不可用")) }
        try JSONEncoder().encode(ids).write(to: directory.appendingPathComponent("font-order.json"), options: .atomic)
    }

    private struct FontError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
