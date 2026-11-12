// Square : une grille plein écran pour naviguer sur le Mac sans Mission Control.
// Chaque fenêtre agrandie (un faux plein écran, sans changement d'espace) a sa case, plus le bureau et les plein écran d'Apple restants.
// Un raccourci ouvre la grille ; un clic ou un chiffre envoie sur la case choisie, sans glissement d'écran.
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Fonctions système non documentées (liste des espaces, photo et repérage des fenêtres)

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: Int32, _ owner: Int32, _ spaces: CFArray, _ options: Int32,
                                      _ setTags: inout UInt64, _ clearTags: inout UInt64) -> CFArray
@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ cid: Int32, _ liste: UnsafePointer<CGWindowID>, _ n: UInt32, _ options: UInt32) -> Unmanaged<CFArray>?
@_silgen_name("CGWindowListCreateImage")
func CGWindowListCreateImageAncienne(_ zone: CGRect, _ options: UInt32, _ wid: CGWindowID, _ image: UInt32) -> Unmanaged<CGImage>?
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// Petit journal dans ~/Library/Logs/Square.log, pour comprendre un souci après coup.
func journal(_ format: String, _ args: CVarArg...) {
    let ligne = ISO8601DateFormatter().string(from: Date()) + " " + String(format: format, arguments: args) + "\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Square.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(ligne.data(using: .utf8)!); try? h.close() }
    else { try? ligne.data(using: .utf8)!.write(to: url) }
}

// MARK: - Modèle

struct Fenetre {
    let wid: CGWindowID
    let pid: pid_t
    let app: String
    let titre: String
    let cadre: CGRect          // coordonnées globales, origine en haut à gauche
    let agrandie: Bool         // remplit l'écran (mode Square), sans être un plein écran d'Apple
    let masquee: Bool          // son application est masquée
}

struct Espace {
    let id: UInt64
    let pleinEcran: Bool       // plein écran d'Apple
    let ecran: String          // identifiant de l'écran
    let rang: Int              // position dans l'ordre de Mission Control, sur son écran
    let fenetres: [Fenetre]    // de la plus en avant à la plus en arrière
    var nomBureau = "Bureau"
}

enum Cible {
    case espace(Espace)                 // un plein écran d'Apple, ou un bureau
    case fenetre(Fenetre, Espace)       // une fenêtre
    case groupe([Fenetre], Espace)      // des fenêtres qui se partagent l'écran : une seule case, une seule « page »
}

struct Tuile {
    let cle: String
    let titre: String
    let icone: NSImage?
    let cible: Cible
    let pid: pid_t
    /// La zone de l'écran occupée : le cadre de la fenêtre, ou celui qui englobe toutes les fenêtres d'un groupe.
    var cadre: CGRect? {
        switch cible {
        case .fenetre(let f, _): return f.cadre
        case .groupe(let fs, _): return Tuile.englobant(fs)
        case .espace: return nil
        }
    }
    static func englobant(_ fs: [Fenetre]) -> CGRect { fs.dropFirst().reduce(fs.first?.cadre ?? .zero) { $0.union($1.cadre) } }
    var place = 0              // case occupée dans la grille : elle ne change jamais tant que la fenêtre existe
}

enum Ecrans {
    static func ecran(_ identifiant: String) -> NSScreen? {
        for s in NSScreen.screens where self.identifiant(s) == identifiant { return s }
        return NSScreen.main
    }
    static func identifiant(_ s: NSScreen?) -> String {
        guard let n = s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return "Main" }
        return CFUUIDCreateString(nil, u) as String
    }
    static func cadreGlobal(_ s: NSScreen?) -> CGRect {
        guard let n = s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return CGDisplayBounds(n)
    }
    /// Zone utilisable (sans barre de menus ni Dock) de l'écran qui contient ce cadre, origine en haut à gauche.
    static func zoneVisible(contenant r: CGRect) -> CGRect {
        let centre = CGPoint(x: r.midX, y: r.midY)
        let s = NSScreen.screens.first { cadreGlobal($0).contains(centre) } ?? NSScreen.main
        guard let s else { return r }
        let h = NSScreen.screens.first?.frame.height ?? s.frame.height
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: h - v.maxY, width: v.width, height: v.height)
    }
}

enum Relevé {
    /// Tous les espaces (plein écran d'Apple et bureaux) avec leurs fenêtres, et l'espace affiché sur chaque écran.
    static func tout() -> (espaces: [Espace], courants: [String: UInt64]) {
        let cid = CGSMainConnectionID()
        let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var parId: [CGWindowID: [String: Any]] = [:]
        for i in infos { if let n = i[kCGWindowNumber as String] as? CGWindowID { parId[n] = i } }
        let moi = ProcessInfo.processInfo.processIdentifier
        var apps: [pid_t: NSRunningApplication] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { apps[a.processIdentifier] = a }

        var espaces: [Espace] = []
        var courants: [String: UInt64] = [:]
        let ecrans = (CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]]) ?? []
        for e in ecrans {
            let ecran = (e["Display Identifier"] as? String) ?? "Main"
            if let c = ((e["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value { courants[ecran] = c }
            var numeroBureau = 0
            let liste = (e["Spaces"] as? [[String: Any]]) ?? []
            let nbBureaux = liste.filter { ($0["type"] as? Int) == 0 }.count
            for (rang, s) in liste.enumerated() {
                guard let id = (s["id64"] as? NSNumber)?.uint64Value else { continue }
                let plein = (s["type"] as? Int) == 4
                var a: UInt64 = 0, b: UInt64 = 0
                let espace = [NSNumber(value: id)] as CFArray
                // Option 2 : fenêtres visibles, dans l'ordre. Option 7 : aussi celles des applications masquées (et les réduites).
                let visibles = (CGSCopyWindowsWithOptionsAndTags(cid, 0, espace, 2, &a, &b) as? [NSNumber])?.map { $0.uint32Value } ?? []
                let toutes = (CGSCopyWindowsWithOptionsAndTags(cid, 0, espace, 7, &a, &b) as? [NSNumber])?.map { $0.uint32Value } ?? []
                var fenetres: [Fenetre] = []
                for (w, masquee) in visibles.map({ ($0, false) }) + toutes.filter({ !visibles.contains($0) }).map({ ($0, true) }) {
                    guard let i = parId[w],
                          (i[kCGWindowLayer as String] as? Int) == 0,
                          let pid = i[kCGWindowOwnerPID as String] as? pid_t, pid != moi, let app = apps[pid],
                          !masquee || app.isHidden,                 // une fenêtre réduite dans le Dock ne compte pas
                          let d = i[kCGWindowBounds as String] as? NSDictionary,
                          let cadre = CGRect(dictionaryRepresentation: d),
                          cadre.width >= 120, cadre.height >= 80,
                          // Une fenêtre rangée hors de l'écran (le panneau du bas de Side range ainsi les siennes) ne compte pas.
                          NSScreen.screens.contains(where: { s in
                              let commun = Ecrans.cadreGlobal(s).intersection(cadre)
                              return !commun.isNull && commun.width * commun.height >= 0.1 * cadre.width * cadre.height
                          }),
                          ((i[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05 else { continue }
                    var agrandie = false
                    if !plein {
                        let zone = Ecrans.zoneVisible(contenant: cadre)
                        let commun = cadre.intersection(zone)
                        agrandie = !commun.isNull && commun.width * commun.height >= 0.9 * zone.width * zone.height
                    }
                    fenetres.append(Fenetre(wid: w, pid: pid, app: app.localizedName ?? "?",
                                            titre: (i[kCGWindowName as String] as? String) ?? "",
                                            cadre: cadre, agrandie: agrandie, masquee: masquee))
                }
                var esp = Espace(id: id, pleinEcran: plein, ecran: ecran, rang: rang, fenetres: fenetres)
                if !plein {
                    numeroBureau += 1
                    esp.nomBureau = nbBureaux > 1 ? "Bureau \(numeroBureau)" : "Bureau"
                }
                espaces.append(esp)
            }
        }
        return (espaces, courants)
    }

    static func espaceCourant(ecran: String) -> UInt64? { tout().courants[ecran] }
}

// MARK: - Accessibilité : retrouver, placer, agrandir une fenêtre

enum AX {
    private static var reperes: [CGWindowID: UInt64] = [:]     // déjà trouvées : on les retrouve tout de suite

    private static func element(pid: pid_t, numero: UInt64, wid: CGWindowID) -> AXUIElement? {
        var d = Data(count: 20)
        d.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        d.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        d.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        d.replaceSubrange(12..<20, with: withUnsafeBytes(of: numero) { Data($0) })
        guard let el = _AXUIElementCreateWithRemoteToken(d as CFData)?.takeRetainedValue() else { return nil }
        var w: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &w) == .success, w == wid else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        return (role as? String) == (kAXWindowRole as String) ? el : nil
    }

    /// Retrouve la fenêtre d'une application, même si elle est sur un autre espace.
    static func fenetre(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        if let n = reperes[wid], let el = element(pid: pid, numero: n, wid: wid) { return el }
        let debut = Date()
        for i: UInt64 in 0..<60000 {
            if i % 500 == 0, Date().timeIntervalSince(debut) > 0.6 { break }
            if let el = element(pid: pid, numero: i, wid: wid) { reperes[wid] = i; return el }
        }
        return nil
    }

    static func vrai(_ el: AXUIElement, _ attribut: String) -> Bool {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribut as CFString, &v)
        return (v as? Bool) ?? false
    }

    static func cadre(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s)
        guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, taille = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &taille)
        return CGRect(origin: point, size: taille)
    }

    static func placer(_ el: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let vp = AXValueCreate(.cgPoint, &p), let vs = AXValueCreate(.cgSize, &s) else { return }
        // Comme AeroSpace : taille, position, puis taille de nouveau (la première peut être bridée par l'ancienne position),
        // en coupant le temps du réglage le mode « interface enrichie » qui fait traîner certaines applications.
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enrichie = vrai(app, "AXEnhancedUserInterface")
        if enrichie { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, vs)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, vp)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, vs)
        if enrichie { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    static func lever(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }
}

enum Agrandir {
    private static var anciens: [CGWindowID: CGRect] = [:]      // taille d'avant, pour pouvoir revenir en arrière

    /// Agrandit la fenêtre pour remplir l'écran (ou lui rend sa taille si elle l'est déjà).
    /// Un plein écran d'Apple est d'abord quitté.
    static func basculer(_ el: AXUIElement, seulementAgrandir: Bool = false) {
        if AX.vrai(el, "AXFullScreen") {
            AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, kCFBooleanFalse)
            attendreSortie(el, essais: 20)
            return
        }
        guard let cadre = AX.cadre(el) else { return }
        let zone = Ecrans.zoneVisible(contenant: cadre)
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(el, &wid)
        let commun = cadre.intersection(zone)
        let dejà = !commun.isNull && commun.width * commun.height >= 0.9 * zone.width * zone.height
        if dejà {
            if !seulementAgrandir, let avant = anciens[wid] { AX.placer(el, avant); anciens[wid] = nil }
        } else {
            anciens[wid] = cadre
            Groupes.retirer(wid)             // agrandie, elle ne partage plus l'écran avec personne
            AX.placer(el, zone)
        }
    }

    private static func attendreSortie(_ el: AXUIElement, essais: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if AX.vrai(el, "AXFullScreen"), essais > 0 { attendreSortie(el, essais: essais - 1); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let cadre = AX.cadre(el) { AX.placer(el, Ecrans.zoneVisible(contenant: cadre)) }
            }
        }
    }

    static func fenetreActive() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &v)
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { NSSound.beep(); return }
        basculer(v as! AXUIElement)
    }

    /// Sort toutes les applications du plein écran d'Apple et les agrandit à la place.
    static func convertirTout() {
        let pleins = Relevé.tout().espaces.filter { $0.pleinEcran }
        journal("Square: conversion de %d plein écran", pleins.count)
        for (i, e) in pleins.enumerated() {
            guard let f = e.fenetres.first else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) {
                if let el = AX.fenetre(pid: f.pid, wid: f.wid) { basculer(el, seulementAgrandir: true) }
            }
        }
    }
}

// MARK: - Aller quelque part

