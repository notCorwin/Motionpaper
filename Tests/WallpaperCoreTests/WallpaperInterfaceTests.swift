import Foundation
import Testing
@testable import WallpaperCore

@Test
func missingFrameworkFailsWithoutLookingUpSymbols() {
    #expect(throws: NativeWallpaperError.missingFramework) {
        try WallpaperInterface.resolveMetadata(in: nil) { _, _ in
            Issue.record("An unavailable framework must not be queried")
            return nil
        }
    }
}

@Test(arguments: WallpaperInterface.requiredSymbols)
func anyMissingABISymbolRejectsTheInterface(missing: String) {
    let address = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    defer { address.deallocate() }
    #expect(throws: NativeWallpaperError.missingSymbols([missing])) {
        try WallpaperInterface.resolveMetadata(in: address) { _, symbol in
            symbol == missing ? nil : address
        }
    }
}

@Test
func allMissingSymbolsAreReportedTogether() {
    let address = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    defer { address.deallocate() }
    #expect(throws: NativeWallpaperError.missingSymbols(WallpaperInterface.requiredSymbols)) {
        try WallpaperInterface.resolveMetadata(in: address) { _, _ in nil }
    }
}

@Test
func completeInterfaceReturnsNativeMetadata() throws {
    let metadata = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    let method = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    defer { metadata.deallocate(); method.deallocate() }
    let resolved = try WallpaperInterface.resolveMetadata(in: method) { _, symbol in
        symbol == WallpaperInterface.metadataSymbol ? metadata : method
    }
    #expect(resolved == metadata)
}
