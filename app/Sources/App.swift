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

/// One row of the Pokedex: a species, and whether it was ever owned. Unowned
/// entries carry no name — the games show ????? until you have had one, and the
/// engine skips 600-odd lookups by not resolving them.
struct DexEntry: Decodable, Identifiable {
    var species_id: Int
    var name: String?
    var registered: Bool
    var shiny: Bool
    var sprite: String?
    var id: Int { species_id }
}

/// The whole registry, read from its own file rather than the state the menu bar
/// reloads every 30 seconds: 649 entries is too much to carry there.
struct Dex: Decodable {
    var total: Int
    var registered: Int
    var entries: [Lossy<DexEntry>]

    var rows: [DexEntry] { entries.compactMap(\.value) }
}

/// One Pokemon on the team. Only the active one earns XP; the rest are frozen
/// at the level they were benched at.
struct PartyMember: Decodable, Identifiable {
    var species_id: Int
    var name: String
    var level: Int
    var pct: Int
    var shiny: Bool?
    var active: Bool
    var sprites: [String: String]?
    var id: Int { species_id }

    var spritePath: String? { sprites?["animated"] ?? sprites?["artwork"] }
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
    var can_retire: Bool?
    var retire_level: Int?
    var shiny: Bool?
    var next_evo: String?
    var next_evo_level: Int?
    var sprites: [String: String]
    var cry: String?
    var pending_evolution: PendingEvolution?
    /// Wrapped so a single malformed member degrades to one missing row instead
    /// of failing the whole Display and blanking the menu bar.
    var party: [Lossy<PartyMember>]?
    var party_size: Int?
    /// Species ever owned, against `caught` which counts what the PC holds.
    var dex_registered: Int?
    var dex_total: Int?

    var partyMembers: [PartyMember] { (party ?? []).compactMap(\.value) }
    var bench: [PartyMember] { partyMembers.filter { !$0.active } }
}

struct PokedexEntry: Decodable, Identifiable {
    var species_id: Int
    var name: String
    var level: Int
    var source: String?
    var maxed: Bool?
    var shiny: Bool?
    var id: Int { species_id }

    /// Distinguishes what was awarded, what was retired early, and what was
    /// pushed all the way to 100 — the pace is the trainer's choice, so the
    /// Pokedex has to show which choice each entry represents.
    var badge: String {
        let mark = shiny == true ? "✨" : ""
        if source == "project" { return mark + "Obtenido" }
        return mark + (maxed == true ? "★ Lv.100" : "Lv.\(level)")
    }

    /// Put away rather than finished: deposited below the retirement floor, so
    /// it sits in the PC without counting towards the collection.
    var isStored: Bool { source == "stored" }
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
    var choices: Int?
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
    case active, pokedex, picker, evolution, party, dex
}

/// What the shared candidate grid is being opened for. An enum rather than a
/// flag per case: the three are mutually exclusive and a stray combination of
/// booleans would silently pick the wrong action.
enum PickerPurpose {
    case claim, retire
}

@MainActor
final class Trainer: ObservableObject {
    @Published var state = TrainerState()
    @Published var isWorking = false
    @Published var isLoadingCandidates = false
    @Published var isLoadingDex = false
    @Published var dex: Dex?

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
            // Evolution waits for the panel, so this is an invitation rather
            // than an announcement: the change has not happened yet.
            case "ready_to_evolve":
                guard let who = event.who else { continue }
                let branches = (event.choices ?? 1) > 1
                Notifier.post(title: "¡\(who.capitalized) está listo para evolucionar!",
                              subtitle: "Nivel \(event.level ?? 0)",
                              body: branches
                                    ? "Abre la barra de menús para elegir su forma."
                                    : "Abre la barra de menús para verlo evolucionar.")

            case "caught":
                guard let who = event.who else { continue }
                Notifier.post(title: "¡Nivel 100!",
                              subtitle: who.capitalized,
                              body: "\(who.capitalized) llegó al máximo y quedó guardado en el PC. Ya puedes entrenar a otro.")
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