enum Bascule {
    static func fleche(gauche: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        for appui in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: gauche ? 123 : 124, keyDown: appui) else { continue }
            e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e.post(tap: .cghidEventTap)
            usleep(15000)
        }
    }

    /// Dernier recours pour changer d'espace : Contrôle + flèches, autant de fois qu'il faut.
    static func parFleches(vers cible: Espace, puis fin: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<12 {
                let (espaces, courants) = Relevé.tout()
                guard let ici = courants[cible.ecran], ici != cible.id,
                      let rangIci = espaces.first(where: { $0.id == ici })?.rang,
                      let rangCible = espaces.first(where: { $0.id == cible.id })?.rang else { break }
                fleche(gauche: rangCible < rangIci)
                let t = Date()
                while Date().timeIntervalSince(t) < 1.2, Relevé.espaceCourant(ecran: cible.ecran) == ici { usleep(30000) }
                if Relevé.espaceCourant(ecran: cible.ecran) == ici { break }   // la flèche n'a rien fait
            }
            DispatchQueue.main.async(execute: fin)
        }
    }

    /// Met une fenêtre devant. Si elle est sur un autre espace, macOS y glisse.
    static func montrer(_ f: Fenetre, dans e: Espace) {
        guard let app = NSRunningApplication(processIdentifier: f.pid) else { return }
        let el = AX.fenetre(pid: f.pid, wid: f.wid)
        journal("Square: vers %@ (fenêtre %d), accessibilité=%d, trouvée=%d", f.app, Int(f.wid), AXIsProcessTrusted() ? 1 : 0, el != nil ? 1 : 0)
        if app.isHidden { app.unhide() }
        // Une fenêtre qui partage l'écran avec d'autres les amène devant avec elle.
        Groupes.monterLeGroupe(de: f) {
            if let el { AX.lever(el) }
            app.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if Relevé.espaceCourant(ecran: e.ecran) != e.id {
                journal("Square: pas arrivé, on finit avec les flèches")
                parFleches(vers: e) {}
            }
        }
    }

    /// Affiche le bureau : les applications agrandies sont masquées, les fenêtres normales reviennent devant.
    static func bureau(_ e: Espace) {
        let normales = e.fenetres.filter { !$0.agrandie && !$0.masquee }
        let pidsNormales = Set(normales.map { $0.pid })
        for pid in Set(e.fenetres.filter { $0.agrandie && !$0.masquee }.map { $0.pid }) where !pidsNormales.contains(pid) {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
        let finir = {
            for f in normales.prefix(8).reversed() { if let el = AX.fenetre(pid: f.pid, wid: f.wid) { AX.lever(el) } }
            if let premier = normales.first, let app = NSRunningApplication(processIdentifier: premier.pid) {
                app.activate(options: [])
            } else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
            }
        }
        if Relevé.espaceCourant(ecran: e.ecran) == e.id { finir(); return }
        if let premier = normales.first {
            montrer(premier, dans: e)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: finir)
        } else {
            journal("Square: vers %@ par les flèches", e.nomBureau)
            parFleches(vers: e, puis: finir)
        }
    }

    static func aller(_ t: Tuile, espaces: [Espace]) {
        switch t.cible {
        case .groupe(let fs, let e):
            if let f = fs.first { montrer(f, dans: e) }
        case .fenetre(let f, let e):
            montrer(f, dans: e)
        case .espace(let e):
            if e.pleinEcran, let f = e.fenetres.first { montrer(f, dans: e) } else if !e.pleinEcran { bureau(e) }
        }
    }

    static func fenetre(deLApp pid: pid_t, espaces: [Espace]) -> (Fenetre, Espace)? {
        guard pid != 0 else { return nil }
        for e in espaces { if let f = e.fenetres.first(where: { $0.pid == pid }) { return (f, e) } }
        return nil
    }

    /// L'espace change-t-il d'écran (glissement de macOS) pour atteindre cette case ?
    static func espaceVise(_ t: Tuile, espaces: [Espace]) -> Espace? {
        switch t.cible {
        case .fenetre(_, let e): return e
        case .groupe(_, let e): return e
        case .espace(let e): return e
        }
    }
}

// MARK: - Images des fenêtres

/// Photographie les fenêtres, même celles qui ne sont pas affichées, pour former l'image de chaque case.
final class Images {
    static let commun = Images()
    private var cache: [CGWindowID: CGImage] = [:]
    private var fonds: [String: CGImage] = [:]

    static var autorisé: Bool { CGPreflightScreenCaptureAccess() }

    private static func photo(_ wid: CGWindowID) -> CGImage? {
        var w = wid
        if let img = (CGSHWCaptureWindowList(CGSMainConnectionID(), &w, 1, 1 << 9)?.takeRetainedValue() as? [CGImage])?.first { return img }
        return CGWindowListCreateImageAncienne(.null, 8, wid, 1 | 16)?.takeRetainedValue()
    }

    func capturer(_ espaces: [Espace], chaque: @escaping () -> Void) {
        guard Images.autorisé else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for e in espaces {
                var nouvelles: [CGWindowID: CGImage] = [:]
                for f in e.fenetres.prefix(16) { if let img = Images.photo(f.wid) { nouvelles[f.wid] = img } }
                if nouvelles.isEmpty { continue }
                DispatchQueue.main.async {
                    for (k, v) in nouvelles { self.cache[k] = v }
                    chaque()
                }
            }
        }
    }

    /// La dernière photo connue d'une fenêtre.
    func enCache(_ wid: CGWindowID) -> CGImage? { cache[wid] }

    func oublier(sauf vivantes: Set<CGWindowID>) { cache = cache.filter { vivantes.contains($0.key) } }

    private func fond(ecran: NSScreen?) -> CGImage? {
        guard let ecran, let url = NSWorkspace.shared.desktopImageURL(for: ecran) else { return nil }
        if let f = fonds[url.path] { return f }
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        fonds[url.path] = img
        return img
    }

    private var flous: [String: CGImage] = [:]

    /// Le fond d'écran, flouté et un peu assombri : le fond de la grille.
    func fondFlou(ecran: NSScreen?) -> CGImage? {
        guard let ecran, let url = NSWorkspace.shared.desktopImageURL(for: ecran), let net = fond(ecran: ecran) else { return nil }
        if let f = flous[url.path] { return f }
        // Réduit d'abord (le flou n'a pas besoin de détails), puis flouté.
        let l = 640, h = max(1, Int(640 * CGFloat(net.height) / CGFloat(max(net.width, 1))))
        guard let ctx = CGContext(data: nil, width: l, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(net, in: CGRect(x: 0, y: 0, width: l, height: h))
        guard let petit = ctx.makeImage() else { return nil }
        let entree = CIImage(cgImage: petit)
        let flou = entree.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.15])
            .cropped(to: entree.extent)
        guard let sortie = CIContext().createCGImage(flou, from: entree.extent) else { return nil }
        flous[url.path] = sortie
        return sortie
    }

    /// Image d'une case. nil s'il n'y a rien à montrer (la case affiche alors la grande icône).
    func image(pour t: Tuile, espaces: [Espace]) -> CGImage? {
        switch t.cible {
        case .fenetre(let f, _): return cache[f.wid]
        case .groupe(let fs, let e):
            guard let tout = composer(fs, ecran: e.ecran, papier: true) else { return nil }
            let zone = Ecrans.cadreGlobal(Ecrans.ecran(e.ecran)), u = Tuile.englobant(fs)
            return tout.cropping(to: CGRect(x: u.minX - zone.minX, y: u.minY - zone.minY, width: u.width, height: u.height)) ?? tout
        case .espace(let e):
            if e.pleinEcran { return composer(e.fenetres, ecran: e.ecran, papier: false) }
            return composer(e.fenetres.filter { !$0.agrandie && !$0.masquee }, ecran: e.ecran, papier: true)
        }
    }

    /// Pose les fenêtres à leur place sur un fond (noir, ou le fond d'écran pour un bureau).
    private func composer(_ fenetres: [Fenetre], ecran identifiant: String, papier: Bool) -> CGImage? {
        let ecran = Ecrans.ecran(identifiant)
        let zone = Ecrans.cadreGlobal(ecran)
        let visibles = fenetres.filter { cache[$0.wid] != nil }
        let image = papier ? fond(ecran: ecran) : nil
        if visibles.isEmpty && image == nil { return nil }
        let l = Int(zone.width), h = Int(zone.height)
        guard l > 0, h > 0, let ctx = CGContext(data: nil, width: l, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: papier ? 0.2 : 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: l, height: h))
        if let f = image {
            let r = max(CGFloat(l) / CGFloat(f.width), CGFloat(h) / CGFloat(f.height))
            let fl = CGFloat(f.width) * r, fh = CGFloat(f.height) * r
            ctx.draw(f, in: CGRect(x: (CGFloat(l) - fl) / 2, y: (CGFloat(h) - fh) / 2, width: fl, height: fh))
        }
        for f in visibles.reversed() {
            guard let img = cache[f.wid] else { continue }
            ctx.draw(img, in: CGRect(x: f.cadre.minX - zone.minX, y: zone.height - (f.cadre.minY - zone.minY) - f.cadre.height,
                                     width: f.cadre.width, height: f.cadre.height))
        }
        return ctx.makeImage()
    }
}

// MARK: - Raccourcis clavier globaux

enum Touches {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installé = false

    static func installer() {
        guard !installé else { return }
        installé = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Touches.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func ajouter(_ id: UInt32, touche: UInt32, modifs: UInt32, action: @escaping () -> Void) {
        installer()
        retirer(id)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x53515245), id: id)   // "SQRE"
        let etat = RegisterEventHotKey(touche, modifs, hk, GetApplicationEventTarget(), 0, &ref)
        if etat == noErr, let ref {
            refs[id] = ref
            actions[id] = action
        } else {
            journal("Square: touche %d refusée (%d)", Int(touche), Int(etat))
        }
    }

    static func retirer(_ id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
        actions[id] = nil
    }
}

struct Raccourci {
    var touche: UInt32
    var modifs: UInt32      // au format Carbon
    var nom: String

    static let défaut = Raccourci(touche: UInt32(kVK_Tab), modifs: UInt32(optionKey), nom: "⌥ Tab")

    static var actuel: Raccourci {
        get {
            let d = UserDefaults.standard
            guard let nom = d.string(forKey: "raccourciNom") else { return défaut }
            return Raccourci(touche: UInt32(d.integer(forKey: "raccourciTouche")),
                             modifs: UInt32(d.integer(forKey: "raccourciModifs")), nom: nom)
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.touche), forKey: "raccourciTouche")
            d.set(Int(newValue.modifs), forKey: "raccourciModifs")
            d.set(newValue.nom, forKey: "raccourciNom")
        }
    }

    static func depuis(_ e: NSEvent) -> Raccourci? {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let speciales: [Int: String] = [
            kVK_Tab: "Tab", kVK_Space: String(localized: "Espace"), kVK_Return: String(localized: "Entrée"), kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
            kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let code = Int(e.keyCode)
        let touche = speciales[code] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        let estF = (speciales[code] ?? "").hasPrefix("F")
        if m.isEmpty && !estF { return nil }            // une lettre seule bloquerait la frappe
        var carbon: UInt32 = 0
        var nom = ""
        if m.contains(.control) { carbon |= UInt32(controlKey); nom += "⌃" }
        if m.contains(.option) { carbon |= UInt32(optionKey); nom += "⌥" }
        if m.contains(.shift) { carbon |= UInt32(shiftKey); nom += "⇧" }
        if m.contains(.command) { carbon |= UInt32(cmdKey); nom += "⌘" }
        return Raccourci(touche: UInt32(code), modifs: carbon, nom: nom.isEmpty ? touche : nom + " " + touche)
    }
}

// MARK: - Grille

let orange = NSColor(srgbRed: 0.847, green: 0.435, blue: 0.290, alpha: 1)

final class Case: NSView {
    var tuile: Tuile
    let numero: Int
    private let image = CALayer()
    private let ombre = CALayer()
    private let grandeIcone = NSImageView()
    private let petiteIcone = NSImageView()
    private var iconesMembres: [(vue: NSImageView, fenetre: Fenetre)] = []
    /// Le cadre de la vignette, dans les coordonnées de la case.
    private(set) var cadreVignette = CGRect.zero
    private let fermer = NSButton()
    private let fermable: Bool
    var auFermer: (() -> Void)?
    private(set) var imageActuelle: CGImage?

    var survol = false { didSet {
        majBordure(); fermer.isHidden = !(survol && fermable)
        for b in subviews where b.identifier?.rawValue == "badge" { b.isHidden = !survol }
    } }
    var courant = false { didSet { majBordure() } }

