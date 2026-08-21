import AppKit
import SwiftUI
import UserNotifications

// MARK: - State model (mirrors ~/.claude/pokemon-state.json written by the engine)

struct EvolutionOption: Decodable, Identifiable {
    var species_id: Int
    var name: String
    var sprites: [String: String]?
    var id: Int { species_id }

    /// Branches past gen 5 have no animated sprite, so artwork stands in.
    var spritePath: String? {
        sprites?["animated"] ?? sprites?["artwork"]
    }
}

struct PendingEvolution: Decodable {
    var stage: Int
    var level: Int
    var options: [EvolutionOption]
}

struct Display: Decodable {
    var name: String
    var level: Int
    var xp: Int
    var xp_next: Int?
    var pct: Int
    var types: [String]
    var emoji: String
    var today_xp: Int
    var caught: Int
    var commits: Int?
    var unclaimed: Int?
    var next_evo: String?
    var next_evo_level: Int?
    var sprites: [String: String]
    var cry: String?
    var pending_evolution: PendingEvolution?
}

struct PokedexEntry: Decodable, Identifiable {
    var species_id: Int
    var name: String
    var level: Int
    var source: String?
    var id: Int { species_id }

    /// Trained to 100 versus awarded for starting a project, so the Pokedex
    /// keeps showing what was actually raised.
    var badge: String { source == "project" ? "Obtenido" : "Lv.\(level)" }
}

struct Candidate: Decodable, Identifiable {
    var species_id: Int
    var name: String
    var id: Int { species_id }
}

struct TrainerEvent: Decodable {
    var type: String
    var at: String
    var from: String?
    var to: String?
    var who: String?
    var level: Int?
    var at_level: Int?
    var species_id: Int?
}

/// Wrapper that turns an undecodable element into nil instead of failing the
/// whole array. One malformed event must never cost the user the menu bar.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct TrainerState: Decodable {
    var display: Display?
    var pokedex: [PokedexEntry] = []
    var candidates: [Candidate] = []
    var events: [TrainerEvent] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case display, pokedex, candidates, events
    }

    /// Every section is decoded independently and degrades to a default, so a
    /// change in one part of the state file cannot blank the entire UI.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try? container.decodeIfPresent(Display.self, forKey: .display)
        pokedex = (try? container.decode([Lossy<PokedexEntry>].self, forKey: .pokedex))?
            .compactMap(\.value) ?? []
        candidates = (try? container.decode([Lossy<Candidate>].self, forKey: .candidates))?
            .compactMap(\.value) ?? []
        events = (try? container.decode([Lossy<TrainerEvent>].self, forKey: .events))?
            .compactMap(\.value) ?? []
    }
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
        view.image = NSImage(contentsOfFile: path)
        view.animates = true
    }
}

// MARK: - Engine bridge

enum PanelRoute {
    case active, pokedex, picker, evolution
}

@MainActor
final class Trainer: ObservableObject {
    @Published var state = TrainerState()
    @Published var isWorking = false
    @Published var isLoadingCandidates = false

    private let statePath = NSHomeDirectory() + "/.claude/pokemon-state.json"
    private var timer: Timer?
    private let notificationDelegate = NotificationDelegate()

    /// Timestamp of the newest event already announced. Persisted so a restart
    /// does not replay milestones the user has already been told about.
    private var lastEventSeen: String {
        get { UserDefaults.standard.string(forKey: "lastEventSeen") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastEventSeen") }
    }

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Notifier.requestAuthorization()

        load()
        // Seed the watermark on first launch so a fresh install does not fire a
        // burst of notifications for history that already happened.
        if lastEventSeen.isEmpty, let newest = state.events.map(\.at).max() {
            lastEventSeen = newest
        }

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
        announceNewEvents()
    }

