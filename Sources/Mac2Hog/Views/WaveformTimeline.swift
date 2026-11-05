#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

/// Song overview + zoomable detail view with waveform, sections, breaks, beat grid, snare hits and triggers.
/// Click = seek / select trigger · drag empty space = scroll · drag a trigger flag = move it · double-click = add trigger.
struct WaveformTimeline: View {
    @EnvironmentObject var state: AppState
    @State private var viewStart: Double = 0
    @State private var dragMode: DragMode?
    /// Zoom and anchor at the start of a trackpad pinch.
    @State private var pinchStart: (zoom: Double, anchorTime: Double, anchorX: CGFloat)?
    @State private var showSnares = true
    @State private var showBeats = true

    enum DragMode { case pan(startView: Double), trigger(UUID), seek }

    private let sectionBand: CGFloat = 22
    private let flagBand: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            OverviewStrip(viewStart: $viewStart)
                .frame(height: 34)
            GeometryReader { geo in
                let width = geo.size.width
                let visible = width / state.zoom
                Canvas { ctx, size in draw(ctx: ctx, size: size) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: width))
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                        state.addTrigger(at: time(atX: v.location.x))
                    })
                    .simultaneousGesture(pinchGesture(width: width))
                    .background(ScrollWheelCatcher { dx, dy, precise in scroll(dx: dx, dy: dy, precise: precise, width: width) })
                    // The playhead is a separate light layer: only it redraws while the song plays.
                    .overlay(PlayheadLayer(viewStart: $viewStart, zoom: state.zoom, visible: visible,
                                           follow: state.followPlayhead).clipped())
                    .contextMenu {
                        Button("Add Trigger at Playhead") { state.addTrigger(at: state.currentTime) }
                    }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: Binding(get: { log2(state.zoom) }, set: { state.zoom = pow(2, $0) }), in: 2...9)
                .frame(width: 160)
            Image(systemName: "plus.magnifyingglass")
            Toggle("Follow", isOn: $state.followPlayhead)
                .help("Keep the waveform and the cue list on the playhead / last fired cue")
            Toggle("Snap to beat", isOn: $state.snapToBeat)
            Toggle("Beats", isOn: $showBeats)
            Toggle("Snares", isOn: $showSnares)
            Spacer()
            legend(color: .orange, "Snare")
            legend(color: .red.opacity(0.5), "Break")
            legend(color: .accentColor, "Trigger")
            Text("Double-click to add a trigger · drag flags to move · pinch to zoom · swipe to scroll")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func legend(color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption)
        }
    }

    // MARK: Coordinates

    private func x(of time: Double) -> CGFloat { CGFloat((time - viewStart) * state.zoom) }
    private func time(atX x: CGFloat) -> Double { max(0, min(state.duration, viewStart + Double(x) / state.zoom)) }

    private func trigger(atX x: CGFloat, y: CGFloat) -> ShowTrigger? {
        state.project.triggers
            .filter { abs(self.x(of: $0.time) - x) < 6 || (y < sectionBand + flagBand && self.x(of: $0.time) <= x && x < self.x(of: $0.time) + 70) }
            .min { abs(self.x(of: $0.time) - x) < abs(self.x(of: $1.time) - x) }
    }

    /// Trackpad pinch-to-zoom. Zooms around the playhead when it is on screen, otherwise around the centre,
    /// so the point you're looking at stays put. Same range as the zoom slider.
    private func pinchGesture(width: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStart == nil {
                    let playheadX = x(of: state.currentTime)
                    let anchorX = (playheadX >= 0 && playheadX <= width) ? playheadX : width / 2
                    pinchStart = (state.zoom, viewStart + Double(anchorX) / state.zoom, anchorX)
                }
                guard let start = pinchStart else { return }
                let newZoom = min(512, max(4, start.zoom * Double(scale)))
                state.zoom = newZoom
                let maxStart = max(0, state.duration - Double(width) / newZoom)
                viewStart = min(maxStart, max(0, start.anchorTime - Double(start.anchorX) / newZoom))
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Horizontal two-finger swipe pans the waveform; a (non-trackpad) mouse wheel pans too.
    private func scroll(dx: CGFloat, dy: CGFloat, precise: Bool, width: CGFloat) {
        let delta = abs(dx) >= abs(dy) ? dx : (precise ? 0 : dy)
        guard delta != 0 else { return }
        let points = Double(delta) * (precise ? 1 : 12)
        let maxStart = max(0, state.duration - Double(width) / state.zoom)
        viewStart = min(maxStart, max(0, viewStart - points / state.zoom))
        if state.followPlayhead && state.isPlaying { state.followPlayhead = false }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragMode == nil {
                    if let t = trigger(atX: v.startLocation.x, y: v.startLocation.y) {
                        // Follow / Wait cues are positioned by their predecessor: select, don't drag.
                        dragMode = t.startMode == .timecode ? .trigger(t.id) : .seek
                        state.selectedTriggerID = t.id
                    } else if v.startLocation.y > sectionBand + flagBand {
                        dragMode = .pan(startView: viewStart)
                    } else {
                        dragMode = .seek
                    }
                }
                switch dragMode {
                case .some(.pan(let start)):
                    let maxStart = max(0, state.duration - Double(width) / state.zoom)
                    viewStart = min(maxStart, max(0, start - Double(v.translation.width) / state.zoom))
                    if abs(v.translation.width) > 3 { state.followPlayhead = false }
                case .some(.trigger(let id)):
                    guard abs(v.translation.width) > 2, let binding = state.binding(for: id) else { break }
                    var t = time(atX: v.location.x)
                    if state.snapToBeat, let a = state.project.analysis { t = TriggerGenerator.snap(t, to: a, subdivision: 4) }
                    binding.wrappedValue.time = t
                case .some(.seek):
                    state.seek(to: time(atX: v.location.x))
                case .none: break
                }
            }
            .onEnded { v in
                let moved = abs(v.translation.width) > 3
                var draggingTrigger = false
                if case .some(.trigger(_)) = dragMode { draggingTrigger = true }
                if !moved && !draggingTrigger { state.seek(to: time(atX: v.location.x)) }
                if draggingTrigger && moved { state.project.normalizeCues() }
                dragMode = nil
            }
    }

    // MARK: Drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let visibleEnd = viewStart + Double(size.width) / state.zoom
        let analysis = state.project.analysis
        let waveTop = sectionBand + flagBand
        let waveHeight = size.height - waveTop - 14
        let mid = waveTop + waveHeight / 2

        // Sections
        if let a = analysis {
            for s in a.sections where s.end > viewStart && s.start < visibleEnd {
                let r = CGRect(x: x(of: s.start), y: 0, width: x(of: s.end) - x(of: s.start), height: sectionBand)
                ctx.fill(Path(r), with: .color(sectionColor(s.kind).opacity(0.75)))
                ctx.fill(Path(CGRect(x: r.minX, y: waveTop, width: r.width, height: waveHeight)),
                         with: .color(sectionColor(s.kind).opacity(0.07)))
                ctx.stroke(Path { p in p.move(to: CGPoint(x: r.minX, y: 0)); p.addLine(to: CGPoint(x: r.minX, y: size.height)) },
                           with: .color(.primary.opacity(0.35)), lineWidth: 1)
                ctx.draw(Text("\(s.name)  [\(s.group)]").font(.caption.bold()).foregroundColor(.white),
                         at: CGPoint(x: max(r.minX, 0) + 6, y: sectionBand / 2), anchor: .leading)
            }
            // Breaks
            for b in a.breaks where b.end > viewStart && b.start < visibleEnd {
                let r = CGRect(x: x(of: b.start), y: waveTop, width: x(of: b.end) - x(of: b.start), height: waveHeight)
                ctx.fill(Path(r), with: .color(.red.opacity(0.12)))
                ctx.draw(Text("BREAK").font(.caption2.bold()).foregroundColor(.red), at: CGPoint(x: r.minX + 4, y: waveTop + 8), anchor: .leading)
            }
            // Beat grid
            if showBeats {
                let pxPerBeat = 60 / a.bpm * state.zoom
                for b in a.beats where b.time >= viewStart && b.time <= visibleEnd {
                    let isBar = b.beatInBar == 1
                    if !isBar && pxPerBeat < 6 { continue }
                    let bx = x(of: b.time)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: bx, y: waveTop)); p.addLine(to: CGPoint(x: bx, y: waveTop + waveHeight)) },
                               with: .color(.primary.opacity(isBar ? 0.25 : 0.08)), lineWidth: isBar ? 1 : 0.5)
                    if isBar && (pxPerBeat * 4 > 28 || b.bar % 4 == 1) {
                        ctx.draw(Text("\(b.bar)").font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                                 at: CGPoint(x: bx + 2, y: size.height - 7), anchor: .leading)
                    }
                }
            }
            // Waveform
            if !a.waveform.isEmpty && a.duration > 0 {
                var path = Path()
                let n = a.waveform.count
                let step: CGFloat = 1
                var px: CGFloat = 0
                while px < size.width {
                    let t0 = time(atX: px), t1 = time(atX: px + step)
                    let i0 = max(0, min(n - 1, Int(t0 / a.duration * Double(n))))
                    let i1 = max(i0 + 1, min(n, Int(t1 / a.duration * Double(n))))
                    let amp = CGFloat(a.waveform[i0..<i1].max() ?? 0)
                    let h = max(0.5, amp * waveHeight * 0.48)
                    path.addRect(CGRect(x: px, y: mid - h, width: step, height: h * 2))
                    px += step
                }
                ctx.fill(path, with: .color(Color.accentColor.opacity(0.55)))
            }
            // Snare hits
            if showSnares {
                for h in a.snares where h.time >= viewStart && h.time <= visibleEnd {
                    let sx = x(of: h.time)
                    let s = 3 + 3 * CGFloat(h.strength)
                    let y = waveTop + waveHeight - 10
                    var d = Path()
                    d.move(to: CGPoint(x: sx, y: y - s)); d.addLine(to: CGPoint(x: sx + s, y: y))
                    d.addLine(to: CGPoint(x: sx, y: y + s)); d.addLine(to: CGPoint(x: sx - s, y: y)); d.closeSubpath()
                    ctx.fill(d, with: .color(h.onGrid ? .orange : .orange.opacity(0.45)))
                }
            }
        }

        // Triggers
        for t in state.project.triggers where t.time >= viewStart - 10 && t.time <= visibleEnd {
            let tx = x(of: t.time)
            let selected = t.id == state.selectedTriggerID
            let fired = false  // fired / running state is shown in the cue list (keeps the waveform from redrawing on every cue)
            let color: Color = !t.enabled ? .gray : (fired ? .green : (selected ? .yellow : .accentColor))
            ctx.stroke(Path { p in p.move(to: CGPoint(x: tx, y: sectionBand)); p.addLine(to: CGPoint(x: tx, y: size.height - 14)) },
                       with: .color(color),
                       style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: t.startMode == .timecode ? [] : [4, 3]))
            let label = Text(t.name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
            let resolved = ctx.resolve(label)
            let ls = resolved.measure(in: CGSize(width: 200, height: flagBand))
            let flag = CGRect(x: tx, y: sectionBand + 1, width: ls.width + 8, height: flagBand - 2)
            ctx.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(color))
            ctx.draw(resolved, at: CGPoint(x: tx + 4, y: flag.midY), anchor: .leading)
        }
    }
}

