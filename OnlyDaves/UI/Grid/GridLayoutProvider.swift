import UIKit

/// Builds the square-tile compositional layout for the grid (DESIGN.md §13.1).
enum GridLayoutProvider {
    /// Half the visible gutter: applied as an inset on every side of every item, so the
    /// gap between two neighbours is `gutter * 2` and tiles stay exactly square.
    static let gutter: CGFloat = 1

    static func make(columns: Int) -> UICollectionViewCompositionalLayout {
        let clamped = min(max(columns, AppSettings.minColumns), AppSettings.maxColumns)

        // The item claims 1/columns of the group width and the group repeats it to fill the
        // row. Sizing the item itself (rather than passing `count:`) is what actually
        // constrains tile width — with `repeatingSubitem:count:` a lone item in a section
        // stretches to the full group width.
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(clamped)),
            heightDimension: .fractionalHeight(1)))
        item.contentInsets = NSDirectionalEdgeInsets(top: gutter, leading: gutter,
                                                     bottom: gutter, trailing: gutter)

        // Height expressed as a fraction of the container *width* keeps rows square
        // regardless of column count.
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalWidth(1.0 / CGFloat(clamped)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .estimated(38)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top)
        header.pinToVisibleBounds = false
        section.boundarySupplementaryItems = [header]
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0)

        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 0
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    /// Point size of one tile, used to size image requests.
    static func tileSize(forWidth width: CGFloat, columns: Int) -> CGSize {
        let clamped = min(max(columns, AppSettings.minColumns), AppSettings.maxColumns)
        let side = max(1, width / CGFloat(clamped) - gutter * 2)
        return CGSize(width: side, height: side)
    }
}
