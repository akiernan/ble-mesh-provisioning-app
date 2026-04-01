# Project: Bluetooth Mesh Provisioning App

## Quick Reference
- **Platform**: iOS 17+ / macOS 14+
- **Language**: Swift 6.0
- **UI Framework**: SwiftUI
- **Architecture**: MVVM with @Observable
- **Minimum Deployment**: iOS 17.0
- **Package Manager**: Swift Package Manager

## XcodeBuildMCP Integration
**IMPORTANT**: This project uses XcodeBuildMCP for all Xcode operations.
- Build: `mcp__xcodebuildmcp__build_sim_name_proj`
- Test: `mcp__xcodebuildmcp__test_sim_name_proj`
- Clean: `mcp__xcodebuildmcp__clean`

## Project Structure
```
MyApp/
├── App/                    # App entry point, App delegate
├── Features/               # Feature modules
│   ├── [FeatureName]/
│   │   ├── Views/          # SwiftUI views
│   │   ├── ViewModels/     # @Observable classes
│   │   └── Models/         # Data models
├── Core/                   # Shared utilities
│   ├── Extensions/
│   ├── Services/
│   └── Networking/
├── Resources/              # Assets, Localizations
└── Tests/
```

## Coding Standards

### Swift Style
- Use Swift 6 strict concurrency
- Prefer `@Observable` over `ObservableObject`
- Use `async/await` for all async operations
- Follow Apple's Swift API Design Guidelines
- Use `guard` for early exits
- Prefer value types (structs) over reference types (classes)

### SwiftUI Patterns
- Extract views when they exceed 100 lines
- Use `@State` for local view state only
- Use `@Environment` for dependency injection
- Prefer `NavigationStack` over deprecated `NavigationView`
- Use `@Bindable` for bindings to @Observable objects

### Navigation Pattern
```swift
// Use NavigationStack with type-safe routing
enum Route: Hashable {
    case detail(Item)
    case settings
}

NavigationStack(path: $router.path) {
    ContentView()
        .navigationDestination(for: Route.self) { route in
            // Handle routing
        }
}
```

### Error Handling
```swift
// Always use typed errors
enum AppError: LocalizedError {
    case networkError(underlying: Error)
    case validationError(message: String)

    var errorDescription: String? {
        switch self {
        case .networkError(let error): return error.localizedDescription
        case .validationError(let msg): return msg
        }
    }
}
```

## Testing Requirements
- Unit tests for all ViewModels
- UI tests for critical user flows
- Use Swift Testing framework (`@Test`, `#expect`)
- Minimum 80% code coverage for business logic

## DO NOT
- Write UITests during scaffolding phase
- Use deprecated APIs (UIKit when SwiftUI suffices)
- Create massive monolithic views
- Use force unwrapping (`!`) without justification
- Ignore Swift 6 concurrency warnings

## Planning Workflow
When starting new features:
1. Read the PRD from `docs/PRD.md`
2. Create feature spec in `docs/specs/[feature-name].md`
3. Use `ultrathink` for architectural decisions
4. Use Plan Mode (`Shift+Tab`) for implementation strategy
5. Implement incrementally with tests

## Memory Imports
@import docs/PRD.md
@import docs/ARCHITECTURE.md
@import docs/ROADMAP.md
