import SwiftUI
import MuesliCore

enum SyncOriginDisplay {
    static let iOSSource = "ios"
    static let iOSBadgeLabel = "iOS"
    static let iOSBadgeHelp = "Sincronizado do Muesli para iOS"

    static func badgeLabel(forDictationSource source: String) -> String? {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == iOSSource
            ? iOSBadgeLabel
            : nil
    }

    static func badgeLabel(forMeetingSource source: MeetingSource) -> String? {
        source == .iOS ? iOSBadgeLabel : nil
    }
}

extension RecordOriginFilter {
    var label: String {
        switch self {
        case .all: return "Todas"
        case .thisMac: return "Este Mac"
        case .fromIPhone: return "Do iPhone"
        }
    }
}

struct RecordOriginPicker: View {
    @Binding var selection: RecordOriginFilter

    var body: some View {
        Picker("Origem do registro", selection: $selection) {
            ForEach(RecordOriginFilter.allCases, id: \.self) { origin in
                Text(origin.label).tag(origin)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .help("Filtre pelo dispositivo em que a gravação foi criada")
        .accessibilityLabel("Origem do registro")
    }
}

struct SyncOriginBadge: View {
    let label: String
    var help: String = SyncOriginDisplay.iOSBadgeHelp

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help(help)
            .accessibilityLabel(help)
    }
}
