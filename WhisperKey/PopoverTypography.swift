import AppKit
import SwiftUI

enum PopoverTypography {
    static let base = Font.system(size: 13, weight: .regular)
    static let sectionTitle = Font.system(size: 13, weight: .medium)
    static let strongSectionTitle = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .medium)
    static let summary = Font.system(size: 15, weight: .medium)
    static let button = Font.system(size: 12, weight: .regular)

    static var primaryColor: Color {
        Color(nsColor: .labelColor)
    }

    static var secondaryColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }
}
