import Foundation

public enum UpdateDownloadCleanup {
    /// Remove only images written by the previous persistent download cache.
    /// The same directory also contains installation failure reports.
    public static func removeLegacyImages(in directory: URL) throws {
        let manager = FileManager.default
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        for entry in entries where isLegacyImageName(entry.lastPathComponent) {
            do {
                let attributes = try manager.attributesOfItem(atPath: entry.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                try manager.removeItem(at: entry)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Another process may have already removed the image.
                continue
            }
        }
    }

    private static func isLegacyImageName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 109, bytes[40] == 45,
              bytes.suffix(4).elementsEqual(".dmg".utf8) else { return false }
        func isHex(_ value: UInt8) -> Bool {
            (48...57).contains(value) || (97...102).contains(value)
        }
        return bytes[..<40].allSatisfy(isHex) && bytes[41..<105].allSatisfy(isHex)
    }
}