    init(tuile: Tuile, numero: Int) {
        self.tuile = tuile
        self.numero = numero
        fermable = true
        super.init(frame: .zero)
        wantsLayer = true
        // La fenêtre flotte sur le fond flou : une vignette à ses proportions, avec une ombre, et son nom en dessous.
        ombre.shadowColor = NSColor.black.cgColor
        ombre.shadowOpacity = 0.45
        ombre.shadowRadius = 22
        ombre.shadowOffset = CGSize(width: 0, height: -10)
        layer?.addSublayer(ombre)
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.cornerRadius = 10
        image.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        ombre.addSublayer(image)

        grandeIcone.image = tuile.icone
        grandeIcone.imageScaling = .scaleProportionallyUpOrDown
        addSubview(grandeIcone)

        petiteIcone.image = tuile.icone
        petiteIcone.imageScaling = .scaleProportionallyUpOrDown
        addSubview(petiteIcone)

        // Pas de nom : l'icône de l'application, à cheval sur le bas de la vignette.
        petiteIcone.wantsLayer = true
        // Une case de groupe : une icône par fenêtre, chacune sous la sienne.
        if case .groupe(let fs, _) = tuile.cible {
            petiteIcone.isHidden = true
            for f in fs {
                let v = NSImageView()
                v.image = NSRunningApplication(processIdentifier: f.pid)?.icon
                v.imageScaling = .scaleProportionallyUpOrDown
                v.wantsLayer = true
                v.shadow = petiteIcone.shadow
                iconesMembres.append((v, f))
            }
        }
        petiteIcone.shadow = { let o = NSShadow(); o.shadowColor = NSColor(white: 0, alpha: 0.45); o.shadowBlurRadius = 8
                               o.shadowOffset = NSSize(width: 0, height: -3); return o }()

        if numero <= 9 {
            let badge = Pastille(texte: "\(numero)")
            badge.identifier = NSUserInterfaceItemIdentifier("badge")
            badge.isHidden = true                 // le chiffre ne se montre qu'au survol
            addSubview(badge)
        }

        fermer.bezelStyle = .circular
        fermer.isBordered = false
        fermer.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(white: 0.1, alpha: 0.85)])))
        // Croix blanche sur rond sombre : visible aussi sur une fenêtre claire (celle du Finder, par exemple).
        fermer.shadow = { let o = NSShadow(); o.shadowColor = NSColor(white: 0, alpha: 0.4); o.shadowBlurRadius = 4; return o }()
        fermer.toolTip = String(localized: "Quitter \(tuile.titre)")
        fermer.target = self
        fermer.action = #selector(clicFermer)
        fermer.isHidden = true
        addSubview(fermer)
        majBordure()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicFermer() { auFermer?() }

    private func majBordure() {
        image.borderWidth = survol ? 4 : (courant ? 2 : 0)
        image.borderColor = (survol ? orange : NSColor(white: 1, alpha: 0.7)).cgColor
    }

    func montrer(_ img: CGImage?) {
        imageActuelle = img
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = img
        CATransaction.commit()
        grandeIcone.isHidden = img != nil
        needsLayout = true
    }

    /// Proportions de la fenêtre : celles de sa photo, sinon celles de son cadre à l'écran.
    private var proportions: CGFloat {
        // La forme de la vignette suit la place de la fenêtre à l'écran, pas sa photo : une photo pas encore refaite
        // (fenêtre qui vient de changer de taille) est simplement rognée, sans déformer la case.
        if let r = tuile.cadre, r.height > 0 { return r.width / r.height }
        if let i = imageActuelle, i.height > 0 { return CGFloat(i.width) / CGFloat(i.height) }
        return 1.6
    }

    override func layout() {
        super.layout()
        // La vignette prend toute la place au-dessus du pied (où dépasse l'icône), à ses proportions, centrée.
        let pied: CGFloat = 26
        let zone = CGRect(x: 0, y: pied, width: bounds.width, height: max(10, bounds.height - pied))
        var l = zone.width, h = l / proportions
        if h > zone.height { h = zone.height; l = h * proportions }
        cadreVignette = CGRect(x: zone.midX - l / 2, y: zone.midY - h / 2, width: l, height: h).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ombre.frame = cadreVignette
        image.frame = ombre.bounds
        ombre.shadowPath = CGPath(roundedRect: ombre.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
        let v = cadreVignette
        let c = min(v.width, v.height) * 0.34
        grandeIcone.frame = NSRect(x: v.midX - c / 2, y: v.midY - c / 2, width: c, height: c)
        fermer.frame = NSRect(x: v.maxX - 40, y: v.maxY - 40, width: 34, height: 34)
        for b in subviews where b.identifier?.rawValue == "badge" { b.frame = NSRect(x: v.minX + 10, y: v.maxY - 38, width: 28, height: 28) }
        // L'icône, centrée et droite, à cheval sur le bord bas de la vignette.
        let cote: CGFloat = 58
        petiteIcone.frame = NSRect(x: v.midX - cote / 2, y: v.minY - 24, width: cote, height: cote)
        if case .groupe(let fs, _) = tuile.cible {
            let tout = Tuile.englobant(fs)
            for (vue, f) in iconesMembres {
                if vue.superview == nil { addSubview(vue, positioned: .below, relativeTo: fermer) }
                // Le cadre de cette fenêtre dans la vignette : l'icône est à cheval sur son bord bas.
                let x = v.minX + (f.cadre.midX - tout.minX) / max(tout.width, 1) * v.width
                let bas = v.maxY - (f.cadre.maxY - tout.minY) / max(tout.height, 1) * v.height
                let c2: CGFloat = 46
                vue.frame = NSRect(x: x - c2 / 2, y: bas - 19, width: c2, height: c2)
            }
        }
    }
}

/// Le chiffre d'une case, bien centré dans un rond.
final class Pastille: NSView {
    private let texte: String
    init(texte: String) { self.texte = texte; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attributs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
                                                        .foregroundColor: NSColor.white]
        let t = texte.size(withAttributes: attributs)
        texte.draw(at: NSPoint(x: bounds.midX - t.width / 2, y: bounds.midY - t.height / 2), withAttributes: attributs)
    }
}

final class BandeBas: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(white: 0, alpha: 0.82), ending: .clear)?.draw(in: bounds, angle: 90)
    }
}

final class Grille: NSView {
    var cases: [Case] = []
    private var zoom: CALayer?
    var auChoix: ((Case) -> Void)?
    var auFond: (() -> Void)?
    var auFermer: ((Tuile) -> Void)?
    var auDepot: ((Tuile, Depot) -> Void)?
    private var animeDisposition = false
    let dock = DockGrille(frame: .zero)

