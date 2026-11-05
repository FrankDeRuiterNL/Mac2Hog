#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct CueListView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var activity: CueActivity
    @State private var selection = Set<UUID>()
    /// Hidden columns (right-click the column titles to change). Type is hidden by default.
    @AppStorage("Mac2Hog.cueList.hiddenColumns") private var hiddenColumnsRaw = CueColumn.type.rawValue

    // Column widths shared by the header and the rows (flexible columns: Name, Console commands).
    private enum W {
        static let status: CGFloat = 18, number: CGFloat = 30, timecode: CGFloat = 96, start: CGFloat = 132
        static let type: CGFloat = 86, on: CGFloat = 28
    }

    enum CueColumn: String, CaseIterable, Identifiable {
        case number, timecode, start, name, type, commands, on
        var id: String { rawValue }
        var title: String {
            switch self {
            case .number: return "#"
            case .timecode: return "Timecode"
            case .start: return "Start"
            case .name: return "Name"
            case .type: return "Type"
            case .commands: return "Console commands"
            case .on: return "On"
            }
        }
    }

    private var hiddenColumns: Set<String> { Set(hiddenColumnsRaw.split(separator: ",").map(String.init)) }
    private func shows(_ column: CueColumn) -> Bool { column == .name || !hiddenColumns.contains(column.rawValue) }

    private func setColumn(_ column: CueColumn, visible: Bool) {
        var hidden = hiddenColumns
        if visible { hidden.remove(column.rawValue) } else { hidden.insert(column.rawValue) }
        hiddenColumnsRaw = hidden.sorted().joined(separator: ",")
    }

    var body: some View {
        let rows = state.project.triggers   // kept in cue-list order by AppState
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                // A List (instead of Table) so rows can get their own background: purple = last fired,
                // red = running (fired and still within its duration).
                List(selection: $selection) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, t in
                        row(t, number: index + 1)
                            .id(t.id)
                            .rowHighlight(highlightColor(t), blinking: t.id == activity.nextCueID)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(ids)
                } primaryAction: { ids in
                    // Double-click: jump the song there (timecode) or make it the next cue (manual).
                    guard let id = ids.first, let t = state.project.triggers.first(where: { $0.id == id }) else { return }
                    if state.mode == .manual { state.setNextCue(id) } else { state.seek(to: t.time) }
                }
                .onDeleteCommand { state.deleteTriggers(selection) }
                .onChange(of: selection) { sel in
                    guard sel.count == 1, let id = sel.first else { return }
                    if id != state.selectedTriggerID { state.selectedTriggerID = id }
                    activity.focusedCueID = id   // clicking a cue always shows it in the inspector
                }
                .onChange(of: state.selectedTriggerID) { id in
                    if let id, !selection.contains(id) { selection = [id] }
                }
                // Follow: keep the last fired cue (or, in manual mode, the next cue) in view.
                .onChange(of: activity.lastFiredID) { id in
                    guard state.followPlayhead, let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: state.cueStack.next?.id) { id in
                    guard state.followPlayhead, state.mode == .manual, let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button { state.addTrigger(at: state.currentTime) } label: {
                    Label(state.editingState != nil ? "Add cue" : "Add at playhead", systemImage: "plus")
                }
                if !state.settings.predefinedTriggers.isEmpty {
                    Menu {
                        ForEach(state.settings.predefinedTriggers) { p in
                            Button(p.name) {
                                let t = state.addTrigger(at: state.currentTime, name: p.name)
                                state.apply(p, to: t.id)
                            }
                        }
                    } label: { Label("Add predefined", systemImage: "star") }
                    .fixedSize()
                    .help("Add a new cue that sends a predefined trigger")
                }
                Button { state.deleteTriggers(selection) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection.isEmpty)
                Button { fireSelected() } label: { Label("Fire selected", systemImage: "bolt.fill") }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("\(rows.count) cues · \(rows.filter { $0.commands.isEmpty }.count) without commands")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: W.status, height: 0)
            if shows(.number) { Text("#").frame(width: W.number, alignment: .trailing) }
            if shows(.timecode) { Text("Timecode").frame(width: W.timecode, alignment: .leading) }
            if shows(.start) { Text("Start").frame(width: W.start, alignment: .leading) }
            Text("Name").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            if shows(.type) { Text("Type").frame(width: W.type, alignment: .leading) }
            if shows(.commands) { Text("Console commands").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading) }
            if shows(.on) { Text("On").frame(width: W.on) }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Text("Columns")
            ForEach(CueColumn.allCases) { column in
                Toggle(column.title, isOn: Binding(get: { shows(column) }, set: { setColumn(column, visible: $0) }))
                    .disabled(column == .name)
            }
        }
        .help("Right-click to show or hide columns")
    }

    private func row(_ t: ShowTrigger, number: Int) -> some View {
        HStack(spacing: 8) {
            statusIcon(t).frame(width: W.status)
            if shows(.number) { Text("\(number)").monospacedDigit().frame(width: W.number, alignment: .trailing) }
            if shows(.timecode) {
                Text(state.project.timecode(at: t.time).description).font(.body.monospacedDigit())
                    .frame(width: W.timecode, alignment: .leading)
            }
            if shows(.start) { startCell(t).frame(width: W.start, alignment: .leading) }
            Text(t.name).foregroundStyle(t.enabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            if shows(.type) {
                Text(t.source.displayName).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: W.type, alignment: .leading)
            }
            if shows(.commands) { commandsText(t).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading) }
            if shows(.on) {
                Toggle("", isOn: Binding(get: { t.enabled }, set: { v in state.binding(for: t.id)?.wrappedValue.enabled = v }))
                    .labelsHidden()
                    .frame(width: W.on)
            }
        }
        .lineLimit(1)
    }

    /// Start type, plus the blue release icon and its delay when the cue has a timed Release command,
    /// e.g. "TC+ ↩︎ 0,4s" (Wait releases show "W" before the value).
    @ViewBuilder
    private func startCell(_ t: ShowTrigger) -> some View {
        if let release = t.commands.first(where: { $0.action == .release && $0.timing != nil }), let timing = release.timing {
            HStack(spacing: 3) {
                Text(t.startMode == .timecode ? "TC+" : "\(t.startDescription) +")
                    .foregroundStyle(t.startMode == .timecode ? Color.secondary : Color.orange)
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue)
                Text((timing.mode == .wait ? "W " : "") + "\(SecondsText.format(timing.seconds))s")
                    .foregroundStyle(.blue)
            }
            .help("\(release.summary) — \(timing.mode == .wait ? "after the cue's Duration" : "after the cue fires")")
        } else {
            Text(t.startDescription)
                .foregroundStyle(t.startMode == .timecode ? Color.secondary : Color.orange)
        }
    }

    /// Red = running (within its duration), purple = last fired, nil = normal row.
    private func highlightColor(_ t: ShowTrigger) -> Color? {
        if activity.runningCueIDs.contains(t.id) { return .red }
        if t.id == activity.lastFiredID { return .purple }
        return nil
    }

    @ViewBuilder
    private func statusIcon(_ t: ShowTrigger) -> some View {
        if state.mode == .manual && state.cueStack.next?.id == t.id {
            Image(systemName: "arrowtriangle.right.fill").foregroundStyle(.green).help("Next cue (Space)")
        } else if t.id == activity.lastFiredID {
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
        } else if t.commands.isEmpty {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("No console command attached")
        } else {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
        }
    }

    private func commandsText(_ t: ShowTrigger) -> some View {
        // Timed releases are shown in the Start column instead.
        let shown = t.commands.filter { !($0.action == .release && $0.timing != nil) }
        return Text(shown.isEmpty ? "—" : shown.map(\.summary).joined(separator: ", "))
            .foregroundStyle(t.commands.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<UUID>) -> some View {
        if let id = ids.first, let t = state.project.triggers.first(where: { $0.id == id }) {
            Button("Fire Now") { ids.compactMap { i in state.project.triggers.first { $0.id == i } }.forEach(state.fire) }
            Button("Go to Position") { state.seek(to: t.time) }
            Button("Set as Next Cue (Manual Mode)") { state.mode = .manual; state.setNextCue(id) }
            Divider()
            Button("Duplicate") { state.duplicateTrigger(id) }
            if ids.count == 1 && !t.commands.isEmpty {
                Button("Copy Commands to All “\(t.source.displayName)” Cues") { state.applyCommandsToAll(from: id) }
            }
            Button(ids.count > 1 ? "Enable / Disable \(ids.count) Cues" : (t.enabled ? "Disable" : "Enable")) {
                for i in ids { state.binding(for: i)?.wrappedValue.enabled.toggle() }
            }
            Divider()
            Button("Delete", role: .destructive) { state.deleteTriggers(ids) }
        }
    }

    private func fireSelected() {
        for t in state.project.sortedTriggers where selection.contains(t.id) { state.fire(t) }
    }
}
/// Subtle dark-green background for the next cue, on for half a second and off for half a second.
private struct NextCueBlink: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(red: 0.10, green: 0.36, blue: 0.20).opacity(on ? 0.7 : 0))
                .padding(.horizontal, 6)
        }
    }
}

private extension View {
    /// Only replaces the row background when highlighted, so normal rows keep the alternating stripes.
    @ViewBuilder
    func rowHighlight(_ color: Color?, blinking: Bool) -> some View {
        if let color {
            listRowBackground(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.6)).padding(.horizontal, 6))
        } else if blinking {
            listRowBackground(NextCueBlink())
        } else {
            self
        }
    }
}
#endif
