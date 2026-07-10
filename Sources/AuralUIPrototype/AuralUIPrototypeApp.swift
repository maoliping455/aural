import AppKit
import AuralCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class AuralAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async {
            AuralChildProcessRegistry.shared.terminateStaleAuralHelpers()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AuralChildProcessRegistry.shared.terminateAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AuralChildProcessRegistry.shared.terminateAll()
    }
}

@main
struct AuralUIPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AuralAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("") {
            AuralRootView()
                .background(AuralTitlebarInstaller())
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("本地转写设置...") {
                    NotificationCenter.default.post(name: .openAuralResourceSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private extension Notification.Name {
    static let openAuralResourceSettings = Notification.Name("io.github.maoliping455.aural.openResourceSettings")
}

struct AuralWindowTitleView: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: AuralTitleIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text("Aural")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityLabel("Aural")
    }
}

struct AuralTitlebarInstaller: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TitlebarInstallerView {
        let view = TitlebarInstallerView()
        view.onWindowAvailable = { window in
            context.coordinator.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: TitlebarInstallerView, context: Context) {
        if let window = nsView.window {
            context.coordinator.install(in: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var installedWindow: NSWindow?
        private weak var titleView: NSView?

        func install(in window: NSWindow) {
            guard installedWindow !== window else {
                return
            }

            window.title = ""
            window.titleVisibility = .hidden

            guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else {
                DispatchQueue.main.async { [weak self, weak window] in
                    if let window {
                        self?.install(in: window)
                    }
                }
                return
            }

            let identifier = NSUserInterfaceItemIdentifier("AuralWindowTitleView")
            if titlebarView.subviews.contains(where: { $0.identifier == identifier }) {
                installedWindow = window
                return
            }

            let hostingView = NSHostingView(rootView: AuralWindowTitleView())
            hostingView.identifier = identifier
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            titlebarView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
                hostingView.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor)
            ])

            self.titleView = hostingView
            self.installedWindow = window
        }
    }
}

@MainActor
final class TitlebarInstallerView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAvailable?(window)
        }
    }
}

enum AuralTitleIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()
}

private let supportedMediaExtensionsText = "支持 mp3、m4a、wav、aac、flac、mp4、mov、m4v"

private actor DroppedFileURLCollector {
    private var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }

    func values() -> [URL] {
        urls
    }
}

struct ImportFeedback: Equatable, Sendable {
    let id = UUID()
    let requestedCount: Int
    let importedCount: Int
    let unsupportedCount: Int
    let failedCount: Int

    var skippedCount: Int {
        unsupportedCount + failedCount
    }

    var hasIssue: Bool {
        skippedCount > 0 || importedCount == 0
    }

    var title: String {
        if importedCount > 0, skippedCount == 0 {
            return "已添加 \(importedCount) 个文件"
        }
        if importedCount > 0 {
            return "已添加 \(importedCount) 个文件，跳过 \(skippedCount) 个"
        }
        if unsupportedCount > 0, failedCount == 0 {
            return "未添加文件：格式不支持"
        }
        if failedCount > 0 {
            return "未添加文件：导入失败"
        }
        return "未添加文件"
    }

    var detail: String {
        var parts: [String] = []
        if unsupportedCount > 0 {
            parts.append("\(unsupportedCount) 个格式不支持")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) 个导入失败")
        }
        if parts.isEmpty {
            return "已加入本地转写队列"
        }
        return parts.joined(separator: "，") + "。\(supportedMediaExtensionsText)"
    }
}

private enum LocalResourceProbeResult: Sendable {
    case status(ModelResourceStatus)
    case ready
    case needsDownload(ModelResourceConfiguration)
}

@MainActor
final class AuralAppModel: ObservableObject {
    @Published var tasks: [TranscriptionTask] = []
    @Published var selectedTaskID: UUID?
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var isRunning = false
    @Published var importFeedback: ImportFeedback?
    @Published var resourceStatus: ModelResourceStatus = .checking
    @Published var isPreparingResources = false
    @Published var selectedModelProfile: ModelResourceProfile = RuntimePaths.selectedModelProfile()
    @Published var selectedAlignmentEnabled = RuntimePaths.selectedAlignmentEnabled()
    @Published var isShowingSettings = false

    private let dataRoot: URL
    private let workerURL: URL
    private let store: TaskStore
    private let queue: TranscriptionQueue
    private let processingRateStore: ProcessingRateStore
    private var smoothedProcessingSecondsPerAudioSecond = 0.08
    private var lastProcessingRateRefresh: Date?
    private let processingRateRefreshInterval: TimeInterval = 15
    private let processingRateSmoothingAlpha = 0.18
    private var pendingImportURLs: [URL] = []
    private var isImportingFiles = false
    private var modelDownloadBaselineBytes: UInt64?
    private var modelDownloadBaselineDate: Date?
    private var resourceRefreshTask: Task<Void, Never>?

    init() {
        let dataRoot = RuntimePaths.defaultDataRoot()
        let workerURL = RuntimePaths.defaultWorkerURL()

        self.dataRoot = dataRoot
        self.workerURL = workerURL
        self.store = TaskStore(rootURL: dataRoot)
        self.processingRateStore = ProcessingRateStore(rootURL: dataRoot)
        self.queue = TranscriptionQueue(
            store: store,
            workerClient: ASRWorkerClient(workerURL: workerURL)
        )
        if let storedRate = processingRateStore.load()?.secondsPerAudioSecond {
            self.smoothedProcessingSecondsPerAudioSecond = clampedProcessingRate(storedRate)
        }
        _ = try? store.recoverInterruptedTasks()
        _ = try? store.repairLocalAudioDurations()
        _ = try? store.repairFailedTasksWithValidTranscript()
        _ = try? store.repairInvalidCompletedTasks()
        reload(forceRateRefresh: true)
        refreshLocalResourceState()
    }

    var selectedTask: TranscriptionTask? {
        guard let selectedTaskID else {
            return tasks.first
        }
        return tasks.first(where: { $0.id == selectedTaskID }) ?? tasks.first
    }

    var isSelecting: Bool {
        !selectedTaskIDs.isEmpty
    }

    var allSelectableTasksSelected: Bool {
        let ids = selectableTaskIDs()
        return !ids.isEmpty && ids.isSubset(of: selectedTaskIDs)
    }

    var selectedTasks: [TranscriptionTask] {
        tasks.filter { selectedTaskIDs.contains($0.id) }
    }

    var canStopSelectedTasks: Bool {
        selectedTasks.contains { $0.status == .pending || $0.status == .running }
    }

    var canStartSelectedTasks: Bool {
        selectedTasks.contains { $0.status == .paused || $0.status == .failed }
    }

    var canDeleteSelectedTasks: Bool {
        !selectedTasks.isEmpty && !selectedTasks.contains { $0.status == .running }
    }

    var canExportSelectedTasks: Bool {
        selectedTasks.contains { isTaskExportable($0) }
    }

    var resourcesReady: Bool {
        resourceStatus.phase == .ready
    }

    var allowsModelProfileSelection: Bool {
        resourceStatus.phase == .needsDownload
            && !isPreparingResources
    }

    var allowsAlignmentSelection: Bool {
        resourceStatus.phase == .needsDownload
            && !isPreparingResources
    }

