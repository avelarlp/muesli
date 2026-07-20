import SwiftUI
import MuesliCore

struct MeetingListItemView: View {
    let record: MeetingRecord
    let isSelected: Bool
    let hasFollowUps: Bool
    let folders: [MeetingFolder]
    private let folderByID: [Int64: MeetingFolder]
    private let folderIDsWithChildren: Set<Int64>
    let onSelect: () -> Void
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: ((String) -> Void)?
    let onDelete: (() -> Void)?
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showFolderPopover = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    init(
        record: MeetingRecord,
        isSelected: Bool,
        hasFollowUps: Bool,
        folders: [MeetingFolder],
        onSelect: @escaping () -> Void,
        onMove: @escaping (Int64?) -> Void,
        onCreateFolderAndMove: ((String) -> Void)?,
        onDelete: (() -> Void)?
    ) {
        self.record = record
        self.isSelected = isSelected
        self.hasFollowUps = hasFollowUps
        self.folders = folders
        self.folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        self.folderIDsWithChildren = Set(folders.compactMap(\.parentID))
        self.onSelect = onSelect
        self.onMove = onMove
        self.onCreateFolderAndMove = onCreateFolderAndMove
        self.onDelete = onDelete
    }

    private var currentFolderName: String? {
        guard let fid = record.folderID else { return nil }
        guard let folder = folderByID[fid] else { return nil }
        // Build breadcrumb path: "Grandparent / Parent / Folder"
        var parts: [String] = [folder.name]
        var current = folder.parentID
        var seen: Set<Int64> = [folder.id]
        while let pid = current, let parent = folderByID[pid], seen.insert(pid).inserted {
            parts.insert(parent.name, at: 0)
            current = parent.parentID
        }
        return parts.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                Text(record.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    relationshipIndicators
                    if !folders.isEmpty {
                        folderMenuButton
                    }
                    if onDelete != nil {
                        deleteButton
                    }
                }
            }

            HStack(spacing: MuesliTheme.spacing4) {
                if record.status != .completed {
                    statusBadge
                    Text("\u{2022}")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Text(formatMeta())
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)

                if let sourceIndicator = sourceIndicator {
                    sourceIndicator
                }

                // Current folder badge
                if let name = currentFolderName {
                    Text("\u{2022}")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(name)
                            .font(MuesliTheme.caption())
                    }
                    .foregroundStyle(MuesliTheme.accent.opacity(0.8))
                }
            }

            Text(previewText())
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .lineLimit(2)
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(
                    isSelected ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .alert("Excluir reunião", isPresented: $showDeleteConfirmation) {
            Button("Excluir", role: .destructive) { onDelete?() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tem certeza de que deseja excluir esta reunião? Notas, transcrição e qualquer gravação mantida serão removidas.")
        }
    }

    // MARK: - Folder menu button

    @ViewBuilder
    private var relationshipIndicators: some View {
        if record.followUpToID != nil || hasFollowUps {
            HStack(spacing: 4) {
                if record.followUpToID != nil {
                    relationshipIcon(
                        "arrow.turn.down.right",
                        help: "Reunião de acompanhamento"
                    )
                }
                if hasFollowUps {
                    relationshipIcon(
                        "arrow.triangle.branch",
                        help: "Possui reuniões de acompanhamento"
                    )
                }
            }
        }
    }

    private func relationshipIcon(_ systemName: String, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MuesliTheme.accent.opacity(0.9))
            .frame(width: 24, height: 24)
            .help(help)
            .accessibilityLabel(help)
    }

    private func folderBreadcrumb(_ folder: MeetingFolder) -> String {
        var parts: [String] = [folder.name]
        var current = folder.parentID
        var seen: Set<Int64> = [folder.id]
        while let pid = current, let parent = folderByID[pid], seen.insert(pid).inserted {
            parts.insert(parent.name, at: 0)
            current = parent.parentID
        }
        return parts.joined(separator: " / ")
    }

    @ViewBuilder
    private var folderMenuButton: some View {
        Button {
            showFolderPopover.toggle()
        } label: {
            Image(systemName: record.folderID != nil ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(
                    record.folderID != nil
                        ? MuesliTheme.accent
                        : (isHovering ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mover para a pasta")
        .popover(isPresented: $showFolderPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                folderPopoverRow(icon: "tray", label: "Sem pasta", isActive: record.folderID == nil) {
                    onMove(nil)
                    showFolderPopover = false
                }
                Divider().padding(.vertical, 4)
                ForEach(folders) { folder in
                    let hasChildren = folderIDsWithChildren.contains(folder.id)
                    folderPopoverRow(
                        icon: hasChildren ? "folder.fill" : "folder",
                        label: folderBreadcrumb(folder),
                        isActive: record.folderID == folder.id
                    ) {
                        onMove(folder.id)
                        showFolderPopover = false
                    }
                }
                if onCreateFolderAndMove != nil {
                    Divider().padding(.vertical, 4)
                    folderPopoverRow(icon: "folder.badge.plus", label: "Nova pasta...") {
                        showFolderPopover = false
                        newFolderName = ""
                        showNewFolderPrompt = true
                    }
                }
            }
            .padding(8)
        }
        .alert("Nova pasta", isPresented: $showNewFolderPrompt) {
            TextField("Nome da pasta", text: $newFolderName)
            Button("Criar") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onCreateFolderAndMove?(trimmed)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Crie uma nova pasta e mova esta reunião para ela.")
        }
    }

    @ViewBuilder
    private func folderPopoverRow(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(MuesliTheme.callout())
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(
                    isHovering
                        ? MuesliTheme.recording.opacity(0.85)
                        : MuesliTheme.textTertiary
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .help("Excluir reunião")
    }

    // MARK: - Formatting

    private var statusBadge: some View {
        Text(record.status.displayLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(record.status.displayColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(record.status.displayColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var sourceIndicator: AnyView? {
        if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: record.source) {
            return AnyView(SyncOriginBadge(label: label))
        }
        if isImportedAudio {
            return AnyView(sourceBadge(icon: "square.and.arrow.down", label: "Importado", help: "Áudio importado"))
        }
        if hasSavedRecording {
            return AnyView(sourceBadge(icon: "waveform", label: "Gravação", help: "Gravação salva disponível"))
        }
        return nil
    }

    private var isImportedAudio: Bool {
        record.source == .audioImport || hasLegacyImportedRecordingPath
    }

    private var hasLegacyImportedRecordingPath: Bool {
        guard let savedRecordingPath = record.savedRecordingPath else { return false }
        let filename = URL(fileURLWithPath: savedRecordingPath).lastPathComponent
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_.+_[0-9A-Fa-f]{8}\.wav$"#
        return filename.range(of: pattern, options: .regularExpression) != nil
    }

    private var hasSavedRecording: Bool {
        guard let savedRecordingPath = record.savedRecordingPath else { return false }
        return !savedRecordingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sourceBadge(icon: String, label: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(isImportedAudio ? MuesliTheme.accent : MuesliTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((isImportedAudio ? MuesliTheme.accent : MuesliTheme.textSecondary).opacity(0.12))
        .clipShape(Capsule())
        .help(help)
        .accessibilityLabel(help)
    }

    private func formatMeta() -> String {
        let time = MeetingBrowserLogic.formatStartTime(record.startTime)
        let duration = formatDuration(record.durationSeconds)
        return "\(time)  \u{2022}  \(duration)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }

    private func previewText() -> String {
        let source: String
        if !record.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.status != .completed {
            source = record.manualNotes
        } else {
            source = record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
        }
        return MeetingPreviewText.snippet(from: source)
    }

}
