// Starting or stopping a bundle, as it happens (mockup "one step failed"): a line per step, the apps of the
// step under way with their progress, and — when a step fails — the end of the failed app's log with Retry,
// Skip it and go on, and Stop what started. "Hide — keep it going" closes the sheet; the run carries on.
import SwiftUI
import AppStarterCore

struct RunSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RunSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(DS.heading)
                    Text(subtitle).font(DS.secondary).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView(value: session.fraction).frame(width: 180)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(session.steps.enumerated()), id: \.element.id) { i, step in stepCard(i, step) }
                    if session.failure != nil {
                        Text("Paused: the next step waits until every app in this one is \(session.phase == .starting ? "up" : "down"), or you skip the one that failed.")
                            .font(DS.secondary).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if session.isRunning && session.failure == nil {
                    Button("Cancel") { session.cancel() }.help("Stops waiting. Whatever has started stays as it is.")
                }
                Spacer()
                if session.isRunning { Button("Hide — keep it going") { model.shownSession = nil }.keyboardShortcut(.cancelAction) }
                else { Button("Done") { model.dismiss(session) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 720, height: 640)
    }

    private var subtitle: String {
        let took = Engine.duration((session.finishedAt ?? Date()).timeIntervalSince(session.startedAt))
        if session.isRunning { return "Step \(session.stepIndex + 1) of \(session.steps.count) · \(took)" }
        return "Took \(took)"
    }

    private enum StepState { case waiting, working, done, failed }

    private func state(_ i: Int, _ step: Step) -> StepState {
        let ps = step.apps.map { session.progress[$0.id] ?? .waiting }
        if ps.contains(where: { if case .failed = $0 { return true }; return false }) { return .failed }
        if ps.allSatisfy({ if case .done = $0 { return true }; if case .skipped = $0 { return true }; return false }) { return .done }
        if i < session.stepIndex || (i == session.stepIndex && session.isRunning) { return .working }
        return .waiting
    }

    @ViewBuilder private func stepCard(_ i: Int, _ step: Step) -> some View {
        let st = state(i, step)
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    mark(st)
                    Text("\(i + 1) · \(step.title.isEmpty ? "Sub-bundle" : step.title)").fontWeight(.semibold)
                    Spacer()
                    Text(summary(step, st)).font(DS.secondary).foregroundStyle(st == .failed ? Theme.problem : .secondary)
                }
                // the apps, while the step is under way or when it has news
                if step.isGroup || st == .working || st == .failed {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(step.apps) { a in appLine(a) }
                    }
                    .padding(.leading, 28)
                }
                if st == .failed, let f = session.failure, f.stepIndex == i {
                    ForEach(f.apps, id: \.id) { fa in
                        Text(model.engine.logs.tail(fa.id, bytes: 1200).split(separator: "\n").suffix(8).joined(separator: "\n"))
                            .font(DS.mono).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: DS.radiusSmall))
                            .padding(.leading, 28)
                    }
                    HStack(spacing: 8) {
                        Button(f.apps.count == 1 ? "Retry \(f.apps[0].name)" : "Retry them") { session.choose(.retry) }.buttonStyle(.borderedProminent)
                        Button(f.apps.count == 1 ? "Skip it and go on" : "Skip them and go on") { session.choose(.skip) }
                        Button(session.phase == .starting ? "Stop what started" : "End here") { session.choose(.giveUp) }
                            .foregroundStyle(Theme.problem)
                        if let a = session.bundle.app(f.apps[0].id) { Button("Full log") { model.shownSession = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.sheet = .logs(bundleId: session.bundle.id, app: a.id) } }.buttonStyle(.link).foregroundStyle(Theme.accent) }
                    }
                    .padding(.leading, 28)
                }
            }
        }
    }

    @ViewBuilder private func mark(_ s: StepState) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.system(size: 17))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.problem).font(.system(size: 17))
        case .working: ProgressView().controlSize(.small).frame(width: 18)
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary).font(.system(size: 17))
        }
    }

    private func summary(_ step: Step, _ s: StepState) -> String {
        switch s {
        case .waiting: return "waiting"
        case .working: return session.phase == .starting ? "starting…" : "stopping…"
        case .failed:
            let n = step.apps.filter { if case .failed = session.progress[$0.id] { return true }; return false }.count
            return "\(n) of \(step.apps.count) did not \(session.phase == .starting ? "start" : "stop")"
        case .done:
            if step.apps.count == 1, case .done(let note) = session.progress[step.apps[0].id] { return note }
            return step.apps.map(\.name).joined(separator: ", ")
        }
    }

    private func appLine(_ a: AppItem) -> some View {
        let p = session.progress[a.id] ?? .waiting
        let (color, text): (Color, String) = {
            switch p {
            case .waiting: return (.secondary, "waiting")
            case .working(let w): return (Theme.accent, w)
            case .done(let n): return (Theme.good, n)
            case .failed(let f): return (Theme.problem, f)
            case .skipped: return (Theme.attention, "skipped")
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Dot(color: color)
            Text(a.name).fontWeight(.medium)
            Text(text).font(DS.secondary).foregroundStyle(p == .waiting ? .secondary : color).lineLimit(2)
        }
    }
}

