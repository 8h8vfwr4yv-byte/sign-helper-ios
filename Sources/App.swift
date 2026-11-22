import SwiftUI
import UniformTypeIdentifiers

@main
struct SignHelperApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var signLog = SignLog()

    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView()
                    .tabItem { Label("IPA 库", systemImage: "square.stack.3d.up") }
                SignView()
                    .tabItem { Label("签名", systemImage: "signature") }
                LogView()
                    .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
                AboutView()
                    .tabItem { Label("说明", systemImage: "info.circle") }
            }
            .environmentObject(library)
            .environmentObject(signLog)
        }
    }
}

// MARK: - 签名日志

struct LogEntry: Identifiable, Codable {
    var id: String
    var time: Date
    var text: String
}

final class SignLog: ObservableObject {
    @Published var entries: [LogEntry] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("signlog.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([LogEntry].self, from: data) {
            entries = list
        }
    }

    func add(_ text: String) {
        entries.insert(LogEntry(id: UUID().uuidString, time: Date(), text: text), at: 0)
        if entries.count > 500 { entries = Array(entries.prefix(500)) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 库存储

struct StoredApp: Identifiable, Codable {
    var id: String
    var fileName: String
    var displayName: String
    var bundleId: String
    var version: String
    var minOS: String
    var signed: Bool
    var teamName: String
    var teamId: String
    var expiration: Date?
    var importedAt: Date
    var size: Int

    var daysLeft: Int? {
        guard let expiration else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiration).day
    }
}

final class LibraryStore: ObservableObject {
    @Published var apps: [StoredApp] = []

    var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPALibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var metaURL: URL { dir.appendingPathComponent("metadata.json") }

    init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: metaURL),
           let list = try? JSONDecoder().decode([StoredApp].self, from: data) {
            apps = list
        }
        sortApps()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(apps) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func sortApps() {
        apps.sort {
            let a = $0.daysLeft ?? Int.max
            let b = $1.daysLeft ?? Int.max
            if a != b { return a < b }
            return $0.importedAt > $1.importedAt
        }
    }

    func fileURL(for app: StoredApp) -> URL { dir.appendingPathComponent(app.fileName) }
    func iconURL(for app: StoredApp) -> URL { dir.appendingPathComponent(app.id + ".png") }

    func importIPA(from src: URL) -> (error: String?, app: StoredApp?) {
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src) else { return ("读取文件失败", nil) }
        guard let parsed = IPAParser.parse(data: data) else { return ("解析失败：这不是有效的 IPA 文件", nil) }
        let id = UUID().uuidString
        let fileName = id + ".ipa"
        do {
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return ("保存到 IPA 库失败", nil)
        }
        if let icon = parsed.iconData {
            try? icon.write(to: dir.appendingPathComponent(id + ".png"), options: .atomic)
        }
        let stored = StoredApp(
            id: id, fileName: fileName,
            displayName: parsed.displayName, bundleId: parsed.bundleId,
            version: parsed.version, minOS: parsed.minOS,
            signed: parsed.signed,
            teamName: parsed.provision?.teamName ?? "",
            teamId: parsed.provision?.teamId ?? "",
            expiration: parsed.provision?.expiration,
            importedAt: Date(), size: data.count
        )
        apps.append(stored)
        sortApps()
        persist()
        return (nil, stored)
    }

    func delete(_ app: StoredApp) {
        try? FileManager.default.removeItem(at: fileURL(for: app))
        try? FileManager.default.removeItem(at: iconURL(for: app))
        apps.removeAll { $0.id == app.id }
        persist()
    }
}

func formatBytes(_ n: Int) -> String {
    if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
    if n >= 1024 { return "\(n / 1024) KB" }
    return "\(n) B"
}