    func reload(forceRateRefresh: Bool = false) {
        do {
            let nextTasks = try store.load()
            let liveTaskIDs = Set(nextTasks.map(\.id))
            if tasks != nextTasks {
                tasks = nextTasks
            }

            let nextSelectedTaskIDs = selectedTaskIDs.intersection(liveTaskIDs)
            if nextSelectedTaskIDs != selectedTaskIDs {
                selectedTaskIDs = nextSelectedTaskIDs
            }

            let nextSelectedTaskID: UUID?
            if let selectedTaskID, liveTaskIDs.contains(selectedTaskID) {
                nextSelectedTaskID = selectedTaskID
            } else {
                nextSelectedTaskID = nextTasks.first?.id
            }
            if nextSelectedTaskID != selectedTaskID {
                selectedTaskID = nextSelectedTaskID
            }
            refreshProcessingRateIfNeeded(force: forceRateRefresh)
        } catch {
            if !tasks.isEmpty {
                tasks = []
            }
            if selectedTaskID != nil {
                selectedTaskID = nil
            }
            if !selectedTaskIDs.isEmpty {
                selectedTaskIDs.removeAll()
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        guard resourcesReady else {
            return
        }
        guard !urls.isEmpty else {
            return
        }

        pendingImportURLs.append(contentsOf: urls)
        guard !isImportingFiles else {
            return
        }

        isImportingFiles = true
        Task { [weak self] in
            await self?.drainImportQueue()
        }
    }

    private func drainImportQueue() async {
        while true {
            let urls = pendingImportURLs
            pendingImportURLs.removeAll()

            guard !urls.isEmpty else {
                isImportingFiles = false
                return
            }

            let feedback = await Self.importMediaFiles(urls, rootURL: store.rootURL)

            reload(forceRateRefresh: true)
            showImportFeedback(feedback)
            if feedback.importedCount > 0 {
                runQueue()
            }
        }
    }

    nonisolated private static func importMediaFiles(_ urls: [URL], rootURL: URL) async -> ImportFeedback {
        let importStore = TaskStore(rootURL: rootURL)
        var importedCount = 0
        var unsupportedCount = 0
        var failedCount = 0

        for url in urls {
            guard MediaFileType.isSupported(url) else {
                unsupportedCount += 1
                continue
            }

            do {
                _ = try await importStore.createTask(fromMediaURL: url)
                importedCount += 1
            } catch {
                failedCount += 1
            }
        }

        return ImportFeedback(
            requestedCount: urls.count,
            importedCount: importedCount,
            unsupportedCount: unsupportedCount,
            failedCount: failedCount
        )
    }

    func chooseFiles() {
        guard resourcesReady else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaFileType.supportedContentTypes
            .sorted { $0.identifier < $1.identifier }
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    func refreshLocalResourceState(prepareIfNeeded: Bool = false) {
        guard !isPreparingResources else {
            return
        }

        let configuration = RuntimePaths.selectedResourceConfiguration()
        selectedModelProfile = configuration.profile
        selectedAlignmentEnabled = configuration.alignmentEnabled

        resourceStatus = .checking
        resourceRefreshTask?.cancel()

        let profile = selectedModelProfile
        let alignmentEnabled = selectedAlignmentEnabled
        let model = self
        resourceRefreshTask = Task { [model, profile, alignmentEnabled, prepareIfNeeded] in
            let result = await Task.detached(priority: .utility) {
                Self.probeLocalResourceState(
                    profile: profile,
                    alignmentEnabled: alignmentEnabled
                )
            }.value
            guard !Task.isCancelled else {
                return
            }
            model.resourceRefreshTask = nil
            model.applyLocalResourceProbeResult(result, prepareIfNeeded: prepareIfNeeded)
        }
    }

    nonisolated private static func probeLocalResourceState(
        profile: ModelResourceProfile,
        alignmentEnabled: Bool
    ) -> LocalResourceProbeResult {
        if let compatibilityStatus = RuntimeCompatibility.blockingStatus() {
            return .status(compatibilityStatus)
        }

        let effectiveProfile = RuntimeCompatibility.effectiveProfile(profile)
        let configuration = ModelResourceConfiguration(
            profile: effectiveProfile,
            alignmentEnabled: alignmentEnabled
        )
        let preparer = ModelResourcePreparer(
            profile: effectiveProfile,
            alignmentEnabled: alignmentEnabled
        )
        if let runtimeStatus = preparer.runtimeProbeStatus() {
            return .status(runtimeStatus)
        }

        if preparer.resourcesAreReady() {
            return .ready
        }

        return .needsDownload(configuration)
    }

    private func applyLocalResourceProbeResult(
        _ result: LocalResourceProbeResult,
        prepareIfNeeded: Bool
    ) {
        guard !isPreparingResources else {
            return
        }

        switch result {
        case .status(let status):
            resourceStatus = status
        case .ready:
            resourceStatus = .ready
            runQueue()
        case .needsDownload(let configuration):
            selectedModelProfile = configuration.profile
            selectedAlignmentEnabled = configuration.alignmentEnabled
            resourceStatus = .needsDownload(
                configuration: configuration,
                allowsProfileSelection: true
            )
            if prepareIfNeeded {
                prepareLocalResources()
            }
        }
    }

    func prepareLocalResources() {
        guard !isPreparingResources else {
            return
        }
        guard !isRunning else {
            return
        }

        if let compatibilityStatus = RuntimeCompatibility.blockingStatus() {
            resourceStatus = compatibilityStatus
            return
        }

        let profile = RuntimeCompatibility.effectiveProfile(selectedModelProfile)
        selectedModelProfile = profile
        let configuration = ModelResourceConfiguration(
            profile: profile,
            alignmentEnabled: selectedAlignmentEnabled
        )
        do {
            try RuntimePaths.saveSelectedResourceConfiguration(configuration)
        } catch {
            resourceStatus = ModelResourceStatus(
                phase: .failed,
                title: "本地转写资源准备失败",
                detail: "无法保存本地模型选择，请检查磁盘权限后重试。"
            )
            return
        }

        resourceRefreshTask?.cancel()
        let preparer = ModelResourcePreparer(
            profile: profile,
            alignmentEnabled: selectedAlignmentEnabled
        )
        isPreparingResources = true
        modelDownloadBaselineBytes = nil
        modelDownloadBaselineDate = nil
        resourceStatus = .checking
        let model = self
        Task.detached(priority: .utility) { [model, preparer] in
            do {
                try preparer.prepare { event in
                    Task { @MainActor [model] in
                        model.handleModelResourceEvent(event)
                    }
                }
                await MainActor.run { [model] in
                    model.isPreparingResources = false
                    model.modelDownloadBaselineBytes = nil
                    model.modelDownloadBaselineDate = nil
                    model.resourceStatus = .ready
                    model.runQueue()
                }
            } catch {
                await MainActor.run { [model] in
                    model.isPreparingResources = false
                    model.modelDownloadBaselineBytes = nil
                    model.modelDownloadBaselineDate = nil
                    model.resourceStatus = model.resourcePreparationFailureStatus(for: error)
                }
            }
        }
    }

    private func resourcePreparationFailureStatus(for error: Error) -> ModelResourceStatus {
        if let preparerError = error as? ModelResourcePreparer.PreparerError,
           case .runtimeIncompatible = preparerError {
            return ModelResourceStatus(
                phase: .failed,
                title: "当前系统暂不支持本地转写",
                detail: "Aural 的本地转写运行时无法在当前系统加载。请升级 macOS，或安装兼容当前系统的 Aural 版本。",
                allowsRetry: false
            )
        }

        return ModelResourceStatus(
            phase: .failed,
            title: "本地转写资源准备失败",
            detail: "请检查网络后重试。已下载的部分会保留，下次会继续下载。"
        )
    }

    func selectModelProfile(_ profile: ModelResourceProfile) {
        guard allowsModelProfileSelection else {
            return
        }
        selectedModelProfile = RuntimeCompatibility.effectiveProfile(profile)
        resourceStatus = .needsDownload(
            configuration: ModelResourceConfiguration(
                profile: selectedModelProfile,
                alignmentEnabled: selectedAlignmentEnabled
            ),
            allowsProfileSelection: true
        )
    }

    func setAlignmentEnabled(_ enabled: Bool) {
        guard allowsAlignmentSelection else {
            return
        }
        selectedAlignmentEnabled = enabled
        resourceStatus = .needsDownload(
            configuration: ModelResourceConfiguration(
                profile: selectedModelProfile,
                alignmentEnabled: selectedAlignmentEnabled
            ),
            allowsProfileSelection: true
        )
    }

    func applyResourceConfiguration(
        profile: ModelResourceProfile,
        alignmentEnabled: Bool,
        prepareIfNeeded: Bool
    ) {
        guard !isRunning else {
            return
        }
        selectedModelProfile = RuntimeCompatibility.effectiveProfile(profile)
        selectedAlignmentEnabled = alignmentEnabled
        do {
            try RuntimePaths.saveSelectedResourceConfiguration(
                ModelResourceConfiguration(
                    profile: selectedModelProfile,
                    alignmentEnabled: selectedAlignmentEnabled
                )
            )
        } catch {
            resourceStatus = ModelResourceStatus(
                phase: .failed,
                title: "本地转写资源准备失败",
                detail: "无法保存本地模型选择，请检查磁盘权限后重试。"
            )
            return
        }

        refreshLocalResourceState(prepareIfNeeded: prepareIfNeeded)
    }

    private func handleModelResourceEvent(_ event: ModelResourceEvent) {
        switch event.type {
        case "checking":
            resourceStatus = .checking
        case "download_started":
            resourceStatus = ModelResourceStatus(
                phase: .downloading,
                title: "正在准备本地模型",
                detail: "",
                progressFraction: resourceStatus.progressFraction,
                remainingTimeText: resourceStatus.remainingTimeText
            )
        case "download_progress":
            let progress = event.progress.map { min(max($0, 0), 1) }
            let remainingTimeText = estimatedModelDownloadRemainingTimeText(for: event)
            resourceStatus = ModelResourceStatus(
                phase: .downloading,
                title: "正在准备本地模型",
                detail: "",
                progressFraction: progress,
                remainingTimeText: remainingTimeText
            )
        case "download_retry":
            resourceStatus = ModelResourceStatus(
                phase: .downloading,
                title: "正在准备本地模型",
                detail: "",
                progressFraction: resourceStatus.progressFraction,
                remainingTimeText: resourceStatus.remainingTimeText
            )
        case "model_ready":
            resourceStatus = ModelResourceStatus(
                phase: .downloading,
                title: "正在准备本地模型",
                detail: "",
                progressFraction: resourceStatus.progressFraction,
                remainingTimeText: resourceStatus.remainingTimeText
            )
        case "completed":
            resourceStatus = .ready
        case "failed":
            resourceStatus = ModelResourceStatus(
                phase: .failed,
                title: "本地转写资源准备失败",
                detail: "请检查网络后重试。已下载的部分会保留，下次会继续下载。"
            )
        default:
            break
        }
    }

    private func estimatedModelDownloadRemainingTimeText(for event: ModelResourceEvent) -> String? {
        guard let downloadedBytes = event.downloadedBytes,
              let totalBytes = event.totalBytes,
              totalBytes > downloadedBytes else {
            return nil
        }

        let now = Date()
        if modelDownloadBaselineBytes == nil
            || modelDownloadBaselineDate == nil
            || downloadedBytes < (modelDownloadBaselineBytes ?? 0)
        {
            modelDownloadBaselineBytes = downloadedBytes
            modelDownloadBaselineDate = now
            return nil
        }

        guard let baselineBytes = modelDownloadBaselineBytes,
              let baselineDate = modelDownloadBaselineDate else {
            return nil
        }

        let elapsedSeconds = now.timeIntervalSince(baselineDate)
        let downloadedDelta = downloadedBytes > baselineBytes ? downloadedBytes - baselineBytes : 0
        guard elapsedSeconds >= 2, downloadedDelta > 1_000_000 else {
            return nil
        }

        let bytesPerSecond = Double(downloadedDelta) / elapsedSeconds
        guard bytesPerSecond > 0 else {
            return nil
        }

        let remainingBytes = totalBytes - downloadedBytes
        let remainingSeconds = Double(remainingBytes) / bytesPerSecond
        guard remainingSeconds.isFinite, remainingSeconds >= 0 else {
            return nil
        }

        return formatDownloadRemainingTime(remainingSeconds)
    }

    private func formatDownloadRemainingTime(_ seconds: TimeInterval) -> String {
        let roundedSeconds = max(1, Int(seconds.rounded()))
        if roundedSeconds < 60 {
            return "还需 \(roundedSeconds) 秒"
        }

        let minutes = roundedSeconds / 60
        let secondsPart = roundedSeconds % 60
        if minutes < 60 {
            return "还需 \(minutes) 分 \(secondsPart) 秒"
        }

        let hours = minutes / 60
        let minutesPart = minutes % 60
        return "还需 \(hours) 小时 \(minutesPart) 分"
    }

    private func showImportFeedback(_ feedback: ImportFeedback) {
        guard feedback.requestedCount > 0 else {
            return
        }

        importFeedback = feedback
        let feedbackID = feedback.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            await MainActor.run {
                guard self?.importFeedback?.id == feedbackID else {
                    return
                }
                self?.importFeedback = nil
            }
        }
    }

    func isTaskSelectable(_ task: TranscriptionTask) -> Bool {
        true
    }

    func isTaskChecked(_ task: TranscriptionTask) -> Bool {
        selectedTaskIDs.contains(task.id)
    }

    func toggleTaskSelection(_ task: TranscriptionTask) {
        guard isTaskSelectable(task) else {
            return
        }

        if selectedTaskIDs.contains(task.id) {
            selectedTaskIDs.remove(task.id)
        } else {
            selectedTaskIDs.insert(task.id)
        }
    }

    func toggleAllSelectableTasks() {
        let ids = selectableTaskIDs()
        guard !ids.isEmpty else {
            return
        }

        if ids.isSubset(of: selectedTaskIDs) {
            selectedTaskIDs.subtract(ids)
        } else {
            selectedTaskIDs.formUnion(ids)
        }
    }

    func clearTaskSelection() {
        selectedTaskIDs.removeAll()
    }

    func statusLabel(for task: TranscriptionTask) -> String {
        switch task.status {
        case .pending:
            guard let estimate = estimatedTranscriptionDuration(for: task) else {
                return task.status.displayName
            }
            return "\(task.status.displayName) 约 \(formatEstimateDuration(estimate))"
        case .running:
            let progress = min(max(task.progressFraction ?? 0, 0), 0.99)
            return "\(runningStageLabel(task.progressStage)) \(Int((progress * 100).rounded()))%"
        case .paused, .done, .failed:
            return task.status.displayName
        }
    }

    private func runningStageLabel(_ stage: String?) -> String {
        switch stage {
        case "preparing", "normalizing", "reading_audio", "segmenting":
            return "准备音频"
        case "loading":
            return "加载模型"
        case "aligning":
            return "对齐时间戳"
        default:
            return TranscriptionStatus.running.displayName
        }
    }

    func stopSelectedTasks() {
        _ = try? store.stopTasks(ids: selectedTaskIDs)
        reload()
    }

    func startSelectedTasks() {
        _ = try? store.startTasks(ids: selectedTaskIDs)
        reload(forceRateRefresh: true)
        runQueue()
    }

    func deleteSelectedTasks() {
        guard canDeleteSelectedTasks else {
            return
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let deletableIDs = selectedTaskIDs.filter { id in
            tasksByID[id]?.status != .running
        }

        for id in deletableIDs {
            try? store.deleteTask(id: id)
        }

        selectedTaskIDs.subtract(deletableIDs)
        reload()
    }

    func exportSelectedTranscripts(format: TranscriptExportFormat) {
        let exportableTasks = selectedTasks.filter(isTaskExportable)
        guard !exportableTasks.isEmpty else {
            return
        }

        if exportableTasks.count == 1, let task = exportableTasks.first {
            exportSingleTranscript(task, format: format)
        } else {
            exportMultipleTranscripts(exportableTasks, format: format)
        }
    }

    func renameTask(_ task: TranscriptionTask, to filename: String) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.filename else {
            return
        }
        try? store.renameTask(id: task.id, filename: trimmed)
        reload()
    }

    private func isTaskExportable(_ task: TranscriptionTask) -> Bool {
        guard task.status == .done, let transcriptPath = task.transcriptPath else {
            return false
        }
        return FileManager.default.fileExists(atPath: transcriptPath)
    }

    private func exportSingleTranscript(_ task: TranscriptionTask, format: TranscriptExportFormat) {
        let panel = NSSavePanel()
        panel.title = "导出转写"
        panel.prompt = "导出"
        panel.allowedContentTypes = [contentType(for: format)]
        panel.nameFieldStringValue = exportFilename(for: task, format: format)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? writeTranscriptExport(for: task, format: format, to: url)
    }

    private func exportMultipleTranscripts(_ tasks: [TranscriptionTask], format: TranscriptExportFormat) {
        let panel = NSOpenPanel()
        panel.title = "选择导出位置"
        panel.prompt = "导出"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        for task in tasks {
            let destinationURL = uniqueExportURL(
                in: folderURL,
                preferredFilename: exportFilename(for: task, format: format)
            )
            try? writeTranscriptExport(for: task, format: format, to: destinationURL)
        }
    }

    private func writeTranscriptExport(for task: TranscriptionTask, format: TranscriptExportFormat, to url: URL) throws {
        guard let transcriptPath = task.transcriptPath else {
            return
        }
        let transcript = TranscriptCleanup.removingExcessiveRepetition(
            from: try TranscriptStore.load(from: URL(fileURLWithPath: transcriptPath))
        )
        let text = TranscriptExportRenderer.render(transcript, format: format)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func contentType(for format: TranscriptExportFormat) -> UTType {
        switch format {
        case .srt:
            return UTType(filenameExtension: format.fileExtension) ?? .plainText
        case .plainText, .timestampedText:
            return .plainText
        }
    }

    private func exportFilename(for task: TranscriptionTask, format: TranscriptExportFormat) -> String {
        let baseName = task.filename
            .replacingOccurrences(of: "\\.[^./\\\\]+$", with: "", options: .regularExpression)
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let safeName = baseName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = safeName.isEmpty ? task.id.uuidString : safeName
        return "\(filename)\(format.filenameSuffix).\(format.fileExtension)"
    }

    private func uniqueExportURL(in folderURL: URL, preferredFilename: String) -> URL {
        let baseURL = folderURL.appendingPathComponent(preferredFilename)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        for index in 2...999 {
            let candidate = folderURL.appendingPathComponent("\(name)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return folderURL.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
    }

    func runQueue() {
        guard resourcesReady else {
            return
        }
        guard ModelResourcePreparer(
            profile: selectedModelProfile,
            alignmentEnabled: selectedAlignmentEnabled
        ).resourcesAreReady() else {
            refreshLocalResourceState(prepareIfNeeded: true)
            return
        }
        guard !isRunning else {
            return
        }
        isRunning = true
        let dataRoot = dataRoot
        let workerURL = workerURL
        Task {
            let refreshTask = Task { @MainActor in
                while !Task.isCancelled {
                    reload()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    let backgroundStore = TaskStore(rootURL: dataRoot)
                    let backgroundQueue = TranscriptionQueue(
                        store: backgroundStore,
                        workerClient: ASRWorkerClient(workerURL: workerURL)
                    )
                    return try backgroundQueue.drainPendingTasks()
                }.value
            } catch {
                // The task itself is marked failed by TranscriptionQueue.
            }
            refreshTask.cancel()
            isRunning = false
            reload(forceRateRefresh: true)
        }
    }

    private func selectableTaskIDs() -> Set<UUID> {
        Set(tasks.filter(isTaskSelectable).map(\.id))
    }

    private func estimatedTranscriptionDuration(for task: TranscriptionTask) -> TimeInterval? {
        guard task.status == .pending, task.durationSec > 0 else {
            return nil
        }
        return task.durationSec * smoothedProcessingSecondsPerAudioSecond
    }

    private func refreshProcessingRateIfNeeded(force: Bool = false, now: Date = Date()) {
        if
            !force,
            let lastProcessingRateRefresh,
            now.timeIntervalSince(lastProcessingRateRefresh) < processingRateRefreshInterval
        {
            return
        }

        guard let sample = currentProcessingRateSample(now: now) ?? historicalProcessingRateSample() else {
            lastProcessingRateRefresh = now
            return
        }

        let clampedSample = clampedProcessingRate(sample)
        if lastProcessingRateRefresh == nil {
            smoothedProcessingSecondsPerAudioSecond = clampedSample
        } else {
            smoothedProcessingSecondsPerAudioSecond =
                smoothedProcessingSecondsPerAudioSecond * (1 - processingRateSmoothingAlpha)
                + clampedSample * processingRateSmoothingAlpha
        }
        persistProcessingRate()
        lastProcessingRateRefresh = now
    }

    private func currentProcessingRateSample(now: Date) -> Double? {
        if
            let running = tasks.first(where: { $0.status == .running }),
            let startedAt = running.startedAt,
            let progress = running.progressFraction,
            progress >= 0.08,
            running.durationSec > 0
        {
            let processedAudioSeconds = running.durationSec * progress
            let elapsedSeconds = now.timeIntervalSince(startedAt)
            if processedAudioSeconds > 5, elapsedSeconds > 1 {
                return elapsedSeconds / processedAudioSeconds
            }
        }
        return nil
    }

    private func historicalProcessingRateSample() -> Double? {
        let historicalRates = tasks.compactMap { task -> Double? in
            guard
                task.status == .done,
                task.durationSec > 0,
                let startedAt = task.startedAt,
                let completedAt = task.completedAt
            else {
                return nil
            }

            let elapsedSeconds = completedAt.timeIntervalSince(startedAt)
            guard elapsedSeconds > 0 else {
                return nil
            }
            return elapsedSeconds / task.durationSec
        }
        guard !historicalRates.isEmpty else { return nil }

        let sortedRates = historicalRates.sorted()
        return sortedRates[sortedRates.count / 2]
    }

    private func clampedProcessingRate(_ rate: Double) -> Double {
        min(max(rate, 0.03), 0.5)
    }

    private func persistProcessingRate() {
        let snapshot = ProcessingRateSnapshot(
            secondsPerAudioSecond: smoothedProcessingSecondsPerAudioSecond
        )
        try? processingRateStore.save(snapshot)
    }
}

struct AuralRootView: View {
    @StateObject private var model = AuralAppModel()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                TaskListPane(model: model)
                    .frame(minWidth: 460, idealWidth: 580, maxWidth: 780)

                Divider()

                TaskDetailPane(
                    task: model.selectedTask,
                    statusText: model.selectedTask.map { model.statusLabel(for: $0) },
                    onChooseFiles: model.chooseFiles,
                    onRename: { task, filename in
                        model.renameTask(task, to: filename)
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !model.resourcesReady {
                ModelResourceGateView(
                    status: model.resourceStatus,
                    isPreparing: model.isPreparingResources,
                    selectedProfile: model.selectedModelProfile,
                    alignmentEnabled: model.selectedAlignmentEnabled,
                    allowsProfileSelection: model.allowsModelProfileSelection,
                    allowsAlignmentSelection: model.allowsAlignmentSelection,
                    onSelectProfile: model.selectModelProfile,
                    onSetAlignmentEnabled: model.setAlignmentEnabled,
                    onPrimaryAction: model.prepareLocalResources
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            ResourceSettingsView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAuralResourceSettings)) { _ in
            model.isShowingSettings = true
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ModelResourceGateView: View {
    let status: ModelResourceStatus
    let isPreparing: Bool
    let selectedProfile: ModelResourceProfile
    let alignmentEnabled: Bool
    let allowsProfileSelection: Bool
    let allowsAlignmentSelection: Bool
    let onSelectProfile: (ModelResourceProfile) -> Void
    let onSetAlignmentEnabled: (Bool) -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(nsImage: AuralTitleIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(status.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !status.detail.isEmpty {
                        Text(status.detail)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(maxWidth: 520)
                    }
                }

                if status.phase == .downloading {
                    VStack(spacing: 8) {
                        ProgressView(value: status.progressFraction ?? 0, total: 1)
                            .progressViewStyle(.linear)
                            .frame(width: 360)
                        Text(progressText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                } else if status.phase == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                } else if status.phase == .needsDownload {
                    VStack(spacing: 14) {
                        if allowsProfileSelection {
                            HStack(spacing: 10) {
                                ForEach(ModelResourceProfile.allCases, id: \.self) { profile in
                                    ModelProfileOptionView(
                                        profile: profile,
                                        isSelected: profile == selectedProfile,
                                        isEnabled: profile.isAvailable(),
                                        onSelect: { onSelectProfile(profile) }
                                    )
                                }
                            }
                            .frame(width: 560)
                        }

                        AlignmentOptionRow(
                            isEnabled: alignmentEnabled,
                            isInteractive: allowsAlignmentSelection,
                            onChange: onSetAlignmentEnabled
                        )
                        .frame(width: allowsProfileSelection ? 560 : 420)

                        Button(action: onPrimaryAction) {
                            Text("开始准备")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(minWidth: 116)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing)
                    }
                } else if status.phase == .failed, status.allowsRetry {
                    Button(action: onPrimaryAction) {
                        Text("重试")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)
                } else if status.phase == .failed {
                    Text("请关注后续版本")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
    }

    private var progressText: String {
        let value = min(max(status.progressFraction ?? 0, 0), 1)
        let percent = "\(Int((value * 100).rounded()))%"
        if status.phase == .downloading {
            let remainingTimeText = status.remainingTimeText ?? "正在估算"
            return "\(percent)  (\(remainingTimeText))"
        }
        return percent
    }
}

private struct ModelProfileOptionView: View {
    let profile: ModelResourceProfile
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: {
            guard isEnabled else {
                return
            }
            onSelect()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                }

                Text(profile.shortDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(profile.estimatedDownloadText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if !isEnabled {
                    Text("需要 16GB 及以上内存")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.48)
        .disabled(!isEnabled)
    }
}

private struct AlignmentOptionRow: View {
    let isEnabled: Bool
    let isInteractive: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { onChange($0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("字幕时间戳对齐")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("推荐开启，播放和字幕定位更准确。关闭后下载更少，速度更快。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!isInteractive)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

struct ResourceSettingsView: View {
    @ObservedObject var model: AuralAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftProfile: ModelResourceProfile
    @State private var draftAlignmentEnabled: Bool

    init(model: AuralAppModel) {
        self.model = model
        _draftProfile = State(initialValue: model.selectedModelProfile)
        _draftAlignmentEnabled = State(initialValue: model.selectedAlignmentEnabled)
    }

    var body: some View {
        let isEditable = !model.isRunning && !model.isPreparingResources

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("本地转写设置")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("默认模型")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(ModelResourceProfile.allCases, id: \.self) { profile in
                        ModelProfileOptionView(
                            profile: profile,
                            isSelected: profile == draftProfile,
                            isEnabled: isEditable && profile.isAvailable(),
                            onSelect: { draftProfile = profile }
                        )
                    }
                }
            }

            AlignmentOptionRow(
                isEnabled: draftAlignmentEnabled,
                isInteractive: isEditable,
                onChange: { draftAlignmentEnabled = $0 }
            )

            HStack {
                Text(isEditable ? "缺失的资源会在准备时下载，已下载资源会保留并复用。" : "正在转写时暂不能修改本地模型设置。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存并准备") {
                    apply(prepareIfNeeded: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isEditable)
            }
        }
        .padding(24)
        .frame(width: 660)
    }

    private func apply(prepareIfNeeded: Bool) {
        model.applyResourceConfiguration(
            profile: draftProfile,
            alignmentEnabled: draftAlignmentEnabled,
            prepareIfNeeded: prepareIfNeeded
        )
    }
}

struct TaskListPane: View {
    @ObservedObject var model: AuralAppModel
    @State private var isHeaderHovered = false
    @State private var isDropTargeted = false
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                DropAreaView(model: model, isTargeted: isDropTargeted)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                if let feedback = model.importFeedback {
                    ImportFeedbackBanner(feedback: feedback)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(spacing: 8) {
                    TaskSearchField(text: $searchText)
                    Button(action: { model.isShowingSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    }
                    .help("本地转写设置")
                }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)

                HStack(spacing: 12) {
                    SelectionCheckbox(
                        isVisible: model.isSelecting || isHeaderHovered,
                        isChecked: allVisibleTasksSelected,
                        isEnabled: !visibleTasks.isEmpty,
                        action: toggleVisibleTasksSelection
                    )
                    Text("全部")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("状态")
                        .frame(width: 132, alignment: .leading)
                    Text("创建时间")
                        .frame(width: 86, alignment: .leading)
                    Text("时长")
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .onHover { isHeaderHovered = $0 }

                Divider()
                    .padding(.horizontal, 24)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        if visibleTasks.isEmpty, !normalizedSearchText.isEmpty {
                            Text("没有匹配的文件")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if model.tasks.isEmpty {
                            EmptyTaskListState()
                        }

                        ForEach(visibleTasks) { task in
                            TaskRowView(
                                task: task,
                                isSelected: model.selectedTask?.id == task.id,
                                isSelecting: model.isSelecting,
                                isChecked: model.isTaskChecked(task),
                                isSelectable: model.isTaskSelectable(task),
                                onSelectTask: {
                                    model.selectedTaskID = task.id
                                },
                                onToggleChecked: {
                                    model.toggleTaskSelection(task)
                                },
                                statusText: model.statusLabel(for: task),
                                onRename: { filename in
                                    model.renameTask(task, to: filename)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, model.isSelecting ? 82 : 24)
                }
            }

            if model.isSelecting {
                SelectionActionBar(
                    count: model.selectedTaskIDs.count,
                    canStop: model.canStopSelectedTasks,
                    canStart: model.canStartSelectedTasks,
                    canExport: model.canExportSelectedTasks,
                    canDelete: model.canDeleteSelectedTasks,
                    onStop: model.stopSelectedTasks,
                    onStart: model.startSelectedTasks,
                    onExport: { format in
                        model.exportSelectedTranscripts(format: format)
                    },
                    onDelete: model.deleteSelectedTasks,
                    onCancel: model.clearTaskSelection
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            importDroppedFiles(from: providers)
            return true
        }
        .animation(.easeInOut(duration: 0.16), value: model.isSelecting)
        .animation(.easeInOut(duration: 0.18), value: model.importFeedback)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTasks: [TranscriptionTask] {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            return model.tasks
        }
        return model.tasks.filter { task in
            task.filename.localizedStandardContains(query)
        }
    }

    private var visibleTaskIDs: Set<UUID> {
        Set(visibleTasks.filter(model.isTaskSelectable).map(\.id))
    }

    private var allVisibleTasksSelected: Bool {
        !visibleTaskIDs.isEmpty && visibleTaskIDs.isSubset(of: model.selectedTaskIDs)
    }

    private func toggleVisibleTasksSelection() {
        guard !visibleTaskIDs.isEmpty else {
            return
        }
        if visibleTaskIDs.isSubset(of: model.selectedTaskIDs) {
            model.selectedTaskIDs.subtract(visibleTaskIDs)
        } else {
            model.selectedTaskIDs.formUnion(visibleTaskIDs)
        }
    }

    private func importDroppedFiles(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collector = DroppedFileURLCollector()

        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard
                    let data,
                    let path = String(data: data, encoding: .utf8),
                    let url = URL(string: path)
                else {
                    group.leave()
                    return
                }

                Task {
                    await collector.append(url)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            Task {
                let urls = await collector.values()
                guard !urls.isEmpty else {
                    return
                }
                await MainActor.run {
                    model.addFiles(urls)
                }
            }
        }
    }
}

struct TaskSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索文件名", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

struct DropAreaView: View {
    @ObservedObject var model: AuralAppModel
    let isTargeted: Bool

    var body: some View {
        Button(action: model.chooseFiles) {
            HStack(spacing: 10) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isTargeted ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("拖入音频/视频 或 点击添加")
                        .font(.system(size: 15, weight: .semibold))
                    Text(supportedMediaExtensionsText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(isTargeted ? Color.blue.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(isTargeted ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.28))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help("选择或拖入文件。\(supportedMediaExtensionsText)")
    }
}

struct ImportFeedbackBanner: View {
    let feedback: ImportFeedback

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: feedback.hasIssue ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(feedback.hasIssue ? .orange : .green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(feedback.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.74))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke((feedback.hasIssue ? Color.orange : Color.green).opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyTaskListState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("还没有转写任务")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("拖入音频或视频后，Aural 会在本机创建转写队列。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(supportedMediaExtensionsText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 24)
    }
}

struct TaskRowView: View {
    let task: TranscriptionTask
    let isSelected: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let isSelectable: Bool
    let onSelectTask: () -> Void
    let onToggleChecked: () -> Void
    let statusText: String
    let onRename: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            SelectionCheckbox(
                isVisible: (isSelecting || isHovered) && isSelectable,
                isChecked: isChecked,
                isEnabled: isSelectable,
                action: onToggleChecked
            )
            VStack(alignment: .leading, spacing: 5) {
                EditableTaskTitle(
                    title: task.filename,
                    font: .system(size: 15, weight: .medium),
                    editorFont: .systemFont(ofSize: 15, weight: .medium),
                    isEditButtonVisible: isHovered,
                    editIconSize: 13,
                    editButtonSize: 22,
                    onRename: onRename
                )
                .layoutPriority(1)
            }
            .layoutPriority(1)
            Spacer()
            StatusPill(status: task.status, text: statusText)
                .frame(width: 132, alignment: .leading)
            Text(formatCreatedAt(task.createdAt))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(formatDuration(task.durationSec))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(isSelected ? Color.blue.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectTask)
        .onHover { isHovered = $0 }
    }
}

struct EditableTaskTitle: View {
    let title: String
    let font: Font
    let editorFont: NSFont
    let isEditButtonVisible: Bool
    let editIconSize: CGFloat
    let editButtonSize: CGFloat
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                RenameCommitTextField(
                    text: $draft,
                    font: editorFont,
                    onCommit: commit,
                    onCancel: cancel
                )
                    .focused($isFieldFocused)
                    .frame(height: max(28, editorFont.pointSize + 12))
                    .onAppear {
                        draft = title
                        DispatchQueue.main.async {
                            isFieldFocused = true
                        }
                    }
                    .onChange(of: isFieldFocused) {
                        if !isFieldFocused {
                            commit()
                        }
                    }
            } else {
                Text(title)
                    .font(font)
                    .lineLimit(1)
                    .help(title)
                if isEditButtonVisible {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: editIconSize, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.blue.opacity(0.86))
                            .frame(width: editButtonSize, height: editButtonSize)
                    }
                    .buttonStyle(.plain)
                    .help("重命名")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: title) {
            if !isEditing {
                draft = title
            }
        }
    }

    private func beginEditing() {
        draft = title
        isEditing = true
    }

    private func commit() {
        guard isEditing else {
            return
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        isFieldFocused = false
        if !trimmed.isEmpty, trimmed != title {
            onRename(trimmed)
        } else {
            draft = title
        }
    }

    private func cancel() {
        draft = title
        isEditing = false
        isFieldFocused = false
    }
}

private struct RenameCommitTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = font
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        let isComposingMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !context.coordinator.isEditing, !isComposingMarkedText, field.stringValue != text {
            field.stringValue = text
        }
        if field.font != font {
            field.font = font
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onCancel: () -> Void
        private var didCancel = false
        var isEditing = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            if didCancel {
                didCancel = false
                return
            }
            commit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                text.wrappedValue = textView.string
                commit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                didCancel = true
                onCancel()
                return true
            default:
                return false
            }
        }

        @objc func commit() {
            onCommit()
        }
    }
}

struct SelectionCheckbox: View {
    let isVisible: Bool
    let isChecked: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(borderColor, lineWidth: 1.4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isChecked ? Color.blue : Color.clear)
                )
                .frame(width: 18, height: 18)
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .opacity(isVisible ? (isEnabled ? 1 : 0.35) : 0)
        .allowsHitTesting(isVisible && isEnabled)
        .onTapGesture(perform: action)
        .help(isChecked ? "取消选择" : "选择")
    }

    private var borderColor: Color {
        if isChecked {
            return .blue
        }
        return Color.secondary.opacity(0.55)
    }
}

struct SelectionActionBar: View {
    let count: Int
    let canStop: Bool
    let canStart: Bool
    let canExport: Bool
    let canDelete: Bool
    let onStop: () -> Void
    let onStart: () -> Void
    let onExport: (TranscriptExportFormat) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("已选择 \(count) 项")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if canStop {
                SelectionActionButton(
                    title: "停止",
                    systemImage: "stop.fill",
                    tint: .orange,
                    action: onStop
                )
            }
            if canStart {
                SelectionActionButton(
                    title: "开始",
                    systemImage: "play.fill",
                    tint: .blue,
                    action: onStart
                )
            }
            if canExport {
                SelectionExportMenu(onExport: onExport)
            }
            SelectionActionButton(
                title: "删除",
                systemImage: "trash",
                tint: .red,
                isEnabled: canDelete,
                action: onDelete
            )
            SelectionActionButton(
                title: "取消",
                systemImage: "xmark",
                tint: .secondary,
                action: onCancel
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.16))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.10), radius: 16, y: 8)
    }
}

struct SelectionExportMenu: View {
    let onExport: (TranscriptExportFormat) -> Void

    var body: some View {
        Menu {
            ForEach(TranscriptExportFormat.allCases, id: \.rawValue) { format in
                Button(format.displayName) {
                    onExport(format)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                Text("导出")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.72)
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.blue.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("选择导出格式")
    }
}

struct SelectionActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .allowsHitTesting(isEnabled)
    }
}

struct StatusPill: View {
    let status: TranscriptionStatus
    let text: String

    init(status: TranscriptionStatus, text: String? = nil) {
        self.status = status
        self.text = text ?? status.displayName
    }

    var body: some View {
        HStack(spacing: 5) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(iconForeground)
            }
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background)
        .clipShape(Capsule())
    }

    private var iconName: String? {
        switch status {
        case .done:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .running:
            "waveform"
        case .paused:
            "pause.fill"
        case .pending:
            nil
        }
    }

    private var iconForeground: Color {
        switch status {
        case .done:
            Color.green.opacity(0.72)
        case .failed:
            .red
        case .running:
            .blue
        case .paused:
            .orange
        case .pending:
            .secondary
        }
    }

    private var foreground: Color {
        switch status {
        case .pending:
            .secondary
        case .running:
            .blue
        case .paused:
            .orange
        case .done:
            .secondary
        case .failed:
            .red
        }
    }

    private var background: Color {
        switch status {
        case .pending:
            Color.secondary.opacity(0.12)
        case .running:
            Color.blue.opacity(0.12)
        case .paused:
            Color.orange.opacity(0.14)
        case .done:
            Color.secondary.opacity(0.08)
        case .failed:
            Color.red.opacity(0.12)
        }
    }
}

struct TaskDetailPane: View {
    let task: TranscriptionTask?
    let statusText: String?
    let onChooseFiles: () -> Void
    let onRename: (TranscriptionTask, String) -> Void
    @State private var isTitleHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let task {
                HStack(alignment: .firstTextBaseline) {
                    EditableTaskTitle(
                        title: task.filename,
                        font: .system(size: 22, weight: .semibold),
                        editorFont: .systemFont(ofSize: 22, weight: .semibold),
                        isEditButtonVisible: isTitleHovered,
                        editIconSize: 17,
                        editButtonSize: 28,
                        onRename: { filename in
                            onRename(task, filename)
                        }
                    )
                    .onHover { isTitleHovered = $0 }
                    Spacer()
                    StatusPill(status: task.status, text: statusText)
                }

                Divider()

                TaskPlaybackTranscriptSection(task: task)
            } else {
                Spacer()
                AuralEmptyDetailView(onChooseFiles: onChooseFiles)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(32)
    }
}

private struct TaskPlaybackTranscriptSection: View {
    let task: TranscriptionTask
    @State private var playbackTime: TimeInterval = 0
    @State private var isPlaybackActive = false
    @State private var transcriptFocus: TranscriptFocus?
    @State private var selectedDetailTab: TaskDetailTab = .transcript
    @State private var playbackSeekRequest: PlaybackSeekRequest?

    var body: some View {
        AudioPlayerShell(
            task: task,
            seekRequest: playbackSeekRequest,
            onPlaybackTimeChange: { playbackTime = $0 },
            onPlaybackStateChange: { isPlaybackActive = $0 },
            onSeekCommitted: { transcriptFocus = TranscriptFocus(time: $0) }
        )

        VStack(alignment: .leading, spacing: 14) {
            TaskDetailTabBar(selectedTab: $selectedDetailTab)

            switch selectedDetailTab {
            case .transcript:
                TranscriptPreview(
                    task: task,
                    currentTime: playbackTime,
                    isPlaybackActive: isPlaybackActive,
                    focus: transcriptFocus,
                    onSeekToTime: seekToTranscriptTime
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: task.id) {
            playbackTime = 0
            isPlaybackActive = false
            transcriptFocus = nil
            playbackSeekRequest = nil
            selectedDetailTab = .transcript
        }
    }

    private func seekToTranscriptTime(_ time: TimeInterval) {
        playbackSeekRequest = PlaybackSeekRequest(time: time)
        transcriptFocus = TranscriptFocus(time: time)
    }
}

enum TaskDetailTab: String, CaseIterable {
    case transcript = "转写"
}

struct TaskDetailTabBar: View {
    @Binding var selectedTab: TaskDetailTab

    var body: some View {
        HStack(spacing: 18) {
            ForEach(TaskDetailTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                        Capsule()
                            .fill(selectedTab == tab ? Color.blue : Color.clear)
                            .frame(width: 34, height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(tab.rawValue))
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.top, 2)
        .overlay(alignment: .bottom) {
            Divider()
                .offset(y: 1)
        }
    }
}

struct AuralEmptyDetailView: View {
    let onChooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 38, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("添加音频或视频开始本地转写")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            Text("文件会复制到 Aural 的本地任务目录，转写完成后可在这里播放和阅读结果。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onChooseFiles) {
                Label("选择文件", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            Text(supportedMediaExtensionsText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TranscriptFocus: Equatable {
    let id = UUID()
    let time: TimeInterval
}

struct PlaybackSeekRequest: Equatable {
    let id = UUID()
    let time: TimeInterval
}

private struct TranscriptDisplayBundle {
    var transcript: Transcript
    var alignment: TranscriptAlignment?
}

struct AudioPlayerShell: View {
    let task: TranscriptionTask
    let seekRequest: PlaybackSeekRequest?
    let onPlaybackTimeChange: (TimeInterval) -> Void
    let onPlaybackStateChange: (Bool) -> Void
    let onSeekCommitted: (TimeInterval) -> Void
    @StateObject private var playback = AudioPlaybackViewModel()
    @State private var previewSegments: [TranscriptSegment] = []

    var body: some View {
        VStack(spacing: 8) {
            PlaybackScrubber(
                currentTime: playback.currentTime,
                duration: playback.duration,
                segments: previewSegments,
                onSeek: playback.seek(to:),
                onSeekCommitted: onSeekCommitted
            )

            HStack {
                Text("\(formatDuration(playback.currentTime)) / \(formatDuration(playback.duration))")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Spacer()
                PlaybackSkipButton(direction: .backward) {
                    playback.seek(by: -15)
                }
                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.leading, playback.isPlaying ? 0 : 2)
                        .frame(width: 30, height: 30)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "暂停" : "播放")
                PlaybackSkipButton(direction: .forward) {
                    playback.seek(by: 15)
                }
                Spacer()
                Menu {
                    ForEach(AudioPlaybackViewModel.availableRates, id: \.self) { rate in
                        Button(action: { playback.setRate(rate) }) {
                            HStack {
                                Text(formatRate(rate))
                                if playback.rate == rate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    PlaybackRateMenuLabel(rate: playback.rate)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("播放速度")
            }
            .frame(height: 30)
            .font(.system(size: 16, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12))
        }
        .zIndex(1)
        .onAppear {
            playback.load(task: task)
            previewSegments = loadTranscriptSegments(for: task)
            onPlaybackTimeChange(playback.currentTime)
            onPlaybackStateChange(playback.isPlaying)
        }
        .onChange(of: task.id) {
            playback.load(task: task)
            previewSegments = loadTranscriptSegments(for: task)
            onPlaybackTimeChange(playback.currentTime)
            onPlaybackStateChange(playback.isPlaying)
        }
        .onChange(of: task.transcriptPath) {
            previewSegments = loadTranscriptSegments(for: task)
        }
        .onChange(of: task.status) {
            previewSegments = loadTranscriptSegments(for: task)
        }
        .onChange(of: seekRequest) {
            guard let seekRequest else {
                return
            }
            playback.seek(to: seekRequest.time)
            onSeekCommitted(seekRequest.time)
        }
        .onChange(of: playback.currentTime) {
            onPlaybackTimeChange(playback.currentTime)
        }
        .onChange(of: playback.isPlaying) {
            onPlaybackStateChange(playback.isPlaying)
        }
        .onDisappear {
            playback.stop()
            onPlaybackTimeChange(0)
            onPlaybackStateChange(false)
        }
    }

    private func loadTranscriptSegments(for task: TranscriptionTask) -> [TranscriptSegment] {
        guard let transcriptPath = task.transcriptPath else {
            return []
        }
        guard let transcript = try? TranscriptStore.load(from: URL(fileURLWithPath: transcriptPath)) else {
            return []
        }
        return TranscriptCleanup.removingExcessiveRepetition(from: transcript).segments
    }
}

private enum PlaybackSkipDirection {
    case backward
    case forward

    var systemImage: String {
        switch self {
        case .backward:
            "gobackward.15"
        case .forward:
            "goforward.15"
        }
    }

    var help: String {
        switch self {
        case .backward:
            "后退 15 秒"
        case .forward:
            "前进 15 秒"
        }
    }
}

private struct PlaybackSkipButton: View {
    let direction: PlaybackSkipDirection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.systemImage)
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary.opacity(0.82))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(direction.help)
        .accessibilityLabel(direction.help)
    }
}

private struct PlaybackRateMenuLabel: View {
    let rate: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .font(.system(size: 13, weight: .semibold))
            Text(formatRate(rate))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.primary.opacity(0.78))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.90))
        )
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(Capsule())
        .accessibilityLabel("播放速度 \(formatRate(rate))")
    }
}

@MainActor
final class AudioPlaybackViewModel: ObservableObject {
    static let availableRates: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1.0

    private let controller = AudioPlayerController()
    private var timer: Timer?
    private var currentTaskID: UUID?

    var progress: Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }

    func load(task: TranscriptionTask) {
        guard currentTaskID != task.id else {
            return
        }
        currentTaskID = task.id
        timer?.invalidate()
        do {
            try controller.load(url: URL(fileURLWithPath: task.localAudioPath))
            duration = controller.duration > 0 ? controller.duration : task.durationSec
            currentTime = controller.currentTime
            isPlaying = controller.isPlaying
            controller.setRate(rate)
            startTimer()
        } catch {
            currentTime = 0
            duration = task.durationSec
            isPlaying = false
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        controller.stop()
        currentTaskID = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func togglePlayback() {
        controller.togglePlayback()
        refresh()
    }

    func seek(by seconds: TimeInterval) {
        controller.seek(by: seconds)
        refresh()
    }

    func seek(to seconds: TimeInterval) {
        controller.seek(to: seconds)
        currentTime = min(max(seconds, 0), duration)
        refresh()
    }

    func setRate(_ nextRate: Float) {
        rate = nextRate
        controller.setRate(nextRate)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    private func refresh() {
        let nextCurrentTime = controller.currentTime
        let nextDuration = controller.duration > 0 ? controller.duration : duration
        let nextIsPlaying = controller.isPlaying

        if abs(currentTime - nextCurrentTime) > 0.02 {
            currentTime = nextCurrentTime
        }
        if abs(duration - nextDuration) > 0.02 {
            duration = nextDuration
        }
        if isPlaying != nextIsPlaying {
            isPlaying = nextIsPlaying
        }
    }
}

struct PlaybackScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let segments: [TranscriptSegment]
    let onSeek: (TimeInterval) -> Void
    let onSeekCommitted: (TimeInterval) -> Void
    @State private var hoverLocation: CGPoint?
    @State private var isDragging = false

    private var progress: Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let hoverX = min(max(hoverLocation?.x ?? width * progress, 0), width)
            let previewTime = time(for: hoverX, width: width)
            ZStack(alignment: .topLeading) {
                if hoverLocation != nil || isDragging {
                    PlaybackHoverPreview(
                        time: previewTime,
                        text: previewText(at: previewTime)
                    )
                    .position(x: min(max(hoverX, 140), max(width - 140, 140)), y: -34)
                    .transition(.opacity)
                    .zIndex(2)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(height: 5)
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: max(7, width * progress), height: 5)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: isDragging || hoverLocation != nil ? 10 : 7, height: isDragging || hoverLocation != nil ? 10 : 7)
                        .offset(x: max(0, min(width * progress, width)) - 5)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .offset(y: 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        hoverLocation = value.location
                        onSeek(time(for: value.location.x, width: width))
                    }
                    .onEnded { value in
                        let committedTime = time(for: value.location.x, width: width)
                        onSeek(committedTime)
                        onSeekCommitted(committedTime)
                        isDragging = false
                    }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    if !isDragging {
                        hoverLocation = nil
                    }
                }
            }
        }
        .frame(height: 16)
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard duration > 0 else {
            return 0
        }
        let ratio = min(max(x / max(width, 1), 0), 1)
        return duration * ratio
    }

    private func previewText(at time: TimeInterval) -> String {
        let directMatch = segments.first { segment in
            time >= segment.startSec && time <= max(segment.endSec, segment.startSec)
        }
        let nearest = segments.min { lhs, rhs in
            distance(from: time, to: lhs) < distance(from: time, to: rhs)
        }
        let segment = directMatch ?? nearest

        let text = segment?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return ""
        }
        let prefix = String(text.prefix(26))
        return text.count > 26 ? "\(prefix)..." : prefix
    }

    private func distance(from time: TimeInterval, to segment: TranscriptSegment) -> TimeInterval {
        if time < segment.startSec {
            return segment.startSec - time
        }
        if time > segment.endSec {
            return time - segment.endSec
        }
        return 0
    }
}

struct PlaybackHoverPreview: View {
    let time: TimeInterval
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(formatTranscriptTime(time))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
    }
}

struct TranscriptPreview: View {
    let task: TranscriptionTask
    let currentTime: TimeInterval
    let isPlaybackActive: Bool
    let focus: TranscriptFocus?
    let onSeekToTime: (TimeInterval) -> Void
    @State private var cachedBundle: TranscriptDisplayBundle?
    @State private var cachedTaskID: UUID?
    @State private var cachedTranscriptPath: String?
    @State private var transcriptLoadAttempted = false
    @State private var flashSegmentIndex: Int?
    @State private var flashPulse = false
    @State private var flashToken = UUID()
    @State private var followedSegmentIndex: Int?
    @State private var isFollowingPlayback = true
    @State private var showFollowPlaybackButton = false

    var body: some View {
        Group {
            if task.status == .done {
            if let bundle = currentTranscriptBundle {
                let transcript = bundle.transcript
                let alignmentItems = bundle.alignment?.items ?? []
                let activeIndex = segmentIndex(for: currentTime, in: transcript.segments)
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                                    let isActiveSegment = activeIndex == index
                                    TranscriptLine(
                                        segment: segment,
                                        currentTime: isActiveSegment ? currentTime : segment.startSec,
                                        alignmentItems: alignmentItems,
                                        isActive: isActiveSegment,
                                        isFocused: flashSegmentIndex == index,
                                        highlightPulse: flashPulse,
                                        onDoubleClickAtTextOffset: { offset in
                                            onSeekToTime(
                                                TranscriptPlaybackSlicer.seekTime(
                                                    in: segment,
                                                    atTextOffset: offset,
                                                    alignmentItems: alignmentItems
                                                )
                                            )
                                        }
                                    )
                                    .id(index)
                                }
                            }
                            .background(
                                ScrollActivityObserver {
                                    pausePlaybackFollow(for: transcript)
                                }
                            )
                            .font(.system(size: 16))
                            .padding(.bottom, 32)
                        }
                        .scrollIndicators(.automatic)

                        if isPlaybackActive,
                           showFollowPlaybackButton,
                           activeIndex != nil {
                            FollowPlaybackButton {
                                restorePlaybackFollow(proxy: proxy, transcript: transcript)
                            }
                            .padding(.bottom, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(1)
                        }
                    }
                    .onChange(of: focus) {
                        focusTranscript(proxy: proxy, transcript: transcript)
                    }
                    .onChange(of: currentTime) {
                        followCurrentSegment(proxy: proxy, transcript: transcript)
                    }
                    .onChange(of: isPlaybackActive) {
                        if isPlaybackActive {
                            if isFollowingPlayback {
                                followCurrentSegment(proxy: proxy, transcript: transcript, force: true)
                            } else if segmentIndex(for: currentTime, in: transcript.segments) != nil {
                                showFollowPlaybackButton = true
                            }
                        } else {
                            showFollowPlaybackButton = false
                        }
                    }
                    .onChange(of: task.id) {
                        followedSegmentIndex = nil
                        flashSegmentIndex = nil
                        flashPulse = false
                        isFollowingPlayback = true
                        showFollowPlaybackButton = false
                    }
                    .animation(.easeInOut(duration: 0.18), value: showFollowPlaybackButton)
                }
            } else if transcriptLoadAttempted {
                Text("转写结果读取失败")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("读取转写结果")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            } else if task.status == .failed {
                Text("转写失败")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if task.status == .paused {
                Text("已停止")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("开始后生成内容")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshTranscriptBundleIfNeeded)
        .onChange(of: task.id) {
            invalidateTranscriptBundle()
            refreshTranscriptBundleIfNeeded()
        }
        .onChange(of: task.transcriptPath) {
            invalidateTranscriptBundle()
            refreshTranscriptBundleIfNeeded()
        }
        .onChange(of: task.status) {
            if task.status == .done {
                refreshTranscriptBundleIfNeeded()
            } else {
                invalidateTranscriptBundle()
            }
        }
    }

    private var currentTranscriptBundle: TranscriptDisplayBundle? {
        guard cachedTaskID == task.id,
              cachedTranscriptPath == task.transcriptPath else {
            return nil
        }
        return cachedBundle
    }

    private func refreshTranscriptBundleIfNeeded() {
        guard task.status == .done else {
            return
        }
        guard cachedTaskID != task.id || cachedTranscriptPath != task.transcriptPath || !transcriptLoadAttempted else {
            return
        }
        cachedTaskID = task.id
        cachedTranscriptPath = task.transcriptPath
        cachedBundle = loadTranscriptBundle()
        transcriptLoadAttempted = true
    }

    private func invalidateTranscriptBundle() {
        cachedBundle = nil
        cachedTaskID = nil
        cachedTranscriptPath = nil
        transcriptLoadAttempted = false
        followedSegmentIndex = nil
        flashSegmentIndex = nil
        flashPulse = false
        isFollowingPlayback = true
        showFollowPlaybackButton = false
    }

    private func loadTranscriptBundle() -> TranscriptDisplayBundle? {
        guard let transcriptPath = task.transcriptPath else {
            return nil
        }
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        guard let transcript = try? TranscriptStore.load(from: transcriptURL) else {
            return nil
        }
        let alignment = try? TranscriptStore.loadAlignment(forTranscriptAt: transcriptURL)
        return TranscriptDisplayBundle(
            transcript: TranscriptCleanup.removingExcessiveRepetition(from: transcript),
            alignment: alignment ?? nil
        )
    }

    private func focusTranscript(proxy: ScrollViewProxy, transcript: Transcript) {
        guard
            let focus,
            let index = segmentIndex(for: focus.time, in: transcript.segments)
        else {
            return
        }

        isFollowingPlayback = true
        showFollowPlaybackButton = false
        followedSegmentIndex = index

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(index, anchor: .center)
        }

        flashSegment(index)
    }

