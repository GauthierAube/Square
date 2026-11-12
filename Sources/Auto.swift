// Agrandissement automatique : chaque nouvelle fenêtre « normale » passe toute seule en faux plein écran, comme dans AeroSpace.
// Les petites fenêtres (réglages, boîtes de dialogue, palettes) sont laissées tranquilles, ainsi que les applications en exception.
import AppKit

enum AgrandirAuto {
    static var actif: Bool {
        get { UserDefaults.standard.object(forKey: "agrandirAuto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agrandirAuto") }
    }

    /// Jamais agrandi tout seul : Side lui-même. Les applications de son tiroir du bas le sont aussi, voir `tuilesDeSide` :
    /// leur liste se règle dans Side, plus dans Square (l'ancien réglage « Ne jamais agrandir » a été retiré le 12/11/2026).
    static let exceptions: Set<String> = ["com.gauthieraube.side"]

    /// Les applications rangées dans le panneau du bas de Side (la liste est tenue par Side, on la relit à chaque fois) :
    /// leurs fenêtres restent dans le panneau, on ne les agrandit jamais.
    static var tuilesDeSide: Set<String> {
        let liste = UserDefaults(suiteName: "com.gauthieraube.side")?.array(forKey: "panneauBasTuiles") as? [[String: String]] ?? []
        return Set(liste.compactMap { $0["bundle"] })
    }

    private static var observateurs: [pid_t: AXObserver] = [:]
    /// Fenêtres déjà examinées : chacune n'est agrandie qu'une fois, pour ne pas défaire une taille que vous avez choisie.
    private static var vues: Set<CGWindowID> = []

    private static func fenetres(_ a: NSRunningApplication) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(a.processIdentifier), kAXWindowsAttribute as CFString, &v)
        return (v as? [AXUIElement]) ?? []
    }

    static func demarrer() {
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            suivre(a)
            // Les fenêtres déjà ouvertes au lancement de Square gardent leur taille.
            for f in fenetres(a) { var wid: CGWindowID = 0; if _AXUIElementGetWindow(f, &wid) == .success { vues.insert(wid) } }
        }
        let centre = NSWorkspace.shared.notificationCenter
        // Comme AeroSpace : un seul signal ne suffit pas (il arrive trop tôt, ou pas du tout). À chaque fois qu'une application
        // passe devant, on relit ses fenêtres et on rattrape celles qui n'ont pas encore été examinées.
        centre.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  a.activationPolicy == .regular, a.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            suivre(a)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { for f in fenetres(a) { examiner(f) } }
        }
        centre.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // L'application met un instant à être prête ; sa première fenêtre a pu s'ouvrir avant qu'on l'écoute.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                suivre(a)
                for f in fenetres(a) { examiner(f) }
            }
        }
        centre.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let o = observateurs[a.processIdentifier] else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            observateurs[a.processIdentifier] = nil
        }
    }

    /// Demande à macOS de nous prévenir chaque fois que cette application ouvre une fenêtre.
    private static func suivre(_ a: NSRunningApplication) {
        let pid = a.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier, observateurs[pid] == nil, a.activationPolicy == .regular else { return }
        var o: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { AgrandirAuto.examiner(element) }
        }, &o) == .success, let o else { return }
        guard AXObserverAddNotification(o, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, nil) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observateurs[pid] = o
    }

    private static func texte(_ el: AXUIElement, _ attribut: String) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribut as CFString, &v)
        return (v as? String) ?? ""
    }

    private static func existe(_ el: AXUIElement, _ attribut: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribut as CFString, &v) == .success && v != nil
    }

    /// Agrandit la fenêtre si c'est une vraie fenêtre de travail.
    static func examiner(_ el: AXUIElement) {
        guard actif else { return }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &wid) == .success, wid != 0, !vues.contains(wid) else { return }
        // Bouton de souris enfoncé (fenêtre ou onglet en cours de déplacement) : on attend que vous ayez lâché.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { examiner(el) }
            return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, let a = NSRunningApplication(processIdentifier: pid),
              a.activationPolicy == .regular, !exceptions.contains(a.bundleIdentifier ?? ""),
              !tuilesDeSide.contains(a.bundleIdentifier ?? "") else { return }
        // Une fenêtre ordinaire, qui sait passer en plein écran : ni boîte de dialogue, ni palette, ni fenêtre de réglages.
        // Une fenêtre pas encore prête (sans sous-rôle ni boutons), réduite ou masquée sera réexaminée plus tard.
        guard texte(el, kAXRoleAttribute) == kAXWindowRole, texte(el, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !a.isHidden, !AX.vrai(el, kAXMinimizedAttribute) else { return }
        vues.insert(wid)
        // Le bouton vert doit exister et être utilisable : c'est ce qui distingue une fenêtre de travail d'un réglage ou d'un dialogue.
        var bouton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFullScreenButtonAttribute as CFString, &bouton) == .success, let bouton,
              CFGetTypeID(bouton) == AXUIElementGetTypeID(), AX.vrai(bouton as! AXUIElement, kAXEnabledAttribute),
              !AX.vrai(el, "AXFullScreen") else { return }
        var modifiable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &modifiable) == .success, modifiable.boolValue,
              let cadre = AX.cadre(el), cadre.width >= 480, cadre.height >= 320 else { return }
        journal("Square: nouvelle fenêtre de %@ agrandie (%.0fx%.0f)", a.localizedName ?? "?", cadre.width, cadre.height)
        Agrandir.basculer(el, seulementAgrandir: true)
    }
}