/// A bundle's logs (Matt: "a Logs button in the bundle itself"): its applications down the left, in start order
/// and by step; the chosen one's log on the right — the newest part, following along while it is open — with
/// Show in Finder and Clear.
struct BundleLogs: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bundleId: UUID
    /// the app shown first (nil = the bundle's first app)
    let initial: UUID?
    @State private var selected: UUID?
    @State private var text = ""
    @State private var follow = true
    @State private var confirmClear = false

    private var bundle: AppBundle? { model.bundle(bundleId) }
    private var app: AppItem? { bundle?.apps.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs — \(bundle?.name ?? "")").font(DS.heading)
                Spacer()
                Toggle("Follow along", isOn: $follow).toggleStyle(.checkbox).help("Refresh every two seconds while this is open")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selected) {
                    if let b = bundle {
                        ForEach(Array(b.steps.enumerated()), id: \.element.id) { i, step in
                            Section("\(i + 1) · \(step.title.isEmpty ? "Sub-bundle" : step.title)") {
                                ForEach(step.apps) { a in
                                    HStack(spacing: 8) {
                                        Dot(color: model.isUp(a.id) ? Theme.good : Theme.problem)
                                        Text(a.name).lineLimit(1)
                                        Spacer()
                                        Text(size(a.id)).font(DS.secondary).foregroundStyle(.secondary)
                                    }
                                    .tag(a.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 250)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let a = app {
                        HStack {
                            Text(a.name).font(DS.section)
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.engine.logs.url(a.id)]) }
                            Button("Clear…") { confirmClear = true }
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(text.isEmpty ? "Nothing yet — the log fills in when App Starter starts or stops this app." : text)
                                    .font(DS.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .background(DS.panel(.light), in: RoundedRectangle(cornerRadius: DS.radiusSmall))
                            .onAppear { proxy.scrollTo("end") }
                            .onChange(of: text) { _, _ in if follow { proxy.scrollTo("end") } }
                        }
                        Text("The newest part is shown; a log is trimmed once it passes \(model.settings.logLimitMB) MB (Settings → Logs). Secret values are hidden in App Starter's own lines; what the app prints itself appears as it is.")
                            .font(DS.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Choose an application on the left.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 980, height: 640)
        // chosen once the list is on screen: a List picks its own row while it first lays out
        .onAppear { DispatchQueue.main.async { selected = initial ?? bundle?.apps.first?.id } }
        // load now, and again every two seconds while following
        .task(id: selected) {
            load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if follow { load() }
            }
        }
        .confirmationDialog("Clear the log of “\(app?.name ?? "")”?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear log") { if let a = app { model.engine.logs.clear(a.id); load() } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        }
    }

    private func load() {
        guard let id = selected else { text = ""; return }
        let t = model.engine.logs.tail(id)
        if t != text { text = t }
    }

    private func size(_ id: UUID) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: model.engine.logs.url(id).path))?[.size] as? Int ?? 0
        return bytes == 0 ? "empty" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