    private func flashSegment(_ index: Int) {
        let token = UUID()
        flashToken = token
        flashSegmentIndex = index
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.24)) {
                flashPulse = true
            }
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard flashToken == token else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                flashPulse = false
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard flashToken == token else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                flashPulse = true
            }
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard flashToken == token else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                flashPulse = false
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard flashToken == token else { return }
            flashSegmentIndex = nil
        }
    }

    private func followCurrentSegment(proxy: ScrollViewProxy, transcript: Transcript, force: Bool = false) {
        guard let index = segmentIndex(for: currentTime, in: transcript.segments) else {
            return
        }
        guard isFollowingPlayback else {
            return
        }
        guard force || followedSegmentIndex != index else {
            return
        }
        followedSegmentIndex = index

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func pausePlaybackFollow(for transcript: Transcript) {
        guard segmentIndex(for: currentTime, in: transcript.segments) != nil else {
            return
        }
        guard isFollowingPlayback || !showFollowPlaybackButton else {
            return
        }
        isFollowingPlayback = false
        showFollowPlaybackButton = isPlaybackActive
    }

    private func restorePlaybackFollow(proxy: ScrollViewProxy, transcript: Transcript) {
        guard let index = segmentIndex(for: currentTime, in: transcript.segments) else {
            return
        }

        isFollowingPlayback = true
        showFollowPlaybackButton = false
        followedSegmentIndex = index

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(index, anchor: .center)
        }
        flashSegment(index)
    }

    private func segmentIndex(for time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        if let exact = segments.firstIndex(where: { segment in
            time >= segment.startSec && time <= max(segment.endSec, segment.startSec)
        }) {
            return exact
        }
        return segments.lastIndex(where: { $0.startSec <= time })
    }
}

