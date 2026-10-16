// Example bundles for trying App Starter out and for screenshots (APPSTARTER_SAMPLE=1 with a scratch
// APPSTARTER_HOME). Their commands only make and remove marker files in a "sample-apps" folder there —
// they never touch a real app.
import Foundation
import AppStarterCore

enum Sample {
    static func bundles() -> [AppBundle] {
        let dir = Home.folder().appendingPathComponent("sample-apps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func fake(_ name: String, _ file: String, delay: String = "0.5") -> AppItem {
            AppItem(name: name, workingFolder: dir.path, start: "sleep \(delay)\ntouch \(file).up", stop: "rm -f \(file).up",
                    health: .output(command: "test -f \(file).up && echo UP", contains: "UP", ignoreCase: false), waitSeconds: 20)
        }
        var trading = fake("AI Trading Desk", "desk", delay: "1")
        trading.env = [EnvVar(name: "DESK_MODE", value: "sandbox"), EnvVar(name: "OPENAI_API_KEY", value: "sk-example-not-real", secret: true)]
        let everything = AppBundle(name: "Mac mini — everything", steps: [
            Step(group: "Local AI", apps: [fake("Ollama", "ollama"), fake("MLX server", "mlx")]),
            Step(group: "Everyday apps", apps: [fake("People Manager", "people"), fake("My Business Manager", "mbm"), fake("Junk Tracker", "junk"), fake("AI Data Depot", "depot")]),
            Step(app: trading),
            Step(app: AppItem(name: "App Router", workingFolder: dir.path, start: "touch router.up", stop: "rm -f router.up", health: .returnCode)),
        ])
        var ai = AppBundle(name: "AI stack", steps: [
            Step(app: fake("Docker Desktop", "docker")),
            Step(group: "Models", apps: [fake("Open WebUI", "webui"), fake("Whisper", "whisper")]),
        ])
        ai.startAtLogin = false
        let desk = AppBundle(name: "Trading Desk", steps: [Step(app: fake("AI Trading Desk (alone)", "desk2"))])
        return [everything, ai, desk]
    }
}
