//
//  AccentColorManager.swift
//  ASign
//
//  Created by Nagata Asami on 6/30/25.
//

import SwiftUI
import UIKit
import NimbleExtensions

// MARK: - Accent Color Manager
class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()
    
    /// Bumped whenever entries are inserted into `_accentColors` above an
    /// existing one. `@AppStorage` stores the *index*, not the colour, so
    /// inserting at the top silently repaints everyone's app unless the saved
    /// value is shifted to match. See `_migrateStoredIndexIfNeeded()`.
    private static let _paletteVersion = 2
    private static let _paletteVersionKey = "ASign.accentColorPaletteVersion"
    
    @AppStorage("Feather.accentColor") private var _selectedAccentColor: Int = 0 {
        didSet {
            objectWillChange.send()
        }
    }
    
    private init() {
        Self._migrateStoredIndexIfNeeded()
    }
    
    private let _accentColors: [(color: Color, uiColor: UIColor)] = [
        // ASign Indigo — the default. Index 0 is what every fresh install and
        // every unset preference resolves to.
        (Color(red: 0x7C/255, green: 0x6F/255, blue: 0xF0/255), UIColor(red: 0x7C/255, green: 0x6F/255, blue: 0xF0/255, alpha: 1.0)), // 0 — ASign Indigo
        (NBHalloween.accent,  NBHalloween.uiAccent),   // 1 — Neon Green
        (NBHalloween.pumpkin, NBHalloween.uiPumpkin),  // 2 — Pumpkin
        (NBHalloween.blood,   NBHalloween.uiBlood),    // 3 — Blood
        // Upstream palette, shifted down.
        (Color(red: 0x53/255, green: 0x94/255, blue: 0xF7/255), UIColor(red: 0x53/255, green: 0x94/255, blue: 0xF7/255, alpha: 1.0)), // 4 — ASign Blue
        (Color(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255), UIColor(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255, alpha: 1.0)), // 5 — Cherry
        (.red, .systemRed),
        (.orange, .systemOrange),
        (.yellow, .systemYellow),
        (.green, .systemGreen),
        (.blue, .systemBlue),
        (.purple, .systemPurple),
        (.pink, .systemPink),
        (.indigo, .systemIndigo),
        (.mint, .systemMint),
        (.cyan, .systemCyan),
        (.teal, .systemTeal)
    ]
    
    var currentAccentColor: Color {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].color
        }
        return _accentColors[_selectedAccentColor].color
    }
    
    var currentUIColor: UIColor {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].uiColor
        }
        return _accentColors[_selectedAccentColor].uiColor
    }
    
    /// Updates the global app tint color
    func updateGlobalTintColor() {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { window in
                    window.tintColor = self.currentUIColor
                }
        }
    }
    
    // MARK: - Migration
    
    /// Shifts a previously saved index so it still points at the colour the
    /// user actually picked, then records that it has done so.
    ///
    /// Someone who had picked Neon Green (v1 index 0) keeps Neon Green
    /// (v2 index 1). Someone who never touched the picker is left unset, and
    /// resolves to ASign Indigo.
    private static func _migrateStoredIndexIfNeeded() {
        let defaults = UserDefaults.standard

        guard defaults.integer(forKey: _paletteVersionKey) < _paletteVersion else { return }

        // A stored index only exists if the picker was actually used; an unset
        // key reads as 0, which is already where we want it.
        if defaults.object(forKey: "Feather.accentColor") != nil {
            let old = defaults.integer(forKey: "Feather.accentColor")
            if defaults.integer(forKey: _paletteVersionKey) < 1 {
                // v0 -> v1: two Halloween entries were inserted above the old palette.
                if old > 0 {
                    defaults.set(old + 2, forKey: "Feather.accentColor")
                }
            } else {
                // v1 -> v2: ASign Indigo was inserted at the very top.
                defaults.set(old + 1, forKey: "Feather.accentColor")
            }
        }

        defaults.set(_paletteVersion, forKey: _paletteVersionKey)
    }
}