struct FollowPlaybackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("跟随播放位置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .help("回到当前播放的转写段落")
        .accessibilityLabel("跟随播放位置")
    }
}

private struct ScrollActivityObserver: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    final class Coordinator: NSObject {
        var onUserScroll: () -> Void
        private weak var scrollView: NSScrollView?

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit {
            detach()
        }

        @MainActor
        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else {
                return
            }
            guard self.scrollView !== scrollView else {
                return
            }

            detach()
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleUserScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleUserScroll),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }

        private func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
        }

        @objc private func handleUserScroll(_ notification: Notification) {
            onUserScroll()
        }
    }
}

struct TranscriptLine: View {
    let segment: TranscriptSegment
    let currentTime: TimeInterval
    let alignmentItems: [TranscriptAlignmentItem]
    let isActive: Bool
    let isFocused: Bool
    let highlightPulse: Bool
    let onDoubleClickAtTextOffset: (Int?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(formatTranscriptTime(segment.startSec))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onDoubleClickAtTextOffset(nil)
                }
            transcriptText
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    TranscriptTextHitTarget(text: segment.text, onDoubleClickAtOffset: onDoubleClickAtTextOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("双击跳转到此处")
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var transcriptText: Text {
        guard
            isActive,
            let highlight = TranscriptPlaybackSlicer.activeHighlight(
                in: segment,
                at: currentTime,
                alignmentItems: alignmentItems
            ) ?? TranscriptPlaybackSlicer.activeHighlight(in: segment, at: currentTime),
            highlight.sliceStartOffset < highlight.highlightEndOffset,
            highlight.highlightEndOffset <= segment.text.count
        else {
            return Text(segment.text)
        }

        let highlightStart = segment.text.index(segment.text.startIndex, offsetBy: highlight.sliceStartOffset)
        let highlightEnd = segment.text.index(segment.text.startIndex, offsetBy: highlight.highlightEndOffset)
        let prefix = String(segment.text[..<highlightStart])
        let active = String(segment.text[highlightStart..<highlightEnd])
        let suffix = String(segment.text[highlightEnd...])
        return Text(prefix) + Text(active).foregroundColor(.blue) + Text(suffix)
    }

    private var backgroundColor: Color {
        if isFocused {
            return Color.blue.opacity(highlightPulse ? 0.12 : 0.05)
        }
        if isActive {
            return Color.blue.opacity(0.06)
        }
        return .clear
    }

    private var borderColor: Color {
        if isFocused {
            return Color.blue.opacity(highlightPulse ? 0.24 : 0.10)
        }
        if isActive {
            return Color.blue.opacity(0.14)
        }
        return .clear
    }
}

private struct TranscriptTextHitTarget: NSViewRepresentable {
    let text: String
    let onDoubleClickAtOffset: (Int?) -> Void

