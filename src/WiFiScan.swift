import CoreLocation
import CoreWLAN
import Foundation

enum WiFiScan {
    @MainActor
    static func run(interfaceName: String, outputPath: String) {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName), interface.powerOn() else {
            return
        }
        var names = scan(interface)
        if names.isEmpty {
            let location = CLLocationManager()
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
                let deadline = Date().addingTimeInterval(25)
                while location.authorizationStatus == .notDetermined, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
            }
            if location.authorizationStatus == .authorizedAlways {
                names = scan(interface)
            }
        }
        let output = URL(fileURLWithPath: outputPath)
        try? names.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    private static func scan(_ interface: CWInterface) -> [String] {
        let networks = try? interface.scanForNetworks(withSSID: nil)
        return (networks ?? []).compactMap(\.ssid).filter { name in
            !name.isEmpty && name.utf8.count <= 32 && name.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}
