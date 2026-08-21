import AppKit
import SwiftUI

// MARK: - State model (mirrors ~/.claude/pokemon-state.json written by the engine)

struct Display: Codable {
    var name: String
    var level: Int
    var xp: Int
    var xp_next: Int?
    var pct: Int
    var types: [String]
    var emoji: String
    var today_xp: Int
    var caught: Int
    var next_evo: String?
    var next_evo_level: Int?
    var sprites: [String: String]
}

struct PokedexEntry: Codable, Identifiable {
    var species_id: Int
    var name: String
    var level: Int
    var id: Int { species_id }
}

struct TrainerState: Codable {
    var display: Display?
    var pokedex: [PokedexEntry] = []
}

/// NSImageView animates GIFs natively; SwiftUI's Image renders only one frame.
/// Used only inside the panel, which is open for a few seconds at a time.
struct AnimatedSprite: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.image = NSImage(contentsOfFile: path)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image?.name() != path {
            view.image = NSImage(contentsOfFile: path)
            view.animates = true
        }
    }
}

// MARK: - Engine bridge

@MainActor
final class Trainer: ObservableObject {
    @Published var state = TrainerState()
    @Published var isWorking = false

    private let statePath = NSHomeDirectory() + "/.claude/pokemon-state.json"
    private var timer: Timer?

    init() {
        load()
        // The engine scan costs ~130ms, so a 30s cadence is cheap and keeps the
        // level close to real time without polling aggressively.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let decoded = try? JSONDecoder().decode(TrainerState.self, from: data)
        else { return }
        state = decoded
    }

    /// Runs the engine off the main thread, then reloads the state it wrote.
    func refresh() {
        guard !isWorking else { return }
        isWorking = true
        Task.detached(priority: .background) {
            Self.runEngine(["scan"])
            await MainActor.run {
                self.load()
                self.isWorking = false
            }
        }
    }

    func swap(to speciesID: Int) {
        Task.detached(priority: .background) {
            Self.runEngine(["choose", String(speciesID)])
            await MainActor.run { self.load() }
        }
    }

    /// nonisolated so it can run off the main thread: the scan takes ~130ms and
    /// would otherwise block the UI while the panel is open.
    nonisolated private static func runEngine(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["\(Config.repoPath)/engine/poketrainer.py"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Panel

struct XPBar: View {
    let pct: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(pct) / 100)
            }
        }
        .frame(height: 8)
    }
}

struct TrainerPanel: View {
    @ObservedObject var trainer: Trainer
    @State private var showingPokedex = false

    var body: some View {
        VStack(spacing: 0) {
            if showingPokedex {
                pokedexView
            } else {
                activeView
            }
        }
        .frame(width: 280)
        .padding(14)
    }

    @ViewBuilder
    private var activeView: some View {
        if let display = trainer.state.display {
            if let gif = display.sprites["animated"] {
                AnimatedSprite(path: gif)
                    .frame(width: 96, height: 96)
            }

            Text(display.name.capitalized)
                .font(.title2.bold())
            Text("\(display.emoji) \(display.types.map(\.capitalized).joined(separator: " / "))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Nivel \(display.level)")
                .font(.headline)
                .padding(.top, 8)

            XPBar(pct: display.pct)
                .padding(.vertical, 4)

            if let next = display.xp_next {
                Text("\(display.xp.formatted()) / \(next.formatted()) XP")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let evo = display.next_evo, let level = display.next_evo_level {
                Text("Evoluciona a \(evo.capitalized) en Lv.\(level)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Divider().padding(.vertical, 10)

            HStack {
                Label("\(display.today_xp.formatted()) XP hoy", systemImage: "bolt.fill")
                Spacer()
                Label("\(display.caught)", systemImage: "checkmark.seal.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider().padding(.vertical, 10)

            Button {
                showingPokedex = true
            } label: {
                Label("Ver Pokédex (\(trainer.state.pokedex.count))", systemImage: "book.fill")
                    .frame(maxWidth: .infinity)
            }

            if display.level >= 100 {
                Button("Entrenar otro Pokémon") { showingPokedex = true }
                    .padding(.top, 4)
            }

            Button("Salir") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Calculando XP…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 120)
        }
    }

    private var pokedexView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pokédex").font(.headline)
                Spacer()
                Text("\(trainer.state.pokedex.count) capturados")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if trainer.state.pokedex.isEmpty {
                Text("Todavía no capturas ninguno.\nLlega a nivel 100 para sumar el primero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(trainer.state.pokedex) { entry in
                        VStack(spacing: 2) {
                            if let image = Sprites.image(Sprites.spritePath(speciesID: entry.species_id)) {
                                Image(nsImage: image)
                                    .resizable().interpolation(.none)
                                    .scaledToFit().frame(height: 32)
                            }
                            Text(entry.name.capitalized)
                                .font(.system(size: 8)).lineLimit(1)
                            Text("Lv.\(entry.level)")
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button("‹ Volver") { showingPokedex = false }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

// MARK: - App

@main
struct TrainYourPokemonApp: App {
    @StateObject private var trainer = Trainer()

    var body: some Scene {
        MenuBarExtra {
            TrainerPanel(trainer: trainer)
        } label: {
            // Static frame in the bar: animating 58 frames at 10 fps forever
            // would mean ~36,000 redraws per hour on a CPU without efficiency
            // cores. The panel animates instead.
            if let path = trainer.state.display?.sprites["animated"],
               let image = Sprites.menuBarIcon(path) {
                // The NSImage already carries the right point size, so it must
                // NOT be made resizable here: that lets the bar stretch it past
                // its own height and clip the sprite.
                Image(nsImage: image)
            } else {
                Image(systemName: "bolt.circle")
            }
            if let level = trainer.state.display?.level {
                Text("Lv.\(level)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