/// Red playhead line over the detail view; also scrolls the view while following.
private struct PlayheadLayer: View {
    @EnvironmentObject var playback: PlaybackClock
    @Binding var viewStart: Double
    let zoom: Double
    let visible: Double
    let follow: Bool

    var body: some View {
        PlayheadCALayer(time: playback.currentTime, playing: playback.isPlaying, viewStart: viewStart, zoom: zoom)
            .allowsHitTesting(false)
            .onChange(of: playback.currentTime) { t in
                guard follow, playback.isPlaying else { return }
                if t < viewStart || t > viewStart + visible * 0.85 {
                    viewStart = max(0, t - visible * 0.15)
                }
            }
    }
}

/// The playhead line is a Core Animation layer that moves linearly at playback speed on the render
/// server. It keeps gliding even while the main thread is busy (e.g. when a cue fires and the cue list and
/// inspector update) and is only re-synced to the player when it drifts or the view scrolls / zooms.
private struct PlayheadCALayer: NSViewRepresentable {
    let time: Double
    let playing: Bool
    let viewStart: Double
    let zoom: Double

    func makeNSView(context: Context) -> PlayheadNSView { PlayheadNSView() }

    func updateNSView(_ view: PlayheadNSView, context: Context) {
        view.sync(time: time, playing: playing, viewStart: viewStart, zoom: zoom)
    }
}

