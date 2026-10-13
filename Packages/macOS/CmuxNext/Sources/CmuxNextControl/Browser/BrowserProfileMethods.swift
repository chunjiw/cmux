import Foundation

/// `browser.profiles.list` and `browser.profiles.create {name?, color?, icon?}`
/// (`cmux browser profiles`, `cmux browser profiles create NAME`): the
/// person's browser profile records (plans/cmux-next/data-model.md 5), the
/// same ones Settings and the sidebar show. An agent makes a new, empty
/// profile here and opens or moves tabs into it by id or name
/// (`browser.page.new_tab|set_profile {profile}`). The app owns the records:
/// it supplies the list and the create, which answers once the app knows the
/// new record.
public struct BrowserProfileMethods: Sendable {
    let list: @MainActor @Sendable () -> [JSONValue]
    let create: @MainActor @Sendable (_ name: String?, _ color: String?, _ icon: String?) async throws -> JSONValue

    public init(list: @escaping @MainActor @Sendable () -> [JSONValue],
                create: @escaping @MainActor @Sendable (_ name: String?, _ color: String?, _ icon: String?) async throws -> JSONValue) {
        self.list = list
        self.create = create
    }

    public var methods: [ControlMethod] {
        let list = list, create = create
        return [
            .mainActor("browser.profiles.list") { _ in .value(["profiles": .array(list())]) },
            .async("browser.profiles.create") { call in
                let text = { (key: String) in call.params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
                return try await create(text("name"), text("color"), text("icon"))
            },
        ]
    }
}
