import SwiftUI

@main
struct MeshProvisionerApp: App {
    @State private var meshService = MeshNetworkService()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

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
                        case .switchCommissioning:
                            SwitchCommissioningView()
                        case .deviceControl:
                            DeviceControlView()
                        case .deviceDiagnostics(let unicastAddress):
                            DeviceDiagnosticsView(unicastAddress: unicastAddress)
                        }
                    }
            }
            .environment(meshService)
            .environment(router)
            .onAppear {
                if meshService.hasProvisionedNetwork {
                    router.navigate(to: .deviceControl)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, meshService.hasProvisionedNetwork else { return }
                Task {
                    try? await meshService.connectToProxy()
                    await meshService.fetchCurrentState()
                }
            }
        }
    }
}
