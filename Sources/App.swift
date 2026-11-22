import SwiftUI
import UniformTypeIdentifiers

@main
struct SignHelperApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView()
                    .tabItem { Label("IPA 库", systemImage: "square.stack.3d.up") }
                SignView()
                    .tabItem { Label("签名", systemImage: "signature") }
                AboutView()
                    .tabItem { Label("说明", systemImage: "info.circle") }
            }
            .environmentObject(library)
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

    func importIPA(from src: URL) -> String? {
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src) else { return "读取文件失败" }
        guard let parsed = IPAParser.parse(data: data) else { return "解析失败：这不是有效的 IPA 文件" }
        let id = UUID().uuidString
        let fileName = id + ".ipa"
        do {
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return "保存到 IPA 库失败"
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
        return nil
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
    @State private var showImporter = false
    @State private var importError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                if library.apps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IPA 库是空的")
                            .font(.headline)
                        Text("点右上角 + 导入 IPA 文件。本助手会解析它的名称、版本、签名状态和描述文件到期时间——个人免费证书只有 7 天有效期，到期前记得用 AltStore / SideStore 续签。")
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
                        Button("删除", role: .destructive) { library.delete(app) }
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
                        if let err = library.importIPA(from: url) { importError = err }
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
    @Environment(\.dismiss) private var dismiss
    let app: StoredApp
    @State private var showSignNotice = false
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
            Section {
                Button {
                    showSignNotice = true
                } label: {
                    Label(app.signed ? "续签这个 IPA" : "给这个 IPA 签名", systemImage: "signature")
                }
                ShareLink(item: library.fileURL(for: app)) {
                    Label("分享 / 导出 IPA", systemImage: "square.and.arrow.up")
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
        .alert("签名入口", isPresented: $showSignNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("真正的签名要向苹果服务器申请证书和描述文件，并对 Mach-O 重新签名——这一步需要 AltServer（电脑）或 SideStore（本机）配合完成，本助手内无法独立完成（原因见“签名”页）。建议：把 IPA 导出后用你现在在用的签名工具续签，或按“签名”页的两条路线操作。")
        }
        .alert("删除这个 IPA？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
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

// MARK: - 签名页

struct SignView: View {
    @State private var message: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("为什么这个助手里没有“输入 Apple ID 就能签名”", systemImage: "lock.shield")
                            .font(.subheadline.weight(.semibold))
                        Text("用个人 Apple ID 签名，背后要完成一整套与苹果服务器的认证：SRP 登录、anisette 设备信任数据、注册设备、申请免费证书（7 天有效）、生成描述文件、最后对 IPA 里的 Mach-O 逐个重新签名。这套流程目前只有 AltStore / SideStore 这类专门工具实现了：\n\n· AltStore：签名在电脑上的 AltServer 完成，手机端负责管理与续签提醒；\n· SideStore：AltStore 的分支，把签名搬到手机上，靠本地 VPN 回环 + anisette 服务器实现。\n\n本助手如果放一个 Apple ID 密码框，既连不上苹果的签名服务、签不了名，还会让你白白交出密码——所以这里不做登录框。助手负责签名之外同样重要的部分：管理 IPA 库、解析每个 IPA 的签名与到期时间、到期前提醒你续签。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("路线一 · AltStore（电脑配合）") {
                    step("1", "电脑装 AltServer，手机与电脑连同一 Wi-Fi（首次用数据线）")
                    step("2", "AltServer 托盘图标 → Install AltStore → 输入 Apple ID 登录，AltStore 装到手机")
                    step("3", "手机打开 AltStore → My Apps → + 选择 IPA，用同一 Apple ID 签名安装")
                    step("4", "每 7 天内让 AltStore 后台自动刷新，或打开 AltStore 点 Refresh All")
                    Button {
                        openSite("https://altstore.io", label: "AltStore 官网")
                    } label: {
                        Label("打开 AltStore 官网", systemImage: "safari")
                    }
                    Button {
                        tryScheme("altstore://", label: "AltStore")
                    } label: {
                        Label("检测本机 AltStore", systemImage: "magnifyingglass")
                    }
                }

                Section("路线二 · SideStore（无需电脑续签）") {
                    step("1", "按 SideStore 官网教程首次配对（需要一次电脑生成配对文件）")
                    step("2", "SideStore 内导入 IPA，用 Apple ID 签名安装")
                    step("3", "开启它的本地 VPN 回环后，可直接在手机上续签")
                    Button {
                        openSite("https://sidestore.io", label: "SideStore 官网")
                    } label: {
                        Label("打开 SideStore 官网", systemImage: "safari")
                    }
                    Button {
                        tryScheme("sidestore://", label: "SideStore")
                    } label: {
                        Label("检测本机 SideStore", systemImage: "magnifyingglass")
                    }
                }

                Section {
                    Text("提示：免费证书签名的 App 最多同时装 3 个（每个 App 的 App ID 也有限额），7 天到期后 App 会打不开，续签即可恢复，数据不丢。本助手 IPA 库里每个条目的“剩余天数”就是按描述文件到期时间算的。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("签名")
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
                .foregroundStyle(.white)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 1)
    }

    private func openSite(_ urlString: String, label: String) {
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
            message = "已打开\(label)，请按官网指引操作。"
        }
    }

    private func tryScheme(_ scheme: String, label: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            message = ok ? "本机已安装 \(label)，已为你打开。" : "本机似乎还没装 \(label)（或系统不允许这样打开），请先按上面的路线安装。"
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

        一、这个工具做什么
        · 导入并管理 IPA 文件库（文件只存在本 App 的沙盒里）
        · 解析每个 IPA 的名称、Bundle ID、版本、图标
        · 解析签名状态与 embedded.mobileprovision：团队、Team ID、到期时间，并算出剩余天数，方便你在 7 天免费证书到期前续签
        · 导出/分享 IPA 给真正的签名工具使用

        二、这个工具不做什么
        · 不收集、不保存你的 Apple ID 和密码（没有登录框）
        · 不直接给 IPA 签名——签名需要与苹果服务器完成证书申请与 anisette 认证，目前由 AltStore（AltServer）或 SideStore 实现，本助手提供完整路线指引与本机检测
        · 本助手自身也是一个未签名 IPA，首次安装同样需要用 AltStore / SideStore / 爱思助手类工具签一次——这是所有侧载工具共同的“先有鸡还是先有蛋”，不是故障

        三、名词速记
        · 免费证书：个人 Apple ID 申请的开发证书，有效期 7 天
        · 描述文件（Provisioning Profile）：把证书、设备 UDID 和 App ID 绑在一起的文件，IPA 的到期时间主要看它
        · 续签：到期前用同一 Apple ID 重新签名安装一遍，App 数据保留
        """
    }
}
