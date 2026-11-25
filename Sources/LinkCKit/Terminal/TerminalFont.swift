import AppKit

/// The font linkC's terminals draw with: SF Mono, falling back to an installed Nerd Font so the
/// icons that prompts and terminal tools draw (folders, git branch, file types) show.
///
/// The system monospaced font is SF Mono, but CoreText ignores a fallback list on it, and its own
/// fallback never reaches a user-installed font for U+E000–U+F8FF, where most Nerd Font icons sit:
/// they drew as the LastResort `?` box. Terminal.app ships SF Mono as ordinary font files, and an
/// ordinary font honors a fallback list, so linkC registers those files for its own process.
public enum TerminalFont {
    /// Where Terminal.app keeps its copy of SF Mono.
    public static let sfMonoFolder = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts")

    /// The Nerd Font family to draw icons with: the symbols-only font first, then a Mono family,
    /// which fits each icon in one cell, then any other. A family counts by its long name ("… Nerd
    /// Font") or its short one ("… NF", such as MesloLGS NF, which Powerlevel10k installs).
    /// Proportional families (Propo, NFP) never fit a cell.
    public static func nerdFamily(in families: [String]) -> String? {
        let nerd = families.filter { isNerd($0) && !$0.hasSuffix("Propo") && !$0.hasSuffix(" NFP") }
        return nerd.first { $0 == "Symbols Nerd Font Mono" }
            ?? nerd.first { $0.hasSuffix("Nerd Font Mono") || $0.hasSuffix(" NFM") }
            ?? nerd.first
    }

    private static func isNerd(_ family: String) -> Bool {
        family.contains("Nerd Font") || family.range(of: #"(^| )NF[MP]?$"#, options: .regularExpression) != nil
    }

    /// The Private Use Areas, where Nerd Font icons sit. Only these reach the Nerd Font: any other
    /// character SF Mono lacks (a spinner frame, a prompt arrow) keeps the system's own fallback.
    private static let iconRanges: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0xE000)!...Unicode.Scalar(0xF8FF)!)
        set.insert(charactersIn: Unicode.Scalar(0xF0000)!...Unicode.Scalar(0x10FFFD)!)
        return set
    }()

    /// SF Mono at `size`, falling back to the Nerd Font picked from `families`. When there is no
    /// Nerd Font or SF Mono cannot be loaded from `sfMonoFolder`, the system monospaced font, and
    /// why Nerd Font icons will not draw.
    public static func make(size: CGFloat, sfMonoFolder: URL, families: [String]) -> (font: NSFont, problem: String?) {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let family = nerdFamily(in: families) else {
            return (system, "no Nerd Font is installed, so Nerd Font icons draw as boxes")
        }
        do {
            try registerSFMono(from: sfMonoFolder)
        } catch {
            return (system, "SF Mono could not be loaded from \(sfMonoFolder.path), so Nerd Font icons draw as boxes: \(error)")
        }
        let descriptor = NSFontDescriptor(name: sfMonoName, size: size)
            .addingAttributes([.cascadeList: [NSFontDescriptor(fontAttributes: [.family: family, .characterSet: iconRanges])]])
        guard let font = NSFont(descriptor: descriptor, size: size), font.fontName == sfMonoName else {
            return (system, "\(sfMonoName) is not available after loading \(sfMonoFolder.path), so Nerd Font icons draw as boxes")
        }
        return (font, nil)
    }

    private static let sfMonoName = "SFMono-Regular"

    private struct NoSFMonoFiles: Error, CustomStringConvertible {
        var description: String { "the folder holds no SF-Mono-*.otf files" }
    }

    /// Registers every SF Mono style in `folder` for this process. A style that is already
    /// registered, by an earlier call or because SF Mono is installed on this Mac, is fine.
    private static func registerSFMono(from folder: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SF-Mono-") && $0.pathExtension == "otf" }
        guard !files.isEmpty else { throw NoSFMonoFiles() }
        for file in files {
            var error: Unmanaged<CFError>?
            guard !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) else { continue }
            guard let error = error?.takeRetainedValue() else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            let code = CFErrorGetCode(error)
            if code == CTFontManagerError.alreadyRegistered.rawValue || code == CTFontManagerError.duplicatedName.rawValue {
                continue
            }
            throw error
        }
    }
}
