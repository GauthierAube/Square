// La langue de l'application. Par défaut, elle suit le Mac : en français si le français passe en premier dans les langues
// du Mac, en anglais sinon (Info.plist : langue de développement « en », langues proposées : anglais et français).
// On peut la forcer dans les réglages : c'est le même réglage que « Réglages Système > Général > Langue et région >
// Applications », enregistré dans les préférences de l'application (clé AppleLanguages). Il s'applique au redémarrage.
// Les textes viennent du catalogue Localizable.xcstrings (textes source en français, traduction anglaise).
import AppKit

enum Langue: String, CaseIterable, Identifiable {
    case automatique, francais, anglais
    var id: String { rawValue }

    /// Le nom affiché dans le choix. Comme dans macOS, le nom de chaque langue s'écrit dans cette langue.
    var nom: String {
        switch self {
        case .automatique: return String(localized: "Automatique (langue du Mac)")
        case .francais: return "Français"
        case .anglais: return "English"
        }
    }

    /// Le choix enregistré pour cette application (et non la langue du Mac).
    static var choisie: Langue {
        let domaine = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let liste = domaine["AppleLanguages"] as? [String], let premiere = liste.first else { return .automatique }
        return premiere.hasPrefix("fr") ? .francais : .anglais
    }

    /// Enregistre le choix et relance l'application, qui s'affiche alors dans la nouvelle langue.
    static func choisir(_ l: Langue) {
        guard l != choisie else { return }
        switch l {
        case .automatique: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .francais: UserDefaults.standard.set(["fr"], forKey: "AppleLanguages")
        case .anglais: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        relancer()
    }

    static func relancer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