    /// Posts a banner for every event newer than the watermark. ISO-8601 UTC
    /// strings sort lexicographically, so a plain string compare is enough.
    private func announceNewEvents() {
        let fresh = state.events.filter { $0.at > lastEventSeen }
        guard !fresh.isEmpty else { return }
        lastEventSeen = state.events.map(\.at).max() ?? lastEventSeen

        for event in fresh {
            switch event.type {
            case "pre_evolution":
                guard let from = event.from, let to = event.to, let level = event.level else { continue }
                Notifier.post(title: "Train Your Pokemon",
                              subtitle: "\(from.capitalized) Lv.\(event.at_level ?? 0)",
                              body: "Está a punto de evolucionar a \(to.capitalized) en el nivel \(level).")

            case "evolution":
                guard let from = event.from, let to = event.to else { continue }
                Notifier.post(title: "¡Evolución!",
                              subtitle: "\(from.capitalized) → \(to.capitalized)",
                              body: "Tu \(from.capitalized) evolucionó a \(to.capitalized).")
                playCry(speciesID: event.species_id)

            case "caught":
                guard let who = event.who else { continue }
                Notifier.post(title: "¡Nivel 100!",
                              subtitle: who.capitalized,
                              body: "\(who.capitalized) llegó al máximo y entró a tu Pokédex. Ya puedes entrenar a otro.")
                playCry(speciesID: event.species_id)

            default:
                continue
            }
        }
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

    /// Plays the active Pokemon's cry. The engine caches the file and records
    /// its path in the display block, so no Python process is needed here.
    ///
    /// macOS CoreAudio decodes Ogg Vorbis natively (afinfo reports type 'Oggf'),
    /// which is the format PokeAPI serves, so afplay needs no conversion step.
    func playCry(speciesID: Int? = nil) {
        let path: String?
        if let speciesID {
            path = "\(Config.repoPath)/assets/cries/\(speciesID)-legacy.ogg"
        } else {
            path = state.display?.cry
        }
        guard let cry = path, FileManager.default.fileExists(atPath: cry) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [cry]
        try? process.run()
    }

    /// Spends a project reward on a species, which goes straight to the Pokedex.
    func claim(_ speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["claim", String(speciesID)])
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.playCry(speciesID: speciesID)
            }
        }
    }

    /// Resolves a branching evolution once the trainer picks a form.
    func evolve(into speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["evolve", String(speciesID)])
            await MainActor.run {
                self.load()
                self.playCry(speciesID: speciesID)
            }
        }
    }

    func loadCandidates() {
        guard !isLoadingCandidates else { return }
        isLoadingCandidates = true
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.isLoadingCandidates = false
            }
        }
    }

    /// Starts training a new species. Only offered at level 100, where the
    /// current Pokemon is already stored in the Pokedex and nothing is lost.
    func swap(to speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["choose", String(speciesID)])
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.playCry()
            }
        }
    }

    /// nonisolated so it can run off the main thread: a scan takes ~130ms and
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
    @State private var route: PanelRoute = .active
    /// The picker is shared: it either swaps who is being trained, or spends a
    /// project reward. This says which.
    @State private var claiming = false

    var body: some View {
        VStack(spacing: 0) {
            switch route {
            case .active: activeView
            case .pokedex: pokedexView
            case .picker: pickerView
            case .evolution: evolutionView
            }
        }
        .frame(width: 280)
        .padding(14)
        .onAppear {
            // Re-read on open so the panel never shows stale numbers, and so a
            // pending milestone is announced right away instead of waiting out
            // the 30s timer.
            trainer.load()
            trainer.playCry()
        }
    }

    @ViewBuilder
    private var activeView: some View {
        if let display = trainer.state.display {
            if let gif = display.sprites["animated"] {
                AnimatedSprite(path: gif)
                    .frame(width: 96, height: 96)
                    .onTapGesture { trainer.playCry() }
                    .help("Clic para escuchar su grito")
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

            // A branching chain stops here until a form is picked, so this is
            // the one thing the panel must surface above everything else.
            if let pending = display.pending_evolution {
                Button {
                    route = .evolution
                } label: {
                    Label("¡Listo para evolucionar! Elige entre \(pending.options.count)",
                          systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            } else if let evo = display.next_evo, let level = display.next_evo_level {
                Text("Evoluciona a \(evo.capitalized) en Lv.\(level)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Divider().padding(.vertical, 10)

            HStack {
                Label("\(display.today_xp.formatted()) XP hoy", systemImage: "bolt.fill")
                Spacer()
                Label("\(display.commits ?? 0)", systemImage: "arrow.triangle.branch")
                Spacer()
                Label("\(display.caught)", systemImage: "checkmark.seal.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Earned by starting a new project. Rare enough to be worth a
            // whole Pokemon without crowding the Pokedex.
            if let unclaimed = display.unclaimed, unclaimed > 0 {
                Button {
                    trainer.loadCandidates()
                    claiming = true
                    route = .picker
                } label: {
                    Label("\(unclaimed) Pokémon por reclamar", systemImage: "gift.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }

            Divider().padding(.vertical, 10)

            Button {
                route = .pokedex
            } label: {
                Label("Ver Pokédex (\(trainer.state.pokedex.count))", systemImage: "book.fill")
                    .frame(maxWidth: .infinity)
            }

            // Swapping resets XP, so it is only offered once the current
            // Pokemon is maxed out and already stored in the Pokedex. The
            // engine enforces the same rule independently.
            if display.level >= 100 {
                Button {
                    trainer.loadCandidates()
                    route = .picker
                } label: {
                    Label("Entrenar otro Pokémon", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            } else {
                Text("Podrás cambiar de Pokémon al llegar a nivel 100.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
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
                            Text(entry.badge)
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button("‹ Volver") { route = .active }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var evolutionView: some View {
        if let pending = trainer.state.display?.pending_evolution {
            VStack(alignment: .leading, spacing: 10) {
                Text("Elige su evolución").font(.headline)
                Text("Alcanzó el nivel \(pending.level). Esta decisión es definitiva.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(pending.options) { option in
                            Button {
                                trainer.evolve(into: option.species_id)
                                route = .active
                            } label: {
                                VStack(spacing: 2) {
                                    if let image = Sprites.image(option.spritePath) {
                                        Image(nsImage: image)
                                            .resizable().interpolation(.none)
                                            .scaledToFit().frame(height: 34)
                                    } else {
                                        Color.clear.frame(height: 34)
                                    }
                                    Text(option.name.capitalized)
                                        .font(.system(size: 8)).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)

                Button("‹ Decidir después") { route = .active }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        } else {
            // The choice was resolved elsewhere (CLI, or another click).
            Color.clear.frame(height: 1).onAppear { route = .active }
        }
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(claiming ? "Reclamar Pokémon" : "Elegir Pokémon").font(.headline)
                Spacer()
                Text("\(trainer.state.candidates.count) disponibles")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(claiming
                 ? "Entra directo a tu Pokédex, marcado como obtenido."
                 : "Empieza en nivel 1 desde la base de su línea evolutiva.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if trainer.isLoadingCandidates && trainer.state.candidates.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Cargando…").font(.caption)
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(trainer.state.candidates) { candidate in
                            Button {
                                if claiming {
                                    trainer.claim(candidate.species_id)
                                    claiming = false
                                } else {
                                    trainer.swap(to: candidate.species_id)
                                }
                                route = .active
                            } label: {
                                VStack(spacing: 2) {
                                    if let image = Sprites.image(Sprites.spritePath(speciesID: candidate.species_id)) {
                                        Image(nsImage: image)
                                            .resizable().interpolation(.none)
                                            .scaledToFit().frame(height: 30)
                                    } else {
                                        Color.clear.frame(height: 30)
                                    }
                                    Text(candidate.name.capitalized)
                                        .font(.system(size: 8)).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Button("‹ Volver") { route = .active }
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
