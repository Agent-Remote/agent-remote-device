import DeviceIPC
import DeviceServices
import Darwin
import Foundation

guard DeviceProcessHardening.disableCoreDumps(),
      let teamIdentifier = XPCServiceBootstrap.teamIdentifier(),
      let policy = try? XPCPeerPolicy(
          bundleIdentifier: DeviceIPCServiceIdentifier.approvalUI,
          teamIdentifier: teamIdentifier
      )
else {
    exit(EXIT_FAILURE)
}

private let service = GUIExecutorService(teamIdentifier: teamIdentifier)
private let delegate = AuthenticatedXPCListenerDelegate(
    exportedInterface: NSXPCInterface(with: GUIExecutorXPCProtocol.self),
    exportedObject: service,
    peerPolicy: policy
)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
