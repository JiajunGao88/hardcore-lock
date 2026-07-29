//
//  ShieldConfigurationExtension.swift
//  ShieldConfigurationExtension
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    
    // 嘲讽文案
    private let tauntingMessages = [
        "Don't be weak.",
        "Touch grass.",
        "Stay focused.",
        "No escape.",
        "You chose this.",
        "Embrace the void.",
        "Discipline is freedom.",
        "The phone can wait.",
        "Be present.",
        "Resist the urge.",
        "You're stronger than this.",
        "Focus on what matters.",
        "Time is precious.",
        "Break the addiction.",
        "Control yourself.",
        "This too shall pass.",
        "Breathe.",
        "Stay hard.",
        "No excuses.",
        "Commit."
    ]
    
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        return createShieldConfiguration()
    }
    
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        return createShieldConfiguration()
    }
    
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return createShieldConfiguration()
    }
    
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return createShieldConfiguration()
    }
    
    private func createShieldConfiguration() -> ShieldConfiguration {
        let randomTaunt = tauntingMessages.randomElement() ?? "Stay focused."

        // NOTE on sizing/corners: ShieldConfiguration exposes only background
        // material/color, icon and three labels — no frame, no cornerRadius.
        // The shield is rendered by a system process, so its geometry and the
        // app-switcher card treatment are not ours to set. What we CAN do is
        // stop flattening it: a fully opaque backgroundColor composites over
        // backgroundBlurStyle and kills the system material entirely, which is
        // what made this read as a bare black rectangle. Using a thick dark
        // material with a near-opaque (not opaque) black lets the system's own
        // material render — still essentially black, but native-looking.
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor.black.withAlphaComponent(0.9),
            icon: nil,
            title: ShieldConfiguration.Label(
                text: randomTaunt,
                color: .white
            ),
            // A second line gives the shield the native title+subtitle rhythm
            // instead of one lonely string floating in the middle.
            subtitle: ShieldConfiguration.Label(
                text: "FIFTEEN · LOCKED",
                color: UIColor.white.withAlphaComponent(0.45)
            ),
            primaryButtonLabel: nil,     // 无解锁按钮！
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: nil    // 无第二按钮！
        )
    }
}
