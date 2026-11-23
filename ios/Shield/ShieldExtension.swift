// The screen shown in place of a locked app or website.
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { shield() }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { shield() }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { shield() }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { shield() }

    private func shield() -> ShieldConfiguration {
        let brass = UIColor(red: 0.85, green: 0.68, blue: 0.36, alpha: 1)
        let enamel = UIColor(red: 0.05, green: 0.11, blue: 0.09, alpha: 1)
        var subtitle = "Time is keeping this closed for now."
        if let l = Engine.load().lock {
            subtitle = "Locked by Time until \(Fmt.when(l.endsAt)).\nIt'll be here when the timer ends."
        }
        let icon = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))?
            .withTintColor(brass, renderingMode: .alwaysOriginal)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: enamel.withAlphaComponent(0.92),
            icon: icon,
            title: .init(text: "Not right now", color: .white),
            subtitle: .init(text: subtitle, color: UIColor.white.withAlphaComponent(0.65)),
            primaryButtonLabel: .init(text: "Close", color: enamel),
            primaryButtonBackgroundColor: brass)
    }
}
