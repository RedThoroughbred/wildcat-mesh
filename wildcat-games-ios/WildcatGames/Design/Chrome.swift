import SwiftUI
import UIKit

/// Navigation and tab bar appearance: transparent bars over the flat
/// background, SF Pro titles in primary text, grey unselected tabs. The
/// selected tab takes the view's `.tint` (white, or a network colour on the
/// network tabs). Called once.
enum Chrome {
    static func apply() {
        let ink = UIColor(Theme.textPrimary)
        let tertiary = UIColor(Theme.textTertiary)
        let accent = UIColor(Theme.accent)

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.largeTitleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont.systemFont(ofSize: 32, weight: .bold),
            .kern: -0.6,
        ]
        nav.titleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        let back = UIBarButtonItemAppearance(style: .plain)
        back.normal.titleTextAttributes = [.foregroundColor: ink]
        nav.buttonAppearance = back
        nav.doneButtonAppearance = back
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = accent

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = UIColor(Theme.bg).withAlphaComponent(0.86)
        tab.shadowColor = UIColor.white.withAlphaComponent(0.07)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = tertiary
            item.normal.titleTextAttributes = [
                .foregroundColor: tertiary,
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            ]
            item.selected.titleTextAttributes = [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            ]
            item.normal.badgeBackgroundColor = ink
            item.normal.badgeTextAttributes = [.foregroundColor: UIColor.black]
            item.selected.badgeBackgroundColor = ink
            item.selected.badgeTextAttributes = [.foregroundColor: UIColor.black]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().unselectedItemTintColor = tertiary

        // Segmented pickers and switches that stay system-drawn.
        UISegmentedControl.appearance().selectedSegmentTintColor = accent
        UISegmentedControl.appearance().backgroundColor = UIColor(Theme.surface1)
        UISegmentedControl.appearance().setTitleTextAttributes([
            .foregroundColor: UIColor(Theme.onAccent),
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        ], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([
            .foregroundColor: UIColor(Theme.textSecondary),
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
        ], for: .normal)
        UISwitch.appearance().onTintColor = UIColor(Theme.ok)
        UIRefreshControl.appearance().tintColor = UIColor(Theme.textSecondary)
    }
}

/// Remi, the two-tone cat (amber Meshtastic half, blue MeshCore half): the
/// app's mark, drawn from the "RemiMark" asset (docs/design/icon-concepts/
/// 07-remi.png) as an app-icon tile with continuous corners.
struct RemiMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("RemiMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .accessibilityLabel("Wildcat Mesh")
    }
}

/// The old name for the mark, kept so call sites compile. `tint` is
/// ignored: Remi carries both network colours.
struct WildcatMark: View {
    var size: CGFloat = 44
    var tint: Color = Theme.amber

    var body: some View {
        RemiMark(size: size)
    }
}
