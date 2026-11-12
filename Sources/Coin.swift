// Coin actif : pousser la souris dans un coin de l'écran affiche la grille. Par défaut, le coin en haut à droite.
import AppKit

enum Coin {
    /// "hd" (haut droite), "hg", "bd", "bg", ou "aucun".
    static var choix: String {
        get { UserDefaults.standard.string(forKey: "coinGrille") ?? "hd" }
        set { UserDefaults.standard.set(newValue, forKey: "coinGrille") }
    }
    static let noms: [(String, String)] = [("hd", String(localized: "En haut à droite")), ("hg", String(localized: "En haut à gauche")),
                                           ("bd", String(localized: "En bas à droite")), ("bg", String(localized: "En bas à gauche")),
                                           ("aucun", String(localized: "Aucun"))]
    private static var armé = true          // il faut ressortir du coin avant de pouvoir le déclencher de nouveau
    private static var ecoute: Any?
    private static var ecouteLocale: Any?

    static func demarrer() {
        guard ecoute == nil else { return }
        ecoute = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in examiner() }
        // Quand la grille est affichée, la souris est au-dessus de Square : ces mouvements-là arrivent par une autre voie.
        ecouteLocale = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { e in examiner(); return e }
    }

    private static func examiner() {
        guard choix != "aucun" else { return }
        let p = NSEvent.mouseLocation
        guard let e = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return }
        let f = e.frame
        let coin = CGPoint(x: choix.hasSuffix("d") ? f.maxX : f.minX, y: choix.hasPrefix("h") ? f.maxY : f.minY)
        let distance = max(abs(p.x - coin.x), abs(p.y - coin.y))
        if distance > 40 { armé = true; return }
        // Tout au fond du coin, sans bouton enfoncé (on ne gêne pas un déplacement de fenêtre).
        // Pendant une capture d'écran (⌘⇧4, ⌘⇧5), Square se tient tranquille : on doit pouvoir viser un coin sans rien déclencher.
        guard armé, distance <= 2, NSEvent.pressedMouseButtons == 0, !CaptureEcran.enCours else { return }
        armé = false
        Programme.appli.grilleParLeCoin()
    }
}

/// Une capture d'écran est-elle en train d'être choisie (⌘⇧4, ⌘⇧5) ? On le voit à la fenêtre de sélection de macOS,
/// posée au-dessus de tout. (L'outil de capture reste en mémoire quelques secondes après : cela ne compte pas.)
enum CaptureEcran {
    static var enCours: Bool {
        let fenetres = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return fenetres.contains { f in
            guard ((f[kCGWindowLayer as String] as? Int) ?? 0) >= 100 else { return false }
            if (f[kCGWindowOwnerName as String] as? String) == "screencapture" { return true }
            guard let pid = f[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.screencaptureui"
        }
    }
}
