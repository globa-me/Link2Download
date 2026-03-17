import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var manager: DownloadManager

    @State private var isShowingSettings = false
    @State private var isShowingAbout = false
    @State private var expandedRecordIDs: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 14) {
                header
                filterBar
                content
            }
            .padding(16)
            .background(Theme.panel.ignoresSafeArea())

            if let toast = manager.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 14)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            manager.clearToast()
                        }
                    }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheetView(settings: settings)
        }
        .sheet(isPresented: $isShowingAbout) {
            AboutSheetView(settings: settings)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: pasteAndStart) {
                    Label(settings.t("toolbar.paste"), systemImage: "link.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.accentStrong)
                        )
                }
                .buttonStyle(.plain)

                Toggle(settings.t("toolbar.smart"), isOn: smartModeBinding)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 180)
                    .help(settings.t("smart.help"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        menuField(title: settings.t("toolbar.download")) {
                            Picker("", selection: $settings.kind) {
                                ForEach(DownloadKind.allCases) { kind in
                                    Text(settings.label(for: kind)).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 105)
                        }

                        menuField(title: settings.t("toolbar.quality")) {
                            Picker("", selection: $settings.quality) {
                                ForEach(QualityPreset.userSelectableCases) { quality in
                                    Text(settings.label(for: quality)).tag(quality)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        if settings.kind == .video {
                            menuField(title: settings.t("toolbar.format")) {
                                Picker("", selection: $settings.videoFormat) {
                                    ForEach(VideoFormat.allCases) { format in
                                        Text(format.rawValue.uppercased()).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 85)
                            }
                        } else {
                            menuField(title: settings.t("toolbar.format")) {
                                Picker("", selection: $settings.audioFormat) {
                                    ForEach(AudioFormat.allCases) { format in
                                        Text(format.rawValue.uppercased()).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 85)
                            }
                        }

                        menuField(title: settings.t("toolbar.speed")) {
                            Picker("", selection: $settings.speedLimit) {
                                ForEach(SpeedLimitPreset.allCases) { speed in
                                    Text(settings.label(for: speed)).tag(speed)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Spacer(minLength: 0)

                toolbarIconButton(systemImage: "gearshape", help: settings.t("toolbar.settings")) {
                    isShowingSettings = true
                }

                toolbarIconButton(systemImage: "info.circle", help: settings.t("toolbar.about")) {
                    isShowingAbout = true
                }
            }

            HStack(spacing: 10) {
                Text("\(settings.t("toolbar.saveTo")): \(settings.displaySaveDirectory())")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                Button(settings.t("toolbar.chooseFolder")) {
                    chooseSaveFolder()
                }
                .buttonStyle(.link)

                Button(settings.t("toolbar.resetDefaults")) {
                    settings.resetDefaults()
                }
                .buttonStyle(.link)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(settings.smartModeEnabled ? settings.t("smart.enabled") : settings.t("smart.disabled"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)

                    if settings.smartModeEnabled {
                        Text(settings.t("smart.profileHint"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            Text(settings.t("toolbar.startHint"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
    }

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $manager.listFilter) {
                Text(settings.t("filter.all")).tag(ListFilter.all)
                Text(settings.t("filter.video")).tag(ListFilter.video)
                Text(settings.t("filter.audio")).tag(ListFilter.audio)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            HStack(spacing: 6) {
                TextField(settings.t("toolbar.search"), text: $manager.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                if !manager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        manager.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(settings.t("toolbar.clearSearch"))
                }
            }

            if !manager.records.isEmpty {
                statPill(title: settings.t("stats.active"), value: activeCount, color: Theme.accentStrong)
                statPill(title: settings.t("stats.queued"), value: queuedCount, color: .orange)
                statPill(title: settings.t("stats.completed"), value: completedCount, color: .green)
                statPill(title: settings.t("stats.failed"), value: failedCount, color: .red)
            }

            Spacer()

            Text("\(manager.filteredRecords.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            if failedCount > 0 {
                Button(settings.t("toolbar.retryErrors")) {
                    manager.retryFailedAndCancelled()
                }
                .buttonStyle(.link)

                Button(settings.t("toolbar.clearErrors")) {
                    manager.removeFailedAndCancelled()
                }
                .buttonStyle(.link)
            }

            if !manager.records.isEmpty {
                Button(settings.t("toolbar.clearList")) {
                    manager.removeAll()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var content: some View {
        Group {
            if manager.filteredRecords.isEmpty {
                if manager.records.isEmpty {
                    noDownloadsView
                } else {
                    noResultsView
                }
            } else {
                List {
                    ForEach(manager.filteredRecords) { record in
                        DownloadRowView(
                            settings: settings,
                            record: record,
                            isExpanded: expandedRecordIDs.contains(record.id),
                            onOpenFile: { manager.openFile(recordID: record.id) },
                            onShowFinder: { manager.openInFinder(recordID: record.id) },
                            onCopySource: { manager.copySourceURL(recordID: record.id) },
                            onOpenBrowser: { manager.openSourceInBrowser(recordID: record.id) },
                            onCancel: { manager.cancel(recordID: record.id) },
                            onRetry: { manager.retry(recordID: record.id) },
                            onDeleteFile: { manager.deleteFile(for: record.id) },
                            onRemoveFromList: { manager.removeRecord(record.id) },
                            onToggleExpand: { toggleExpanded(record.id) }
                        )
                            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                            .listRowBackground(Theme.rowBackground)
                            .contextMenu {
                                if let path = record.filePath,
                                   FileManager.default.fileExists(atPath: path) {
                                    Button(settings.t("action.showFinder")) {
                                        manager.openInFinder(recordID: record.id)
                                    }

                                    Button(settings.t("action.openFile")) {
                                        manager.openFile(recordID: record.id)
                                    }

                                    Button(settings.t("action.deleteFile")) {
                                        manager.deleteFile(for: record.id)
                                    }
                                }

                                Button(settings.t("action.copySource")) {
                                    manager.copySourceURL(recordID: record.id)
                                }

                                Button(settings.t("action.openBrowser")) {
                                    manager.openSourceInBrowser(recordID: record.id)
                                }

                                if record.status == .queued || record.status == .downloading {
                                    Button(settings.t("action.cancel")) {
                                        manager.cancel(recordID: record.id)
                                    }
                                }

                                if record.status == .failed || record.status == .cancelled {
                                    Button(settings.t("action.retry")) {
                                        manager.retry(recordID: record.id)
                                    }
                                }

                                if record.status != .queued && record.status != .downloading {
                                    Button(settings.t("action.removeFromList")) {
                                        manager.removeRecord(record.id)
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
            }
        }
    }

    private var noDownloadsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accentStrong)
            Text(settings.t("empty.title"))
                .font(.system(size: 17, weight: .semibold))
            Text(settings.t("empty.subtitle"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            HStack(spacing: 10) {
                Button(settings.t("empty.action.paste")) {
                    pasteAndStart()
                }
                .buttonStyle(.borderedProminent)

                Button(settings.t("empty.action.settings")) {
                    isShowingSettings = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accentStrong)
            Text(settings.t("empty.noResultsTitle"))
                .font(.system(size: 17, weight: .semibold))
            Text(settings.t("empty.noResultsSubtitle"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            Button(settings.t("empty.action.resetFilters")) {
                resetFilters()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
    }

    private func menuField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
    }

    private func toolbarIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func statPill(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title): \(value)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
    }

    private func pasteAndStart() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            manager.toastMessage = settings.t("toast.invalidURL")
            return
        }
        manager.enqueue(urlString: value)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = settings.t("toolbar.chooseFolder")
        panel.directoryURL = URL(fileURLWithPath: settings.saveDirectory)

        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url.path
            settings.ensureSaveDirectoryExists()
        }
    }

    private func resetFilters() {
        manager.listFilter = .all
        manager.searchQuery = ""
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRecordIDs.contains(id) {
            expandedRecordIDs.remove(id)
        } else {
            expandedRecordIDs.insert(id)
        }
    }

    private var smartModeBinding: Binding<Bool> {
        Binding(
            get: { settings.smartModeEnabled },
            set: { newValue in
                settings.setSmartMode(newValue)
            }
        )
    }

    private var activeCount: Int {
        manager.records.filter { $0.status == .downloading }.count
    }

    private var queuedCount: Int {
        manager.records.filter { $0.status == .queued }.count
    }

    private var failedCount: Int {
        manager.records.filter { $0.status == .failed }.count
    }

    private var completedCount: Int {
        manager.records.filter { $0.status == .completed }.count
    }
}

struct DownloadRowView: View {
    @ObservedObject var settings: SettingsStore
    let record: DownloadRecord
    let isExpanded: Bool
    let onOpenFile: () -> Void
    let onShowFinder: () -> Void
    let onCopySource: () -> Void
    let onOpenBrowser: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDeleteFile: () -> Void
    let onRemoveFromList: () -> Void
    let onToggleExpand: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                thumbnailView

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if let uploader = record.uploaderName, !uploader.isEmpty {
                        Text(uploader)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }

                    metadataBadges

                    Text(fileNameLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(statusText)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.18))
                        .foregroundStyle(statusColor)
                        .clipShape(Capsule())

                    Text(AppFormatters.relativeDateString(from: record.updatedAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            HStack(spacing: 8) {
                if hasValidFile {
                    rowActionButton(title: settings.t("action.openFile"), systemImage: "play.circle.fill", emphasized: true, action: onOpenFile)
                    rowActionButton(title: settings.t("action.showFinder"), systemImage: "folder", emphasized: false, action: onShowFinder)
                }

                if record.status == .queued || record.status == .downloading {
                    rowActionButton(title: settings.t("action.cancel"), systemImage: "xmark.circle", emphasized: false, action: onCancel)
                }

                if record.status == .failed || record.status == .cancelled {
                    rowActionButton(title: settings.t("action.retry"), systemImage: "arrow.clockwise", emphasized: false, action: onRetry)
                }

                Spacer(minLength: 0)

                Menu {
                    Button(settings.t("action.copySource"), action: onCopySource)
                    Button(settings.t("action.openBrowser"), action: onOpenBrowser)

                    if hasValidFile {
                        Divider()
                        Button(settings.t("action.openFile"), action: onOpenFile)
                        Button(settings.t("action.showFinder"), action: onShowFinder)
                        Button(settings.t("action.deleteFile"), action: onDeleteFile)
                    }

                    if record.status == .queued || record.status == .downloading {
                        Divider()
                        Button(settings.t("action.cancel"), action: onCancel)
                    }

                    if record.status == .failed || record.status == .cancelled {
                        Divider()
                        Button(settings.t("action.retry"), action: onRetry)
                    }

                    if record.status != .queued && record.status != .downloading {
                        Divider()
                        Button(settings.t("action.removeFromList"), action: onRemoveFromList)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "ellipsis.circle")
                        Text(settings.t("action.more"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
                }
                .menuStyle(.borderlessButton)
                .l2dHideMenuIndicatorIfAvailable()
                .fixedSize(horizontal: true, vertical: false)

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))

            if isExpanded {
                expandedDetails
            }

            if record.status == .downloading {
                if record.progress > 0.001 {
                    ProgressView(value: record.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        stageBadgeText(stageDisplayText)
                        Spacer()
                        Text("\(Int(record.progress * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let transferProgressLine {
                        Text(transferProgressLine)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(record.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        stageBadgeText(stageDisplayText)
                        Text(record.statusMessage.isEmpty ? settings.t("progress.preparing") : record.statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                    }
                    if let transferProgressLine {
                        Text(transferProgressLine)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            } else if record.status == .queued {
                ProgressView(value: 0.0)
                    .progressViewStyle(.linear)
                HStack {
                    Text(record.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(settings.t("row.status.queued"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            } else if record.status == .failed, let error = record.errorMessage {
                statusBanner(text: error, color: .red, systemImage: "exclamationmark.triangle.fill")
            } else if record.status == .cancelled {
                statusBanner(text: settings.t("row.status.cancelledHint"), color: .gray, systemImage: "xmark.circle.fill")
            } else if record.status == .completed && record.statusMessage != settings.t("row.status.completed") {
                statusBanner(text: record.statusMessage, color: .orange, systemImage: "exclamationmark.circle.fill")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isHovered ? Theme.accent.opacity(0.40) : Color.clear, lineWidth: 1.1)
        )
        .shadow(color: isHovered ? Color.black.opacity(0.08) : .clear, radius: 8, x: 0, y: 3)
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var hasValidFile: Bool {
        guard let path = record.filePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let path = record.thumbnailPath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 92, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent.opacity(0.15))
                .frame(width: 92, height: 54)
                .overlay(
                    Image(systemName: record.kind == .video ? "film" : "music.note")
                        .foregroundStyle(Theme.accentStrong)
                )
        }
    }

    private var fileNameLine: String {
        record.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? settings.t("meta.noFile")
    }

    private var transferProgressLine: String? {
        let downloaded = AppFormatters.sizeString(from: record.downloadedBytes)
        let total = AppFormatters.sizeString(from: record.totalBytes)
        let speed = AppFormatters.speedString(from: record.averageSpeedBytesPerSecond)

        var parts: [String] = []
        if record.downloadedBytes != nil && record.totalBytes != nil {
            parts.append("\(downloaded) \(settings.t("progress.stats.of")) \(total)")
        } else if record.totalBytes != nil {
            parts.append("\(settings.t("progress.stats.total")) \(total)")
        } else if record.downloadedBytes != nil {
            parts.append(downloaded)
        }

        if record.averageSpeedBytesPerSecond != nil {
            parts.append("\(settings.t("progress.stats.avg")) \(speed)")
        }

        if let eta = remainingTimeLine {
            parts.append("\(settings.t("progress.stats.left")) \(eta)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var remainingTimeLine: String? {
        guard let totalBytes = record.totalBytes,
              let downloadedBytes = record.downloadedBytes,
              let averageSpeed = record.averageSpeedBytesPerSecond,
              averageSpeed > 0,
              totalBytes > downloadedBytes else {
            return nil
        }

        let remainingBytes = Double(totalBytes - downloadedBytes)
        let remainingSeconds = remainingBytes / averageSpeed
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return nil }
        return AppFormatters.remainingTimeString(from: remainingSeconds)
    }

    private var statusText: String {
        switch record.status {
        case .queued: return settings.t("row.status.queued")
        case .downloading: return settings.t("row.status.downloading")
        case .completed: return settings.t("row.status.completed")
        case .failed: return settings.t("row.status.failed")
        case .cancelled: return settings.t("row.status.cancelled")
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .queued: return .orange
        case .downloading: return Theme.accentStrong
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private func rowActionButton(title: String, systemImage: String, emphasized: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(emphasized ? .white : Theme.accentStrong)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(emphasized ? Theme.accentStrong : Theme.accent.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
    }

    private var metadataBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                metaBadge(text: record.serviceName, systemImage: "globe")
                metaBadge(text: record.outputFormat, systemImage: "doc")
                metaBadge(text: record.qualityLabel, systemImage: "sparkles.tv")
                metaBadge(text: AppFormatters.durationString(from: record.durationSeconds), systemImage: "clock")
                metaBadge(text: AppFormatters.sizeString(from: record.fileSizeBytes), systemImage: "externaldrive")
            }
            .padding(.vertical, 1)
        }
        .allowsHitTesting(false)
    }

    private func metaBadge(text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func statusBanner(text: String, color: Color, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private var stageDisplayText: String {
        let stage = record.processingStage ?? .preparing
        return "\(settings.t("stage.label")): \(settings.label(for: stage))"
    }

    private func stageBadgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.accentStrong)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(0.16))
            )
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(title: settings.t("details.source"), value: record.sourceURL)
            detailRow(title: settings.t("details.file"), value: fileNameLine)
            detailRow(title: settings.t("details.updated"), value: AppFormatters.dateTimeString(from: record.updatedAt))

            HStack(spacing: 8) {
                rowActionButton(title: settings.t("action.copySource"), systemImage: "doc.on.doc", emphasized: false, action: onCopySource)
                rowActionButton(title: settings.t("action.openBrowser"), systemImage: "safari", emphasized: false, action: onOpenBrowser)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(title):")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct SettingsSheetView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.t("settings.title"))
                .font(.system(size: 20, weight: .bold))

            Group {
                row(title: settings.t("settings.language")) {
                    Picker("", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(settings.label(for: language)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                row(title: settings.t("settings.kind")) {
                    Picker("", selection: $settings.kind) {
                        ForEach(DownloadKind.allCases) { kind in
                            Text(settings.label(for: kind)).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                row(title: settings.t("settings.quality")) {
                    Picker("", selection: $settings.quality) {
                        ForEach(QualityPreset.userSelectableCases) { quality in
                            Text(settings.label(for: quality)).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                row(title: settings.t("settings.videoFormat")) {
                    Picker("", selection: $settings.videoFormat) {
                        ForEach(VideoFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                row(title: settings.t("settings.audioFormat")) {
                    Picker("", selection: $settings.audioFormat) {
                        ForEach(AudioFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                row(title: settings.t("settings.limit")) {
                    Picker("", selection: $settings.speedLimit) {
                        ForEach(SpeedLimitPreset.allCases) { speed in
                            Text(settings.label(for: speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                row(title: settings.t("settings.cookies")) {
                    Picker("", selection: $settings.cookieSource) {
                        ForEach(BrowserCookieSource.allCases) { source in
                            Text(settings.label(for: source)).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            Toggle(settings.t("toolbar.smart"), isOn: Binding(
                get: { settings.smartModeEnabled },
                set: { settings.setSmartMode($0) }
            ))
            .help(settings.t("smart.help"))
            Toggle(settings.t("settings.subtitles"), isOn: $settings.includeSubtitles)
            Toggle(settings.t("settings.audioTracks"), isOn: $settings.includeAdditionalAudioTracks)

            HStack {
                Text("\(settings.t("settings.path")): \(settings.displaySaveDirectory())")
                    .lineLimit(1)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }

            HStack {
                Button(settings.t("toolbar.resetDefaults")) {
                    settings.resetDefaults()
                }
                Spacer()
                Button(settings.t("settings.close")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .frame(width: 220, alignment: .leading)
            content()
            Spacer()
        }
    }
}

struct AboutSheetView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.t("about.title"))
                .font(.system(size: 20, weight: .bold))

            Divider()

            HStack {
                Text(settings.t("about.app"))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("Link2Download")
            }

            HStack {
                Text(settings.t("about.version"))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(appVersion)
            }

            HStack {
                Text(settings.t("about.developer"))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("Геннадий Захаров")
            }

            HStack {
                Text(settings.t("about.website"))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Link("zakharov.asia", destination: websiteURL)
            }

            HStack {
                Spacer()
                Button(settings.t("settings.close")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var appVersion: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "1.0"
    }

    private var websiteURL: URL {
        URL(string: "https://zakharov.asia/")!
    }
}

private extension View {
    @ViewBuilder
    func l2dHideMenuIndicatorIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.menuIndicator(.hidden)
        } else {
            self
        }
    }
}
