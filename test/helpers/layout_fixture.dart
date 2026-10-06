import 'package:trycatch/state/layout_tree.dart';

// ── Factory ──────────────────────────────────────────────────────────────────

/// Builds a balanced alternating tree from an ordered tile list — used as
/// the factory default layout.
LayoutNode treeFromOrder(List<LeafNode> leaves) {
  LayoutNode build(List<LeafNode> list, int depth) {
    if (list.length == 1) return list.single;
    final mid = (list.length / 2).ceil();
    // Alternate: even depth → side-by-side, odd depth → stacked.
    final vertical = depth.isOdd;
    return SplitNode(
      vertical: vertical,
      ratio: 0.5,
      a: build(list.sublist(0, mid), depth + 1),
      b: build(list.sublist(mid), depth + 1),
    );
  }

  if (leaves.isEmpty) {
    throw ArgumentError('A layout fixture needs at least one leaf.');
  }
  return build(leaves, 0);
}
