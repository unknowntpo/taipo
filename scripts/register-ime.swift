// Makes macOS aware of an installed input method bundle without enabling it.
// usage: swift scripts/register-ime.swift <path/to/Taipo.app>
import Carbon
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let status = TISRegisterInputSource(url)
print(status == noErr ? "registered" : "TISRegisterInputSource failed: \(status)")
exit(status == noErr ? 0 : 1)
