// The menu bar item by the clock (Matt: "quick links to close App Starter, open it, start / stop the bundles,
// and each bundle's status"): every bundle with its light — green all up, red all down, yellow some of each —
// and a Start or Stop button; Open App Starter, Settings, Close App Starter. Closing App Starter leaves your
// apps running.
import SwiftUI
import AppStarterCore

struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("App Starter").fontWeight(.bold)
                Spacer()
                let all = model.bundles.flatMap(\.activeApps)
                Text("\(all.filter { model.isUp($0.id) }.count) of \(all.count) apps up").font(DS.secondary).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                legend(Theme.good, "all up"); legend(Theme.attention, "some up, some down"); legend(Theme.problem, "all down")
            }
            if model.bundles.isEmpty {
                Text("No bundles yet — make one in App Starter.").foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(model.bundles) { b in row(b) }
            Divider().padding(.vertical, 2)
            menuItem("Open App Starter", "macwindow") { openApp() }
            SettingsLink { Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 4).hoverHighlight().clipShape(RoundedRectangle(cornerRadius: 6))
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            menuItem("Close App Starter", "power", note: "your apps keep running") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 400)
        .font(DS.body)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Dot(color: c, size: 7); Text(t) }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func row(_ b: AppBundle) -> some View {
        let s = model.sessions[b.id]
        let busy = s?.isRunning ?? false
        let st = model.status(b)
        return HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small).frame(width: 12) } else { Dot(color: Theme.light(st), size: 10) }
            VStack(alignment: .leading, spacing: 1) {
                Text(b.name).fontWeight(.semibold).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(detail(b, s, st)).font(DS.secondary).foregroundStyle(s?.failure != nil ? Theme.attention : busy ? Theme.accent : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if busy {
                Button("Show") { openApp(); model.shownSession = s }.controlSize(.small)
            } else if st == .allUp {
                Button("Stop") { openApp(); model.askToStop = b }.controlSize(.small)
            } else if st != .empty && st != .allPaused {
                Button(st == .mixed ? "Start the rest" : "Start") { model.run(b, .starting, show: false) }.controlSize(.small).buttonStyle(.borderedProminent)
                if st == .mixed { Button("Stop") { openApp(); model.askToStop = b }.controlSize(.small) }
            }
        }
        .padding(8)
        .background(DS.surface(scheme), in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSmall).strokeBorder(DS.edge(scheme)))
    }

    private func detail(_ b: AppBundle, _ s: RunSession?, _ st: BundleStatus) -> String {
        if let s, s.isRunning {
            if s.failure != nil { return "Needs you — a step failed" }
            return "\(s.phase == .starting ? "Starting" : "Stopping") · step \(s.stepIndex + 1) of \(s.steps.count)"
        }
        let n = b.apps.count
        if st == .mixed { return "\(model.upCount(b)) of \(n) up" }
        return "\(st.label) · \(n) app\(n == 1 ? "" : "s")"
    }

    private func menuItem(_ title: String, _ icon: String, note: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon)
                if let note { Text("— \(note)").font(DS.secondary).foregroundStyle(.secondary) }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 4).hoverHighlight().clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func openApp() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