// MARK: - IPA 库

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var signLog: SignLog
    @State private var showImporter = false
    @State private var importError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                if library.apps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IPA 库是空的")
                            .font(.headline)
                        Text("点右上角 + 用文件选择器加载本地 IPA。本助手会解析它的名称、版本、签名状态和描述文件到期时间——个人免费证书只有 7 天有效期，到期前记得续签。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(library.apps) { app in
                    NavigationLink {
                        AppDetailView(app: app)
                    } label: {
                        AppRow(app: app)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            signLog.add("从 IPA 库删除：\(app.displayName)（\(app.bundleId)）")
                            library.delete(app)
                        }
                    }
                }
            }
            .navigationTitle("IPA 签名助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let outcome = library.importIPA(from: url)
                        if let err = outcome.error {
                            importError = err
                            signLog.add("导入失败：\(err)")
                        } else if let app = outcome.app {
                            let state = app.signed ? "已签名" : "未签名"
                            signLog.add("导入 IPA：\(app.displayName)（\(app.bundleId)），\(state)")
                        }
                    }
                }
            }
            .alert("导入提示", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(importError ?? "") }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var library: LibraryStore
    let app: StoredApp

    var statusText: String {
        if !app.signed { return "未签名" }
        if let days = app.daysLeft {
            if days < 0 { return "签名已过期" }
            return "已签名 · 剩 \(days) 天"
        }
        return "已签名"
    }

    var statusColor: Color {
        if !app.signed { return .orange }
        if let days = app.daysLeft {
            if days < 0 { return .red }
            if days <= 2 { return .red }
            if days <= 7 { return .orange }
        }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).lineLimit(1)
                Text(app.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            Spacer()
            Text(formatBytes(app.size))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconView: some View {
        Group {
            if let data = try? Data(contentsOf: library.iconURL(for: app)),
               let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "app").foregroundStyle(.secondary))
            }
        }
    }
}

// MARK: - 详情