    /// Files the current Pokemon in the Pokedex and starts the next one. Both
    /// happen at once so the panel is never left without an active Pokemon.
    func retire(startingWith speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["retire", String(speciesID)])
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.playCry(speciesID: speciesID)
            }
        }
    }

    /// Files the current Pokemon and hands training to the next one on the
    /// bench, so retiring shrinks the team instead of replacing a member.
    func retireAndPromote() {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["retire"])
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.playCry()
            }
        }
    }

    /// Benches the current Pokemon and picks up another from the team. Nothing
    /// is filed and no XP moves — this is putting one down, not finishing it.
    func switchTo(_ speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["switch", String(speciesID)])
            await MainActor.run {
                self.load()
                self.playCry(speciesID: speciesID)
            }
        }
    }

    /// Puts a team member in the PC at whatever level it is, which is the only
    /// way to free a slot below the retirement floor. Nothing is lost: the entry
    /// is marked as stored and can be taken back out.
    func deposit(_ speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["deposit", String(speciesID)])
            Self.runEngine(["candidates"])
            await MainActor.run { self.load() }
        }
    }

    /// Takes a stored Pokemon back out and resumes training it. The entry
    /// leaves storage while it is on the team and returns on the next
    /// retirement, at whatever level it reached by then.
    func withdraw(_ speciesID: Int) {
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["withdraw", String(speciesID)])
            Self.runEngine(["candidates"])
            await MainActor.run {
                self.load()
                self.playCry(speciesID: speciesID)
            }
        }
    }

    /// Spends a project reward on a species, which goes straight to storage.
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

    /// Rebuilds the registry and reads it back. The first run downloads a sprite
    /// for every species in range (~12s); afterwards they are on disk.
    func loadDex() {
        guard !isLoadingDex else { return }
        isLoadingDex = true
        Task.detached(priority: .userInitiated) {
            Self.runEngine(["dex"])
            let path = NSHomeDirectory() + "/.claude/pokemon-dex.json"
            let decoded = FileManager.default.contents(atPath: path)
                .flatMap { try? JSONDecoder().decode(Dex.self, from: $0) }
            await MainActor.run {
                if let decoded { self.dex = decoded }
                self.isLoadingDex = false
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
    /// The candidate grid is shared by three flows; this says which one opened it.
    @State private var picking: PickerPurpose = .retire
    /// Form the animation is currently morphing into, once chosen.
    @State private var evolvingTo: EvolutionOption?
    /// Stored Pokemon awaiting confirmation to come back out. The grid cells are
    /// small and sit four to a row, so a tap asks before it acts.
    @State private var withdrawing: PokedexEntry?
    /// The PC is reachable from the main view and from the team, so "back" has
    /// to return where it was opened from.
    @State private var storageReturn: PanelRoute = .active
    /// Team member awaiting confirmation to go to the PC. Offered only with a
    /// full team, which is the one situation where a slot has to be freed.
    @State private var depositing: PartyMember?

    var body: some View {
        VStack(spacing: 0) {
            switch route {
            case .active: activeView
            case .pokedex: pokedexView
            case .picker: pickerView
            case .evolution: evolutionView
            case .party: partyView
            case .dex: dexView
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

            Text(display.shiny == true
                 ? "✨ \(display.name.capitalized) ✨"
                 : display.name.capitalized)
                .font(.title2.bold())
                .foregroundStyle(display.shiny == true ? .yellow : .primary)
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
                    // Names what will actually happen. "Elige entre 1" made no
                    // sense on the single-option case, which is most of them.
                    Label(pending.options.count > 1
                          ? "Elegir evolución · \(pending.options.count) formas"
                          : "Evolucionar a \(pending.options.first?.name.capitalized ?? "")",
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
                    picking = .claim
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
                route = .party
            } label: {
                Label("Equipo (\(display.partyMembers.count)/\(display.party_size ?? 6))",
                      systemImage: "person.2.fill")
                    .frame(maxWidth: .infinity)
            }

            Button {
                trainer.loadDex()
                route = .dex
            } label: {
                Label("Pokédex (\(display.dex_registered ?? 0)/\(display.dex_total ?? 649))",
                      systemImage: "book.fill")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 6)

            Button {
                withdrawing = nil
                storageReturn = .active
                route = .pokedex
            } label: {
                Label("PC de Bill (\(trainer.state.pokedex.count))", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 6)

            // Retiring files the Pokemon at whatever level it reached and
            // starts the next one. The floor exists so an entry still means
            // something; the engine enforces it independently.
            if display.can_retire == true {
                // With someone on the bench, retiring hands training over to
                // them and the team shrinks by one — which is also the only way
                // to free a slot. With an empty bench there is nobody to
                // promote, so a new species has to be picked.
                let next = display.bench.first
                Button {
                    if next != nil {
                        trainer.retireAndPromote()
                    } else {
                        trainer.loadCandidates()
                        picking = .retire
                        route = .picker
                    }
                } label: {
                    Label(retireLabel(display: display, next: next),
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                // A ternary of two styles will not typecheck: they are
                // different types. The prominent slot belongs to evolution.
                .buttonStyle(.bordered)
                .padding(.top, 6)
            } else {
                Text("Podrás retirarlo desde el nivel \(display.retire_level ?? 50).")
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

    /// Names what retiring will actually do, which depends on whether anyone is
    /// waiting on the bench to take over.
    private func retireLabel(display: Display, next: PartyMember?) -> String {
        let at = display.level >= 100 ? "Retirar" : "Retirar en Lv.\(display.level)"
        guard let next else { return "\(at) y entrenar otro" }
        return "\(at) y seguir con \(next.name.capitalized)"
    }

    private var partyView: some View {
        let display = trainer.state.display
        let members = display?.partyMembers ?? []
        let capacity = display?.party_size ?? 6

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equipo").font(.headline)
                Spacer()
                Text("\(members.count)/\(capacity)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Solo el que estás entrenando gana XP. Los demás quedan congelados en su nivel hasta que los retomes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let full = members.count >= capacity

            if let member = depositing {
                depositConfirmation(member)
            }

            VStack(spacing: 6) {
                ForEach(members) { member in
                    HStack(spacing: 2) {
                        Button {
                            // The active member is already training; tapping it
                            // would bench and unbench the same Pokemon.
                            guard !member.active else { return }
                            trainer.switchTo(member.species_id)
                            route = .active
                        } label: {
                            partyRow(member)
                        }
                        .buttonStyle(.plain)
                        .disabled(member.active)

                        // Shown only with a full team. Freeing a slot is the
                        // only reason to put a Pokemon away, and an always-on
                        // control here would just be a way to mis-tap.
                        if full {
                            Button {
                                depositing = member
                            } label: {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Enviar a \(member.name.capitalized) al PC")
                        }
                    }
                }
            }

            // A team slot is filled from the PC and nowhere else. Handing out
            // fresh species here would bypass both routes that make getting a
            // Pokemon mean something — retiring one at the floor, or being
            // awarded one for starting a project — and turn the roster into
            // something asked for rather than earned.
            if members.count < capacity {
                if !withdrawableEntries.isEmpty {
                    Button {
                        withdrawing = nil
                        storageReturn = .party
                        route = .pokedex
                    } label: {
                        Label("Sacar del PC (\(withdrawableEntries.count))",
                              systemImage: "tray.and.arrow.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    // Spelling out the two steps matters: an earlier version put
                    // "Lv.40" and "cupo" in one sentence and read as if reaching
                    // 40 handed you a team slot. It does not — it lets you
                    // retire, retiring fills the PC, and the PC fills the slot.
                    Text(emptyPCHint(display))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Equipo completo. Envía a uno al PC para hacer espacio — vuelve con su nivel cuando lo saques.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("‹ Volver") {
                depositing = nil
                route = .active
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// The floor that gates retiring does not apply here, because depositing is
    /// not a way into the collection: the entry is marked as stored and left out
    /// of the caught count, so it frees the slot without cheapening anything.
    private func depositConfirmation(_ member: PartyMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("¿Enviar a \(member.name.capitalized) Lv.\(member.level) al PC?")
                .font(.caption.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(member.active
                 ? "Libera un cupo y pasa a entrenar el primero de la banca. Queda guardado con su nivel y no cuenta como capturado."
                 : "Libera un cupo. Queda guardado con su nivel y no cuenta como capturado.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Enviar al PC") {
                    trainer.deposit(member.species_id)
                    depositing = nil
                }
                .buttonStyle(.borderedProminent)
                Button("Cancelar") { depositing = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Why an empty slot cannot be filled yet, in the order the steps actually
    /// happen. Names the level the Pokemon being trained is at, so the distance
    /// to retiring is a number rather than a rule to work out.
    private func emptyPCHint(_ display: Display?) -> String {
        let floor = display?.retire_level ?? 40
        let base = "Un cupo se llena sacando a alguien del PC, y el PC está vacío. "
            + "Un Pokémon llega al PC al retirarlo, o al ganarlo empezando un proyecto nuevo."
        guard let display else { return base }
        if display.level >= floor {
            return base + " Ya puedes retirar a \(display.name.capitalized)."
        }
        return base + " Retirar necesita Lv.\(floor), y \(display.name.capitalized) va en \(display.level)."
    }

    private func partyRow(_ member: PartyMember) -> some View {
        HStack(spacing: 8) {
            if let image = Sprites.image(member.spritePath) {
                Image(nsImage: image)
                    .resizable().interpolation(.none)
                    .scaledToFit().frame(width: 32, height: 32)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(member.shiny == true
                         ? "✨ \(member.name.capitalized)"
                         : member.name.capitalized)
                        .font(.caption.bold())
                        .foregroundStyle(member.shiny == true ? .yellow : .primary)
                    Spacer()
                    Text("Lv.\(member.level)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                XPBar(pct: member.pct)
            }

            // Marks who is earning XP, so the row that cannot be tapped also
            // explains why.
            Image(systemName: member.active ? "bolt.fill" : "pause.circle")
                .font(.caption)
                // Both branches typed as Color on purpose: `.tertiary` is a
                // different ShapeStyle, and a ternary of two styles will not
                // typecheck.
                .foregroundStyle(member.active ? Color.yellow : Color.secondary.opacity(0.6))
        }
        .padding(6)
        .background(member.active ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var dexView: some View {
        let dex = trainer.dex

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pokédex").font(.headline)
                Spacer()
                Text("\(dex?.registered ?? trainer.state.display?.dex_registered ?? 0)"
                     + "/\(dex?.total ?? trainer.state.display?.dex_total ?? 649)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Text("Se registra al momento de tener una, y nunca baja. Las que faltan salen en silueta.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let dex {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                              spacing: 8) {
                        ForEach(dex.rows) { entry in
                            dexCell(entry)
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(trainer.isLoadingDex
                         ? "Armando la Pokédex…"
                         : "Sin datos todavía.")
                        .font(.caption).foregroundStyle(.secondary)
                    // Only the first build pays for the sprites; after that the
                    // whole range is on disk.
                    Text("La primera vez baja el sprite de las 649.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(height: 120)
            }

            Button("‹ Volver") { route = .active }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private func dexCell(_ entry: DexEntry) -> some View {
        VStack(spacing: 1) {
            if let path = entry.sprite {
                if entry.registered {
                    if let image = Sprites.image(path) {
                        Image(nsImage: image)
                            .resizable().interpolation(.none)
                            .scaledToFit().frame(height: 28)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                } else if let shape = Sprites.silhouette(path, color: .secondaryLabelColor) {
                    // Label colour rather than white: this has to read on both
                    // the light and the dark panel.
                    Image(nsImage: shape)
                        .resizable().interpolation(.none)
                        .scaledToFit().frame(height: 28)
                        .opacity(0.45)
                } else {
                    Color.clear.frame(height: 28)
                }
            } else {
                Color.clear.frame(height: 28)
            }

            Text(entry.registered
                 ? (entry.shiny ? "✨" : "") + (entry.name?.capitalized ?? "?????")
                 : "#\(String(format: "%03d", entry.species_id))")
                .font(.system(size: 7))
                .lineLimit(1)
                .foregroundStyle(entry.registered ? .secondary : .tertiary)
        }
        .help(entry.registered
              ? "\(entry.name?.capitalized ?? "") · Nº\(entry.species_id)"
              : "Nº\(entry.species_id) — todavía no la tienes")
    }

    private var pokedexView: some View {
        let display = trainer.state.display
        let members = display?.partyMembers ?? []
        let capacity = display?.party_size ?? 6
        let roomLeft = members.count < capacity

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PC de Bill").font(.headline)
                Spacer()
                Text(storageCountLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if trainer.state.pokedex.isEmpty {
                Text("El PC está vacío.\nRetira al que estás entrenando para guardar el primero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
            } else {
                // Confirms before acting: the cells are small, four to a row,
                // and a mis-tap would put a stored Pokemon back into training.
                if let entry = withdrawing {
                    withdrawConfirmation(entry, roomLeft: roomLeft, capacity: capacity)
                } else {
                    Text("Toca a uno para sacarlo y seguir entrenándolo. Vuelve al PC cuando lo retires.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(trainer.state.pokedex) { entry in
                            // A Pokemon that reached 100 is stored while still
                            // being trained, so it can be in both places at once.
                            let onTeam = members.contains { $0.species_id == entry.species_id }
                            Button {
                                withdrawing = entry
                            } label: {
                                VStack(spacing: 2) {
                                    if let image = Sprites.image(Sprites.spritePath(speciesID: entry.species_id)) {
                                        Image(nsImage: image)
                                            .resizable().interpolation(.none)
                                            .scaledToFit().frame(height: 32)
                                            // Dimmed when already on the team,
                                            // and again when it was only parked
                                            // rather than trained to the floor.
                                            .opacity(onTeam ? 0.4 : (entry.isStored ? 0.75 : 1))
                                    }
                                    Text(entry.name.capitalized)
                                        .font(.system(size: 8)).lineLimit(1)
                                    Text(onTeam ? "en el equipo" : entry.badge)
                                        .font(.system(size: 8))
                                        .foregroundStyle(entry.isStored ? Color.secondary.opacity(0.7)
                                                                        : Color.secondary)
                                }
                                .padding(3)
                                .background(withdrawing?.species_id == entry.species_id
                                            ? Color.accentColor.opacity(0.20) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onTeam)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            Button("‹ Volver") {
                withdrawing = nil
                route = storageReturn
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func withdrawConfirmation(_ entry: PokedexEntry,
                                      roomLeft: Bool,
                                      capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if roomLeft {
                Text("¿Sacar a \(entry.name.capitalized) \(entry.badge) del PC?")
                    .font(.caption.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pasa a ser el que entrenas y sale del PC hasta que lo retires.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sacar") {
                        trainer.withdraw(entry.species_id)
                        withdrawing = nil
                        route = .active
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancelar") { withdrawing = nil }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Equipo completo (\(capacity)). Retira a uno para hacerle espacio a \(entry.name.capitalized).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancelar") { withdrawing = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var evolutionView: some View {
        if let pending = trainer.state.display?.pending_evolution {
            // One option evolves straight away; a branch asks first, then the
            // animation plays for whichever form was picked.
            if let target = evolvingTo ?? (pending.options.count == 1 ? pending.options.first : nil),
               let fromPath = trainer.state.display?.sprites["animated"],
               let toPath = target.spritePath {
                VStack(spacing: 8) {
                    EvolutionAnimation(fromPath: fromPath, toPath: toPath) {
                        trainer.evolve(into: target.species_id)
                        evolvingTo = nil
                        route = .active
                    }
                    Text("¿Qué? ¡\(trainer.state.display?.name.capitalized ?? "") está evolucionando!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 150)
            } else {
                branchPicker(pending)
            }
        } else {
            // Resolved elsewhere (CLI, or a second click).
            Color.clear.frame(height: 1).onAppear { route = .active }
        }
    }

    private func branchPicker(_ pending: PendingEvolution) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Elige su evolución").font(.headline)
            Text("Alcanzó el nivel \(pending.level). Esta decisión es definitiva.")
                .font(.caption2)
                .foregroundStyle(.secondary)

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(pending.options) { option in
                            Button {
                                // Hands off to the animation; the evolution is
                                // committed when it finishes.
                                evolvingTo = option
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
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(pickerTitle).font(.headline)
                Spacer()
                Text("\(trainer.state.candidates.count) disponibles")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(pickerSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if trainer.isLoadingCandidates && trainer.state.candidates.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Cargando…").font(.caption)
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    spriteGrid(trainer.state.candidates) { candidate in
                        switch picking {
                        case .claim:
                            trainer.claim(candidate.species_id)
                        case .retire:
                            trainer.retire(startingWith: candidate.species_id)
                        }
                        route = .active
                    } cell: { candidate in
                        (candidate.species_id, candidate.name, nil)
                    }
                }
                .frame(maxHeight: 220)
            }

            Button("‹ Volver") { route = .active }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// The PC holds everything; only finished stints count as collected, so both
    /// numbers are shown when they differ.
    private var storageCountLabel: String {
        let total = trainer.state.pokedex.count
        let caught = trainer.state.pokedex.filter { !$0.isStored }.count
        return caught == total ? "\(total) guardados"
                               : "\(total) guardados · \(caught) capturados"
    }

    /// Stored Pokemon that could come out: everything in the PC except one that
    /// reached 100 and is therefore stored while still on the team.
    private var withdrawableEntries: [PokedexEntry] {
        let onTeam = Set((trainer.state.display?.partyMembers ?? []).map(\.species_id))
        return trainer.state.pokedex.filter { !onTeam.contains($0.species_id) }
    }

    /// The four-across sprite grid both sections use. `cell` supplies what to
    /// draw for an item; `action` what tapping it does.
    private func spriteGrid<Item: Identifiable>(
        _ items: [Item],
        action: @escaping (Item) -> Void,
        cell: @escaping (Item) -> (Int, String, String?)
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
            ForEach(items) { item in
                let (speciesID, name, caption) = cell(item)
                Button {
                    action(item)
                } label: {
                    VStack(spacing: 2) {
                        if let image = Sprites.image(Sprites.spritePath(speciesID: speciesID)) {
                            Image(nsImage: image)
                                .resizable().interpolation(.none)
                                .scaledToFit().frame(height: 30)
                        } else {
                            Color.clear.frame(height: 30)
                        }
                        Text(name.capitalized)
                            .font(.system(size: 8)).lineLimit(1)
                        if let caption {
                            Text(caption)
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pickerTitle: String {
        switch picking {
        case .claim: return "Reclamar Pokémon"
        case .retire: return "Elegir Pokémon"
        }
    }

    private var pickerSubtitle: String {
        switch picking {
        case .claim:
            return "Entra directo al PC de Bill, marcado como obtenido."
        case .retire:
            return "Empieza en nivel 1 desde la base de su línea evolutiva."
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
