// Carrousel : pendant un glissement à quatre doigts, les fenêtres apparaissent en cartes au milieu de l'écran, sans bandeau.
// Les cartes suivent les doigts ; celle du centre grandit, les autres restent petites. La carte du centre, quand vous levez
// les doigts, grandit jusqu'à la place de sa fenêtre, qui passe devant. On va ainsi de la quatrième à la première d'un seul geste.
import AppKit

final class Carrousel {
    static let commun = Carrousel()
    private var panneau: NSPanel?
    private let scene = NSView()
    private let voile = CALayer()            // léger assombrissement de l'écran, pour détacher les cartes
    private let groupe = CALayer()
    private var cartes: [(carte: CALayer, image: CALayer)] = []
    private var tuiles: [Tuile] = []
    /// Largeur de la carte du centre, réglable (menu de Square, « Taille du carrousel… »).
    static var taille: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "carrouselTaille"); return v > 0 ? CGFloat(v) : 330 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "carrouselTaille") }
    }
    static let tailles: ClosedRange<CGFloat> = 200...620
    private var largeur: CGFloat = 330, hauteur: CGFloat = 206     // la carte du centre
    private let petit: CGFloat = 0.52                              // taille des autres, par rapport à celle du centre
    private var position: CGFloat = 0
    private(set) var visible = false

    private func construire() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        scene.wantsLayer = true
        voile.backgroundColor = NSColor.black.cgColor
        scene.layer?.addSublayer(voile)
        scene.layer?.addSublayer(groupe)
        p.contentView = scene
        return p
    }

    func ouvrir(_ tuiles: [Tuile], depart: Int, espaces: [Espace], ecran: NSScreen, anime: Bool = true) {
        largeur = Carrousel.taille
        hauteur = (largeur / 1.6).rounded()
        let p = panneau ?? construire()
        panneau = p
        self.tuiles = tuiles
        p.setFrame(ecran.frame, display: false)
        let zone = CGRect(origin: .zero, size: ecran.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        voile.frame = zone
        voile.opacity = 0
        groupe.frame = zone
        cartes.forEach { $0.carte.removeFromSuperlayer() }
        cartes = tuiles.map { t in
            let carte = CALayer()
            carte.bounds = CGRect(x: 0, y: 0, width: largeur, height: hauteur)
            carte.shadowColor = NSColor.black.cgColor
            carte.shadowOpacity = 0.5
            carte.shadowRadius = 26
            carte.shadowOffset = CGSize(width: 0, height: -12)
            carte.shadowPath = CGPath(roundedRect: carte.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
            let image = CALayer()
            image.frame = carte.bounds
            image.cornerRadius = 14
            image.masksToBounds = true
            image.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            image.contentsGravity = .resizeAspectFill
            image.contents = Images.commun.image(pour: t, espaces: espaces)
            image.borderColor = orange.cgColor
            carte.addSublayer(image)
            // L'icône de l'application, à cheval sur le bord bas de la carte, comme dans la grille.
            let icone = CALayer()
            let cote = (largeur * 0.18).rounded()
            icone.frame = CGRect(x: largeur / 2 - cote / 2, y: -cote * 0.42, width: cote, height: cote)
            icone.contents = t.icone?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            icone.shadowOpacity = 0.4
            icone.shadowRadius = 6
            icone.shadowOffset = CGSize(width: 0, height: -3)
            carte.addSublayer(icone)
            groupe.addSublayer(carte)
            return (carte, image)
        }
        groupe.opacity = anime ? 0 : 1
        groupe.transform = anime ? CATransform3DMakeScale(0.86, 0.86, 1) : CATransform3DIdentity
        voile.opacity = anime ? 0 : 0.28
        CATransaction.commit()
        placer(CGFloat(depart), anime: false)
        p.alphaValue = 1
        p.orderFrontRegardless()
        visible = true
        guard anime else { return }
        // Apparition : les cartes arrivent en fondu en grossissant un peu, l'écran s'assombrit à peine.
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.13)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        groupe.opacity = 1
        groupe.transform = CATransform3DIdentity
        voile.opacity = 0.28
        CATransaction.commit()
    }

    /// Les photos viennent d'être refaites : on les remplace.
    func rafraichir(espaces: [Espace]) {
        guard visible else { return }
        for (c, t) in zip(cartes, tuiles) { if let img = Images.commun.image(pour: t, espaces: espaces) { c.image.contents = img } }
    }

    /// Amène la position p (en nombre de fenêtres, éventuellement entre deux) au centre. La carte du centre est grande ;
    /// en s'en éloignant, une carte rétrécit et s'efface un peu.
    func placer(_ p: CGFloat, anime: Bool) {
        position = p
        let centre = CGPoint(x: groupe.bounds.midX, y: groupe.bounds.midY)
        let pas = largeur * petit + 34, pousse = largeur * (1 - petit) / 2
        CATransaction.begin()
        if anime {
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else { CATransaction.setDisableActions(true) }
        for (i, c) in cartes.enumerated() {
            let d = CGFloat(i) - p, proche = 1 - min(abs(d), 1)
            let taille = petit + (1 - petit) * proche
            c.carte.position = CGPoint(x: centre.x + d * pas + (d > 0 ? 1 : (d < 0 ? -1 : 0)) * min(abs(d), 1) * pousse, y: centre.y)
            c.carte.transform = CATransform3DMakeScale(taille, taille, 1)
            c.carte.opacity = 1          // toutes les cartes pleinement opaques (plus d'effet de transparence sur les voisines)
            c.carte.zPosition = 10 - abs(d)
            c.image.borderWidth = proche > 0.5 ? 4 : 0
        }
        CATransaction.commit()
    }

    /// Fin de l'aperçu des réglages : tout s'efface, sans choisir de fenêtre.
    func masquer() {
        guard visible, let p = panneau else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }) {
            if !self.visible { p.orderOut(nil) }
        }
    }

    /// Doigts levés : la carte choisie grandit jusqu'à la place de sa fenêtre, les autres s'effacent, puis tout disparaît.
    func fermer(sur index: Int) {
        guard visible, let p = panneau else { return }
        visible = false
        var arrivee = groupe.bounds
        if cartes.indices.contains(index), let r = tuiles[index].cadre {
            let ecran = Ecrans.cadreGlobal(p.screen)
            arrivee = CGRect(x: r.minX - ecran.minX, y: groupe.bounds.height - (r.minY - ecran.minY) - r.height, width: r.width, height: r.height)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.3, 1))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.visible else { return }
            p.orderOut(nil)
        }
        voile.opacity = 0
        for (i, c) in cartes.enumerated() {
            if i == index {
                c.carte.zPosition = 20
                c.carte.opacity = 1
                c.carte.position = CGPoint(x: arrivee.midX, y: arrivee.midY)
                c.carte.transform = CATransform3DMakeScale(arrivee.width / largeur, arrivee.height / hauteur, 1)
                c.image.borderWidth = 0
                c.carte.shadowOpacity = 0
                c.carte.sublayers?.last?.opacity = 0      // l'icône s'efface en route
            } else {
                c.carte.opacity = 0
            }
        }
        CATransaction.commit()
    }
}
