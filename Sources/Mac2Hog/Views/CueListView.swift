#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct CueListView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()

    var body: some View {
        let rows = state.project.sortedTriggers
        let numbers = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0 + 1) })
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("") { (t: ShowTrigger) in statusIcon(t) }
                    .width(22)
                TableColumn("#") { (t: ShowTrigger) in Text("\(numbers[t.id] ?? 0)").monospacedDigit() }
                    .width(32)
                TableColumn("Timecode") { (t: ShowTrigger) in
                    Text(state.project.timecode(at: t.time).description).font(.body.monospacedDigit())
                }
                .width(min: 90, ideal: 100)
                TableColumn("Name") { (t: ShowTrigger) in
                    Text(t.name).foregroundStyle(t.enabled ? Color.primary : Color.secondary)
                }
                TableColumn("Type") { (t: ShowTrigger) in Text(t.source.displayName).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Console commands") { (t: ShowTrigger) in commandsText(t) }
                    .width(min: 160, ideal: 240)
                TableColumn("On") { (t: ShowTrigger) in
                    Toggle("", isOn: Binding(get: { t.enabled }, set: { v in state.binding(for: t.id)?.wrappedValue.enabled = v }))
                        .labelsHidden()
                }
                .width(28)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                // Double-click: jump the song there (timecode) or make it the next cue (manual).
                guard let id = ids.first, let t = state.project.triggers.first(where: { $0.id == id }) else { return }
                if state.mode == .manual { state.setNextCue(id) } else { state.seek(to: t.time) }
            }
            .onDeleteCommand { state.deleteTriggers(selection) }
            .onChange(of: selection) { sel in
                if sel.count == 1, let id = sel.first, id != state.selectedTriggerID { state.selectedTriggerID = id }
            }
            .onChange(of: state.selectedTriggerID) { id in
                if let id, !selection.contains(id) { selection = [id] }
            }

            Divider()
            HStack(spacing: 8) {
                Button { state.addTrigger(at: state.currentTime) } label: { Label("Add at playhead", systemImage: "plus") }
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

    @ViewBuilder
    private func statusIcon(_ t: ShowTrigger) -> some View {
        if state.mode == .manual && state.cueStack.next?.id == t.id {
            Image(systemName: "arrowtriangle.right.fill").foregroundStyle(.green).help("Next cue (Space)")
        } else if t.id == state.lastFiredID {
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
        } else if t.commands.isEmpty {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("No console command attached")
        } else {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
        }
    }

    private func commandsText(_ t: ShowTrigger) -> some View {
        Text(t.commands.isEmpty ? "—" : t.commands.map(\.summary).joined(separator: ", "))
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
#endif
