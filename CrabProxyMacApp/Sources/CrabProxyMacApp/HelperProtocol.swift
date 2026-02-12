import Foundation

@objc protocol CrabProxyHelperProtocol {
  func enablePF(pfConf: String, certPath: String, reply: @escaping (Bool, String?) -> Void)
  func disablePF(reply: @escaping (Bool, String?) -> Void)
  func installCert(certPath: String, reply: @escaping (Bool, String?) -> Void)
  func removeCert(commonName: String, reply: @escaping (Bool, String?) -> Void)
  func checkCert(commonName: String, reply: @escaping (Bool) -> Void)
}
