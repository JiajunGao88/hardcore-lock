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
        
        return ShieldConfiguration(
            backgroundBlurStyle: .dark,
            backgroundColor: .black,
            icon: nil,
            title: ShieldConfiguration.Label(
                text: randomTaunt,
                color: .white
            ),
            subtitle: nil,
            primaryButtonLabel: nil,     // 无解锁按钮！
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: nil    // 无第二按钮！
        )
    }
}