    func makeNSView(context: Context) -> TextHitView {
        let view = TextHitView()
        view.text = text
        view.onDoubleClickAtOffset = onDoubleClickAtOffset
        return view
    }

    func updateNSView(_ nsView: TextHitView, context: Context) {
        nsView.text = text
        nsView.onDoubleClickAtOffset = onDoubleClickAtOffset
    }

    final class TextHitView: NSView {
        var text = ""
        var onDoubleClickAtOffset: (Int?) -> Void = { _ in }

        override var isFlipped: Bool {
            true
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
            recognizer.numberOfClicksRequired = 2
            recognizer.buttonMask = 0x1
            recognizer.delaysPrimaryMouseButtonEvents = false
            addGestureRecognizer(recognizer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended else {
                return
            }
            onDoubleClickAtOffset(characterOffset(at: recognizer.location(in: self)))
        }

        private func characterOffset(at location: CGPoint) -> Int? {
            guard !text.isEmpty, bounds.width > 0, bounds.height > 0 else {
                return nil
            }

            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(
                size: CGSize(width: max(bounds.width, 1), height: CGFloat.greatestFiniteMagnitude)
            )
            textContainer.lineFragmentPadding = 0
            textContainer.lineBreakMode = .byWordWrapping
            textContainer.maximumNumberOfLines = 0
            layoutManager.addTextContainer(textContainer)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.lineBreakMode = .byWordWrapping
            let textStorage = NSTextStorage(
                attributedString: NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 16),
                        .paragraphStyle: paragraphStyle
                    ]
                )
            )
            textStorage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: textContainer)

