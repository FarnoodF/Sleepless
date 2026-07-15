import Foundation
import Network

final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Sleepless.ConnectivityMonitor")
    private var pathIsSatisfied = true
    private let probeURL = URL(string: "https://www.apple.com/library/test/success.html")!

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.queue.async {
                self?.pathIsSatisfied = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    func checkNow(completion: @escaping (Bool) -> Void) {
        queue.async {
            let pathOk = self.pathIsSatisfied
            guard pathOk else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            var request = URLRequest(url: self.probeURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            URLSession.shared.dataTask(with: request) { _, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode
                let ok = error == nil && code.map { 200..<400 ~= $0 } == true
                DispatchQueue.main.async { completion(ok) }
            }.resume()
        }
    }
}
