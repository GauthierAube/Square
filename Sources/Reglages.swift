// La fenêtre de réglages de Square, construite comme celle de Side et comme les Réglages Système de macOS :
// une barre latérale à gauche avec des rubriques à pastille colorée, et à droite le contenu en groupes.
import AppKit
import SwiftUI
import ServiceManagement

/// Les réglages, tels que la fenêtre les affiche. Chaque changement est enregistré tout de suite.
final class ReglagesModele: ObservableObject {
    @Published var auDemarrage = SMAppService.mainApp.status == .enabled {
        didSet {
            guard auDemarrage != (SMAppService.mainApp.status == .enabled) else { return }
            if auDemarrage { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
    @Published var raccourci = Raccourci.actuel.nom
    @Published var toucheDirecte = Appli.toucheDirecte {
        didSet { Appli.toucheDirecte = toucheDirecte; Programme.appli.brancherRaccourcisDirects() }
    }
    @Published var coin = Coin.choix { didSet { Coin.choix = coin } }
    @Published var agrandirAuto = AgrandirAuto.actif { didSet { AgrandirAuto.actif = agrandirAuto } }
    @Published var boutonVert = BoutonVert.actif { didSet { BoutonVert.actif = boutonVert } }
    @Published var dockAffiche = DockGrille.affiche { didSet { DockGrille.affiche = dockAffiche } }
    @Published var dockCote = DockGrille.cote { didSet { DockGrille.cote = dockCote } }
    @Published var dockCorbeille = DockGrille.corbeille { didSet { DockGrille.corbeille = dockCorbeille } }
    @Published var dockTaille = DockGrille.tailleIcones { didSet { DockGrille.tailleIcones = dockTaille } }
    @Published var dockLoupe = DockGrille.loupe { didSet { DockGrille.loupe = dockLoupe } }
    @Published var glisse = Glisse.actif { didSet { Glisse.actif = glisse } }
    @Published var inverse = Glisse.inverse { didSet { Glisse.inverse = inverse } }
    @Published var tailleCartes = Double(Carrousel.taille) { didSet { Carrousel.taille = CGFloat(tailleCartes.rounded()) } }
    @Published var delai = Glisse.attente { didSet { Glisse.attente = (delai * 100).rounded() / 100 } }

    /// Relit ce qui a pu changer ailleurs (le raccourci, modifié dans sa propre petite fenêtre).
    func relire() {
        raccourci = Raccourci.actuel.nom
    }
}

/// Les rubriques de la barre latérale.
enum VoletReglages: String, CaseIterable, Identifiable {
    case grille, dock, gestes, fenetres, general
    var id: String { rawValue }
    var titre: String {
        switch self {
        case .grille: return "Grille"
        case .dock: return "Dock"
        case .gestes: return "Gestes"
        case .fenetres: return "Fenêtres"
        case .general: return "Général"
        }
    }
    var symbole: String {
        switch self {
        case .grille: return "square.grid.2x2.fill"
        case .dock: return "dock.rectangle"
        case .gestes: return "hand.draw.fill"
        case .fenetres: return "macwindow"
        case .general: return "gearshape.fill"
        }
    }
    var couleur: Color {
        switch self {
        case .grille: return .blue
        case .dock: return .green
        case .gestes: return .orange
        case .fenetres: return .purple
        case .general: return .gray
        }
    }
}

struct ReglagesVue: View {
    @ObservedObject var m: ReglagesModele
    @State private var volet: VoletReglages

    init(m: ReglagesModele, depart: VoletReglages = .grille) {
        self.m = m
        _volet = State(initialValue: depart)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(VoletReglages.allCases) { ligne($0) }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 48)
            .padding(.bottom, 10)
            .frame(width: 210)
            .background(ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.primary.opacity(0.05)
            })
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(volet.titre).font(.title2.weight(.semibold))
                    .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 2)
                Form { contenu }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)   // remplit toute la fenêtre
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in m.relire() }
    }

    private func ligne(_ v: VoletReglages) -> some View {
        let choisi = v == volet
        return HStack(spacing: 9) {
            Image(systemName: v.symbole)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(v.couleur.gradient))
            Text(v.titre)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(choisi ? Color.primary.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { volet = v }
        .accessibilityAddTraits(choisi ? [.isButton, .isSelected] : .isButton)
    }

    private func curseur(_ titre: String, _ valeur: Binding<Double>, _ plage: ClosedRange<Double>, _ texte: String,
                         pendant: ((Bool) -> Void)? = nil) -> some View {
        LabeledContent(titre) {
            HStack {
                Slider(value: valeur, in: plage) { enCours in pendant?(enCours) }.frame(width: 190)
                Text(texte).monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            }
        }
    }

    private func note(_ texte: String) -> some View {
        Text(texte).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var contenu: some View {
        switch volet {
        case .grille:
            Section {
                LabeledContent("Raccourci") {
                    HStack {
                        Text(m.raccourci).foregroundStyle(.secondary)
                        Button("Changer…") { Programme.appli.reglerLeRaccourci() }
                    }
                }
                Picker("Aller à la fenêtre 1, 2, 3…", selection: $m.toucheDirecte) {
                    Text("⌘ + chiffre").tag("cmd")
                    Text("⌥ + chiffre").tag("opt")
                    Text("⌃ + chiffre").tag("ctrl")
                    Text("Désactivé").tag("aucun")
                }
            } header: { Text("Clavier") } footer: {
                note("La touche choisie avec un chiffre de 1 à 9 mène droit à la fenêtre de ce numéro, dans l'ordre des cases de la grille (le numéro s'affiche au survol d'une case). Attention : ces raccourcis sont alors pris à toutes les applications. ⌘ + chiffre sert par exemple à changer d'onglet dans Safari ou de présentation dans le Finder ; ⌃ + chiffre n'est presque jamais utilisé.")
            }
            Section {
                Picker("Coin actif", selection: $m.coin) {
                    ForEach(Coin.noms, id: \.0) { code, nom in Text(nom).tag(code) }
                }
            } header: { Text("Coin de l'écran") } footer: {
                note("Pousser la souris tout au fond de ce coin affiche la grille ; y revenir la referme. Si macOS utilise déjà ce coin, désactive-le dans Réglages Système > Bureau et Dock > Coins actifs.")
            }
            Section {
                LabeledContent("Cases vides") {
                    Button("Resserrer la grille") {
                        UserDefaults.standard.removeObject(forKey: "placesCases")
                        UserDefaults.standard.removeObject(forKey: "placesApps")
                    }
                }
            } header: { Text("Organisation") } footer: {
                note("Dans la grille : glisser une case sur le milieu d'une autre change l'ordre ; la glisser sur un bord partage l'écran entre les deux fenêtres ; deux doigts vers le haut sur une case ferment l'application.")
            }
        case .dock:
            Section {
                Toggle("Afficher le Dock dans la grille", isOn: $m.dockAffiche)
                Picker("Position", selection: $m.dockCote) {
                    Text("En bas").tag("bas")
                    Text("En haut").tag("haut")
                    Text("À gauche").tag("gauche")
                    Text("À droite").tag("droite")
                }
                .pickerStyle(.segmented)
                .disabled(!m.dockAffiche)
                Toggle("Afficher la corbeille au bout du Dock", isOn: $m.dockCorbeille).disabled(!m.dockAffiche)
            } header: { Text("Affichage") } footer: {
                note("La liste des applications s'ouvre toujours du côté intérieur de l'écran, avec sa pointe dirigée vers le Dock.")
            }
            Section {
                curseur("Taille des icônes", $m.dockTaille, 30...72, "\(Int(m.dockTaille.rounded())) pt")
                curseur("Grossissement au survol", $m.dockLoupe, 1...2,
                        m.dockLoupe < 1.005 ? "Aucun" : "+ \(Int(((m.dockLoupe - 1) * 100).rounded())) %")
            } header: { Text("Icônes") }
            .disabled(!m.dockAffiche)
            Section {
                LabeledContent("Repartir du Dock de macOS") {
                    Button("Recopier le Dock de macOS") { DockGrille.apps = DockGrille.appsDuDock() }
                }
            } header: { Text("Applications") } footer: {
                note("À sa première utilisation, ce Dock est une copie de celui de macOS ; ensuite il vit sa vie. Son premier bouton ouvre la liste de toutes les applications : Entrée ajoute au Dock l'application choisie, Suppr l'en retire. Un clic droit sur une icône permet de la retirer du Dock ou de quitter l'application.")
            }
        case .gestes:
            Section {
                Toggle("Passer d'une application à l'autre", isOn: $m.glisse)
                Picker("Sens", selection: $m.inverse) {
                    Text("Les cartes suivent les doigts").tag(false)
                    Text("Inversé").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!m.glisse)
            } header: { Text("Quatre doigts vers la gauche ou la droite") } footer: {
                note("Un effleurement rapide change d'application sans rien afficher. Un geste posé fait apparaître le carrousel, et l'application du centre passe devant quand les doigts se lèvent. Le geste ne s'active que s'il n'y a qu'un seul bureau ; sinon macOS glisse d'un bureau à l'autre.")
            }
            Section {
                curseur("Taille des cartes", $m.tailleCartes,
                        Double(Carrousel.tailles.lowerBound)...Double(Carrousel.tailles.upperBound),
                        "\(Int(m.tailleCartes.rounded())) pt") { enCours in Programme.appli.apercuDuCarrousel(enCours) }
                    .onChange(of: m.tailleCartes) { _, _ in Programme.appli.apercuDuCarrousel(true) }
                curseur("Apparition après un geste vif", $m.delai, 0.04...0.35, String(format: "%.2f s", m.delai))
            } header: { Text("Carrousel") } footer: {
                note("Pendant que tu règles la taille, le vrai carrousel s'affiche au milieu de l'écran. Apparition : plus court, le carrousel vient plus tôt mais un simple effleurement risque de l'afficher ; plus long, c'est l'inverse.")
            }
            .disabled(!m.glisse)
        case .fenetres:
            Section {
                Toggle("Agrandir chaque nouvelle fenêtre", isOn: $m.agrandirAuto)
            } header: { Text("Nouvelles fenêtres") } footer: {
                note("Chaque nouvelle fenêtre de travail remplit l'écran toute seule, sans passer en plein écran d'Apple.")
            }
            Section {
                LabeledContent("Applications du tiroir de Side") {
                    Text(AgrandirAuto.tuilesDeSide.isEmpty ? "Aucune" : "\(AgrandirAuto.tuilesDeSide.count)").foregroundStyle(.secondary)
                }
            } header: { Text("Jamais agrandies") } footer: {
                note("Les applications rangées dans le tiroir du bas de Side gardent leur place dans le tiroir : Square ne les agrandit pas. Leur liste se règle dans Side (Réglages > Tiroir du bas).")
            }
            Section {
                Toggle("Le bouton vert remplit l'écran", isOn: $m.boutonVert)
            } header: { Text("Bouton vert") } footer: {
                note("Un clic remplit l'écran en restant sur le même bureau ; un second rend à la fenêtre sa taille. Maj + clic ou Option + clic gardent le plein écran d'Apple.")
            }
            Section {
                LabeledContent("Fenêtres en plein écran d'Apple") {
                    Button("Les en sortir") { Agrandir.convertirTout() }
                }
            } header: { Text("Dépannage") } footer: {
                note("À utiliser seulement s'il reste des fenêtres dans un plein écran d'Apple : elles en sortent et remplissent l'écran à la place.")
            }
        case .general:
            Section("Démarrage") {
                Toggle("Lancer Square à l'ouverture du Mac", isOn: $m.auDemarrage)
            }
            Section("Présentation") {
                LabeledContent("Les gestes de Square, en images") {
                    Button("Revoir la présentation") { Accueil.montrer() }
                }
            }
        }
    }
}

/// La fenêtre elle-même : une seule, rouverte au même endroit.
enum Reglages {
    private static var fenetre: NSWindow?
    private static let modele = ReglagesModele()

    static func ouvrir() {
        if fenetre == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ReglagesVue(m: modele)))
            w.title = "Réglages de Square"
            // Comme les Réglages Système : barre de titre fondue dans le contenu, barre latérale à gauche.
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 760, height: 500))   // sinon une bande vide reste en bas
            w.isReleasedWhenClosed = false
            w.center()
            fenetre = w
        }
        modele.relire()
        NSApp.activate(ignoringOtherApps: true)
        fenetre?.makeKeyAndOrderFront(nil)
    }

    /// Pour les essais : dessine la fenêtre dans une image, sans rien afficher.
    static func image(_ volet: VoletReglages, vers sortie: URL) {
        let vue = NSHostingView(rootView: ReglagesVue(m: modele, depart: volet))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = vue
        vue.layoutSubtreeIfNeeded()
        guard let rep = vue.bitmapImageRepForCachingDisplay(in: vue.bounds) else { return }
        vue.cacheDisplay(in: vue.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: sortie)
    }
}
