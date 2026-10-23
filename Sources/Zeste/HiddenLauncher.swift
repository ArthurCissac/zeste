import AppKit

/// Ouvre au démarrage des apps qui doivent tourner en arrière-plan (VPN, dictée…),
/// sans afficher leur fenêtre : elles restent utilisables depuis la barre des menus et leurs raccourcis.
@MainActor
enum HiddenLauncher {
    static let key = "hiddenApps"

    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func start() {
        // Quelques secondes de marge : à l'ouverture de session, le Mac a d'autres choses à lancer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { launchAll() } }
    }

    static func launchAll() {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                // Déjà lancée (par macOS ou par l'app elle-même) : on cache simplement sa fenêtre.
                keepHidden(running)
                continue
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                guard let app else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { keepHidden(app) } }
            }
        }
    }

    /// Beaucoup d'apps (Electron notamment) affichent leur fenêtre une fois chargées, même lancées cachées :
    /// on la recache pendant les premières secondes, puis on les laisse tranquilles.
    static func keepHidden(_ app: NSRunningApplication) {
        for delay in [0.3, 1.0, 2.0, 3.5, 5.0, 7.5, 10.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !app.isTerminated && !app.isHidden { app.hide() }
            }
        }
    }
}
