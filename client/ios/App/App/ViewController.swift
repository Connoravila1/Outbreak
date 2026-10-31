import Capacitor

/// The bridge's view controller, subclassed only to register the local Patrol plugin.
class ViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(PatrolPlugin())
    }
}