    /// Des fenêtres ont quitté la grille : leurs cases disparaissent et les autres glissent en douceur vers leur nouvelle place
    /// (et leur nouvelle taille, si la grille a perdu une colonne ou une ligne).
    func reorganiser(_ tuiles: [Tuile], fin: @escaping () -> Void) {
        let gardees = Dictionary(uniqueKeysWithValues: tuiles.map { ($0.cle, $0) })
        for c in cases where gardees[c.tuile.cle] == nil { c.removeFromSuperview() }
        cases = cases.filter { gardees[$0.tuile.cle] != nil }
        for c in cases { if let t = gardees[c.tuile.cle] { c.tuile = t } }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            animeDisposition = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            animeDisposition = false
        }, completionHandler: fin)
    }
    // Glisser-déposer d'une case
    private var prise: Case?
    private var priseEn = CGPoint.zero
    private var volante: CALayer?
    private let repere = CALayer()
    private var depot: Depot?
    private var videsActuelles: [(place: Int, cadre: CGRect)] = []
    // Redimensionnement : la séparation entre deux fenêtres d'une case de groupe, que l'on tire
    private var reglage: (c: Case, a: Fenetre, b: Fenetre, horizontal: Bool)?
    private var restante: CALayer?             // la fenêtre qui reste seule dans son groupe s'étend pendant qu'on emporte l'autre
    private var restanteWid: CGWindowID = 0
    private var source: Tuile?                 // ce que l'on transporte : la case, ou une seule fenêtre d'une case de groupe
    private var sortDUnGroupe = false
    private var origineVolante = CGRect.zero
    private var imageVolante: CGImage?
    private var zone: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        addSubview(dock)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Le fond de la grille : le fond d'écran du bureau, flouté.
    func poserFond(_ img: CGImage?) { layer?.contents = img }

    /// Où chaque fenêtre est dessinée dans la grille (seule dans sa case, ou à sa place dans une case de groupe).
    private func cadresDesFenetres() -> [CGWindowID: CGRect] {
        var r: [CGWindowID: CGRect] = [:]
        let ecran = Ecrans.cadreGlobal(window?.screen)
        for c in cases {
            let v = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY)
            switch c.tuile.cible {
            case .fenetre(let f, _): r[f.wid] = v
            case .groupe(let fs, _):
                let ecran = Tuile.englobant(fs)
                for f in fs {
                    r[f.wid] = CGRect(x: v.minX + (f.cadre.minX - ecran.minX) / ecran.width * v.width,
                                      y: v.maxY - (f.cadre.maxY - ecran.minY) / ecran.height * v.height,
                                      width: f.cadre.width / ecran.width * v.width, height: f.cadre.height / ecran.height * v.height)
                }
            case .espace: break
            }
        }
        return r
    }

    /// D'où part une fenêtre qu'on vient de lâcher : de l'endroit où était la souris, pas de son ancienne case.
    private var lachers: [CGWindowID: CGRect] = [:]
    private var volants: [CALayer] = []

    /// Recharge la grille. Avec « transition », chaque fenêtre glisse de son ancienne place à la nouvelle, en changeant
    /// de forme s'il le faut (partage de l'écran, retour au plein écran, échange de cases) : rien ne saute.
    func charger(_ tuiles: [Tuile], courante: String?, espaces: [Espace], transition: Bool) {
        guard transition, let fond = layer else { lachers = [:]; charger(tuiles, courante: courante, espaces: espaces); return }
        var avant = cadresDesFenetres()
        for (w, r) in lachers { avant[w] = r }
        lachers = [:]
        charger(tuiles, courante: courante, espaces: espaces)
        let apres = cadresDesFenetres()
        volants.forEach { $0.removeFromSuperlayer() }
        volants = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (w, arrivee) in apres {
            guard let depart = avant[w] else { continue }
            let l = CALayer()
            l.contents = Images.commun.enCache(w)
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.cornerRadius = 10
            l.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            l.frame = depart
            l.zPosition = 70
            l.setValue(NSValue(rect: arrivee), forKey: "arrivee")
            fond.addSublayer(l)
            volants.append(l)
        }
        CATransaction.commit()
        let nouvelles = cases
        nouvelles.forEach { $0.alphaValue = 0 }
        let lot = volants
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1))
        CATransaction.setCompletionBlock { [weak self] in
            // Les vraies cases prennent le relais, en fondu, puis les calques de transition disparaissent.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                nouvelles.forEach { $0.animator().alphaValue = 1 }
            }) {
                lot.forEach { $0.removeFromSuperlayer() }
                self?.volants.removeAll { l in lot.contains { $0 === l } }
            }
        }
        for l in lot { if let r = (l.value(forKey: "arrivee") as? NSValue)?.rectValue { l.frame = r } }
        CATransaction.commit()
    }

    func charger(_ tuiles: [Tuile], courante: String?, espaces: [Espace]) {
        zoom?.removeFromSuperlayer()
        zoom = nil
        vedette = nil
        cases.forEach { $0.removeFromSuperview() }
        cases = tuiles.enumerated().map { i, t in
            let c = Case(tuile: t, numero: i + 1)
            c.courant = t.cle == courante
            c.auFermer = { [weak self] in self?.auFermer?(t) }
            c.montrer(Images.commun.image(pour: t, espaces: espaces))
            addSubview(c)
            return c
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        majSurvol()
    }

    func rafraichir(espaces: [Espace]) {
        for c in cases { c.montrer(Images.commun.image(pour: c.tuile, espaces: espaces)) }
    }

    override func layout() {
        super.layout()
        // Le Dock couvre toute la grille (il laisse passer les clics hors de sa pastille) ; les cases occupent la place
        // qui reste, du côté opposé au sien.
        dock.frame = bounds
        let reserve = dock.reserve
        var zone = bounds
        switch DockGrille.cote {
        case "haut": zone.size.height -= reserve
        case "gauche": zone.origin.x += reserve; zone.size.width -= reserve
        case "droite": zone.size.width -= reserve
        default: zone.origin.y += reserve; zone.size.height -= reserve
        }
        // Une vraie grille, aérée : chaque fenêtre a sa case fixe, une case sans fenêtre reste vide.
        guard !cases.isEmpty else { return }
        let positions = cases.map { Grille.position($0.tuile.place) }
        let colonnes = (positions.map { $0.colonne }.max() ?? 0) + 1
        let lignes = (positions.map { $0.ligne }.max() ?? 0) + 1
        let margeX = bounds.width * 0.045, margeY = bounds.height * 0.04
        let ecartX = bounds.width * 0.035, ecartY = bounds.height * 0.04
        let pied: CGFloat = 26                               // la place de l'icône qui dépasse sous la vignette
        let largeurMax = (zone.width - 2 * margeX - CGFloat(colonnes - 1) * ecartX) / CGFloat(colonnes)
        let hauteurMax = (zone.height - 2 * margeY - CGFloat(lignes - 1) * ecartY) / CGFloat(lignes) - pied
        // Des cases aux proportions de l'écran, aussi grandes que possible, et la grille entière centrée.
        let format = bounds.width / max(bounds.height, 1)
        let largeur = min(largeurMax, hauteurMax * format), hauteur = largeur / format + pied
        let totalL = CGFloat(colonnes) * largeur + CGFloat(colonnes - 1) * ecartX
        let totalH = CGFloat(lignes) * hauteur + CGFloat(lignes - 1) * ecartY
        let x0 = zone.midX - totalL / 2, sommet = zone.midY + totalH / 2
        func cadre(_ p: (colonne: Int, ligne: Int)) -> NSRect {
            NSRect(x: x0 + CGFloat(p.colonne) * (largeur + ecartX),
                   y: sommet - CGFloat(p.ligne + 1) * hauteur - CGFloat(p.ligne) * ecartY, width: largeur, height: hauteur)
        }
        for (c, p) in zip(cases, positions) { if animeDisposition { c.animator().frame = cadre(p) } else { c.frame = cadre(p) } }
        // Les cases vides de la grille : on peut y déposer une fenêtre.
        let prises = Set(cases.map { $0.tuile.place })
        videsActuelles = (0..<24).filter { !prises.contains($0) }.compactMap { k in
            let p = Grille.position(k)
            guard p.colonne < colonnes, p.ligne < lignes else { return nil }
            return (k, cadre(p).insetBy(dx: 0, dy: pied / 2).offsetBy(dx: 0, dy: pied / 2))
        }
    }

    /// Où se trouve la case numéro k. Les quatre premières forment un carré (deux en haut, deux en bas) ; les suivantes
    /// ajoutent des colonnes à droite (haut puis bas), sans jamais déplacer les précédentes ; au-delà de huit, une troisième ligne.
    static func position(_ k: Int) -> (colonne: Int, ligne: Int) {
        if k < 4 { return (k % 2, k / 2) }
        if k < 8 { return (k / 2, k % 2) }
        if k < 12 { return (k - 8, 2) }
        return (4 + (k - 12) / 3, (k - 12) % 3)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let zone { removeTrackingArea(zone) }
        let z = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(z)
        zone = z
    }

    func majSurvol() {
        guard let w = window else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        // La souris reprend la main sur la molette, mais seulement si elle a vraiment bougé : tourner la molette la fait
        // toujours trembler d'un ou deux points, ce qui ramenait la mise en avant sous le pointeur.
        if vedette != nil {
            let ici = NSEvent.mouseLocation
            if hypot(ici.x - sourisVedette.x, ici.y - sourisVedette.y) < 18 { return }
            vedette = nil
        }
        for c in cases { let s = c.frame.contains(p); if c.survol != s { c.survol = s } }
        // Au-dessus d'une séparation entre deux fenêtres d'un groupe, le pointeur montre qu'on peut la tirer.
        var curseur = NSCursor.arrow
        if let c = cases.first(where: { $0.frame.contains(p) }), case .groupe(let fs, _) = c.tuile.cible {
            let v = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY), tout = Tuile.englobant(fs)
            if v.contains(p), let (_, _, horizontal) = Grille.separation(fs, x: tout.minX + (p.x - v.minX) / max(v.width, 1) * tout.width,
                                                  y: tout.minY + (1 - (p.y - v.minY) / max(v.height, 1)) * tout.height,
                                                  marge: 9 / max(v.width, 1) * tout.width) {
                curseur = horizontal ? .resizeLeftRight : .resizeUpDown
            }
        }
        curseur.set()
    }

    override func mouseMoved(with event: NSEvent) { majSurvol() }
    override func mouseEntered(with event: NSEvent) { majSurvol() }
    override func mouseExited(with event: NSEvent) { majSurvol() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Deux doigts vers le haut sur une case : on ferme l'application, comme sur iPhone

    private var balayee: Case?
    private var montee: CGFloat = 0
    private var baseBalayee = CGRect.zero

    // MARK: La molette de la souris parcourt les cases, en boucle

    /// La case mise en avant par la molette (nil : aucune). Un clic, Entrée ou le clic de la molette la choisit.
    private(set) var vedette: Case?
    private var cumulMolette: CGFloat = 0
    private var dernierCran: TimeInterval = 0
    private var sourisVedette = CGPoint.zero

    /// Avance la mise en avant d'une case, dans un sens ou dans l'autre. Après la dernière, on revient à la première.
    private func avancerVedette(_ d: Int) {
        guard !cases.isEmpty else { return }
        let depart = vedette ?? cases.first(where: { $0.survol }) ?? cases.first(where: { $0.courant })
        var i = depart.flatMap { c in cases.firstIndex { $0 === c } } ?? (d > 0 ? -1 : 0)
        i = ((i + d) % cases.count + cases.count) % cases.count
        vedette = cases[i]
        sourisVedette = NSEvent.mouseLocation
        for c in cases { let s = c === vedette; if c.survol != s { c.survol = s } }
    }

    /// Choisit la case mise en avant par la molette, s'il y en a une.
    @discardableResult
    func choisirVedette() -> Bool {
        guard let c = vedette, zoom == nil else { return false }
        vedette = nil
        auChoix?(c)
        return true
    }

    override func otherMouseUp(with event: NSEvent) { choisirVedette() }      // clic de la molette

    override func scrollWheel(with event: NSEvent) {
        guard zoom == nil, volante == nil else { return }
        // Une molette de souris n'a pas de « phase », contrairement au trackpad : elle fait défiler la mise en avant.
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return }
            // La molette envoie beaucoup de petits mouvements, surtout lancée : on les cumule, et on n'avance que d'une case
            // à la fois, pas plus de sept fois par seconde.
            cumulMolette += event.hasPreciseScrollingDeltas ? dy : dy * 10
            let seuil: CGFloat = 70
            guard abs(cumulMolette) >= seuil else { return }
            let maintenant = ProcessInfo.processInfo.systemUptime
            if maintenant - dernierCran >= 0.14 {
                avancerVedette(cumulMolette < 0 ? 1 : -1)
                dernierCran = maintenant
                // Une ligne par cran dans le journal, pour régler la molette sur de vrais mouvements.
                journal("Square: molette dans la grille — cran %@ (cumul %.0f, %@)", cumulMolette < 0 ? "suivant" : "précédent",
                        Double(cumulMolette), event.hasPreciseScrollingDeltas ? "fin" : "par lignes")
            }
            cumulMolette = 0
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if event.phase == .began {
            balayee = cases.first { $0.frame.contains(p) }
            baseBalayee = balayee?.frame ?? .zero
            montee = 0
        }
        guard let c = balayee else { return }
        if event.phase == .changed {
            // Avec le défilement « naturel », des doigts qui montent donnent un déplacement négatif.
            montee += event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            let h = max(0, montee)
            c.frame = baseBalayee.offsetBy(dx: 0, dy: h)
            c.alphaValue = max(0.25, 1 - h / 320)
        } else if event.phase == .ended || event.phase == .cancelled {
            balayee = nil
            let partie = montee > 110 && event.phase == .ended
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                c.animator().frame = partie ? baseBalayee.offsetBy(dx: 0, dy: bounds.height) : baseBalayee
                c.animator().alphaValue = partie ? 0 : 1
            }) { [weak self] in if partie { self?.auFermer?(c.tuile) } }
        }
    }

    /// Clic droit sur une case : quitter l'application.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let c = cases.first(where: { $0.frame.contains(p) }) else { return }
        clicDroitSur = c.tuile
        let menu = NSMenu()
        let item = menu.addItem(withTitle: String(localized: "Quitter \(c.tuile.titre.components(separatedBy: " — ").first ?? String(localized: "l'application"))"),
                                action: #selector(quitterLaCase), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    private var clicDroitSur: Tuile?
    @objc private func quitterLaCase() { if let t = clicDroitSur { clicDroitSur = nil; auFermer?(t) } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        prise = cases.first { $0.frame.contains(p) }
        priseEn = p
        source = prise?.tuile
        origineVolante = prise.map { $0.cadreVignette.offsetBy(dx: $0.frame.minX, dy: $0.frame.minY) } ?? .zero
        imageVolante = prise?.imageActuelle
        reglage = nil
        // Dans une case de groupe : sur la séparation entre deux fenêtres, on les redimensionne ; sur une fenêtre, on l'attrape
        // pour la sortir du groupe. (Pour déplacer la case entière, on l'attrape par une icône, en bas.)
        if let c = prise, case .groupe(let fs, let e) = c.tuile.cible, origineVolante.contains(p) {
            let v = origineVolante, ecran = Tuile.englobant(fs)
            let sx = ecran.minX + (p.x - v.minX) / max(v.width, 1) * ecran.width
            let sy = ecran.minY + (1 - (p.y - v.minY) / max(v.height, 1)) * ecran.height
            if let (a, b, horizontal) = Grille.separation(fs, x: sx, y: sy, marge: 9 / max(v.width, 1) * ecran.width) {
                reglage = (c, a, b, horizontal)
                return
            }
            guard p.y > origineVolante.minY + 34 else { return }
            if let f = fs.first(where: { $0.cadre.contains(CGPoint(x: sx, y: sy)) }) {
                var t = Tuile(cle: "f\(f.wid)", titre: f.app, icone: c.tuile.icone, cible: .fenetre(f, e), pid: f.pid)
                t.place = c.tuile.place
                source = t
                sortDUnGroupe = true
                imageVolante = Images.commun.image(pour: t, espaces: [])
                origineVolante = CGRect(x: v.minX + (f.cadre.minX - ecran.minX) / ecran.width * v.width,
                                        y: v.maxY - (f.cadre.maxY - ecran.minY) / ecran.height * v.height,
                                        width: f.cadre.width / ecran.width * v.width, height: f.cadre.height / ecran.height * v.height)
            }
        }
    }

    /// La séparation entre deux fenêtres d'un groupe qui se trouve sous ce point de l'écran, s'il y en a une.
    /// horizontal : les fenêtres sont côte à côte (on tire la séparation vers la gauche ou la droite).
    static func separation(_ fs: [Fenetre], x: CGFloat, y: CGFloat, marge: CGFloat) -> (Fenetre, Fenetre, Bool)? {
        for a in fs {
            for b in fs where b.wid != a.wid {
                let ca = a.cadre, cb = b.cadre
                if abs(ca.maxX - cb.minX) < 14, abs(x - ca.maxX) <= marge, y > max(ca.minY, cb.minY), y < min(ca.maxY, cb.maxY) { return (a, b, true) }
                if abs(ca.maxY - cb.minY) < 14, abs(y - ca.maxY) <= marge, x > max(ca.minX, cb.minX), x < min(ca.maxX, cb.maxX) { return (a, b, false) }
            }
        }
        return nil
    }

    /// On tire la séparation : les deux fenêtres voisines changent de taille dans la case, en direct.
    private func regler(_ r: (c: Case, a: Fenetre, b: Fenetre, horizontal: Bool), _ p: CGPoint) {
        guard case .groupe(let fs, let e) = r.c.tuile.cible else { return }
        let v = r.c.cadreVignette.offsetBy(dx: r.c.frame.minX, dy: r.c.frame.minY), tout = Tuile.englobant(fs)
        let mini: CGFloat = 260
        var ca = r.a.cadre, cb = r.b.cadre
        if r.horizontal {
            let limite = min(max(ca.maxX + (p.x - priseEn.x) / max(v.width, 1) * tout.width, ca.minX + mini), cb.maxX - mini)
            ca.size.width = limite - ca.minX
            cb.size.width = cb.maxX - limite; cb.origin.x = limite
        } else {
            let limite = min(max(ca.maxY - (p.y - priseEn.y) / max(v.height, 1) * tout.height, ca.minY + mini), cb.maxY - mini)
            ca.size.height = limite - ca.minY
            cb.size.height = cb.maxY - limite; cb.origin.y = limite
        }
        let nouvelles = fs.map { f -> Fenetre in
            let c = f.wid == r.a.wid ? ca : (f.wid == r.b.wid ? cb : f.cadre)
            return Fenetre(wid: f.wid, pid: f.pid, app: f.app, titre: f.titre, cadre: c, agrandie: false, masquee: f.masquee)
        }
        var t = Tuile(cle: r.c.tuile.cle, titre: r.c.tuile.titre, icone: r.c.tuile.icone, cible: .groupe(nouvelles, e), pid: r.c.tuile.pid)
        t.place = r.c.tuile.place
        r.c.tuile = t
        r.c.montrer(Images.commun.image(pour: t, espaces: []))
    }

    /// La case transportée prend la place d'une autre ; celles qui se trouvent entre les deux glissent d'un cran.
    private func inserer(_ c: Case, aLaPlaceDe cible: Case) {
        var ordre = cases.sorted { $0.tuile.place < $1.tuile.place }
        let places = ordre.map { $0.tuile.place }                  // les mêmes cases de la grille, redistribuées
        guard let de = ordre.firstIndex(where: { $0 === c }), let vers = ordre.firstIndex(where: { $0 === cible }) else { return }
        ordre.remove(at: de)
        ordre.insert(c, at: vers)
        for (x, place) in zip(ordre, places) { x.tuile.place = place }
        ordreChange = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            animeDisposition = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            animeDisposition = false
        }
    }
    private var ordreChange = false

    /// On tire une case : sa vignette suit la souris. Au-dessus d'une autre case, un repère orange montre ce qui se passera
    /// si on lâche : toute la vignette (échange des places) ou une moitié (partage de l'écran de ce côté).
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = reglage { regler(r, p); return }
        guard zoom == nil, let c = prise, let source, let fond = layer else { return }
        let origine = origineVolante
        if volante == nil {
            guard hypot(p.x - priseEn.x, p.y - priseEn.y) > 8 else { return }
            let l = CALayer()
            l.contents = imageVolante
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.cornerRadius = 10
            l.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            l.opacity = 0.92
            l.zPosition = 90
            l.frame = origine
            fond.addSublayer(l)
            volante = l
            repere.backgroundColor = orange.withAlphaComponent(0.4).cgColor
            repere.borderColor = orange.cgColor
            repere.borderWidth = 3
            repere.cornerRadius = 10
            repere.zPosition = 80
            repere.isHidden = true
            fond.addSublayer(repere)
            c.alphaValue = sortDUnGroupe ? 0.6 : 0.25
            // On emporte une des deux fenêtres d'un groupe : celle qui reste s'étend tout de suite dans sa case.
            if sortDUnGroupe, case .groupe(let fs, _) = c.tuile.cible, fs.count == 2, case .fenetre(let pris, _) = source.cible,
               let autre = fs.first(where: { $0.wid != pris.wid }) {
                let v = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY), tout = Tuile.englobant(fs)
                let r = CALayer()
                r.contents = Images.commun.enCache(autre.wid)
                r.contentsGravity = .resizeAspectFill
                r.masksToBounds = true
                r.cornerRadius = 10
                r.zPosition = 60
                r.frame = CGRect(x: v.minX + (autre.cadre.minX - tout.minX) / tout.width * v.width,
                                 y: v.maxY - (autre.cadre.maxY - tout.minY) / tout.height * v.height,
                                 width: autre.cadre.width / tout.width * v.width, height: autre.cadre.height / tout.height * v.height)
                fond.addSublayer(r)
                restante = r
                restanteWid = autre.wid
                c.alphaValue = 0
                CATransaction.flush()
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.28)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1))
                r.frame = v
                CATransaction.commit()
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Un peu plus petite pendant le transport, pour bien voir ce qu'il y a dessous.
        let l = origine.width * 0.7, h = origine.height * 0.7
        volante?.frame = CGRect(x: p.x - l / 2, y: p.y - h / 2, width: l, height: h)
        depot = nil
        repere.isHidden = true
        if let cible = cases.first(where: { $0 !== c && $0.frame.contains(p) }) {
            let v = cible.cadreVignette.offsetBy(dx: cible.frame.minX, dy: cible.frame.minY)
            let rx = (p.x - v.minX) / max(v.width, 1), ry = (p.y - v.minY) / max(v.height, 1)
            var zone = v
            // La fenêtre visée : celle de la case, ou, dans une case de groupe, celle qui se trouve sous la souris.
            var visee: Fenetre?, cadreVisee = v
            var rxv = rx, ryv = ry
            if case .fenetre = source.cible {
                switch cible.tuile.cible {
                case .fenetre(let f, _): visee = f
                case .groupe(let fs, _):
                    let ecran = Tuile.englobant(fs)
                    let sx = ecran.minX + rx * ecran.width, sy = ecran.minY + (1 - ry) * ecran.height
                    if let f = fs.first(where: { $0.cadre.contains(CGPoint(x: sx, y: sy)) }) {
                        visee = f
                        rxv = (sx - f.cadre.minX) / max(f.cadre.width, 1)
                        ryv = 1 - (sy - f.cadre.minY) / max(f.cadre.height, 1)
                        cadreVisee = CGRect(x: v.minX + (f.cadre.minX - ecran.minX) / ecran.width * v.width,
                                            y: v.maxY - (f.cadre.maxY - ecran.minY) / ecran.height * v.height,
                                            width: f.cadre.width / ecran.width * v.width, height: f.cadre.height / ecran.height * v.height)
                    }
                case .espace: break
                }
            }
            if let f = visee, rxv < 0.27 || rxv > 0.73 || ryv < 0.27 || ryv > 0.73 {
                zone = cadreVisee
                if rxv < 0.27 { zone.size.width /= 2; depot = .partager(f, .gauche) }
                else if rxv > 0.73 { zone.origin.x = cadreVisee.midX; zone.size.width /= 2; depot = .partager(f, .droite) }
                else if ryv > 0.73 { zone.origin.y = cadreVisee.midY; zone.size.height /= 2; depot = .partager(f, .haut) }
                else { zone.size.height /= 2; depot = .partager(f, .bas) }
            } else if sortDUnGroupe { depot = .separer(nil); zone = .zero }
            else {
                // Au milieu d'une autre case : comme sur iPhone, la case transportée prend cette place tout de suite
                // et les autres se poussent pour lui faire de la place.
                CATransaction.commit()
                inserer(c, aLaPlaceDe: cible)
                return
            }
            repere.frame = zone
            repere.isHidden = false
        } else if let vide = videsActuelles.first(where: { $0.cadre.contains(p) }) {
            depot = sortDUnGroupe ? .separer(vide.place) : .place(vide.place)
            repere.frame = vide.cadre
            repere.isHidden = false
        } else if sortDUnGroupe, !c.frame.contains(p) {
            depot = .separer(nil)          // lâchée n'importe où hors de sa case : elle quitte le groupe
        }
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard zoom == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let r = reglage {
            // Fin d'un redimensionnement : les vraies fenêtres prennent les tailles choisies.
            reglage = nil; prise = nil; source = nil
            if case .groupe(let fs, _) = r.c.tuile.cible {
                auDepot?(r.c.tuile, .redimensionner(Dictionary(uniqueKeysWithValues: fs.map { ($0.wid, $0.cadre) })))
            }
            return
        }
        if let c = prise, volante != nil {
            // Fin d'un glisser-déposer. On retient d'où part la fenêtre lâchée, pour que la transition parte de la souris.
            if let v = volante, let source, depot != nil {
                switch source.cible {
                case .fenetre(let f, _): lachers = [f.wid: v.frame]
                default: lachers = [:]
                }
                // La fenêtre restée dans la case s'est déjà étendue : la transition repart de là.
                if let r = restante { lachers[restanteWid] = r.frame }
            }
            restante?.removeFromSuperlayer(); restante = nil
            repere.removeFromSuperlayer()
            prise = nil
            let transportee = source ?? c.tuile
            source = nil; sortDUnGroupe = false
            let reordonne = ordreChange
            ordreChange = false
            if let d = depot {
                volante?.removeFromSuperlayer(); volante = nil
                c.alphaValue = 1
                depot = nil
                auDepot?(transportee, d)
            } else if let v = volante {
                // Lâchée sans autre effet : la vignette rejoint sa case en douceur (sa nouvelle case, si l'ordre a changé).
                volante = nil
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1))
                CATransaction.setCompletionBlock { [weak self] in
                    v.removeFromSuperlayer()
                    c.alphaValue = 1
                    guard let self, reordonne else { return }
                    self.auDepot?(transportee, .ordre(Dictionary(uniqueKeysWithValues: self.cases.map { ($0.tuile.cle, $0.tuile.place) })))
                }
                v.frame = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY)
                v.opacity = 1
                CATransaction.commit()
            }
            return
        }
        prise = nil
        source = nil; sortDUnGroupe = false
        // Une case mise en avant par la molette : un clic, où qu'il soit, la choisit.
        if choisirVedette() { return }
        if let c = cases.first(where: { $0.frame.contains(p) }) { auChoix?(c) }
        else { auFond?() }
    }

    /// L'image de la case grandit jusqu'à remplir l'écran.
    func zoomer(_ c: Case, fin: @escaping () -> Void) {
        guard let img = c.imageActuelle, let fond = layer else { fin(); return }
        let l = CALayer()
        l.contents = img
        l.contentsGravity = .resizeAspectFill
        l.masksToBounds = true
        l.cornerRadius = 12
        l.frame = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY)
        l.zPosition = 100
        fond.addSublayer(l)
        zoom = l
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(fin)
        // Elle rejoint la place exacte de la fenêtre (sous la barre des menus), pour qu'il n'y ait aucun saut à l'arrivée.
        let arrivee = cadreReel(c)
        l.frame = arrivee
        l.cornerRadius = 0
        CATransaction.commit()
    }
}

