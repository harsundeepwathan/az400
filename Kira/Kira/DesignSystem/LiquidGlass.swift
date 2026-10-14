import SwiftUI

// Liquid Glass adoption (iOS 26+), with graceful fallbacks for iOS 18–25.
//
// HIG › Materials: Liquid Glass forms the *functional layer* — tab bars, toolbars, controls —
// floating above content. Don't use it in the content layer, and use it sparingly on custom
// controls. Kira therefore applies NO custom glass to content; it relies on standard tab bars,
// toolbars, sheets, menus and button styles, which adopt Liquid Glass automatically when built
// with the iOS 26 SDK. The helpers below only opt into the new *system* behaviours.

extension View {
    /// Primary action in a view (HIG › Buttons: one prominent button for the most likely action).
    /// iOS 26: accent-tinted Liquid Glass. Earlier: bordered prominent.
    @ViewBuilder
    func kiraProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    /// Secondary actions alongside a prominent one.
    @ViewBuilder
    func kiraSecondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).controlSize(.large)
        }
    }

    /// HIG › Tab bars: the tab bar can minimise while people scroll down, returning on tap or scroll to top.
    @ViewBuilder
    func kiraTabBarMinimizesOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Secondary line under a large title (e.g. the date under "Summary").
    @ViewBuilder
    func kiraNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

/// Standard dismiss button for sheets (HIG › Toolbars: use the standard Close button rather than
/// a text label). iOS 26 renders the system close symbol; earlier versions show "Cancel".
struct CloseToolbarItem: ToolbarContent {
    var action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if #available(iOS 26.0, *) {
                Button(role: .close, action: action)
            } else {
                Button("Cancel", role: .cancel, action: action)
            }
        }
    }
}

/// Standard confirm button (Done/Save) for sheets: trailing, prominent, paired with Close
/// (HIG › Sheets: always pair Done with Cancel/Close).
struct ConfirmToolbarItem: ToolbarContent {
    var title: LocalizedStringKey = "Done"
    var isDisabled = false
    var action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if #available(iOS 26.0, *) {
                Button(role: .confirm, action: action) { Text(title) }
                    .disabled(isDisabled)
            } else {
                Button(title, action: action)
                    .fontWeight(.semibold)
                    .disabled(isDisabled)
            }
        }
    }
}
