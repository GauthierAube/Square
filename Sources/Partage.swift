// Partage de l'écran : dans la grille, glisser une fenêtre sur le bord d'une autre les range côte à côte (ou l'une sur l'autre).
// Les fenêtres ainsi réunies forment un groupe : amener l'une devant amène aussi les autres.
import AppKit

enum Cote { case gauche, droite, haut, bas }

/// Ce que l'on fait d'une case qu'on lâche dans la grille.
enum Depot {
    case echanger(Tuile)          // au milieu d'une autre case : elles échangent leurs places
    case place(Int)               // sur une case vide : elle s'y installe
    case partager(Fenetre, Cote)  // sur un bord d'une autre fenêtre : les deux se partagent l'écran
    case ordre([String: Int])     // les cases ont été réordonnées en glissant : la nouvelle place de chacune
    case redimensionner([CGWindowID: CGRect])   // la séparation entre deux fenêtres d'un groupe a été tirée
    case separer(Int?)            // une fenêtre sortie de son groupe : elle reprend tout l'écran (sur cette case vide, si précisée)
}

enum Groupes {
    // Mémorisés d'un lancement de Square à l'autre (les numéros de fenêtre restent valables tant que les fenêtres sont ouvertes).
    private static var groupes: [Set<CGWindowID>] = {
        ((UserDefaults.standard.array(forKey: "groupesFenetres") as? [[Int]]) ?? []).map { Set($0.map { CGWindowID($0) }) }
    }() { didSet { enregistrer() } }
    private static var pids: [CGWindowID: pid_t] = {
        var d: [CGWindowID: pid_t] = [:]
        for (k, v) in (UserDefaults.standard.dictionary(forKey: "groupesPids") as? [String: Int]) ?? [:] {
            if let w = UInt32(k) { d[w] = pid_t(v) }
        }
        return d
    }() { didSet { enregistrer() } }