extension Grille {
    /// La place de la fenêtre à l'écran, dans les coordonnées de la grille. Sans fenêtre connue : tout l'écran.
    func cadreReel(_ c: Case) -> CGRect {
        guard let r = c.tuile.cadre else { return bounds }
        let ecran = Ecrans.cadreGlobal(window?.screen)
        return CGRect(x: r.minX - ecran.minX, y: bounds.height - (r.minY - ecran.minY) - r.height, width: r.width, height: r.height)
    }

    /// Apparition de la grille : la fenêtre où vous êtes rétrécit jusqu'à sa case, les autres arrivent en fondu en grossissant un peu.
    func preparerApparition() { for c in cases { c.alphaValue = 0 } }

    func apparaitre() {
        guard let fond = layer else { cases.forEach { $0.alphaValue = 1 }; return }
        let duree = 0.3, courbe = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        var volants: [(CALayer, Case)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in cases {
            let vignette = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY)
            guard let img = c.imageActuelle else { continue }
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.zPosition = c.courant ? 60 : 50
            if c.courant {
                l.frame = cadreReel(c)
                l.cornerRadius = 0
            } else {
                l.frame = vignette.insetBy(dx: vignette.width * 0.06, dy: vignette.height * 0.06)
                l.cornerRadius = 10
                l.opacity = 0
            }
            fond.addSublayer(l)
            volants.append((l, c))
        }
        CATransaction.commit()
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duree)
        CATransaction.setAnimationTimingFunction(courbe)
        CATransaction.setCompletionBlock { [weak self] in
            // Les vraies cases prennent le relais (avec leur icône, leur chiffre et leur ombre).
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self?.cases.forEach { $0.animator().alphaValue = 1 }
            } completionHandler: { volants.forEach { $0.0.removeFromSuperlayer() } }
        }
        for (l, c) in volants {
            l.frame = c.cadreVignette.offsetBy(dx: c.frame.minX, dy: c.frame.minY)
            l.cornerRadius = 10
            l.opacity = 1
        }
        CATransaction.commit()
        // Une case sans photo n'a pas de calque volant : elle apparaît simplement en fondu.
        let avecCalque = Set(volants.map { ObjectIdentifier($0.1) })
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duree
            for c in cases where !avecCalque.contains(ObjectIdentifier(c)) { c.animator().alphaValue = 1 }
        }
    }
}

final class Panneau: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Application

