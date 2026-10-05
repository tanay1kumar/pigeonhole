// Probe: compares the app's hand-written MIME table (GoogleDriveService.mimeType(for:) as of bd396dc) with UTType.preferredMIMEType
// for 74 extensions. Finding (2026-10-04): 61 of 74 fall back to application/octet-stream; UTType knows 47 of those 61.
// Run: swiftc -O tools/bench/probes/mime_table.swift -o "$TMPDIR/mime_table" && "$TMPDIR/mime_table"

import Foundation
import UniformTypeIdentifiers

// exact copy of GoogleDriveService.mimeType(for:) (GoogleDriveService.swift:184-200)
func appMime(_ fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "doc": return "application/msword"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "xls": return "application/vnd.ms-excel"
    case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    case "mp3": return "audio/mpeg"
    case "mp4": return "video/mp4"
    case "zip": return "application/zip"
    default: return "application/octet-stream"
    }
}

let exts = ["jpg","jpeg","png","gif","pdf","txt","doc","docx","xls","xlsx","mp3","mp4","zip",
            "heic","heif","webp","tiff","tif","bmp","svg","ico","dng","raw","cr2","nef",
            "mov","m4v","avi","mkv","webm",
            "wav","m4a","aac","flac","aiff","ogg",
            "csv","tsv","md","json","xml","html","htm","rtf","yaml","log",
            "ppt","pptx","key","pages","numbers","epub",
            "swift","py","js","ts","c","h","java","sh",
            "dmg","pkg","tar","gz","tgz","7z","rar","ics","vcf","psd","ai","sketch","fig",""]
var fallback: [String] = []
print(String(format: "%-8@ %-34@ %@", "ext" as NSString, "app mimeType" as NSString, "UTType.preferredMIMEType"))
for e in exts {
    let a = appMime(e)
    let u = UTType(filenameExtension: e)?.preferredMIMEType ?? "nil"
    if a == "application/octet-stream" { fallback.append(e.isEmpty ? "(none)" : e) }
    let flag = (a == "application/octet-stream" && u != "nil" && u != a) ? "  <- app falls back" : ""
    print(String(format: "%-8@ %-34@ %@%@", (e.isEmpty ? "(none)" : e) as NSString, (a.count > 34 ? String(a.prefix(31)) + "..." : a) as NSString, u as NSString, flag as NSString))
}
print("\nfalls back to application/octet-stream (\(fallback.count) of \(exts.count) tested): \(fallback.joined(separator: " "))")
let mismatched = exts.filter { appMime($0) != "application/octet-stream" && UTType(filenameExtension: $0)?.preferredMIMEType != appMime($0) }
print("mapped but differs from UTType: \(mismatched.map { "\($0)=\(UTType(filenameExtension: $0)?.preferredMIMEType ?? "nil")" })")
