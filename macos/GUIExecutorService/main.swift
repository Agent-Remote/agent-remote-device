import DeviceIPC
import DeviceServices
import Darwin
import Foundation

guard DeviceProcessHardening.disableCoreDumps(),
      let signerIdentity = XPCServiceBootstrap.signerIdentity(),
      let policy = try? XPCPeerPolicy(
          bundleIdentifier: DeviceIPCServiceIdentifier.approvalUI,
          signerIdentity: signerIdentity
      )
else {
    exit(EXIT_FAILURE)
}

private let service = GUIExecutorService(signerIdentity: signerIdentity)
private let delegate = AuthenticatedXPCListenerDelegate(
    exportedInterface: NSXPCInterface(with: GUIExecutorXPCProtocol.self),
    exportedObject: service,
    peerPolicy: policy
)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
