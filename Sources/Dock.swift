// Le Dock de la grille : une rangée d'icônes en bas, toujours visible, pour ouvrir une application d'un clic.
// La loupe au survol est celle du mini-Dock de Side, reprise calcul pour calcul : maximale sous le pointeur, elle retombe
// en cosinus jusqu'à deux icônes et demie de distance, et les icônes voisines s'écartent réellement.
// Pour la fluidité : chaque icône est une image préparée une fois pour toutes en grand, que la carte graphique étire ;
// rien n'est redessiné pendant le survol, et l'affichage est calé sur le rythme de l'écran.
import AppKit
import QuartzCore

final class DockGrille: NSView {
    var auLancement: ((String) -> Void)?
    var auBoutonApps: (() -> Void)?
    var auCorbeille: (() -> Void)?
    private var rangCorbeille = -1
    /// Afficher la corbeille au bout du Dock.
    static var corbeille: Bool {
        get { UserDefaults.standard.object(forKey: "dockCorbeille") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockCorbeille") }
    }

    // Mêmes mesures que le mini-Dock de Side.
    static let marge: CGFloat = 6, ecart: CGFloat = 6
    static let bas: CGFloat = 22                       // distance entre le Dock et le bas de l'écran
    private var t: CGFloat = 46                        // taille des icônes au repos
    private var grossissement: CGFloat = 1.25
    private var epaisseur: CGFloat { t + 14 }
    /// De quel côté de l'écran se tient le Dock : "bas", "haut", "gauche" ou "droite". Et s'il est affiché.
    static var cote: String {
        get { UserDefaults.standard.string(forKey: "dockCote") ?? "bas" }
        set { UserDefaults.standard.set(newValue, forKey: "dockCote") }
    }
    static var affiche: Bool {
        get { UserDefaults.standard.object(forKey: "dockAffiche") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockAffiche") }
    }
    private var cote = "bas"
    private var vertical: Bool { cote == "gauche" || cote == "droite" }
    /// Distance entre le Dock et le bord de l'écran (en haut, il passe sous l'encoche de la caméra).
    private var bord: CGFloat { Self.bas + (cote == "haut" ? (window?.screen?.safeAreaInsets.top ?? 0) : 0) }
    /// Place à réserver pour lui dans la grille, du côté où il se tient.
    var reserve: CGFloat { isHidden ? 0 : bord + epaisseur + 18 }
    /// La longueur disponible le long du Dock.
    private var axe: CGFloat { vertical ? bounds.height : bounds.width }

    /// Un rectangle décrit le long du Dock : `a` est la distance depuis le début (la gauche, ou le haut pour un Dock vertical),
    /// `l` sa longueur, `c` sa distance au bord de l'écran où se tient le Dock, `e` son épaisseur.
    private func cadre(_ a: CGFloat, _ l: CGFloat, _ c: CGFloat, _ e: CGFloat) -> CGRect {
        switch cote {
        case "haut": return CGRect(x: a, y: bounds.height - c - e, width: l, height: e)
        case "gauche": return CGRect(x: c, y: bounds.height - a - l, width: e, height: l)
        case "droite": return CGRect(x: bounds.width - c - e, y: bounds.height - a - l, width: e, height: l)
        default: return CGRect(x: a, y: c, width: l, height: e)
        }
    }
    /// Où se trouve un point de la vue le long du Dock.
    private func leLong(_ p: CGPoint) -> CGFloat { vertical ? bounds.height - p.y : p.x }

    private var chemins: [String] = []
    private var cases: [(l: CGFloat, icone: Bool)] = []
    private var calques: [CALayer] = []                // un calque par case : une icône, ou un trait
    private var cadres: [CGRect] = []                  // la place actuelle de chaque case
    private var points: [Int: CALayer] = [:]
    private let pastille = CALayer()
    private var zone: NSTrackingArea?

    // La loupe : où est le pointeur le long du Dock, et à quel point elle est « allumée » (0 à 1).
    private var souris: CGFloat = 0
    private var force: CGFloat = 0
    private var forceDepart: CGFloat = 0, forceCible: CGFloat = 0, forceDebut: TimeInterval = 0, forceDuree: TimeInterval = 0.16
    private var lien: CADisplayLink?
    private var aRedessiner = false

    /// Les applications du Dock. À la première utilisation, c'est une copie du Dock de macOS, dans le même ordre ;
    /// la liste est enregistrée tout de suite, et ensuite ce Dock vit sa vie.
    static var apps: [String] {
        get {
            if let l = UserDefaults.standard.stringArray(forKey: "dockApps") { return l.filter { FileManager.default.fileExists(atPath: $0) } }
            let duDock = appsDuDock()
            if !duDock.isEmpty { UserDefaults.standard.set(duDock, forKey: "dockApps") }
            return duDock
        }
        set { UserDefaults.standard.set(newValue, forKey: "dockApps") }
    }

    /// Les applications gardées dans le Dock de macOS, dans leur ordre.
    static func appsDuDock() -> [String] {
        let tuiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        var vues = Set<String>()
        return tuiles.compactMap { tuile -> String? in
            guard let donnees = tuile["tile-data"] as? [String: Any],
                  let fichier = donnees["file-data"] as? [String: Any],
                  let adresse = fichier["_CFURLString"] as? String,
                  let url = URL(string: adresse) ?? URL(string: adresse.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
                  url.isFileURL else { return nil }
            let chemin = url.standardizedFileURL.path
            guard chemin.hasSuffix(".app"), FileManager.default.fileExists(atPath: chemin), vues.insert(chemin).inserted else { return nil }
            return chemin
        }
    }

    /// Taille des icônes au repos, et de combien grossit celle qui est sous le pointeur (1 = pas du tout, 2 = deux fois).
    static var tailleIcones: Double {
        get { UserDefaults.standard.object(forKey: "dockTaille") as? Double ?? 46 }
        set { UserDefaults.standard.set(newValue, forKey: "dockTaille") }
    }
    static var loupe: Double {
        get { UserDefaults.standard.object(forKey: "dockLoupe") as? Double ?? 1.25 }
        set { UserDefaults.standard.set(newValue, forKey: "dockLoupe") }
    }

    static func basculer(_ chemin: String) {
        var l = apps
        if let i = l.firstIndex(of: chemin) { l.remove(at: i) } else { l.append(chemin) }
        apps = l
    }

    private static let iconeApps: NSImage = {
        let apps = "/System/Applications/Apps.app"
        return NSWorkspace.shared.icon(forFile: FileManager.default.fileExists(atPath: apps) ? apps : "/Applications")
    }()
    /// Les icônes déjà préparées, par chemin et par taille.
    private static var prepares: [String: CGImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pastille.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        pastille.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        pastille.borderWidth = 1
        layer?.addSublayer(pastille)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// L'icône, dessinée une seule fois à sa plus grande taille (grossie, et à la finesse de l'écran).
    private func image(_ icone: NSImage, cle: String) -> CGImage? {
        let pixels = Int((t * grossissement * (window?.backingScaleFactor ?? 2)).rounded(.up))
        let nom = "\(cle)|\(pixels)"
        if let deja = DockGrille.prepares[nom] { return deja }
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let avant = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        icone.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.current = avant
        let img = ctx.makeImage()
        DockGrille.prepares[nom] = img
        return img
    }

    func charger() {
        t = CGFloat(min(max(DockGrille.tailleIcones, 30), 72))
        grossissement = CGFloat(min(max(DockGrille.loupe, 1), 2))
        chemins = DockGrille.apps
        cote = DockGrille.cote
        isHidden = !DockGrille.affiche
        calques.forEach { $0.removeFromSuperlayer() }
        points.values.forEach { $0.removeFromSuperlayer() }
        points = [:]
        // Tout à gauche : le bouton « Apps », puis un trait, puis les applications.
        cases = [(t, true), (1, false)] + Array(repeating: (t, true), count: chemins.count)
        // Tout au bout, après un trait : la corbeille (elle s'ouvre dans le Finder).
        let avecCorbeille = DockGrille.corbeille
        if avecCorbeille { cases += [(1, false), (t, true)] }
        rangCorbeille = avecCorbeille ? cases.count - 1 : -1
        let ouvertes = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        calques = cases.enumerated().map { i, k in
            let c = CALayer()
            if !k.icone {
                c.backgroundColor = NSColor(white: 1, alpha: 0.3).cgColor
            } else {
                let chemin = (i == 0 || i == rangCorbeille) ? "" : chemins[i - 2]
                if i == rangCorbeille {
                    c.contents = image(NSImage(named: NSImage.trashFullName) ?? NSImage(named: NSImage.trashEmptyName) ?? NSImage(), cle: "corbeille")
                } else {
                    c.contents = image(i == 0 ? DockGrille.iconeApps : NSWorkspace.shared.icon(forFile: chemin), cle: i == 0 ? "apps" : chemin)
                }
                c.contentsGravity = .resizeAspect
                c.minificationFilter = .trilinear
                c.magnificationFilter = .linear
                // Un petit point sous les applications déjà ouvertes.
                if i > 0, i != rangCorbeille, ouvertes.contains(chemin) {
                    let p = CALayer()
                    p.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
                    p.cornerRadius = 2
                    layer?.addSublayer(p)
                    points[i] = p
                }
            }
            layer?.addSublayer(c)
            return c
        }
        CATransaction.commit()
        force = 0; forceCible = 0
        arreterLeLien()
        disposer()
    }

    // MARK: La loupe (calculs repris du mini-Dock de Side)

    /// Le grossissement de chaque case quand le pointeur vise le point `m` du Dock au repos.
    private func echelles(_ m: CGFloat, _ f: CGFloat) -> [CGFloat] {
        let plus = (grossissement - 1) * f, portee = 2.5 * (t + Self.ecart)
        var debut = Self.marge
        return cases.map { k in
            defer { debut += k.l + Self.ecart }
            guard k.icone, plus > 0 else { return 1 }
            let d = min(1, abs(debut + k.l / 2 - m) / portee)
            return 1 + plus * 0.5 * (1 + cos(.pi * d))
        }
    }

    /// Où se retrouve, dans le Dock grossi, le point `m` du Dock au repos (le Dock grossi déborde autant des deux côtés).
    private func position(_ m: CGFloat, _ f: CGFloat) -> CGFloat {
        let e = echelles(m, f)
        let enPlus = zip(cases, e).reduce(0) { $0 + $1.0.l * ($1.1 - 1) }
        var repos = Self.marge, grossi = Self.marge
        for (k, s) in zip(cases, e) {
            if m <= repos { return grossi - (repos - m) - enPlus / 2 }
            if m <= repos + k.l { return grossi + (m - repos) * s - enPlus / 2 }
            repos += k.l + Self.ecart; grossi += k.l * s + Self.ecart
        }
        return grossi - (repos - m) - enPlus / 2
    }

    private var repos: CGFloat {
        2 * Self.marge + cases.reduce(0) { $0 + $1.l } + Self.ecart * CGFloat(max(0, cases.count - 1))
    }

    /// Les icônes se décalent en grossissant : on cherche quel point du Dock au repos se trouve sous le pointeur maintenant
    /// (par approches successives), puis on grossit autour de lui. Sans cela, l'icône visée glisserait sous la souris.
    private func echellesActuelles() -> [CGFloat] {
        guard force > 0 else { return cases.map { _ in 1 } }
        let x = souris - (axe - repos) / 2
        var bas: CGFloat = 0, haut = repos
        for _ in 0..<14 {
            let milieu = (bas + haut) / 2
            if position(milieu, force) < x { bas = milieu } else { haut = milieu }
        }
        return echelles((bas + haut) / 2, force)
    }

    override func layout() {
        super.layout()
        disposer()
    }

    /// Place la pastille et les icônes. Rien n'est redessiné : seuls des calques changent de place et de taille.
    private func disposer() {
        guard !cases.isEmpty, calques.count == cases.count else { return }
        let e = echellesActuelles()
        let enPlus = zip(cases, e).reduce(0) { $0 + $1.0.l * ($1.1 - 1) }
        let largeur = repos + enPlus
        let a0 = (axe - largeur) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pastille.frame = cadre(a0, largeur, bord, epaisseur)
        pastille.cornerRadius = min(22, epaisseur / 2.6)
        var a = a0 + Self.marge
        // Le bord des icônes tourné vers l'extérieur de l'écran ne bouge pas : elles grossissent vers l'intérieur.
        cadres = []
        for (i, k) in cases.enumerated() {
            let l = k.l * e[i]
            let r = k.icone ? cadre(a, l, bord + 9, l) : cadre(a, 1, bord + epaisseur * 0.15, epaisseur * 0.7)
            calques[i].frame = r
            cadres.append(r)
            points[i]?.frame = cadre(a + l / 2 - 2, 4, bord + 3, 4)
            a += l + Self.ecart
        }
        CATransaction.commit()
    }

    /// Où accrocher la liste des applications : le milieu du bouton « Apps » (au repos), sur le bord du Dock tourné vers
    /// l'intérieur de l'écran, dans les coordonnées de l'écran. Et le côté où se tient le Dock.
    var ancreBoutonApps: (point: NSPoint, cote: String) {
        let r = cadre((axe - repos) / 2 + Self.marge + t / 2, 0, bord + epaisseur, 0)
        let p = NSPoint(x: r.midX, y: r.midY)
        return (window?.convertPoint(toScreen: convert(p, to: nil)) ?? p, cote)
    }

    /// La case sous ce point, d'après la place réelle des icônes (grossies ou non).
    private func rang(_ p: CGPoint) -> Int? {
        for (i, r) in cadres.enumerated() where cases[i].icone { if r.insetBy(dx: -Self.ecart / 2, dy: -8).contains(p) { return i } }
        return nil
    }

    /// La pastille, avec ce qui dépasse au-dessus quand les icônes grossissent.
    private var zoneActive: CGRect {
        let largeur = vertical ? pastille.frame.height : pastille.frame.width
        return cadre((axe - largeur) / 2 - 2, largeur + 4, bord, epaisseur + t * (grossissement - 1) * force)
    }

    /// Hors de la pastille, le Dock laisse passer les clics vers la grille.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let s = superview else { return nil }
        return zoneActive.contains(convert(point, from: s)) ? self : nil
    }

    // MARK: Le pointeur sur le Dock : la loupe s'allume en douceur, puis le suit sans retard

    private func viser(_ cible: CGFloat, duree: TimeInterval) {
        if cible != forceCible {
            forceDepart = force; forceCible = cible; forceDuree = duree
            forceDebut = CACurrentMediaTime()
        }
        if cible > 0 || force > 0 { lancerLeLien() }
    }

    private func lancerLeLien() {
        guard lien == nil else { return }
        let l = displayLink(target: self, selector: #selector(battre))
        l.add(to: .main, forMode: .common)
        lien = l
    }

    private func arreterLeLien() { lien?.invalidate(); lien = nil }

    // Mesure de régularité (une ligne dans le journal à la fin de chaque survol) : nombre d'images, durée moyenne et pire écart.
    private var imagePrecedente: CFTimeInterval = 0
    private var mesures: (n: Int, somme: Double, pire: Double, calcul: Double) = (0, 0, 0, 0)
    private var visee: CGFloat = 0           // où est vraiment le pointeur ; `souris` le rejoint en quelques millisecondes

    /// Une fois par image affichée à l'écran : on lit la position du pointeur à cet instant précis (sans attendre les
    /// événements de souris, que macOS regroupe et distribue irrégulièrement à une application qui n'est pas au premier plan),
    /// la force de la loupe avance, et le Dock se replace.
    @objc private func battre() {
        let maintenant = CACurrentMediaTime()
        let dt = imagePrecedente > 0 ? maintenant - imagePrecedente : 1.0 / 120
        imagePrecedente = maintenant
        var bouge = false
        if let w = window {
            let p = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if zoneActive.insetBy(dx: -4, dy: -4).contains(p) {
                visee = leLong(p)
                if forceCible != 1 { forceDepart = force; forceCible = 1; forceDuree = 0.16; forceDebut = maintenant }
            } else if forceCible != 0 {
                forceDepart = force; forceCible = 0; forceDuree = 0.22; forceDebut = maintenant
            }
        }
        // Le pointeur est suivi de très près, avec un soupçon d'amorti (15 ms) qui gomme les à-coups de la souris.
        let suivi = CGFloat(1 - exp(-dt / 0.015))
        let avant = souris
        souris = force == 0 ? visee : souris + (visee - souris) * suivi
        if abs(souris - avant) > 0.01 { bouge = true }
        if force != forceCible {
            let k = min(1, (maintenant - forceDebut) / forceDuree)
            force = forceDepart + (forceCible - forceDepart) * CGFloat(1 - pow(1 - k, 2))     // ralentit en arrivant
            if k >= 1 { force = forceCible }
            bouge = true
        }
        if bouge { disposer() }
        if mesures.n > 0 || force > 0 {
            mesures.n += 1; mesures.somme += dt; mesures.pire = max(mesures.pire, dt)
            mesures.calcul = max(mesures.calcul, CACurrentMediaTime() - maintenant)
        }
        if force == 0, forceCible == 0 {
            if mesures.n > 20 {
                journal("Square: Dock survolé, %d images, %.1f ms en moyenne, pire %.1f ms, calcul le plus long %.2f ms",
                        mesures.n, mesures.somme / Double(mesures.n) * 1000, mesures.pire * 1000, mesures.calcul * 1000)
            }
            mesures = (0, 0, 0, 0)
            imagePrecedente = 0
            arreterLeLien()
        }
    }

    /// Un mouvement de souris au-dessus du Dock réveille la loupe ; ensuite, c'est le rythme de l'écran qui la mène.
    private func suivre(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard zoneActive.insetBy(dx: -4, dy: -4).contains(p) else { return }
        if lien == nil { visee = leLong(p); souris = visee }
        viser(1, duree: 0.16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let zone { removeTrackingArea(zone) }
        let z = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(z)
        zone = z
    }
    override func mouseMoved(with event: NSEvent) { suivre(event) }
    override func mouseEntered(with event: NSEvent) { suivre(event) }
    override func mouseExited(with event: NSEvent) {}
    override func viewDidMoveToWindow() { if window == nil { arreterLeLien() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = rang(convert(event.locationInWindow, from: nil)) else { return }
        if i == 0 { auBoutonApps?() } else if i == rangCorbeille { auCorbeille?() } else { auLancement?(chemins[i - 2]) }
    }

    /// Clic droit sur une icône : la retirer du Dock.
    override func rightMouseDown(with event: NSEvent) {
        guard let i = rang(convert(event.locationInWindow, from: nil)), i >= 2, i != rangCorbeille else { return }
        let menu = NSMenu()
        let chemin = chemins[i - 2]
        // Une application ouverte peut être quittée d'ici.
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == chemin }) {
            let nom = app.localizedName ?? String(localized: "l'application")
            let quitter = menu.addItem(withTitle: String(localized: "Quitter \(nom)"), action: #selector(quitter(_:)), keyEquivalent: "")
            quitter.target = self
            quitter.representedObject = chemin
            menu.addItem(.separator())
        }
        let item = menu.addItem(withTitle: String(localized: "Retirer du Dock"), action: #selector(retirer(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = chemin
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    var auQuitter: ((String) -> Void)?
    @objc private func quitter(_ item: NSMenuItem) {
        if let c = item.representedObject as? String { auQuitter?(c) }
    }

    @objc private func retirer(_ item: NSMenuItem) {
        guard let c = item.representedObject as? String else { return }
        DockGrille.basculer(c)
        charger()
        superview?.needsLayout = true
    }
}

// MARK: - La liste de toutes les applications, avec une recherche

final class PanneauLanceur: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class LigneAppli: NSView {
    let chemin: String
    var auClic: (() -> Void)?
    var auDock: (() -> Void)?
    private let epingle = NSButton()
    private var survol = false { didSet { teinter() } }
    var choisie = false { didSet { teinter() } }

    private func teinter() {
        layer?.backgroundColor = (choisie ? NSColor(white: 1, alpha: 0.22) : (survol ? NSColor(white: 1, alpha: 0.09) : .clear)).cgColor
    }

    init(chemin: String, nom: String, dansLeDock: Bool) {
        self.chemin = chemin
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 38))
        wantsLayer = true
        layer?.cornerRadius = 8
        let icone = NSImageView(frame: NSRect(x: 8, y: 4, width: 30, height: 30))
        icone.image = NSWorkspace.shared.icon(forFile: chemin)
        addSubview(icone)
        let texte = NSTextField(labelWithString: nom)
        texte.font = .systemFont(ofSize: 14)
        texte.textColor = .white
        texte.lineBreakMode = .byTruncatingTail
        texte.frame = NSRect(x: 48, y: 9, width: 236, height: 20)
        addSubview(texte)
        epingle.isBordered = false
        epingle.image = NSImage(systemSymbolName: dansLeDock ? "checkmark.circle.fill" : "plus.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        epingle.contentTintColor = dansLeDock ? orange : NSColor(white: 1, alpha: 0.75)
        epingle.toolTip = dansLeDock ? String(localized: "Retirer du Dock") : String(localized: "Ajouter au Dock")
        epingle.frame = NSRect(x: 300, y: 5, width: 28, height: 28)
        epingle.target = self
        epingle.action = #selector(clicEpingle)
        addSubview(epingle)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicEpingle() { auDock?() }
    override func mouseEntered(with event: NSEvent) { survol = true }
    override func mouseExited(with event: NSEvent) { survol = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { auClic?() } }
}

/// Le panneau du bouton « Apps » : il flotte au-dessus de ce bouton, avec une petite pointe, et contient un champ de
/// recherche et la liste des applications.
/// Au clavier : les flèches parcourent la liste, Entrée ajoute l'application au Dock, Suppr l'en retire (le panneau reste
/// ouvert), ⌘ Entrée l'ouvre, Échap referme. À la souris : un clic sur une ligne ouvre l'application, le bouton à droite
/// l'ajoute au Dock ou l'en retire.
final class Lanceur: NSObject, NSTextFieldDelegate {
    static let commun = Lanceur()
    var auChoix: ((String) -> Void)?
    var auDock: (() -> Void)?
    var aLaFermeture: (() -> Void)?
    private var panneau: PanneauLanceur?
    private let fond = NSVisualEffectView()
    private let champ = NSTextField()
    private let defilement = NSScrollView()
    private let liste = NSView()
    private var toutes: [(chemin: String, nom: String)] = []
    private var trouvees: [(chemin: String, nom: String)] = []
    private var lignes: [LigneAppli] = []
    private var choix = 0
    private var parcourue = false          // on a bougé dans la liste avec les flèches : Retour arrière agit alors sur le Dock
    var ouvert: Bool { panneau?.isVisible == true }
    private let largeur: CGFloat = 360, hauteur: CGFloat = 420, pointe: CGFloat = 11, hauteurLigne: CGFloat = 40

    private func construire() -> PanneauLanceur {
        // Le panneau garde une marge de la taille de la pointe sur ses quatre côtés : elle peut ainsi sortir de n'importe lequel.
        let cadre = NSRect(x: 0, y: 0, width: largeur + 2 * pointe, height: hauteur + 2 * pointe)
        let p = PanneauLanceur(contentRect: cadre, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        fond.frame = cadre
        fond.material = .hudWindow
        fond.blendingMode = .behindWindow
        fond.state = .active
        fond.appearance = NSAppearance(named: .darkAqua)
        let contenu = NSView(frame: NSRect(x: pointe, y: pointe, width: largeur, height: hauteur))
        fond.addSubview(contenu)
        champ.frame = NSRect(x: 14, y: hauteur - 42, width: largeur - 28, height: 28)
        champ.placeholderString = String(localized: "Rechercher une app")
        champ.font = .systemFont(ofSize: 15)
        champ.isBordered = false
        champ.drawsBackground = false
        champ.focusRingType = .none
        champ.textColor = .white
        champ.delegate = self
        contenu.addSubview(champ)
        let trait = NSBox(frame: NSRect(x: 0, y: hauteur - 50, width: largeur, height: 1))
        trait.boxType = .separator
        contenu.addSubview(trait)
        defilement.frame = NSRect(x: 0, y: 6, width: largeur, height: hauteur - 58)
        defilement.drawsBackground = false
        defilement.hasVerticalScroller = true
        defilement.documentView = liste
        contenu.addSubview(defilement)
        p.contentView = fond
        return p
    }

    /// La forme du panneau : un rectangle arrondi, avec une pointe qui sort du côté du Dock, à la distance `d` le long de ce côté.
    private func forme(cote: String, pointeEn d: CGFloat) -> NSImage {
        let l = largeur, h = hauteur, p = pointe
        return NSImage(size: NSSize(width: l + 2 * p, height: h + 2 * p), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: p, y: p, width: l, height: h), xRadius: 16, yRadius: 16).fill()
            let t = NSBezierPath()
            switch cote {
            case "haut":    // le Dock est en haut : la pointe sort par le haut
                t.move(to: NSPoint(x: d - 13, y: p + h - 1)); t.line(to: NSPoint(x: d, y: h + 2 * p)); t.line(to: NSPoint(x: d + 13, y: p + h - 1))
            case "gauche":
                t.move(to: NSPoint(x: p + 1, y: d - 13)); t.line(to: NSPoint(x: 0, y: d)); t.line(to: NSPoint(x: p + 1, y: d + 13))
            case "droite":
                t.move(to: NSPoint(x: p + l - 1, y: d - 13)); t.line(to: NSPoint(x: l + 2 * p, y: d)); t.line(to: NSPoint(x: p + l - 1, y: d + 13))
            default:
                t.move(to: NSPoint(x: d - 13, y: p + 1)); t.line(to: NSPoint(x: d, y: 0)); t.line(to: NSPoint(x: d + 13, y: p + 1))
            }
            t.close()
            t.fill()
            return true
        }
    }

    /// La liste des applications installées (mêmes dossiers que dans Side).
    private func chargerLesApps() {
        guard toutes.isEmpty else { return }
        let fm = FileManager.default
        let racines = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var vues = Set<String>(), l: [(String, String)] = []
        func ajouter(_ u: URL) {
            guard u.pathExtension == "app", vues.insert(u.resolvingSymlinksInPath().path).inserted else { return }
            l.append((u.path, fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")))
        }
        for racine in racines {
            let contenu = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: racine), includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for u in contenu {
                if u.pathExtension == "app" { ajouter(u); continue }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, u.lastPathComponent != "Utilities" {
                    ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).forEach(ajouter)
                }
            }
        }
        toutes = l.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map { (chemin: $0.0, nom: $0.1) }
    }

    /// Refait la liste : les apps dont le nom contient le texte, celles dont le nom commence par lui d'abord.
    /// « garder » : le chemin de l'application qui doit rester choisie (après un ajout ou un retrait).
    private func filtrer(garder: String? = nil) {
        let t = champ.stringValue.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { trouvees = toutes } else {
            let dedans = toutes.filter { $0.nom.localizedStandardContains(t) }
            let cle = t.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let debut = dedans.filter { $0.nom.lowercased().folding(options: .diacriticInsensitive, locale: nil).hasPrefix(cle) }
            trouvees = debut + dedans.filter { a in !debut.contains { $0.chemin == a.chemin } }
        }
        let haut = defilement.contentView.bounds.origin
        liste.subviews.forEach { $0.removeFromSuperview() }
        let dock = Set(DockGrille.apps)
        let total = max(CGFloat(trouvees.count) * hauteurLigne + 8, defilement.contentSize.height)
        liste.frame = NSRect(x: 0, y: 0, width: largeur, height: total)
        lignes = trouvees.enumerated().map { i, a in
            let ligne = LigneAppli(chemin: a.chemin, nom: a.nom, dansLeDock: dock.contains(a.chemin))
            ligne.frame.origin = NSPoint(x: 10, y: total - 4 - CGFloat(i + 1) * hauteurLigne)
            ligne.auClic = { [weak self] in self?.ouvrirApp(a.chemin) }
            ligne.auDock = { [weak self] in self?.basculerDock(a.chemin) }
            liste.addSubview(ligne)
            return ligne
        }
        if let garder, let i = trouvees.firstIndex(where: { $0.chemin == garder }) {
            choix = i
            defilement.contentView.scroll(to: haut)
        } else {
            choix = 0
            defilement.contentView.scroll(to: NSPoint(x: 0, y: total - defilement.contentSize.height))
        }
        marquer()
    }

    /// Met en valeur la ligne choisie et la garde visible.
    private func marquer() {
        for (i, l) in lignes.enumerated() { l.choisie = i == choix }
        if lignes.indices.contains(choix) { lignes[choix].scrollToVisible(lignes[choix].bounds.insetBy(dx: 0, dy: -4)) }
    }

    private func basculerDock(_ chemin: String) {
        DockGrille.basculer(chemin)
        auDock?()
        filtrer(garder: chemin)
    }

    /// S'ouvre contre le point donné (le bouton « Apps »), du côté intérieur de l'écran, la pointe dirigée vers lui.
    /// `cote` : le côté de l'écran où se tient le Dock.
    func ouvrir(surEcran ecran: NSScreen, contre ancre: NSPoint, cote: String) {
        let p = panneau ?? construire()
        panneau = p
        chargerLesApps()
        champ.stringValue = ""
        parcourue = false
        let l = largeur + 2 * pointe, h = hauteur + 2 * pointe, jeu: CGFloat = 4
        let e = ecran.frame
        var origine = NSPoint.zero, d: CGFloat = 0
        // Centré sur le bouton ; s'il déborderait de l'écran, il se décale et seule la pointe reste sur le bouton.
        switch cote {
        case "haut", "bas":
            origine.x = min(max(ancre.x - l / 2, e.minX + 8), e.maxX - l - 8)
            origine.y = cote == "bas" ? ancre.y + jeu : ancre.y - jeu - h
            d = min(max(ancre.x - origine.x, pointe + 30), l - pointe - 30)
        default:
            origine.y = min(max(ancre.y - h / 2, e.minY + 8), e.maxY - h - 8)
            origine.x = cote == "gauche" ? ancre.x + jeu : ancre.x - jeu - l
            d = min(max(ancre.y - origine.y, pointe + 30), h - pointe - 30)
        }
        fond.maskImage = forme(cote: cote, pointeEn: d)
        p.setFrameOrigin(origine)
        filtrer()
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(champ)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; p.animator().alphaValue = 1 }
    }

    func fermer() {
        guard ouvert else { return }
        panneau?.orderOut(nil)
        aLaFermeture?()
    }

    private func ouvrirApp(_ chemin: String) {
        fermer()
        auChoix?(chemin)
    }

    func controlTextDidChange(_ obj: Notification) { parcourue = false; filtrer() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let choisie = trouvees.indices.contains(choix) ? trouvees[choix].chemin : nil
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            fermer(); return true
        case #selector(NSResponder.moveDown(_:)):
            if !trouvees.isEmpty { choix = min(choix + 1, trouvees.count - 1); parcourue = true; marquer() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !trouvees.isEmpty { choix = max(choix - 1, 0); parcourue = true; marquer() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard let choisie else { return true }
            // ⌘ Entrée ouvre l'application ; Entrée seule l'ajoute au Dock, et le panneau reste ouvert.
            if NSEvent.modifierFlags.contains(.command) { ouvrirApp(choisie) }
            else if !DockGrille.apps.contains(choisie) { basculerDock(choisie) }
            return true
        case #selector(NSResponder.deleteForward(_:)):
            if let choisie, DockGrille.apps.contains(choisie) { basculerDock(choisie) }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Retour arrière efface le texte, sauf si on vient de parcourir la liste (ou si le champ est vide) :
            // il retire alors du Dock l'application choisie.
            guard parcourue || champ.stringValue.isEmpty, let choisie, DockGrille.apps.contains(choisie) else { return false }
            basculerDock(choisie)
            return true
        default:
            return false
        }
    }
}
