import AppKit
import Network

// google picker config, api key lives in the gitignored Info.plist
struct DrivePickerConfig {
    let apiKey: String
    let appId: String

    static func load() -> DrivePickerConfig? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let apiKey = info["GooglePickerAPIKey"] as? String,
              !apiKey.isEmpty, !apiKey.hasPrefix("YOUR_") else {
            return nil
        }

        // project number is the prefix of the oauth client id ("123456-abc.apps.googleusercontent.com")
        let clientID = info["GIDClientID"] as? String ?? ""
        let appId = (info["GoogleCloudProjectNumber"] as? String)
            ?? String(clientID.prefix { $0.isNumber })
        guard !appId.isEmpty else { return nil }

        return DrivePickerConfig(apiKey: apiKey, appId: appId)
    }
}

enum DrivePickerResult {
    case picked([DriveFolder])
    case cancelled
    case failed(String)
}

// picker runs in the user's browser, in-app web views have no google session
// (google blocks signing in there too)
// a one-shot server on 127.0.0.1 serves the page and gets the folders back
final class DrivePickerSession {
    private static var current: DrivePickerSession?

    private let listener: NWListener
    private let secret = UUID().uuidString   // keeps other local apps from grabbing the page/token
    private let page: String
    private var completion: ((DrivePickerResult) -> Void)?

    static func start(config: DrivePickerConfig, accessToken: String, maxItems: Int,
                      completion: @escaping (DrivePickerResult) -> Void) throws {
        current?.finish(.cancelled)
        current = try DrivePickerSession(config: config, accessToken: accessToken,
                                         maxItems: maxItems, completion: completion)
    }

    static func cancel() {
        current?.finish(.cancelled)
    }

    private init(config: DrivePickerConfig, accessToken: String, maxItems: Int,
                 completion: @escaping (DrivePickerResult) -> Void) throws {
        self.completion = completion

        let pageConfig: [String: Any] = [
            "apiKey": config.apiKey,
            "appId": config.appId,
            "token": accessToken,
            "maxItems": maxItems
        ]
        let json = (try? JSONSerialization.data(withJSONObject: pageConfig))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        page = Self.pageTemplate.replacingOccurrences(of: "__CONFIG__", with: json)

        // loopback only, nothing outside this mac can connect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port,
                   let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.secret)") {
                    NSWorkspace.shared.open(url)
                }
            case .failed(let error):
                self.finish(.failed("Couldn't start Google Picker: \(error.localizedDescription)"))
            default:
                break
            }
        }
        listener.start(queue: .main)
    }

    private func finish(_ result: DrivePickerResult) {
        guard let completion else { return }
        self.completion = nil
        listener.cancel()
        if Self.current === self {
            Self.current = nil
        }
        completion(result)
    }

    // MARK: tiny http server

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let components = URLComponents(string: String(parts[1])) else {
                self.respond(on: connection, status: "400 Bad Request", body: "")
                return
            }

            switch components.path {
            case "/\(self.secret)":
                self.respond(on: connection, body: self.page)
            case "/\(self.secret)/result":
                let payload = components.queryItems?.first { $0.name == "data" }?.value
                let result = Self.parseResult(payload)
                self.respond(on: connection, body: Self.donePage(for: result))
                self.finish(result)
                NSApp.activate(ignoringOtherApps: true)
            default:
                self.respond(on: connection, status: "404 Not Found", body: "")
            }
        }
    }

    private func respond(on connection: NWConnection, status: String = "200 OK", body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseResult(_ payload: String?) -> DrivePickerResult {
        guard let payload,
              let data = payload.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = body["action"] as? String else {
            return .failed("Google Picker sent back something unexpected")
        }

        switch action {
        case "picked":
            let docs = body["folders"] as? [[String: String]] ?? []
            let folders = docs.compactMap { doc -> DriveFolder? in
                guard let id = doc["id"], let name = doc["name"] else { return nil }
                return DriveFolder(id: id, name: name)
            }
            return .picked(folders)
        case "cancel":
            return .cancelled
        default:
            return .failed(body["message"] as? String ?? "Google Picker failed")
        }
    }

    // MARK: pages

    private static func donePage(for result: DrivePickerResult) -> String {
        let message: String
        switch result {
        case .picked(let folders):
            message = "Added \(folders.count) folder\(folders.count == 1 ? "" : "s")"
        case .cancelled:
            message = "No folders picked"
        case .failed:
            message = "Something went wrong, check the app for details"
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Pigeonhole</title>
        <style>
          body { font: 15px -apple-system, sans-serif; display: grid; place-items: center;
                 height: 100vh; margin: 0; color: #333; text-align: center; }
          p { color: #777; }
        </style></head>
        <body><div><h2>\(message)</h2><p>You can close this tab and go back to the app.</p></div></body>
        </html>
        """
    }

    private static let pageTemplate = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>Choose folders · Pigeonhole</title>
    <style>
      html, body { margin: 0; height: 100%; background: #f5f5f7; font: 14px -apple-system, sans-serif; }
      #status { padding: 32px; color: #666; text-align: center; }
    </style>
    <script>
      const CONFIG = __CONFIG__;

      // hand the result back to the app, the server answers with a "you can close this tab" page
      function post(message) {
        location.replace(location.pathname + '/result?data=' + encodeURIComponent(JSON.stringify(message)));
      }

      function onApiLoad() {
        gapi.load('picker', {
          callback: createPicker,
          onerror: () => post({ action: 'error', message: "Couldn't load Google Picker" })
        });
      }

      function createPicker() {
        const view = new google.picker.DocsView(google.picker.ViewId.FOLDERS)
          .setIncludeFolders(true)
          .setSelectFolderEnabled(true)
          .setMimeTypes('application/vnd.google-apps.folder')
          .setParent('root');

        const picker = new google.picker.PickerBuilder()
          .addView(view)
          .enableFeature(google.picker.Feature.MULTISELECT_ENABLED)
          .setMaxItems(CONFIG.maxItems)
          .setOAuthToken(CONFIG.token)
          .setDeveloperKey(CONFIG.apiKey)
          .setAppId(CONFIG.appId)
          .setOrigin(window.location.origin)
          .setTitle('Pick folders for dropped files')
          .setCallback(onPicked)
          .build();
        picker.setVisible(true);
        document.getElementById('status').textContent = '';
      }

      function onPicked(data) {
        const action = data[google.picker.Response.ACTION];
        if (action === google.picker.Action.PICKED) {
          const folders = data[google.picker.Response.DOCUMENTS].map(doc => ({
            id: doc[google.picker.Document.ID],
            name: doc[google.picker.Document.NAME]
          }));
          post({ action: 'picked', folders });
        } else if (action === google.picker.Action.CANCEL) {
          post({ action: 'cancel' });
        }
      }
    </script>
    </head>
    <body>
      <div id="status">Loading Google Drive…</div>
      <script async defer src="https://apis.google.com/js/api.js"
              onload="onApiLoad()"
              onerror="post({ action: 'error', message: 'Couldn\\'t reach Google, check your connection' })"></script>
    </body>
    </html>
    """
}