struct AppDetailView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var signLog: SignLog
    @Environment(\.dismiss) private var dismiss
    let app: StoredApp
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            Section("应用信息") {
                row("名称", app.displayName)
                row("Bundle ID", app.bundleId)
                row("版本", app.version.isEmpty ? "—" : app.version)
                row("最低系统", app.minOS.isEmpty ? "—" : "iOS \(app.minOS)")
                row("大小", formatBytes(app.size))
                row("导入时间", app.importedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("签名信息") {
                row("状态", app.signed ? "已签名" : "未签名")
                if !app.teamName.isEmpty { row("团队", app.teamName) }
                if !app.teamId.isEmpty { row("Team ID", app.teamId) }
                if let exp = app.expiration {
                    row("描述文件到期", exp.formatted(date: .abbreviated, time: .shortened))
                    if let days = app.daysLeft {
                        row("剩余天数", days < 0 ? "已过期 \(-days) 天" : "\(days) 天")
                    }
                } else if app.signed {
                    Text("未找到可解析的描述文件（可能为企业/商店签名）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未签名的 IPA 需要先签名才能安装。用个人 Apple ID 的免费证书签名后有效期为 7 天。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("导出结果") {
                ShareLink(item: library.fileURL(for: app)) {
                    Label("导出 / 分享这个 IPA", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("从库中删除", systemImage: "trash")
                }
            }
        }
        .navigationTitle(app.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除这个 IPA？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                signLog.add("从 IPA 库删除：\(app.displayName)（\(app.bundleId)）")
                library.delete(app)
                dismiss()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - 签名页（模式区分）

enum SignMode: String, CaseIterable, Identifiable {
    case backend = "后端签名"
    case local = "本地签名（实验性）"
    var id: String { rawValue }
}

struct SignView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var signLog: SignLog

    @State private var mode: SignMode = .backend
    @State private var selectedAppId: String = ""
    @AppStorage("backendEndpoint") private var endpoint: String = ""
    @AppStorage("savedAppleId") private var appleId: String = ""
    @State private var password: String = ""
    @State private var busy = false
    @State private var resultFile: URL? = nil
    @State private var resultNote: String = ""

    private var selectedApp: StoredApp? {
        library.apps.first { $0.id == selectedAppId } ?? library.apps.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section("选择 IPA") {
                    if library.apps.isEmpty {
                        Text("IPA 库是空的，先到“IPA 库”页导入一个 IPA。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("待签名 IPA", selection: Binding(
                            get: { selectedApp?.id ?? "" },
                            set: { selectedAppId = $0 }
                        )) {
                            ForEach(library.apps) { app in
                                Text("\(app.displayName)（\(app.signed ? "已签名" : "未签名")）").tag(app.id)
                            }
                        }
                    }
                }

                Section("签名模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(SignMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    if mode == .backend {
                        Text("后端模式：把 IPA 与 Apple ID 提交到你自己配置的签名服务器，由服务器完成向苹果申请证书、生成描述文件与重签名。本助手只做客户端提交与结果导出。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("本地模式（实验性）：依赖外部开源签名组件（如 ldid / zsign 类工具）在本机重签名。iOS 官方 SDK 没有内置代码签名接口，本构建未集成此类组件，高版本原生环境下也可能失效——此模式当前只记录流程日志并导出原始 IPA 副本。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if mode == .backend {
                    Section("后端签名接口") {
                        TextField("接口地址（https://…，你自己的服务器）", text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("接口约定：POST multipart/form-data，字段 apple_id、password，文件字段名为 ipa；成功时直接返回签名后的 IPA 文件数据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Apple ID 登录") {
                        TextField("Apple ID（邮箱）", text: $appleId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        SecureField("密码（仅本次请求使用，不保存、不写日志）", text: $password)
                        Text("密码只保存在内存里、随本次请求发给上面你自己配置的接口，用完即弃；不会存入设备、不会出现在日志中。没有你自己的签名服务器时请用本地模式或 AltStore / SideStore。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button {
                            Task { await runBackendSign() }
                        } label: {
                            if busy {
                                HStack { ProgressView(); Text("正在提交后端签名…") }
                            } else {
                                Label("登录并签名（后端）", systemImage: "signature")
                            }
                        }
                        .disabled(busy || selectedApp == nil)
                    }
                } else {
                    Section("本地签名（实验性）") {
                        Button {
                            runLocalSign()
                        } label: {
                            Label("尝试本地签名（实验性）", systemImage: "flask")
                        }
                        .disabled(selectedApp == nil)
                    }
                }

                if let resultFile {
                    Section("导出结果") {
                        if !resultNote.isEmpty {
                            Text(resultNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ShareLink(item: resultFile) {
                            Label("导出结果 IPA", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("其他可行路线") {
                    Text("没有自建后端时，成熟路线是 AltStore（电脑 AltServer 签名）或 SideStore（本机签名）：官网 altstore.io / sidestore.io，按其教程用 Apple ID 登录即可。本助手的价值在于签名之外：管理 IPA 库、解析到期时间、记录签名日志。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("签名")
        }
    }

    // 后端签名：把 IPA 与 Apple ID 提交到用户配置的接口
    private func runBackendSign() async {
        guard let app = selectedApp else { return }
        let ep = endpoint.trimmingCharacters(in: .whitespaces)
        let aid = appleId.trimmingCharacters(in: .whitespaces)
        signLog.add("后端签名开始：\(app.displayName)（\(app.bundleId)）")
        guard let url = URL(string: ep), ep.hasPrefix("https://") else {
            signLog.add("后端签名失败：未配置有效的 https 接口地址")
            resultNote = "未配置后端接口地址，请先在上方填写你自己的签名服务器地址。"
            resultFile = nil
            return
        }
        guard !aid.isEmpty, !password.isEmpty else {
            signLog.add("后端签名失败：Apple ID 或密码为空")
            resultNote = "请填写 Apple ID 与密码。"
            resultFile = nil
            return
        }
        busy = true
        defer { busy = false }
        do {
            let ipaData = try Data(contentsOf: library.fileURL(for: app))
            signLog.add("正在上传 IPA（\(formatBytes(ipaData.count))）到后端接口…")
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("apple_id", aid)
            field("password", password)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"ipa\"; filename=\"app.ipa\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(ipaData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 180

            let (data, response) = try await URLSession.shared.data(for: request)
            password = ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200, data.count > 22, data.prefix(2).elementsEqual([0x50, 0x4B]) {
                let outDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SignedOutput", isDirectory: true)
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let outURL = outDir.appendingPathComponent(app.displayName + "-signed.ipa")
                try data.write(to: outURL, options: .atomic)
                resultFile = outURL
                resultNote = "后端签名成功（\(formatBytes(data.count))），可导出后安装。"
                signLog.add("后端签名成功：\(app.displayName)，结果 \(formatBytes(data.count))，已保存待导出")
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                resultFile = nil
                resultNote = "后端返回异常（HTTP \(code)），未得到签名 IPA。"
                signLog.add("后端签名失败：HTTP \(code) \(snippet)")
            }
        } catch {
            password = ""
            resultFile = nil
            resultNote = "请求失败：\(error.localizedDescription)"
            signLog.add("后端签名失败：\(error.localizedDescription)")
        }
    }

    // 本地签名（实验性）：无官方接口、未集成外部组件——如实记录并导出原始副本
    private func runLocalSign() {
        guard let app = selectedApp else { return }
        signLog.add("本地签名（实验性）开始：\(app.displayName)（\(app.bundleId)）")
        signLog.add("本地签名：iOS 官方 SDK 无内置代码签名接口，实验性签名依赖外部开源组件（ldid / zsign 类），本构建未集成")
        signLog.add("本地签名未执行：高版本原生环境下外部签名组件可能失效，导出结果为原始 IPA 副本（\(app.signed ? "保持原签名状态" : "仍未签名")）")
        resultFile = library.fileURL(for: app)
        resultNote = "本地签名（实验性）在本构建中未实际执行：导出的是原始 IPA 副本。真正签名请使用后端模式或 AltStore / SideStore。"
    }
}

// MARK: - 日志页

struct LogView: View {
    @EnvironmentObject var signLog: SignLog
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if signLog.entries.isEmpty {
                    Text("暂无日志。导入 IPA、执行签名等操作都会记录在这里（不含密码等敏感信息）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(signLog.entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text)
                            .font(.subheadline)
                        Text(entry.time.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("签名日志")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                        .disabled(signLog.entries.isEmpty)
                }
            }
            .alert("清空全部日志？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { signLog.clear() }
            }
        }
    }
}

// MARK: - 说明页

struct AboutView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(aboutText)
                    .font(.body)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("说明")
        }
    }

    private var aboutText: String {
        """
        IPA 签名助手 · 说明

        本项目为技术学习演示项目。

        一、重要备注
        · iOS 官方 SDK 没有内置代码签名接口，任何“在 App 内直接签名”的实现都依赖苹果未公开的流程或外部开源组件，并非系统提供的能力。
        · 本地签名属于实验性功能：依赖外部开源组件（如 ldid / zsign 类签名器），在高版本原生环境下可能失效；本构建未集成此类组件，本地模式只记录流程并导出原始 IPA 副本。
        · 后端模式为可选对接：由你自备签名服务器，本助手只负责按约定接口提交 IPA 与 Apple ID 并导出返回结果；密码仅在内存中使用，不保存、不写入日志。

        二、这个工具做什么
        · 用文件选择器加载本地 IPA，管理 IPA 库（文件只存在本 App 沙盒里）
        · 解析每个 IPA 的名称、Bundle ID、版本、图标
        · 解析签名状态与 embedded.mobileprovision：团队、Team ID、到期时间，算出剩余天数
        · 签名状态日志：导入、签名尝试、结果都会记录，可查看与清空
        · 导出结果：详情页可导出原始 IPA，签名页可导出后端返回的签名结果

        三、免费 Apple ID 的限制（README 同步写明）
        · 有效期 7 天：免费证书与描述文件 7 天到期，到期后 App 无法打开，续签后恢复，数据不丢
        · App 数量上限：同一台设备上免费签名的 App 最多同时存在 3 个；7 天内可注册的 App ID 数量也有上限（约 10 个）
        · 每个 App 的推送、App Groups 等部分能力在免费签名下不可用或受限

        四、个人使用范围提示
        · 本工具仅供个人学习与自用：给自己拥有的设备、自己有权使用的 IPA 签名
        · 请勿用于分发、代签收费、绕过付费或侵犯他人权益的用途
        · 本助手自身也是一个未签名 IPA，首次安装同样需要先用 AltStore / SideStore 等工具签一次——这是所有侧载工具共同的前提，不是故障
        """
    }
}
