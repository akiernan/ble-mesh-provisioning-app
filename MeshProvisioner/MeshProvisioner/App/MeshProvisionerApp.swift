import SwiftUI

@main
struct MeshProvisionerApp: App {
    @State private var meshService = MeshNetworkService()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $router.path) {
                DeviceDiscoveryView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .provisioning:
                            ProvisioningView()
                        case .keyBinding:
                            KeyBindingView()
                        case .groupConfig:
                            GroupConfigView()
                        case .deviceControl:
                            DeviceControlView()
                        }
                    }
            }
            .environment(meshService)
            .environment(router)
        }
    }
}
