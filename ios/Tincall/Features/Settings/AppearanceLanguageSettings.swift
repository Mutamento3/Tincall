// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable {
    case dark, light, system

    var title: String {
        switch self {
        case .dark: String(localized: "深色")
        case .light: String(localized: "浅色")
        case .system: String(localized: "跟随系统")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        case .system: "circle.lefthalf.filled"
        }
    }
}

struct AppearanceLanguageSettings: View {
    @AppStorage("tincall.appearance") private var appearance = AppAppearance.system
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fonts = CaptionFontStore.shared
    @State private var isImportingFont = false
    @State private var fontError: String?
    @State private var showsFontRename = false
    @State private var renamingFontID = ""
    @State private var editedFontName = ""
    @State private var fontToDelete: CaptionFontStore.Entry?
    @State private var isDeletingFonts = false

    private var languageName: String {
        let locale = Locale.current
        let language = Bundle.main.preferredLocalizations.first ?? locale.language.minimalIdentifier
        return locale.localizedString(forIdentifier: language) ?? language
    }

    var body: some View {
        SettingsList {
            Section {
                HStack(spacing: 12) {
                    ForEach([AppAppearance.light, .dark, .system], id: \.self) { option in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                appearance = option
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: option.symbol)
                                    .font(.system(size: 23, weight: .regular))
                                    .frame(height: 28)
                                Text(option.title).font(.caption)
                            }
                            .foregroundStyle(appearance == option ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background((appearance == option ? Color.settingsSurface(lightOpacity: colorScheme == .dark ? 0.14 : 0.1) : Color.settingsSurface()),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(appearance == option ? Color.accentColor : Color.primary.opacity(0.1),
                                              lineWidth: 0.75))
                            .contentShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(appearance == option ? .isSelected : [])
                    }
                }
            } header: {
                SettingsSectionHeading(number: "01", title: String(localized: "外观"), caption: "APPEARANCE")
            }
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text(languageName).foregroundStyle(.primary)
                        Spacer()
                        Text("点击切换语言").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            } header: {
                SettingsSectionHeading(number: "02", title: String(localized: "语言"), caption: "LANGUAGE")
            } footer: {
                Text("语言跟随系统设置，可在系统设置中为 Tincall 单独选择。")
                    .font(.footnote).foregroundStyle(Color.secondary)
            }
            Section {
                HStack(spacing: 12) {
                    Button { isImportingFont = true } label: {
                        SettingsActionLabel(title: String(localized: "导入字体"), symbol: "square.and.arrow.down",
                                            detail: String(localized: "选择 TTF／OTF 字体文件"))
                    }
                    if !fonts.fonts.isEmpty {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                isDeletingFonts.toggle()
                            }
                        } label: {
                            Text(isDeletingFonts ? String(localized: "完成") : String(localized: "删除"))
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                ForEach(Array(fonts.fonts.enumerated()), id: \.element.id) { index, font in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.accentColor)
                            Text("\(index + 1)")
                                .font(.system(size: index < 99 ? 12 : 10, weight: .semibold, design: .rounded))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                        Text(font.title)
                            .font(Font(fonts.font(named: font.id, size: 16)))
                        Spacer(minLength: 0)
                        Group {
                            if isDeletingFonts {
                                Button { fontToDelete = font } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 17, weight: .regular))
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(String(localized: "删除字体：\(font.title)"))
                            } else {
                                Button {
                                    renamingFontID = font.id
                                    editedFontName = font.title
                                    showsFontRename = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(String(localized: "修改字体名称：\(font.title)"))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                }
                if let error = fonts.loadingError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                SettingsSectionHeading(number: "03", title: String(localized: "通话字体"), caption: "CALL FONT")
            } footer: {
                Text("支持 TTF／OTF。导入后可在通话内设置中选择，用于通话字幕、文字视图正文和输入框。")
                    .font(.footnote).foregroundStyle(Color.secondary)
            }
        }
        .listSectionSpacing(10)
        .onChange(of: fonts.fonts.isEmpty) { _, isEmpty in
            if isEmpty { isDeletingFonts = false }
        }
        .modifier(SettingsPageStyle(title: String(localized: "显示与字体"), subtitle: String(localized: "外观 · 语言 · 通话字体"),
                                    symbol: "circle.lefthalf.filled", index: "APPEARANCE & LANGUAGE"))
        .fileImporter(isPresented: $isImportingFont,
                      allowedContentTypes: [UTType(filenameExtension: "ttf")!, UTType(filenameExtension: "otf")!]) { result in
            do { try fonts.importFont(from: result.get()) }
            catch {
                if (error as NSError).code != CocoaError.userCancelled.rawValue {
                    fontError = error.localizedDescription
                }
            }
        }
        .alert("修改字体名称", isPresented: $showsFontRename) {
            TextField("字体名称", text: $editedFontName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { }
            Button("保存") {
                do { try fonts.rename(renamingFontID, to: editedFontName) }
                catch { fontError = error.localizedDescription }
            }
            .disabled(editedFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("字体操作失败", isPresented: Binding(get: { fontError != nil },
            set: { if !$0 { fontError = nil } })) {
            Button("好", role: .cancel) { fontError = nil }
        } message: { Text(fontError ?? "") }
        .alert("删除字体", isPresented: Binding(get: { fontToDelete != nil },
            set: { if !$0 { fontToDelete = nil } }), presenting: fontToDelete) { font in
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                do { try fonts.remove(font.id) }
                catch { fontError = error.localizedDescription }
            }
        } message: { font in
            Text("将从 Tincall 移除「\(font.title)」。正在使用时会恢复系统默认，原字体文件不受影响。")
        }
    }
}
