// probe: memory cost of building the multipart upload body like the old GoogleDriveService.uploadFile (no network)
// result: peak footprint ~2x the file size (50 MiB file -> 102.6 MiB peak, 200 MiB -> 402.7 MiB)
// run: dd if=/dev/urandom of="$TMPDIR/test_50m.bin" bs=1m count=50 && swiftc -O tools/bench/probes/upload_body_memory.swift -o "$TMPDIR/upload_body" \
//      && /usr/bin/time -l "$TMPDIR/upload_body" "$TMPDIR/test_50m.bin" 2>&1 | grep -E 'file=|peak memory footprint'

import Foundation
// same as the old GoogleDriveService.uploadFile body building (no network)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let t0 = Date()
let fileData = try Data(contentsOf: url)
let metadataData = try JSONSerialization.data(withJSONObject: ["name": url.lastPathComponent, "mimeType": "application/octet-stream"])
let boundary = "Boundary-\(UUID().uuidString)"
var body = Data()
body.append("--\(boundary)\r\n".data(using: .utf8)!)
body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
body.append(metadataData)
body.append("\r\n".data(using: .utf8)!)
body.append("--\(boundary)\r\n".data(using: .utf8)!)
body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
body.append(fileData)
body.append("\r\n".data(using: .utf8)!)
body.append("--\(boundary)--\r\n".data(using: .utf8)!)
var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
request.httpBody = body
print("file=\(fileData.count) body=\(body.count) overhead=\(body.count - fileData.count) bytes, build=\(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