final class PlayheadNSView: NSView {
    private let line = CALayer()
    private var animating = false
    private var lastViewStart = -1.0
    private var lastZoom = -1.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        line.backgroundColor = NSColor.systemRed.cgColor
        line.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.bounds = CGRect(x: 0, y: 0, width: 2, height: bounds.height)
        line.position.y = bounds.midY
        CATransaction.commit()
    }

    func sync(time: Double, playing: Bool, viewStart: Double, zoom: Double) {
        let x = CGFloat((time - viewStart) * zoom)
        let viewChanged = viewStart != lastViewStart || zoom != lastZoom
        lastViewStart = viewStart
        lastZoom = zoom
        if playing {
            if animating, !viewChanged, let shown = line.presentation()?.position.x {
                // Still on track (within ~40 ms of the player): leave the running animation alone.
                if abs(shown - x) <= max(2, CGFloat(zoom * 0.04)) { return }
            }
            let span: CFTimeInterval = 60
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = x
            anim.toValue = x + CGFloat(zoom * span)
            anim.duration = span
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            anim.isRemovedOnCompletion = false
            anim.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.removeAllAnimations()
            line.position.x = x
            line.add(anim, forKey: "playhead")
            CATransaction.commit()
            animating = true
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.removeAllAnimations()
            line.position.x = x
            CATransaction.commit()
            animating = false
        }
    }
}

