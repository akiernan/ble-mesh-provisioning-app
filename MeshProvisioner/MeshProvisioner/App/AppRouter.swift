import Foundation
import SwiftUI

// MARK: - Routes

enum AppRoute: Hashable {
    case provisioning
    case keyBinding
    case groupConfig
    case deviceControl
}

// MARK: - AppRouter

@Observable
@MainActor
final class AppRouter {
    var path = NavigationPath()

    func navigate(to route: AppRoute) {
        path.append(route)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