            guard layoutManager.numberOfGlyphs > 0 else {
                return nil
            }

            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(
                for: location,
                in: textContainer,
                fractionOfDistanceThroughGlyph: &fraction
            )
            guard glyphIndex >= 0, glyphIndex < layoutManager.numberOfGlyphs else {
                return nil
            }

            let glyphRect = layoutManager
                .boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
                .insetBy(dx: -2, dy: -2)
            guard glyphRect.contains(location) else {
                return nil
            }

            let utf16Location = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard let offset = characterOffset(forUTF16Location: utf16Location) else {
                return nil
            }
            guard isVisibleTextCharacter(at: offset) else {
                return nil
            }
            return offset
        }

        private func characterOffset(forUTF16Location utf16Location: Int) -> Int? {
            guard !text.isEmpty else {
                return nil
            }

            var location = min(max(utf16Location, 0), max(text.utf16.count - 1, 0))
            while location >= 0 {
                let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: location)
                if let stringIndex = String.Index(utf16Index, within: text) {
                    return text.distance(from: text.startIndex, to: stringIndex)
                }
                location -= 1
            }
            return nil
        }

        private func isVisibleTextCharacter(at offset: Int) -> Bool {
            let characters = Array(text)
            guard offset >= 0, offset < characters.count else {
                return false
            }
            return !String(characters[offset]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private func formatCreatedAt(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M-d HH:mm"
    return formatter.string(from: date)
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds > 0 else {
        return "00:00"
    }
    let value = Int(seconds.rounded())
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

private func formatEstimateDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else {
        return "<1 分钟"
    }
    if seconds < 60 {
        return "<1 分钟"
    }

    let totalMinutes = max(1, Int(ceil(seconds / 60)))
    if totalMinutes < 60 {
        return "\(totalMinutes) 分钟"
    }

    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if minutes == 0 {
        return "\(hours) 小时"
    }
    return "\(hours) 小时 \(minutes) 分钟"
}

private func formatTranscriptTime(_ seconds: Double) -> String {
    let value = Int(seconds.rounded())
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

private func formatRate(_ rate: Float) -> String {
    if rate == floor(rate) {
        return String(format: "%.1fx", rate)
    }
    return "\(rate)x"
}
