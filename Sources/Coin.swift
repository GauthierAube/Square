// Coin actif : pousser la souris dans un coin de l'écran affiche la grille. Par défaut, le coin en haut à droite.
import AppKit

enum Coin {
    /// "hd" (haut droite), "hg", "bd", "bg", ou "aucun".
    static var choix: String {
        get { UserDefaults.standard.string(forKey: "coinGrille") ?? "hd" }
        set { UserDefaults.standard.set(newValue, forKey: "coinGrille") }
    }
    static let noms: [(String, String)] = [("hd", "En haut à droite"), ("hg", "En haut à gauche"),
                                           ("bd", "En bas à droite"), ("bg", "En bas à gauche"), ("aucun", "Aucun")]
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
        guard armé, distance <= 2, NSEvent.pressedMouseButtons == 0 else { return }
        armé = false
        Programme.appli.grilleParLeCoin()
    }
}
