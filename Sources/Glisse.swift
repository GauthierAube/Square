// Glissement à quatre doigts vers la gauche ou la droite : application suivante ou précédente, sur le même bureau.
// Il remplace le glissement de macOS entre bureaux quand il n'y a qu'un seul bureau. S'il y en a plusieurs, on laisse macOS faire.
// (Trois doigts ne conviennent pas ici : ils servent déjà à déplacer les fenêtres.)
import AppKit

/// Une touche du trackpad, telle que la décrit le module « MultitouchSupport » de macOS (non documenté par Apple).
private struct ContactGlisse {
    var frame: Int32; var horodatage: Double; var identifiant: Int32; var etat: Int32
    var doigt: Int32; var main: Int32
    var x: Float; var y: Float; var vx: Float; var vy: Float   // position de 0 à 1, et vitesse
    var taille: Float; var zero1: Int32; var angle: Float; var grandAxe: Float; var petitAxe: Float
    var ax: Float; var ay: Float; var avx: Float; var avy: Float
    var zero2: Int32; var zero3: Int32; var densite: Float
}

enum Glisse {
    static var actif: Bool {
        get { UserDefaults.standard.object(forKey: "glisseQuatreDoigts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "glisseQuatreDoigts") }
    }
    /// Sens du glissement. Par défaut, comme entre les bureaux de macOS : les cartes suivent les doigts (doigts vers la gauche,
    /// on avance vers la droite). Inversé : doigts vers la droite pour avancer vers la droite.
    static var inverse: Bool {
        get { UserDefaults.standard.bool(forKey: "glisseInverse") }
        set { UserDefaults.standard.set(newValue, forKey: "glisseInverse") }
    }
    private static var demarre = false
    private static var depart: [Int32: (Float, Float)] = [:]   // où chaque doigt s'est posé

    private typealias Liste = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Rappel = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Inscrire = @convention(c) (UnsafeMutableRawPointer?, Rappel) -> Void
    private typealias Lancer = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    static func demarrer() {
        guard !demarre else { return }
        guard let module = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let fListe = dlsym(module, "MTDeviceCreateList"), let fInscrire = dlsym(module, "MTRegisterContactFrameCallback"),
              let fLancer = dlsym(module, "MTDeviceStart") else { journal("Square: trackpad illisible, pas de glissement"); return }
        let liste = unsafeBitCast(fListe, to: Liste.self), inscrire = unsafeBitCast(fInscrire, to: Inscrire.self)
        let lancer = unsafeBitCast(fLancer, to: Lancer.self)
        guard let appareils = liste()?.takeRetainedValue() as? [AnyObject] else { return }
        for a in appareils {
            let p = Unmanaged.passUnretained(a).toOpaque()
            inscrire(p, { _, touches, nombre, _, _ in
                Glisse.recevoir(touches, Int(nombre))
                return 0
            })
            lancer(p, 0)
        }
        demarre = true
        journal("Square: glissement à quatre doigts surveillé sur %d trackpad(s)", appareils.count)
    }

    private static var phase = 0             // 0 : pas encore décidé, 1 : le carrousel suit les doigts, -1 : ce geste n'est pas pour nous
    private static var montre = false         // le carrousel est affiché pour ce geste
    private static var debutGeste: TimeInterval = 0
    private static let attente: TimeInterval = 0.24   // un geste parti vite mais qui dure plus que cela affiche quand même le carrousel
    private static let vif: Float = 0.5               // au-delà de cette vitesse de départ, le geste est pris pour un effleurement
    private static var departVif = false
    private static var rapidite: Float = 0
    private static var dxPrec: Float = 0
    private static var instantPrec: TimeInterval = 0
    private static var instantPose: TimeInterval = 0
    private static var dernier: Float = 0     // dernier trajet envoyé, en nombre de fenêtres
    private static let debut: Float = 0.02    // trajet avant de trancher entre horizontal (nous) et vertical (Side)
    private static let parFenetre: Float = 0.11   // trajet des doigts, en largeur de trackpad, pour avancer d'une fenêtre

    /// Appelé par macOS à chaque instant où des doigts touchent le trackpad (hors du fil principal).
    private static func recevoir(_ touches: UnsafeMutableRawPointer?, _ nombre: Int) {
        guard actif, let touches, nombre == 4 else {
            // Doigts levés : le carrousel choisit la fenêtre sous le cadre. (Un doigt levé un instant ne suffit pas.)
            if nombre < 3 || !actif {
                if phase == 1 {
                    let q = dernier
                    if montre {
                        DispatchQueue.main.async { Programme.appli.carrouselFin(CGFloat(q)) }
                    } else if abs(q) > 0.12 {
                        // Geste bref, doigts déjà relevés : pas de carrousel, on passe simplement à la fenêtre voisine.
                        DispatchQueue.main.async { Programme.appli.voisine(q > 0 ? 1 : -1) }
                    }
                }
                depart = [:]; phase = 0; dernier = 0; montre = false
            }
            return
        }
        guard phase >= 0 else { return }
        let contacts = touches.bindMemory(to: ContactGlisse.self, capacity: nombre)
        var dx: Float = 0, dy: Float = 0, suivis: Float = 0
        var vus: [Int32: (Float, Float)] = [:]
        for i in 0..<nombre {
            let c = contacts[i]
            vus[c.identifiant] = (c.x, c.y)
            if let d = depart[c.identifiant] { dx += c.x - d.0; dy += c.y - d.1; suivis += 1 }
        }
        let maintenant = ProcessInfo.processInfo.systemUptime
        if suivis < 4 { if phase == 0 { depart = vus; instantPose = maintenant }; return }   // les quatre doigts viennent de se poser
        // Tant que les doigts sont immobiles, le départ du mouvement reste « maintenant ».
        if phase == 0, max(abs(dx / suivis), abs(dy / suivis)) < 0.006 { instantPose = maintenant }
        dx /= suivis; dy /= suivis
        if phase == 0 {
            guard max(abs(dx), abs(dy)) > debut else { return }
            // Nettement vertical : c'est pour Side (sa carte, son panneau du bas).
            guard abs(dx) > abs(dy) else { phase = -1; return }
            phase = 1
            debutGeste = maintenant
            // Vitesse de départ : le trajet déjà fait, sur le temps écoulé depuis que les doigts ont commencé à bouger.
            rapidite = abs(dx) / Float(max(maintenant - instantPose, 0.008))
            dxPrec = dx; instantPrec = maintenant
            // Le geste est jugé une fois pour toutes, à son départ : parti vite, c'est un effleurement, et le carrousel
            // ne se montre que si les doigts sont encore posés un bon moment après (ralentir en fin de geste ne compte pas).
            departVif = rapidite > vif
        }
        // Comme entre les bureaux : la bande suit les doigts. Doigts vers la gauche, on avance vers les fenêtres de droite.
        // Vitesse des doigts, en largeurs de trackpad par seconde (lissée).
        let dt = Float(maintenant - instantPrec)
        if dt > 0.003 { rapidite = rapidite * 0.5 + abs(dx - dxPrec) / dt * 0.5; dxPrec = dx; instantPrec = maintenant }
        dernier = (inverse ? dx : -dx) / parFenetre
        let q = dernier
        if !montre {
            // Un geste posé affiche le carrousel tout de suite. Seul un effleurement rapide le retient : si les doigts se
            // relèvent aussitôt, on change de fenêtre sans rien afficher ; s'ils ralentissent ou restent, il apparaît.
            guard !departVif || maintenant - debutGeste > attente else { return }
            montre = true
            DispatchQueue.main.async { Programme.appli.carrouselDebut() }
        }
        DispatchQueue.main.async { Programme.appli.carrouselSuivre(CGFloat(q)) }
    }
}