final class Appli: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var barre: NSStatusItem!
    private var panneau: Panneau?
    private let grille = Grille()
    private var espaces: [Espace] = []
    private var tuiles: [Tuile] = []
    private var ouverteÀ = Date.distantPast
    private var pidDevant: pid_t = 0         // application devant en ce moment
    private var pidAvant: pid_t = 0          // celle d'avant
    private var fenetreRaccourci: NSWindow?
    private var ecoute: Any?

    private let idGrille: UInt32 = 1
    private let idAgrandir: UInt32 = 2
    private let chiffres: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    private let pavé: [Int] = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                               kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]

    func applicationDidFinishLaunching(_ note: Notification) {
        barre = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        barre.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Square")
        let menu = NSMenu()
        menu.delegate = self
        barre.menu = menu

        grille.auChoix = { [weak self] c in self?.choisir(c.tuile, depuis: c) }
        grille.auFond = { [weak self] in self?.fermerGrilleEnRevenant() }
        grille.auFermer = { [weak self] t in self?.fermer(t) }
        grille.auDepot = { [weak self] t, d in self?.deposer(t, d) }
        grille.dock.auLancement = { [weak self] chemin in self?.lancerDepuisLeDock(chemin) }
        grille.dock.auBoutonApps = { [weak self] in self?.basculerLanceur() }
        grille.dock.auCorbeille = { [weak self] in
            self?.fermerGrille()
            // Avec Side (dans une version qui accepte les commandes), la corbeille s'ouvre dans sa carte. Sinon, dans le Finder.
            let side = "com.gauthieraube.side"
            let accepte = (CFPreferencesCopyAppValue("commandesExterieures" as CFString, side as CFString) as? Bool) == true
            if accepte, !NSRunningApplication.runningApplications(withBundleIdentifier: side).isEmpty {
                DistributedNotificationCenter.default().postNotificationName(.init(side + ".commande"), object: "corbeille",
                                                                             userInfo: nil, deliverImmediately: true)
            } else if let corbeille = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(corbeille)
            }
        }
        grille.dock.auQuitter = { [weak self] chemin in self?.quitterDepuisLeDock(chemin) }
        Lanceur.commun.auChoix = { [weak self] chemin in self?.lancerDepuisLeDock(chemin) }
        Lanceur.commun.auDock = { [weak self] in self?.grille.dock.charger(); self?.grille.needsLayout = true }
        Lanceur.commun.aLaFermeture = { [weak self] in
            self?.lanceurFermeA = Date()
            // Les chiffres et Échap de la grille reprennent du service.
            if let e = self?.ecouteLanceur { NSEvent.removeMonitor(e) }
            self?.ecouteLanceur = nil
            if self?.panneau?.isVisible == true { self?.brancherTouchesGrille() }
        }

        brancherRaccourci()
        AgrandirAuto.demarrer()
        BoutonVert.demarrer()
        Glisse.demarrer()
        Coin.demarrer()
        brancherRaccourcisDirects()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(ouvrirReglages),
                                                            name: .init("com.gauthieraube.square.reglages"), object: nil)
        // Commandes venues d'une autre application (Mulot, pour les boutons de la souris).
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(commandeExterieure(_:)),
                                                            name: .init("com.gauthieraube.square.commande"), object: nil)
        Touches.ajouter(idAgrandir, touche: UInt32(kVK_Return), modifs: UInt32(controlKey | optionKey)) { Agrandir.fenetreActive() }

        pidDevant = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(self, selector: #selector(espaceChangé), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        centre.addObserver(self, selector: #selector(appActivée(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Première ouverture : la présentation de Square.
        if !Accueil.vu { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Accueil.montrer() } }
        // Autorisations demandées une fois : Accessibilité (pour déplacer les fenêtres) et Enregistrement de l'écran (pour les images).
        let cle = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([cle: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        // Première série de photos dès le lancement : la grille aura ses images à la première ouverture.
        Images.commun.capturer(Relevé.tout().espaces) {}
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func ajouter(_ titre: String, _ action: Selector, à m: NSMenu = menu) -> NSMenuItem {
            let i = m.addItem(withTitle: titre, action: action, keyEquivalent: "")
            i.target = self
            return i
        }
        // Le menu ne garde que les actions ; tous les réglages sont dans la fenêtre « Réglages… ».
        _ = ajouter(String(localized: "Afficher la grille  (\(Raccourci.actuel.nom))"), #selector(basculerGrille))
        _ = ajouter(String(localized: "Agrandir la fenêtre en cours  (⌃⌥ Entrée)"), #selector(agrandirActive))
        menu.addItem(.separator())
        let reglages = ajouter(String(localized: "Réglages…"), #selector(ouvrirReglages))
        reglages.keyEquivalent = ","
        if !AXIsProcessTrusted() || !Images.autorisé {
            menu.addItem(.separator())
            if !AXIsProcessTrusted() { _ = ajouter(String(localized: "Autoriser « Accessibilité »…"), #selector(ouvrirAccessibilité)) }
            if !Images.autorisé { _ = ajouter(String(localized: "Autoriser « Enregistrement de l'écran »…"), #selector(ouvrirCapture)) }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quitter Square"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func agrandirActive() {
        // Le menu vient de se fermer : on laisse l'application d'avant reprendre la main.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Agrandir.fenetreActive() }
    }




    @objc private func ouvrirReglages() {
        fermerGrille()          // la grille flotte au-dessus de tout : la fenêtre de réglages resterait cachée derrière
        Reglages.ouvrir()
    }

    // MARK: Raccourcis directs : une touche et un chiffre pour aller droit à la fenêtre de ce numéro

    /// La touche à tenir avec le chiffre : "cmd", "opt", "ctrl", ou "aucun" pour ne pas avoir ces raccourcis.
    static var toucheDirecte: String {
        get { UserDefaults.standard.string(forKey: "raccourcisDirects") ?? "cmd" }
        set { UserDefaults.standard.set(newValue, forKey: "raccourcisDirects") }
    }

    /// (Ré)enregistre les neuf raccourcis, d'après le réglage.
    func brancherRaccourcisDirects() {
        for i in 0..<9 { Touches.retirer(UInt32(200 + i)) }
        let modifs: Int
        switch Appli.toucheDirecte {
        case "cmd": modifs = cmdKey
        case "opt": modifs = optionKey
        case "ctrl": modifs = controlKey
        default: return
        }
        for i in 0..<9 {
            Touches.ajouter(UInt32(200 + i), touche: UInt32(chiffres[i]), modifs: UInt32(modifs)) { [weak self] in self?.allerALaFenetre(i) }
        }
    }

    /// Va droit à la fenêtre numéro n + 1, dans l'ordre des cases de la grille.
    private func allerALaFenetre(_ n: Int) {
        if panneau?.isVisible == true {
            if grille.cases.indices.contains(n) { choisir(grille.cases[n].tuile, depuis: grille.cases[n]) }
            return
        }
        let (tous, courants) = Relevé.tout()
        let apps = construire(tous).filter { if case .espace(let e) = $0.cible { return e.pleinEcran }; return true }
        guard apps.indices.contains(n) else { NSSound.beep(); return }
        let ecran = Ecrans.identifiant(ecranSousLaSouris())
        guard apps[n].cle != cléCourante(tous, courants, ecran: ecran) else { return }     // on y est déjà
        journal("Square: raccourci %d → %@", n + 1, apps[n].titre.components(separatedBy: " — ").first ?? "")
        espaces = tous
        Bascule.aller(apps[n], espaces: tous)
    }

    /// Une autre application demande une action de Square : « grille », « suivante », « precedente » ou « agrandir ».
    @objc private func commandeExterieure(_ note: Notification) {
        guard let commande = note.object as? String else { return }
        if !commande.hasPrefix("carrousel:suivre") { journal("Square: commande reçue — %@", commande) }   // pas 60 lignes par seconde
        switch commande {
        case "grille": basculerGrille()
        case "suivante": voisine(1)
        case "precedente": voisine(-1)
        case "agrandir": Agrandir.fenetreActive()
        default:
            // Le carrousel mené de l'extérieur (bouton de pouce de la souris tenu pendant qu'on la déplace, ou molette du pouce) :
            // « carrousel:debut », « carrousel:suivre:<position> », « carrousel:fin:<position> », « carrousel:cran:<±1> ».
            let morceaux = commande.split(separator: ":").map(String.init)
            guard morceaux.first == "carrousel", morceaux.count >= 2 else { return }
            let valeur = morceaux.count > 2 ? CGFloat(Double(morceaux[2]) ?? 0) : 0
            switch morceaux[1] {
            case "debut": carrouselDebut()
            case "suivre": carrouselSuivre(valeur)
            case "fin": carrouselFin(valeur)
            case "cran": carrouselParCrans(valeur > 0 ? 1 : -1)
            default: break
            }
        }
    }

    private var carrouselCrans = 0
    private var carrouselAttente: Timer?

    /// La molette du pouce : chaque cran avance le carrousel d'une fenêtre ; quand la molette s'arrête un instant,
    /// la fenêtre du centre passe devant. On voit ainsi où l'on va, au lieu de changer de fenêtre à chaque cran.
    private func carrouselParCrans(_ d: Int) {
        if carrouselApps.isEmpty {
            carrouselDebut()
            carrouselCrans = 0
            guard !carrouselApps.isEmpty else { return }
        }
        carrouselCrans = min(max(carrouselCrans + d, -carrouselDepart), carrouselApps.count - 1 - carrouselDepart)
        Carrousel.commun.placer(CGFloat(carrouselDepart + carrouselCrans), anime: true)
        carrouselAttente?.invalidate()
        carrouselAttente = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.carrouselFin(CGFloat(self.carrouselCrans))
            self.carrouselCrans = 0
        }
    }

    /// Pour la fenêtre de réglages : changer le raccourci, et montrer ou cacher l'aperçu du carrousel.
    func reglerLeRaccourci() { changerRaccourci() }
    func apercuDuCarrousel(_ visible: Bool) {
        if visible { apercuCarrousel(anime: !Carrousel.commun.visible) } else { Carrousel.commun.masquer() }
    }



    /// La souris est arrivée dans le coin choisi : la grille s'affiche (si elle l'est déjà, rien ne change).
    func grilleParLeCoin() {
        // Grille déjà affichée : un second passage dans le coin la referme, et vous retrouvez l'application où vous étiez.
        if panneau?.isVisible == true { journal("Square: grille refermée par le coin"); fermerGrilleEnRevenant(); return }
        journal("Square: grille ouverte par le coin")
        ouvrirGrille()
    }

    @objc private func resserrerGrille() {
        UserDefaults.standard.removeObject(forKey: "placesCases")
        UserDefaults.standard.removeObject(forKey: "placesApps")
    }

    // MARK: Carrousel (glissement à quatre doigts)

    private var fenetreCarrousel: NSWindow?

    /// Réglage de la taille des cartes : une petite fenêtre en bas de l'écran, et le carrousel lui-même en aperçu au centre.
    @objc private func reglerCarrousel() {
        if let w = fenetreCarrousel { w.makeKeyAndOrderFront(nil); return }
        guard let ecran = ecranSousLaSouris() else { return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 176), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        w.title = String(localized: "Carrousel à quatre doigts")
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)     // au-dessus de l'aperçu
        w.hidesOnDeactivate = false
        let petit = NSTextField(labelWithString: String(localized: "Petit")), grand = NSTextField(labelWithString: String(localized: "Grand"))
        petit.frame = NSRect(x: 20, y: 122, width: 44, height: 18)
        grand.frame = NSRect(x: 362, y: 122, width: 44, height: 18)
        let curseur = NSSlider(value: Double(Carrousel.taille), minValue: Double(Carrousel.tailles.lowerBound),
                               maxValue: Double(Carrousel.tailles.upperBound), target: self, action: #selector(tailleCarrouselChangée(_:)))
        curseur.isContinuous = true
        curseur.frame = NSRect(x: 66, y: 118, width: 290, height: 26)
        let titreTaille = NSTextField(labelWithString: String(localized: "Taille des cartes"))
        titreTaille.font = .systemFont(ofSize: 12, weight: .semibold)
        titreTaille.frame = NSRect(x: 20, y: 146, width: 380, height: 18)
        // Le délai avant d'afficher le carrousel quand le geste part vite.
        let titreDelai = NSTextField(labelWithString: String(localized: "Après un geste vif, le carrousel apparaît…"))
        titreDelai.font = .systemFont(ofSize: 12, weight: .semibold)
        titreDelai.frame = NSRect(x: 20, y: 80, width: 380, height: 18)
        let tot = NSTextField(labelWithString: String(localized: "Vite")), tard = NSTextField(labelWithString: String(localized: "Tard"))
        tot.frame = NSRect(x: 20, y: 56, width: 44, height: 18)
        tard.frame = NSRect(x: 362, y: 56, width: 44, height: 18)
        let delai = NSSlider(value: Glisse.attente, minValue: 0.04, maxValue: 0.35, target: self, action: #selector(delaiCarrouselChangé(_:)))
        delai.isContinuous = true
        delai.frame = NSRect(x: 66, y: 52, width: 290, height: 26)
        let aide = NSTextField(wrappingLabelWithString: String(localized: "Vers « Vite » : il apparaît plus tôt, mais un simple effleurement risque de l'afficher. Vers « Tard » : l'inverse."))
        aide.font = .systemFont(ofSize: 11)
        aide.textColor = .secondaryLabelColor
        aide.frame = NSRect(x: 20, y: 12, width: 384, height: 32)
        for v in [titreTaille, petit, curseur, grand, titreDelai, tot, delai, tard, aide] as [NSView] { w.contentView?.addSubview(v) }
        let v = ecran.visibleFrame
        w.setFrameOrigin(NSPoint(x: v.midX - 210, y: v.minY + 40))
        fenetreCarrousel = w
        NotificationCenter.default.addObserver(self, selector: #selector(fenetreCarrouselFermée), name: NSWindow.willCloseNotification, object: w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        apercuCarrousel(anime: true)
    }

    @objc private func delaiCarrouselChangé(_ curseur: NSSlider) { Glisse.attente = (curseur.doubleValue * 100).rounded() / 100 }

    @objc private func tailleCarrouselChangée(_ curseur: NSSlider) {
        Carrousel.taille = CGFloat(curseur.doubleValue.rounded())
        apercuCarrousel(anime: false)
    }

    /// Le carrousel tel qu'il apparaîtra, avec vos fenêtres du moment.
    private func apercuCarrousel(anime: Bool) {
        guard let ecran = fenetreCarrousel?.screen ?? ecranSousLaSouris() else { return }
        let (tous, courants) = Relevé.tout()
        let apps = construire(tous).filter { if case .espace(let e) = $0.cible { return e.pleinEcran }; return true }
        guard !apps.isEmpty else { return }
        let ici = cléCourante(tous, courants, ecran: Ecrans.identifiant(ecran))
        let depart = apps.firstIndex { $0.cle == ici } ?? min(1, apps.count - 1)
        Carrousel.commun.ouvrir(apps, depart: depart, espaces: tous, ecran: ecran, anime: anime)
    }

    @objc private func fenetreCarrouselFermée() {
        guard let w = fenetreCarrousel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: w)
        fenetreCarrousel = nil
        Carrousel.commun.masquer()
    }

    private var carrouselApps: [Tuile] = []
    private var carrouselDepart = 0

    /// Les quatre doigts partent à l'horizontale : le carrousel apparaît, calé sur la fenêtre où vous êtes.
    func carrouselDebut() {
        carrouselApps = []
        guard !CaptureEcran.enCours, fenetreCarrousel == nil, panneau?.isVisible != true, let ecran = ecranSousLaSouris() else { return }
        let (tous, courants) = Relevé.tout()
        let id = Ecrans.identifiant(ecran)
        // Avec plusieurs bureaux sur l'écran, c'est macOS qui glisse d'un bureau à l'autre : on ne s'en mêle pas.
        guard tous.filter({ $0.ecran == id }).count == 1 || UserDefaults.standard.bool(forKey: "glisseToujours") else { return }
        let apps = construire(tous).filter { if case .espace(let e) = $0.cible { return e.pleinEcran }; return true }
        guard apps.count > 1 else { return }
        espaces = tous
        carrouselApps = apps
        let ici = cléCourante(tous, courants, ecran: id)
        carrouselDepart = apps.firstIndex { $0.cle == ici } ?? 0
        Carrousel.commun.ouvrir(apps, depart: carrouselDepart, espaces: tous, ecran: ecran)
        Images.commun.capturer(tous) { [weak self] in if let self { Carrousel.commun.rafraichir(espaces: self.espaces) } }
    }

    /// Pas de boucle (essayée puis retirée le 12/11 : on s'y perd) : on s'arrête aux deux bouts.
    private func carrouselPosition(_ q: CGFloat) -> CGFloat {
        min(max(CGFloat(carrouselDepart) + q, 0), CGFloat(carrouselApps.count - 1))
    }

    func carrouselSuivre(_ q: CGFloat) {
        guard !carrouselApps.isEmpty else { return }
        Carrousel.commun.placer(carrouselPosition(q), anime: false)
    }

    /// Doigts levés : la fenêtre sous le cadre passe devant. Un petit geste bref suffit pour passer à la voisine.
    func carrouselFin(_ q: CGFloat) {
        guard !carrouselApps.isEmpty else { return }
        var cible = Int(carrouselPosition(q).rounded())
        if cible == carrouselDepart, abs(q) > 0.22 { cible = min(max(carrouselDepart + (q > 0 ? 1 : -1), 0), carrouselApps.count - 1) }
        Carrousel.commun.fermer(sur: cible)
        let apps = carrouselApps
        carrouselApps = []
        guard cible != carrouselDepart else { return }
        journal("Square: quatre doigts → %@", apps[cible].titre.components(separatedBy: " — ").first ?? "")
        Bascule.aller(apps[cible], espaces: espaces)
    }

    /// Glissement à quatre doigts : passe à l'application agrandie voisine, dans l'ordre des cases de la grille.
    /// Avec plusieurs bureaux sur l'écran, c'est macOS qui glisse d'un bureau à l'autre : on ne s'en mêle pas.
    func voisine(_ sens: Int) {
        guard panneau?.isVisible != true, !CaptureEcran.enCours else { return }
        let (espaces, courants) = Relevé.tout()
        let ecran = Ecrans.identifiant(ecranSousLaSouris())
        guard espaces.filter({ $0.ecran == ecran }).count == 1 || UserDefaults.standard.bool(forKey: "glisseToujours") else { return }
        let apps = construire(espaces).filter { if case .espace(let e) = $0.cible { return e.pleinEcran }; return true }
        guard apps.count > 1 else { return }
        let ici = cléCourante(espaces, courants, ecran: ecran)
        let rang = apps.firstIndex { $0.cle == ici }
        // Aux deux bouts, on s'arrête, comme entre les bureaux. Depuis le bureau nu, on entre par le bout le plus proche.
        let cible = rang.map { $0 + sens } ?? (sens > 0 ? 0 : apps.count - 1)
        guard apps.indices.contains(cible) else { NSSound.beep(); return }
        journal("Square: quatre doigts → %@", apps[cible].titre.components(separatedBy: " — ").first ?? "")
        Bascule.aller(apps[cible], espaces: espaces)
    }

    @objc private func basculerAuto() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    @objc private func ouvrirAccessibilité() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func ouvrirCapture() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: Raccourci

    private func brancherRaccourci() {
        let r = Raccourci.actuel
        Touches.ajouter(idGrille, touche: r.touche, modifs: r.modifs) { [weak self] in self?.appuiRaccourci() }
    }

    private func appuiRaccourci() {
        if panneau?.isVisible == true {
            let rapide = Date().timeIntervalSince(ouverteÀ) < 0.4
            fermerGrille()
            if rapide { retourPrécédent() }         // double appui : application d'avant
        } else {
            ouvrirGrille()
        }
    }

    @objc private func changerRaccourci() {
        Touches.retirer(idGrille)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Raccourci de Square")
        w.isReleasedWhenClosed = false
        let t = NSTextField(wrappingLabelWithString: String(localized: "Appuyez sur le nouveau raccourci.\nIl faut au moins une touche ⌃ ⌥ ⇧ ou ⌘ (ou une touche F1 à F20).\nÉchap pour annuler."))
        t.alignment = .center
        t.frame = NSRect(x: 20, y: 20, width: 340, height: 80)
        w.contentView?.addSubview(t)
        w.center()
        fenetreRaccourci = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        ecoute = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.fenetreRaccourci else { return e }
            if Int(e.keyCode) == kVK_Escape { self.finRaccourci(); return nil }
            guard let r = Raccourci.depuis(e) else { NSSound.beep(); return nil }
            Raccourci.actuel = r
            self.finRaccourci()
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fenetreRaccourciFermée), name: NSWindow.willCloseNotification, object: w)
    }

    @objc private func fenetreRaccourciFermée() { finRaccourci() }

    private func finRaccourci() {
        guard let w = fenetreRaccourci else { return }
        fenetreRaccourci = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: w)
        if let ecoute { NSEvent.removeMonitor(ecoute) }
        ecoute = nil
        w.close()
        brancherRaccourci()
    }

    // MARK: Grille

    private func ecranSousLaSouris() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    /// Construit les cases : les fenêtres agrandies, les plein écran d'Apple, puis les bureaux.
    private func construire(_ espaces: [Espace]) -> [Tuile] {
        var haut: [Tuile] = [], bureaux: [Tuile] = []
        var membresDe: [String: [String]] = [:]       // pour chaque case de groupe, les cases de ses fenêtres
        var parApp: [pid_t: Int] = [:]
        // Une case par fenêtre, agrandie ou non. Le bureau lui-même n'a pas de case.
        func retenue(_ f: Fenetre) -> Bool { f.agrandie || !f.masquee }
        for e in espaces where !e.pleinEcran { for f in e.fenetres where retenue(f) { parApp[f.pid, default: 0] += 1 } }
        for e in espaces {
            if e.pleinEcran {
                guard let f = e.fenetres.first else { continue }
                var noms: [String] = []
                for x in e.fenetres where !noms.contains(x.app) { noms.append(x.app) }
                haut.append(Tuile(cle: "e\(e.id)", titre: noms.joined(separator: " + "),
                                  icone: NSRunningApplication(processIdentifier: f.pid)?.icon, cible: .espace(e), pid: f.pid))
            } else {
                var dejaGroupees: Set<CGWindowID> = []
                for f in e.fenetres where retenue(f) {
                    if dejaGroupees.contains(f.wid) { continue }
                    // Les fenêtres qui se partagent l'écran n'ont qu'une case à elles toutes.
                    let membres = e.fenetres.filter { retenue($0) && Groupes.ensemble($0.wid, f.wid) }
                    if membres.count > 1 {
                        dejaGroupees.formUnion(membres.map { $0.wid })
                        let cle = "g\(membres.map { $0.wid }.min() ?? f.wid)"
                        membresDe[cle] = membres.map { "f\($0.wid)" }
                        var noms: [String] = []
                        for x in membres where !noms.contains(x.app) { noms.append(x.app) }
                        haut.append(Tuile(cle: cle, titre: noms.joined(separator: " + "),
                                          icone: NSRunningApplication(processIdentifier: f.pid)?.icon, cible: .groupe(membres, e), pid: f.pid))
                        continue
                    }
                    let titre = (parApp[f.pid] ?? 0) > 1 && !f.titre.isEmpty ? "\(f.app) — \(f.titre)" : f.app
                    haut.append(Tuile(cle: "f\(f.wid)", titre: titre, icone: NSRunningApplication(processIdentifier: f.pid)?.icon,
                                      cible: .fenetre(f, e), pid: f.pid))
                }
            }
        }
        // Chaque fenêtre garde sa case pour de bon. Une nouvelle prend la première case libre (ou celle que son application
        // occupait la dernière fois) ; une fenêtre fermée laisse sa case vide, sans déplacer les autres.
        let reglages = UserDefaults.standard
        let vivantes = Set(haut.map { $0.cle })
        var places = (reglages.dictionary(forKey: "placesCases") as? [String: Int]) ?? [:]
        if places.isEmpty {     // première fois : on reprend l'ordre déjà affiché
            let ordre = (reglages.stringArray(forKey: "ordreCases") ?? []).filter { vivantes.contains($0) }
            for (i, cle) in ordre.enumerated() { places[cle] = i }
        }
        // Un groupe tout neuf s'installe à la place d'une de ses fenêtres (la plus proche du début).
        for (cle, membres) in membresDe where places[cle] == nil {
            if let p = membres.compactMap({ places[$0] }).min() { places[cle] = p }
        }
        // Une fenêtre qui vient de quitter son groupe ne reprend pas la case du groupe : elle ira sur la première case libre.
        places = places.filter { vivantes.contains($0.key) }
        var vues: Set<Int> = []
        for cle in places.keys.sorted() { if let p = places[cle], !vues.insert(p).inserted { places[cle] = nil } }
        var souvenirs = (reglages.dictionary(forKey: "placesApps") as? [String: Int]) ?? [:]
        func app(_ t: Tuile) -> String { NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier ?? "?" }
        var prises = Set(places.values)
        for t in haut where places[t.cle] == nil {
            var p = 0
            if let ancienne = souvenirs[app(t)], !prises.contains(ancienne) { p = ancienne } else { while prises.contains(p) { p += 1 } }
            places[t.cle] = p
            prises.insert(p)
        }
        for i in haut.indices { haut[i].place = places[haut[i].cle] ?? 0 }
        haut.sort { $0.place < $1.place }
        for t in haut.reversed() { souvenirs[app(t)] = t.place }
        reglages.set(places, forKey: "placesCases")
        reglages.set(souvenirs, forKey: "placesApps")
        reglages.set(haut.map { $0.cle }, forKey: "ordreCases")

        return haut + bureaux
    }

    /// La case de ce qui est à l'écran en ce moment.
    private func cléCourante(_ espaces: [Espace], _ courants: [String: UInt64], ecran: String) -> String? {
        guard let id = courants[ecran], let e = espaces.first(where: { $0.id == id }) else { return nil }
        if e.pleinEcran { return "e\(e.id)" }
        if let devant = e.fenetres.first(where: { !$0.masquee }) {
            let membres = e.fenetres.filter { Groupes.ensemble($0.wid, devant.wid) }
            return membres.count > 1 ? "g\(membres.map { $0.wid }.min() ?? devant.wid)" : "f\(devant.wid)"
        }
        return "e\(e.id)"
    }

    @objc private func basculerGrille() {
        if panneau?.isVisible == true { fermerGrilleEnRevenant() } else { ouvrirGrille() }
    }

    private func ouvrirGrille() {
        guard let ecran = ecranSousLaSouris() else { return }
        let (tous, courants) = Relevé.tout()
        espaces = tous
        tuiles = construire(tous)
        if panneau == nil {
            let p = Panneau(contentRect: ecran.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .black
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            p.animationBehavior = .none
            p.contentView = grille
            panneau = p
        }
        panneau?.setFrame(ecran.frame, display: false)
        let cle = cléCourante(tous, courants, ecran: Ecrans.identifiant(ecran))
        grille.poserFond(Images.commun.fondFlou(ecran: ecran))
        grille.dock.charger()
        grille.charger(tuiles, courante: cle, espaces: tous)
        grille.preparerApparition()
        panneau?.orderFrontRegardless()
        grille.apparaitre()
        grille.majSurvol()
        ouverteÀ = Date()

        brancherTouchesGrille()
        Images.commun.oublier(sauf: Set(tous.flatMap { $0.fenetres.map { $0.wid } }))
        Images.commun.capturer(tous) { [weak self] in
            guard let self, self.panneau?.isVisible == true else { return }
            self.grille.rafraichir(espaces: self.espaces)
        }
    }

    private func brancherTouchesGrille() {
        Touches.ajouter(100, touche: UInt32(kVK_Escape), modifs: 0) { [weak self] in self?.fermerGrilleEnRevenant() }
        // Entrée choisit la case mise en avant par la molette.
        Touches.ajouter(120, touche: UInt32(kVK_Return), modifs: 0) { [weak self] in self?.grille.choisirVedette() }
        for (i, c) in grille.cases.prefix(9).enumerated() {
            Touches.ajouter(UInt32(101 + i), touche: UInt32(chiffres[i]), modifs: 0) { [weak self] in self?.choisir(c.tuile, depuis: c) }
            Touches.ajouter(UInt32(111 + i), touche: UInt32(pavé[i]), modifs: 0) { [weak self] in self?.choisir(c.tuile, depuis: c) }
        }
    }

    private func retirerTouches() { for id in 100...121 { Touches.retirer(UInt32(id)) } }

    private var ecouteLanceur: Any?
    private var lanceurFermeA = Date.distantPast

    /// Clic droit sur une icône du Dock, « Quitter » : comme la croix d'une case, la grille se resserre en douceur.
    private func quitterDepuisLeDock(_ chemin: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == chemin }) else { return }
        if let t = tuiles.first(where: { t in
            if t.pid == app.processIdentifier { return true }
            if case .groupe(let fs, _) = t.cible { return fs.contains { $0.pid == app.processIdentifier } }
            return false
        }), case .fenetre = t.cible {
            fermer(t)
        } else {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.grille.dock.charger() }
    }

    /// Le bouton « Apps » du Dock : la liste de toutes les applications s'ouvre au-dessus de lui (ou se referme).
    private func basculerLanceur() {
        if Lanceur.commun.ouvert { Lanceur.commun.fermer(); return }
        // Un second clic sur le bouton referme la liste : l'appui l'a déjà fermée (clic hors d'elle), le relâchement
        // ne doit pas la rouvrir aussitôt.
        guard Date().timeIntervalSince(lanceurFermeA) > 0.4, let ecran = panneau?.screen else { return }
        retirerTouches()            // le clavier sert maintenant à chercher : les chiffres ne choisissent plus une case
        let ancre = grille.dock.ancreBoutonApps
        Lanceur.commun.ouvrir(surEcran: ecran, contre: ancre.point, cote: ancre.cote)
        // Un clic ailleurs que dans la liste la referme.
        ecouteLanceur = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
            if Lanceur.commun.ouvert, e.window is PanneauLanceur == false { Lanceur.commun.fermer() }
            return e
        }
    }

    /// Clic sur une icône du Dock de la grille : l'application déjà ouverte passe devant (sa case grandit), sinon elle se lance
    /// (et sa fenêtre s'agrandit toute seule, comme toute nouvelle fenêtre).
    private func lancerDepuisLeDock(_ chemin: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == chemin }),
           let c = grille.cases.first(where: { c in
               if c.tuile.pid == app.processIdentifier { return true }
               if case .groupe(let fs, _) = c.tuile.cible { return fs.contains { $0.pid == app.processIdentifier } }
               return false
           }) {
            choisir(c.tuile, depuis: c)
            return
        }
        journal("Square: ouverture depuis le Dock de la grille")
        fermerGrille()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: chemin), configuration: config) { [weak self] app, _ in
            guard let app else { return }
            DispatchQueue.main.async { self?.amenerDevant(app, essais: 40) }
        }
    }

    /// Une application lancée depuis Square (qui n'est pas au premier plan) peut s'ouvrir derrière la fenêtre en cours :
    /// macOS ne laisse pas toujours une application de fond en amener une autre devant. On attend donc sa fenêtre
    /// (jusqu'à douze secondes), puis on l'amène devant nous-mêmes, comme le fait un choix dans la grille.
    private func amenerDevant(_ app: NSRunningApplication, essais: Int) {
        guard essais > 0, !app.isTerminated else { return }
        let (tous, _) = Relevé.tout()
        if let (f, e) = Bascule.fenetre(deLApp: app.processIdentifier, espaces: tous) {
            // Déjà devant : rien à faire. Sinon on la lève.
            if tous.first(where: { $0.id == e.id })?.fenetres.first(where: { !$0.masquee })?.wid != f.wid || !app.isActive {
                journal("Square: %@ amenée devant après son lancement", f.app)
                Bascule.montrer(f, dans: e)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.amenerDevant(app, essais: essais - 1) }
    }

    /// Une case a été lâchée dans la grille : échange de places, nouvelle place, ou partage de l'écran.
    private func deposer(_ t: Tuile, _ d: Depot) {
        var places = (UserDefaults.standard.dictionary(forKey: "placesCases") as? [String: Int]) ?? [:]
        switch d {
        case .echanger(let autre):
            places[t.cle] = autre.place
            places[autre.cle] = t.place
        case .place(let k):
            places[t.cle] = k
        case .separer(let k):
            // La fenêtre quitte son groupe et reprend tout l'écran ; si elle n'y laisse qu'une fenêtre, celle-ci aussi.
            guard case .fenetre(let a, _) = t.cible else { return }
            if let k { places[t.cle] = k; UserDefaults.standard.set(places, forKey: "placesCases") }
            appliquerCadres(Groupes.separer(a, membres: membresDuGroupe(a.wid)))
            return
        case .redimensionner(let cadres):
            appliquerCadres(cadres, transition: false)
            return
        case .ordre(let nouvelles):
            // Les cases sont déjà à leur place à l'écran : on retient le nouvel ordre, et on les refait à l'identique.
            for (cle, p) in nouvelles { places[cle] = p }
            UserDefaults.standard.set(places, forKey: "placesCases")
            UserDefaults.standard.removeObject(forKey: "placesApps")
            redessinerGrille()
            return
        case .partager(let autre, let cote):
            guard case .fenetre(let a, _) = t.cible else { return }
            // Les fenêtres se rangent derrière la grille, qui reste affichée : leurs deux cases n'en font plus qu'une.
            // Si elle vient d'un autre groupe, celles qu'elle y laisse reprennent la place libérée.
            let anciennes = membresDuGroupe(a.wid), nouvelles = membresDuGroupe(autre.wid)
            var cadres: [CGWindowID: CGRect] = [:]
            if !anciennes.contains(where: { $0.wid == autre.wid }) { cadres = Groupes.quitter(a, membres: anciennes) }
            for (w, r) in Groupes.partager(a, sur: autre, cote: cote, membres: nouvelles) { cadres[w] = r }
            appliquerCadres(cadres)
            return
        }
        UserDefaults.standard.set(places, forKey: "placesCases")
        UserDefaults.standard.removeObject(forKey: "placesApps")     // les anciennes places par application ne valent plus
        redessinerGrille(transition: true)
    }

    /// Les fenêtres qui partagent l'écran avec celle-ci, elle comprise (elle seule si elle n'est dans aucun groupe).
    private func membresDuGroupe(_ wid: CGWindowID) -> [Fenetre] {
        for t in tuiles {
            if case .groupe(let fs, _) = t.cible, fs.contains(where: { $0.wid == wid }) { return fs }
            if case .fenetre(let f, _) = t.cible, f.wid == wid { return [f] }
        }
        return []
    }

    /// La grille se redessine tout de suite avec les nouveaux cadres, sans attendre les fenêtres ; celles-ci sont déplacées
    /// juste après, derrière la grille, puis les photos sont refaites.
    private func appliquerCadres(_ cadres: [CGWindowID: CGRect], transition: Bool = true) {
        var touchees: [Fenetre] = []
        espaces = espaces.map { e in
            var copie = Espace(id: e.id, pleinEcran: e.pleinEcran, ecran: e.ecran, rang: e.rang, fenetres: e.fenetres.map { f in
                guard let r = cadres[f.wid] else { return f }
                touchees.append(f)
                let zone = Ecrans.zoneVisible(contenant: r)
                let pleine = r.width * r.height >= 0.9 * zone.width * zone.height
                return Fenetre(wid: f.wid, pid: f.pid, app: f.app, titre: f.titre, cadre: r, agrandie: pleine, masquee: f.masquee)
            })
            copie.nomBureau = e.nomBureau
            return copie
        }
        if let ecran = panneau?.screen, panneau?.isVisible == true {
            tuiles = construire(espaces)
            let courants = Relevé.tout().courants
            grille.charger(tuiles, courante: cléCourante(espaces, courants, ecran: Ecrans.identifiant(ecran)), espaces: espaces, transition: transition)
            retirerTouches()
            brancherTouchesGrille()
        }
        DispatchQueue.main.async { [weak self] in
            Groupes.appliquer(cadres, fenetres: touchees)
            self?.redessinerBientot()
        }
    }

    /// Les fenêtres viennent d'être déplacées derrière la grille : on leur laisse un instant, puis la grille se redessine
    /// et reprend des photos fraîches.
    private func redessinerBientot() {
        // Les cases sont déjà à jour : on ne refait que leurs photos, une fois les fenêtres redessinées à leur nouvelle taille.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.panneau?.isVisible == true else { return }
            Images.commun.capturer(self.espaces) { [weak self] in
                guard let self, self.panneau?.isVisible == true else { return }
                self.grille.rafraichir(espaces: self.espaces)
            }
        }
    }

    /// La grille se redessine sur place, sans rejouer l'animation d'ouverture.
    private func redessinerGrille(transition: Bool = false) {
        guard let ecran = panneau?.screen else { return }
        let (tous, courants) = Relevé.tout()
        espaces = tous
        tuiles = construire(tous)
        grille.charger(tuiles, courante: cléCourante(tous, courants, ecran: Ecrans.identifiant(ecran)), espaces: tous, transition: transition)
        retirerTouches()
        brancherTouchesGrille()
    }

    /// Refermer sans rien choisir : la fenêtre où vous étiez regrandit jusqu'à sa place, puis la grille disparaît.
    private func fermerGrilleEnRevenant() {
        guard panneau?.isVisible == true, let c = grille.cases.first(where: { $0.courant }) else { fermerGrille(); return }
        retirerTouches()
        grille.zoomer(c) { [weak self] in self?.fermerGrille() }
    }

    private func fermerGrille() {
        Lanceur.commun.fermer()
        panneau?.orderOut(nil)
        retirerTouches()
    }

    private func choisir(_ t: Tuile, depuis c: Case) {
        journal("Square: choix %@", t.titre)
        retirerTouches()
        Bascule.aller(t, espaces: espaces)
        // L'image de la case grandit et cache ce qui se passe derrière ; la grille disparaît une fois arrivé.
        let vise = Bascule.espaceVise(t, espaces: espaces)
        grille.zoomer(c) { [weak self] in self?.attendreArrivée(vise, essais: 25) }
    }

    private func attendreArrivée(_ e: Espace?, essais: Int) {
        if let e, essais > 0, Relevé.espaceCourant(ecran: e.ecran) != e.id {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.attendreArrivée(e, essais: essais - 1) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fermerGrille() }
    }

    private func retourPrécédent() {
        guard pidAvant != 0, let app = NSRunningApplication(processIdentifier: pidAvant) else { return }
        journal("Square: retour à %@", app.localizedName ?? "?")
        if app.isHidden { app.unhide() }
        app.activate(options: [])
    }

    private func fermer(_ t: Tuile) {
        guard let app = NSRunningApplication(processIdentifier: t.pid) else { return }
        // Le Finder ne se quitte pas : on ferme simplement sa fenêtre.
        if app.bundleIdentifier == "com.apple.finder", case .fenetre(let f, _) = t.cible, let el = AX.fenetre(pid: f.pid, wid: f.wid) {
            var bouton: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &bouton)
            if let bouton, CFGetTypeID(bouton) == AXUIElementGetTypeID() { AXUIElementPerformAction(bouton as! AXUIElement, kAXPressAction as CFString) }
        } else {
            app.terminate()
        }
        // Les cases de l'application quittent la grille tout de suite, et les autres se resserrent en douceur.
        let finder = app.bundleIdentifier == "com.apple.finder"
        var pidsPartis: Set<pid_t> = finder ? [] : [t.pid]
        if case .groupe(let fs, _) = t.cible {
            // Une case de groupe : toutes ses applications se ferment.
            for f in fs where f.pid != t.pid { NSRunningApplication(processIdentifier: f.pid)?.terminate(); pidsPartis.insert(f.pid) }
        }
        let parties = Set(tuiles.filter { $0.cle == t.cle || pidsPartis.contains($0.pid) }.map { $0.cle })
        tuiles.removeAll { parties.contains($0.cle) }
        // Pas de trou : la fenêtre de la dernière case vient occuper la case libérée (une seule fenêtre change de place).
        while let derniere = tuiles.indices.max(by: { tuiles[$0].place < tuiles[$1].place }) {
            let prises = Set(tuiles.map { $0.place })
            guard let libre = (0..<tuiles[derniere].place).first(where: { !prises.contains($0) }) else { break }
            tuiles[derniere].place = libre
        }
        tuiles.sort { $0.place < $1.place }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: tuiles.map { ($0.cle, $0.place) }), forKey: "placesCases")
        UserDefaults.standard.removeObject(forKey: "placesApps")
        guard panneau?.isVisible == true else { return }
        if tuiles.isEmpty { fermerGrille(); return }
        let courante = grille.cases.first { $0.courant && !parties.contains($0.tuile.cle) }?.tuile.cle
        retirerTouches()
        grille.reorganiser(tuiles) { [weak self] in
            guard let self, self.panneau?.isVisible == true else { return }
            // Les cases sont refaites à l'identique, au même endroit, pour remettre à jour leurs chiffres.
            self.grille.charger(self.tuiles, courante: courante, espaces: self.espaces)
            self.brancherTouchesGrille()
        }
    }

    @objc private func espaceChangé() {
        // Changement d'espace fait ailleurs (trackpad, Mission Control) : la grille n'a plus de raison de rester.
        if panneau?.isVisible == true, Date().timeIntervalSince(ouverteÀ) > 0.5, grille.cases.allSatisfy({ !$0.survol }) { fermerGrille() }
    }

    @objc private func appActivée(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if app.processIdentifier != pidDevant { pidAvant = pidDevant; pidDevant = app.processIdentifier }
    }
}

