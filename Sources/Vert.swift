// Bouton vert : au lieu du plein écran d'Apple (un espace à part, avec son glissement), la fenêtre passe en faux plein écran :
// elle remplit l'écran en restant sur le même bureau. Un second clic lui rend sa taille.
// Maj + clic ou Option + clic gardent le comportement d'origine de macOS.
import AppKit

enum BoutonVert {
    static var actif: Bool {
        get { UserDefaults.standard.object(forKey: "boutonVertFaux") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "boutonVertFaux") }
    }
    private static var filtre: CFMachPort?
    private static var clicAvalé = false
    private static let systeme: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.25)      // une application figée ne doit pas bloquer les clics
        return s
    }()

    static func demarrer() {
        guard filtre == nil else { return }
        let masque = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        filtre = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: masque, callback: { _, type, ev, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let f = BoutonVert.filtre { CGEvent.tapEnable(tap: f, enable: true) }
                return Unmanaged.passUnretained(ev)
            }
            if type == .leftMouseUp {
                guard BoutonVert.clicAvalé else { return Unmanaged.passUnretained(ev) }
                BoutonVert.clicAvalé = false
                return nil
            }
            guard BoutonVert.actif, !ev.flags.contains(.maskShift), !ev.flags.contains(.maskAlternate),
                  let fenetre = BoutonVert.fenetreDuBoutonVert(ev.location) else { return Unmanaged.passUnretained(ev) }
            BoutonVert.clicAvalé = true
            DispatchQueue.main.async {
                journal("Square: bouton vert → faux plein écran")
                Agrandir.basculer(fenetre)
            }
            return nil
        }, userInfo: nil)
        guard let filtre else { journal("Square: bouton vert non surveillé (autorisation Accessibilité ?)"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, filtre, 0), .commonModes)
        CGEvent.tapEnable(tap: filtre, enable: true)
    }

    private static func texte(_ el: AXUIElement, _ attribut: String) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribut as CFString, &v)
        return (v as? String) ?? ""
    }

    /// Si le clic tombe sur le bouton vert d'une fenêtre ordinaire, renvoie cette fenêtre.
    private static func fenetreDuBoutonVert(_ p: CGPoint) -> AXUIElement? {
        // Tri rapide, sans interroger aucune application : le clic est-il dans le coin haut gauche de la fenêtre du dessus ?
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // Le panneau du bas de Side, s'il est ouvert : il gère lui-même le bouton vert de ses tuiles.
        let panneauSide = infos.compactMap { i -> CGRect? in
            guard (i[kCGWindowOwnerName as String] as? String) == "Side", (i[kCGWindowLayer as String] as? Int) == 0,
                  let d = i[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d), r.height > 300 else { return nil }
            return r
        }.first
        // La fenêtre ordinaire la plus en avant sous le pointeur (les calques invisibles posés au-dessus de l'écran ne comptent pas).
        guard let dessus = infos.first(where: { i in
            guard (i[kCGWindowLayer as String] as? Int) == 0,
                  let d = i[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) else { return false }
            return r.contains(p)
        }),
              let d = dessus[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
              p.x - r.minX < 110, p.y - r.minY < 60 else { return nil }
        // Une tuile du panneau de Side (fenêtre posée à l'intérieur du panneau) : on laisse Side s'en occuper.
        if let panneauSide, panneauSide.insetBy(dx: -2, dy: -2).contains(r) { return nil }
        var el: AXUIElement?
        let etat = AXUIElementCopyElementAtPosition(systeme, Float(p.x), Float(p.y), &el)
        guard etat == .success, let el, texte(el, kAXSubroleAttribute) == "AXFullScreenButton" else {
            journal("Square: clic près du coin d'une fenêtre, pas sur le bouton vert (état %d, rôle %@, sous-rôle %@)", Int(etat.rawValue),
                    el.map { texte($0, kAXRoleAttribute) } ?? "-", el.map { texte($0, kAXSubroleAttribute) } ?? "-")
            return nil
        }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &v)
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let fenetre = v as! AXUIElement
        // Déjà dans un plein écran d'Apple : le bouton vert sert à en sortir, on laisse macOS faire.
        if AX.vrai(fenetre, "AXFullScreen") { return nil }
        return fenetre
    }
}