    private static func enregistrer() {
        UserDefaults.standard.set(groupes.map { $0.map { Int($0) } }, forKey: "groupesFenetres")
        let vivants = Set(groupes.flatMap { $0 })
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: pids.filter { vivants.contains($0.key) }.map { (String($0.key), Int($0.value)) }),
                                  forKey: "groupesPids")
    }

    static func lier(_ a: Fenetre, _ b: Fenetre) {
        pids[a.wid] = a.pid; pids[b.wid] = b.pid
        retirer(a.wid)                                  // la fenêtre déplacée quitte son ancien groupe
        if let i = groupes.firstIndex(where: { $0.contains(b.wid) }) { groupes[i].insert(a.wid) }
        else { groupes.append([a.wid, b.wid]) }
    }

    static func retirer(_ wid: CGWindowID) {
        for i in groupes.indices { groupes[i].remove(wid) }
        groupes.removeAll { $0.count < 2 }
    }

    /// Ces deux fenêtres se partagent-elles l'écran ? (Une fenêtre est toujours « ensemble » avec elle-même.)
    static func ensemble(_ a: CGWindowID, _ b: CGWindowID) -> Bool {
        a == b || groupes.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Les autres fenêtres du groupe de celle-ci.
    static func compagnes(_ wid: CGWindowID) -> [(wid: CGWindowID, pid: pid_t)] {
        guard let g = groupes.first(where: { $0.contains(wid) }) else { return [] }
        return g.filter { $0 != wid }.compactMap { w in pids[w].map { (w, $0) } }
    }

    private static func enLigne(_ fs: [Fenetre]) -> Bool {
        guard let p = fs.first else { return false }
        return fs.allSatisfy { abs($0.cadre.minY - p.cadre.minY) < 14 && abs($0.cadre.height - p.cadre.height) < 14 }
    }
    private static func enColonne(_ fs: [Fenetre]) -> Bool {
        guard let p = fs.first else { return false }
        return fs.allSatisfy { abs($0.cadre.minX - p.cadre.minX) < 14 && abs($0.cadre.width - p.cadre.width) < 14 }
    }

    /// Répartit des fenêtres en bandes égales dans une zone : côte à côte (horizontal) ou l'une sous l'autre.
    private static func bandes(_ ordre: [CGWindowID], dans zone: CGRect, horizontal: Bool) -> [CGWindowID: CGRect] {
        var r: [CGWindowID: CGRect] = [:]
        let n = CGFloat(ordre.count)
        for (i, w) in ordre.enumerated() {
            let debut = (CGFloat(i) / n * (horizontal ? zone.width : zone.height)).rounded()
            let fin = (CGFloat(i + 1) / n * (horizontal ? zone.width : zone.height)).rounded()
            r[w] = horizontal ? CGRect(x: zone.minX + debut, y: zone.minY, width: fin - debut, height: zone.height)
                              : CGRect(x: zone.minX, y: zone.minY + debut, width: zone.width, height: fin - debut)
        }
        return r
    }

    /// La fenêtre glissée rejoint la cible. Si la cible fait déjà partie d'une rangée de bandes (ou est seule), toutes les
    /// fenêtres se répartissent en bandes égales : deux, trois, quatre… Sinon, la zone de la cible est coupée en deux.
    /// « membres » : les fenêtres qui partagent déjà l'écran avec la cible (elle comprise).
    /// Renvoie les nouveaux cadres, sans encore toucher aux fenêtres (la grille peut ainsi se redessiner tout de suite).
    static func partager(_ a: Fenetre, sur b: Fenetre, cote: Cote, membres: [Fenetre]) -> [CGWindowID: CGRect] {
        let autres = (membres.contains { $0.wid == b.wid } ? membres : [b]).filter { $0.wid != a.wid }
        let horizontal = cote == .gauche || cote == .droite
        var cadres: [CGWindowID: CGRect] = [:]
        if horizontal ? enLigne(autres) : enColonne(autres) {
            let zone = autres.count == 1 && b.agrandie ? Ecrans.zoneVisible(contenant: b.cadre) : Tuile.englobant(autres)
            var ordre = autres.sorted { horizontal ? $0.cadre.minX < $1.cadre.minX : $0.cadre.minY < $1.cadre.minY }.map { $0.wid }
            let rang = (ordre.firstIndex(of: b.wid) ?? 0) + (cote == .droite || cote == .bas ? 1 : 0)
            ordre.insert(a.wid, at: rang)
            cadres = bandes(ordre, dans: zone, horizontal: horizontal)
        } else {
            let zone = b.agrandie ? Ecrans.zoneVisible(contenant: b.cadre) : b.cadre
            var pourA = zone, pourB = zone
            switch cote {
            case .gauche: pourA.size.width = (zone.width / 2).rounded(); pourB.origin.x = pourA.maxX; pourB.size.width = zone.maxX - pourA.maxX
            case .droite: pourB.size.width = (zone.width / 2).rounded(); pourA.origin.x = pourB.maxX; pourA.size.width = zone.maxX - pourB.maxX
            case .haut: pourA.size.height = (zone.height / 2).rounded(); pourB.origin.y = pourA.maxY; pourB.size.height = zone.maxY - pourA.maxY
            case .bas: pourB.size.height = (zone.height / 2).rounded(); pourA.origin.y = pourB.maxY; pourA.size.height = zone.maxY - pourB.maxY
            }
            cadres = [a.wid: pourA, b.wid: pourB]
        }
        journal("Square: écran partagé entre %@ et %@", a.app, b.app)
        lier(a, b)
        return cadres
    }

    /// La fenêtre quitte son groupe (« membres » : toutes ses fenêtres, elle comprise). Celles qui restent se partagent la place
    /// libérée : une seule reprend tout l'écran, une rangée de bandes se répartit de nouveau à parts égales.
    static func quitter(_ f: Fenetre, membres: [Fenetre]) -> [CGWindowID: CGRect] {
        let autres = membres.filter { $0.wid != f.wid }
        retirer(f.wid)
        guard !autres.isEmpty, membres.contains(where: { $0.wid == f.wid }) else { return [:] }
        let zone = Tuile.englobant(membres)
        if autres.count == 1 { return [autres[0].wid: Ecrans.zoneVisible(contenant: zone)] }
        if enLigne(membres) { return bandes(autres.sorted { $0.cadre.minX < $1.cadre.minX }.map { $0.wid }, dans: zone, horizontal: true) }
        if enColonne(membres) { return bandes(autres.sorted { $0.cadre.minY < $1.cadre.minY }.map { $0.wid }, dans: zone, horizontal: false) }
        return [:]
    }

    /// La fenêtre quitte son groupe et remplit de nouveau l'écran.
    static func separer(_ f: Fenetre, membres: [Fenetre]) -> [CGWindowID: CGRect] {
        var cadres = quitter(f, membres: membres)
        journal("Square: %@ quitte le partage d'écran", f.app)
        cadres[f.wid] = Ecrans.zoneVisible(contenant: f.cadre)
        return cadres
    }

    /// Place réellement les fenêtres à leurs nouveaux cadres.
    static func appliquer(_ cadres: [CGWindowID: CGRect], fenetres: [Fenetre]) {
        for f in fenetres {
            guard let r = cadres[f.wid], let el = AX.fenetre(pid: f.pid, wid: f.wid) else { continue }
            AX.placer(el, r)
        }
    }

    /// Amène devant tout le groupe d'une fenêtre, elle en dernier. (macOS ne fait passer devant qu'une application à la fois.)
    static func monterLeGroupe(de f: Fenetre, puis fin: @escaping () -> Void) {
        var reste = compagnes(f.wid)
        func suivante() {
            guard !reste.isEmpty else { fin(); return }
            let c = reste.removeFirst()
            monter(c.wid, pid: c.pid, puis: suivante)
        }
        suivante()
    }

    private static func monter(_ wid: CGWindowID, pid: pid_t, puis fin: @escaping () -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid), let el = AX.fenetre(pid: pid, wid: wid) else { fin(); return }
        if app.isHidden { app.unhide() }
        AX.lever(el)
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: fin)
    }
}