// MARK: - Démarrage

@main
enum Programme {
    static let appli = Appli()

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--essai") { essai(); return }
        // Pour les essais : « --image-reglages dossier » dessine chaque rubrique des réglages dans une image, sans rien afficher.
        if let i = args.firstIndex(of: "--image-accueil"), i + 1 < args.count {
            _ = NSApplication.shared
            Accueil.images(vers: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = args.firstIndex(of: "--image-reglages"), i + 1 < args.count {
            _ = NSApplication.shared
            for v in VoletReglages.allCases {
                Reglages.image(v, vers: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("reglages-\(v.rawValue).png"))
            }
            return
        }
        if args.contains("--reglages") {    // demande au Square déjà lancé d'ouvrir sa fenêtre de réglages
            DistributedNotificationCenter.default().postNotificationName(.init("com.gauthieraube.square.reglages"), object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            return
        }
        if args.contains("--convertir") {   // même effet que la ligne du menu, sans interface
            Agrandir.convertirTout()
            RunLoop.main.run(until: Date().addingTimeInterval(9))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appli
        app.run()
    }

    /// Vérification sans interface : affiche ce que Square voit.
    static func essai() {
        let (tous, courants) = Relevé.tout()
        print("accessibilité:", AXIsProcessTrusted(), "capture:", Images.autorisé, "courants:", courants)
        for e in tous {
            print(e.id, e.pleinEcran ? "plein écran" : e.nomBureau)
            for f in e.fenetres { print("   ", f.wid, f.app, f.agrandie ? "AGRANDIE" : "", f.masquee ? "MASQUÉE" : "", Int(f.cadre.width), "x", Int(f.cadre.height), f.titre) }
        }
    }
}