/// Two-finger trackpad swipes (and the mouse wheel) over the waveform scroll it horizontally.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ precise: Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.onScroll = onScroll }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct OverviewPlayhead: View {
    @EnvironmentObject var playback: PlaybackClock
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.red)
                .frame(width: 2)
                .offset(x: CGFloat(playback.currentTime / max(duration, 0.001)) * geo.size.width - 1)
        }
        .allowsHitTesting(false)
    }
}

func sectionColor(_ kind: SectionKind) -> Color {
    switch kind {
    case .intro: return .teal
    case .verse: return .blue
    case .buildUp: return .orange
    case .chorus: return .pink
    case .breakdown: return .red
    case .bridge: return .purple
    case .outro: return .gray
    case .section: return .indigo
    }
}

/// Whole-song mini map: sections, triggers, the visible window and the playhead. Click to jump.
struct OverviewStrip: View {
    @EnvironmentObject var state: AppState
    @Binding var viewStart: Double

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let d = max(state.duration, 0.001)
                func x(_ t: Double) -> CGFloat { CGFloat(t / d) * size.width }
                if let a = state.project.analysis {
                    for s in a.sections {
                        ctx.fill(Path(CGRect(x: x(s.start), y: 0, width: x(s.end) - x(s.start), height: size.height)),
                                 with: .color(sectionColor(s.kind).opacity(0.35)))
                    }
                    if !a.energy.isEmpty {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: size.height))
                        for (i, e) in a.energy.enumerated() {
                            p.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(a.energy.count) * size.width, y: size.height * (1 - CGFloat(e) * 0.9)))
                        }
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        ctx.fill(p, with: .color(.primary.opacity(0.25)))
                    }
                }
                for t in state.project.triggers {
                    ctx.fill(Path(CGRect(x: x(t.time), y: 0, width: 1, height: size.height)), with: .color(.accentColor))
                }
                let visible = Double(geo.size.width) / state.zoom
                ctx.stroke(Path(CGRect(x: x(viewStart), y: 1, width: max(4, x(viewStart + visible) - x(viewStart)), height: size.height - 2)),
                           with: .color(.yellow), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let d = state.duration
                let visible = Double(geo.size.width) / state.zoom
                let t = Double(v.location.x / geo.size.width) * d
                viewStart = max(0, min(max(0, d - visible), t - visible / 2))
                state.followPlayhead = false
            })
            .overlay(OverviewPlayhead(duration: state.duration).clipped())
        }
        .background(Color.primary.opacity(0.05))
    }
}
#endif
