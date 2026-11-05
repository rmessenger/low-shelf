import Foundation
import ServiceManagement

public enum LoginItemFailure: Error {
    case registration(String)
}

@available(macOS 13.0, *)
public enum LoginItem {
    public static func setEnabled(_ enabled: Bool) throws(LoginItemFailure) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw .registration(error.localizedDescription)
        }
    }
}
