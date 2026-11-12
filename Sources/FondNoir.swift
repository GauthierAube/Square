// Plein écran des vidéos : certaines applications gardent les proportions de leur fenêtre (une vidéo dans QuickTime).
// Agrandie par Square, une telle fenêtre ne remplit pas tout l'écran, et l'on voit les autres applications autour.
// Square la colle en haut de l'écran, et pose derrière elle un fond noir sur tout l'écran, comme un vrai plein écran.
// Le fond n'est là que tant que cette fenêtre est devant ; un clic sur le fond la ramène devant.
import AppKit

private final class PanneauFond: NSPanel {
    var auClic: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override func mouseDown(with event: NSEvent) { auClic?() }
}

enum FondNoir {
    /// Les fenêtres qui n'ont pas pu remplir l'écran, avec leur application.
    private static var suivies: [CGWindowID: pid_t] = [:]
    private static var fond: PanneauFond?
    private static var minuteur: Timer?
    private static var devant: CGWindowID?

    /// Après un agrandissement : la fenêtre a-t-elle vraiment rempli la zone ? Sinon, elle est centrée et suivie.
    static func verifier(_ el: AXUIElement, zone: CGRect) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            var wid: CGWindowID = 0, pid: pid_t = 0
            guard _AXUIElementGetWindow(el, &wid) == .success, AXUIElementGetPid(el, &pid) == .success, let c = AX.cadre(el) else { return }
            let manque = zone.width - c.width > 16 || zone.height - c.height > 16
            guard manque, c.width >= 320, c.height >= 200 else { oublier(wid); return }
            // Collée en haut de l'écran (centrée en largeur) : la bande noire reste en bas.
            AX.placer(el, CGRect(x: (zone.midX - c.width / 2).rounded(), y: zone.minY, width: c.width, height: c.height))
            suivies[wid] = pid
            journal("Square: fenêtre %d aux proportions fixes, collée en haut sur un fond noir", Int(wid))
            demarrer()
            maj()
        }
    }

    static func estSuivie(_ wid: CGWindowID) -> Bool { suivies[wid] != nil }

    /// La fenêtre reprend une taille ordinaire : plus de fond pour elle.
    static func oublier(_ wid: CGWindowID) {
        guard suivies.removeValue(forKey: wid) != nil else { return }
        maj()
    }

    private static func demarrer() {
        guard minuteur == nil else { return }
        minuteur = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in maj() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { maj() }
        }
    }

    /// Le fond suit la fenêtre la plus en avant : il se montre derrière elle si c'est une fenêtre suivie, et disparaît sinon.
    static func maj() {
        let moi = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let visibles = Set(infos.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        // Les fenêtres fermées sont oubliées (une fenêtre seulement cachée, application masquée, est gardée).
        for (w, pid) in suivies where !visibles.contains(w) && NSRunningApplication(processIdentifier: pid) == nil { suivies[w] = nil }
        if suivies.isEmpty { cacher(); minuteur?.invalidate(); minuteur = nil; return }
        // La fenêtre d'application la plus en avant (ni Square, ni barre des menus, ni fenêtre invisible).
        let premiere = infos.first { i in
            ((i[kCGWindowLayer as String] as? Int) ?? 1) == 0 && (i[kCGWindowOwnerPID as String] as? pid_t) != moi
                && ((i[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05
        }
        guard let p = premiere, let w = p[kCGWindowNumber as String] as? CGWindowID, suivies[w] != nil,
              let d = p[kCGWindowBounds as String] as? NSDictionary, let cadre = CGRect(dictionaryRepresentation: d),
              let ecran = NSScreen.screens.first(where: { Ecrans.cadreGlobal($0).contains(CGPoint(x: cadre.midX, y: cadre.midY)) }) else {
            cacher(); return
        }
        let f = fond ?? creer()
        if f.frame != ecran.frame { f.setFrame(ecran.frame, display: false) }
        f.auClic = {
            guard let pid = suivies[w] else { return }
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        f.order(.below, relativeTo: Int(w))
        devant = w
    }

    private static func creer() -> PanneauFond {
        let f = PanneauFond(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        f.backgroundColor = .black
        f.isOpaque = true
        f.hasShadow = false
        f.level = .normal
        f.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        f.animationBehavior = .none
        fond = f
        return f
    }

    private static func cacher() {
        guard devant != nil else { return }
        devant = nil
        fond?.orderOut(nil)
    }
}
