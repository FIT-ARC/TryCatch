/// Workspace layout as a KD-tree — hyprland-style tiling.
///
/// Internal nodes split their rectangle horizontally (left|right) or
/// vertically (top/bottom) at a draggable [SplitNode.ratio]; leaves are
/// tiles. Split directions alternate with depth so new splits rotate
/// orientation, and every tile type declares a minimum pixel size that the
/// divider drag respects.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import '../foundation/app_log.dart';
import '../foundation/ids.dart';

/// Per-tile-type minimum size in logical pixels (from `TileRegistry`).
typedef MinSizeLookup = Size Function(String tileType);

// ── Model ────────────────────────────────────────────────────────────────────

sealed class LayoutNode {
  const LayoutNode();

  /// All tile ids in this subtree, in layout order.
  List<LeafNode> get leaves;

  /// Minimum size this subtree can be squeezed to, in logical pixels.
  Size minSize(MinSizeLookup minOf);

  Map<String, dynamic> toJson();

  static LayoutNode fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'split' => SplitNode(
          id: json['id'] as String?,
          vertical: json['vertical'] as bool? ?? false,
          ratio: (json['ratio'] as num?)?.toDouble() ?? 0.5,
          a: LayoutNode.fromJson(json['a'] as Map<String, dynamic>),
          b: LayoutNode.fromJson(json['b'] as Map<String, dynamic>),
        ),
      'leaf' => LeafNode(
          tileId: json['tileId'] as String,
          tileType: json['tileType'] as String,
          settings: (json['settings'] as Map?)
                  ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
              const {},
        ),
      _ => throw FormatException('Unknown layout node type: $type'),
    };
  }
}

/// Internal node: divides the available rect into two children.
class SplitNode extends LayoutNode {
  /// Stable identity for ratio updates across immutable tree rebuilds.
  final String id;

  /// `true` → children stacked top/bottom; `false` → side by side.
  final bool vertical;

  /// Fraction of the extent given to the first child (0..1).
  final double ratio;

  final LayoutNode a;
  final LayoutNode b;

  SplitNode({
    required this.vertical,
    required this.ratio,
    required this.a,
    required this.b,
    String? id,
  }) : id = id ?? _nextSplitId();

  /// Rebuilds this node with a new ratio (divider drag).
  SplitNode withRatio(double newRatio) => SplitNode(
        id: id,
        vertical: vertical,
        ratio: newRatio,
        a: a,
        b: b,
      );

  SplitNode withChildren({LayoutNode? a, LayoutNode? b}) => SplitNode(
        id: id,
        vertical: vertical,
        ratio: ratio,
        a: a ?? this.a,
        b: b ?? this.b,
      );

  /// Rebuilds this node with the split running along the other axis. The
  /// ratio carries over (it is a fraction of the new extent).
  SplitNode flipOrientation() => SplitNode(
        id: id,
        vertical: !vertical,
        ratio: ratio,
        a: a,
        b: b,
      );

  @override
  List<LeafNode> get leaves => [...a.leaves, ...b.leaves];

  @override
  Size minSize(MinSizeLookup minOf) {
    final sa = a.minSize(minOf);
    final sb = b.minSize(minOf);
    return vertical
        ? Size(
            math.max(sa.width, sb.width), sa.height + sb.height + dividerWidth)
        : Size(
            sa.width + sb.width + dividerWidth, math.max(sa.height, sb.height));
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'split',
        'id': id,
        'vertical': vertical,
        'ratio': ratio,
        'a': a.toJson(),
        'b': b.toJson(),
      };
}

/// Unique split ids from the shared [Ids] generator.
String _nextSplitId() => Ids.next('s');

/// Leaf: one tile instance.
class LeafNode extends LayoutNode {
  final String tileId;
  final String tileType;

  /// Per-tile settings bag (string map), e.g. the 3D flight tiles' camera
  /// mode. Persisted with the workspace; tiles that need a setting read it
  /// and report changes back so the save file follows the live UI.
  final Map<String, String> settings;

  LeafNode({
    required this.tileId,
    required this.tileType,
    Map<String, String> settings = const {},
  }) : settings = Map.unmodifiable(settings);

  /// Copy with a replaced settings bag.
  LeafNode withSettings(Map<String, String> settings) => LeafNode(
        tileId: tileId,
        tileType: tileType,
        settings: settings,
      );

  @override
  List<LeafNode> get leaves => [this];

  @override
  Size minSize(MinSizeLookup minOf) => minOf(tileType);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'leaf',
        'tileId': tileId,
        'tileType': tileType,
        'settings': settings,
      };
}

/// Visual thickness of the divider between split children.
const double dividerWidth = 8;

// ── Geometry ─────────────────────────────────────────────────────────────────

/// A rectangle in logical pixels.
class Rect2 {
  final double left, top, width, height;

  const Rect2(this.left, this.top, this.width, this.height);
}

/// Result of laying the tree out: leaf → its rect, plus every divider that
/// can be dragged.
class LayoutResult {
  final Map<String, Rect2> leafRects;
  final List<DividerHandle> dividers;

  const LayoutResult({required this.leafRects, required this.dividers});
}

/// A draggable divider between two subtrees.
class DividerHandle {
  final String nodeId;
  final Rect2 hitArea;

  /// Orientation of the split the divider belongs to.
  final bool vertical;

  /// Full extent (px) available to the two children along the split axis.
  final double extent;

  /// The clamped ratio actually used for this layout (for drag deltas).
  final double ratio;

  const DividerHandle({
    required this.nodeId,
    required this.hitArea,
    required this.vertical,
    required this.extent,
    required this.ratio,
  });
}

/// Lays out the tree inside [bounds], clamping ratios so both sides of every
/// split keep their minimum sizes.
LayoutResult layoutTree(
  LayoutNode root,
  Rect2 bounds,
  MinSizeLookup minOf,
) {
  final leafRects = <String, Rect2>{};
  final dividers = <DividerHandle>[];
  _layoutNode(root, bounds, minOf, leafRects, dividers);
  return LayoutResult(leafRects: leafRects, dividers: dividers);
}

void _layoutNode(
  LayoutNode node,
  Rect2 bounds,
  MinSizeLookup minOf,
  Map<String, Rect2> leafRects,
  List<DividerHandle> dividers,
) {
  if (node is LeafNode) {
    leafRects[node.tileId] = bounds;
    return;
  }
  if (node is! SplitNode) return;

  final minA = node.a.minSize(minOf);
  final minB = node.b.minSize(minOf);

  final extent = node.vertical ? bounds.height : bounds.width;
  final minAExtent = node.vertical ? minA.height : minA.width;
  final minBExtent = node.vertical ? minB.height : minB.width;

  final usable = (extent - dividerWidth).clamp(0.0, double.infinity);
  final ratio = _clampRatio(node.ratio, usable, minAExtent, minBExtent);

  final firstExtent = ratio * usable;
  final secondExtent = usable - firstExtent;

  final dividerHit = node.vertical
      ? Rect2(bounds.left, bounds.top + firstExtent, bounds.width, dividerWidth)
      : Rect2(bounds.left + firstExtent, bounds.top, dividerWidth, bounds.height);

  dividers.add(DividerHandle(
    nodeId: node.id,
    hitArea: dividerHit,
    vertical: node.vertical,
    extent: usable,
    ratio: ratio,
  ));

  if (node.vertical) {
    _layoutNode(node.a,
        Rect2(bounds.left, bounds.top, bounds.width, firstExtent), minOf,
        leafRects, dividers);
    _layoutNode(node.b,
        Rect2(bounds.left, bounds.top + firstExtent + dividerWidth, bounds.width, secondExtent),
        minOf, leafRects, dividers);
  } else {
    _layoutNode(node.a,
        Rect2(bounds.left, bounds.top, firstExtent, bounds.height), minOf,
        leafRects, dividers);
    _layoutNode(node.b,
        Rect2(bounds.left + firstExtent + dividerWidth, bounds.top, secondExtent, bounds.height),
        minOf, leafRects, dividers);
  }
}

/// Clamps [ratio] so both children keep their minimum extents.
double _clampRatio(
  double ratio,
  double usable,
  double minFirst,
  double minSecond,
) {
  if (usable <= 0) return 0.5;
  final lo = minFirst / usable;
  final hi = 1 - minSecond / usable;
  if (lo > hi) return 0.5; // children can't both fit — center the divider
  return ratio.clamp(lo, hi);
}

// ── Single-node updates + snapping (pure) ────────────────────────────────────

/// Updates the ratio of the split with [nodeId] (depth-first, first match).
LayoutNode? setSplitRatio(LayoutNode? node, String nodeId, double ratio) {
  if (node == null) return null;
  if (node is SplitNode) {
    if (node.id == nodeId) return node.withRatio(ratio);
    final left = setSplitRatio(node.a, nodeId, ratio);
    if (!identical(left, node.a)) {
      return node.withChildren(a: left, b: node.b);
    }
    final right = setSplitRatio(node.b, nodeId, ratio);
    if (!identical(right, node.b)) {
      return node.withChildren(a: node.a, b: right);
    }
    return node;
  }
  return node;
}

/// Flips the orientation of the *first* split with [nodeId] (depth-first).
LayoutNode? flipSplitOrientation(LayoutNode? node, String nodeId) {
  if (node == null) return null;
  if (node is SplitNode) {
    if (node.id == nodeId) return node.flipOrientation();
    final left = flipSplitOrientation(node.a, nodeId);
    if (!identical(left, node.a)) {
      return node.withChildren(a: left, b: node.b);
    }
    final right = flipSplitOrientation(node.b, nodeId);
    if (!identical(right, node.b)) {
      return node.withChildren(a: node.a, b: right);
    }
    return node;
  }
  return node;
}

/// PowerPoint-style snap for a divider drag.
///
/// Candidates, in priority order:
/// 1. alignment with another parallel divider's absolute position
///    (e.g. the Highlights|Events split lining up with the
///    Max-alt|Nose-cone split below it),
/// 2. classic fractions of the split extent: 25% / 33% / 50% / 66% / 75%.
///
/// Returns the snapped ratio plus a short label for the drag badge
/// (`'Aligned'`, `'50%'`, `'⅓'` …), or `null` when nothing is close enough.
/// [snapPx] is the grab radius in logical pixels.
({double ratio, String label})? snapDividerRatio({
  required double rawRatio,
  required DividerHandle dragged,
  required List<DividerHandle> all,
  double snapPx = 8,
}) {
  if (dragged.extent <= 0 || snapPx <= 0) return null;
  final pxPerRatio = dragged.extent;

  // Absolute pixel position of the dragged divider's parent origin, derived
  // from its current hit area so alignment compares absolute coordinates.
  final origin = dragged.vertical
      ? dragged.hitArea.top - dragged.ratio * dragged.extent
      : dragged.hitArea.left - dragged.ratio * dragged.extent;
  final rawPos = origin + rawRatio * dragged.extent;

  // 1. Align with parallel dividers.
  double bestSigned = 0;
  var best = snapPx;
  for (final other in all) {
    if (other.nodeId == dragged.nodeId) continue;
    if (other.vertical != dragged.vertical) continue;
    final otherPos = dragged.vertical ? other.hitArea.top : other.hitArea.left;
    final delta = otherPos - rawPos;
    if (delta.abs() <= best) {
      best = delta.abs();
      bestSigned = delta;
    }
  }
  if (best < snapPx) {
    final ratio =
        ((rawPos + bestSigned - origin) / pxPerRatio).clamp(0.02, 0.98);
    return (ratio: ratio, label: 'Aligned');
  }

  // 2. Fractions.
  final fractions = <({double ratio, String label})>[
    (ratio: 0.5, label: '50%'),
    (ratio: 1 / 3, label: '⅓'),
    (ratio: 2 / 3, label: '⅔'),
    (ratio: 0.25, label: '25%'),
    (ratio: 0.75, label: '75%'),
  ];
  var bestFractionRatio = -1.0;
  var bestFractionLabel = '';
  var bestFractionDelta = snapPx;
  for (final entry in fractions) {
    final delta = ((entry.ratio - rawRatio).abs()) * pxPerRatio;
    if (delta <= bestFractionDelta) {
      bestFractionDelta = delta;
      bestFractionRatio = entry.ratio;
      bestFractionLabel = entry.label;
    }
  }
  if (bestFractionRatio >= 0) {
    return (ratio: bestFractionRatio, label: bestFractionLabel);
  }
  return null;
}

// ── Mutations (pure) ─────────────────────────────────────────────────────────

/// Inserts a new leaf for [tileType] by splitting the largest-area leaf.
///
/// The split orientation is chosen from the target leaf's shape (wide leaf →
/// side-by-side, tall leaf → stacked), keeping the tiling balanced.
({LayoutNode root, String tileId})? insertLeaf(
  LayoutNode? root,
  String tileType,
  String newTileId,
  MinSizeLookup minOf,
) {
  if (root == null) {
    return (root: LeafNode(tileId: newTileId, tileType: tileType), tileId: newTileId);
  }

  // Find the largest-area leaf and its parent path.
  final leavesWithRects = <(LeafNode, double)>[];
  _collectAreas(root, boundsFor(root, minOf), minOf, leavesWithRects);
  if (leavesWithRects.isEmpty) return null;

  leavesWithRects.sort((x, y) => y.$2.compareTo(x.$2));
  final target = leavesWithRects.first.$1;

  final newLeaf = LeafNode(tileId: newTileId, tileType: tileType);
  final result = _splitLeaf(root, target.tileId, newLeaf, minOf);
  return (root: result, tileId: newTileId);
}

/// Splits the leaf [tileId] into two, placing [newTileId] with [tileType]
/// beside it. Returns `null` when [tileId] is not in the tree.
({LayoutNode root, String tileId})? splitLeaf(
  LayoutNode? root,
  String tileId,
  String tileType,
  String newTileId,
  MinSizeLookup minOf,
) {
  if (root == null) return null;
  if (!root.leaves.any((l) => l.tileId == tileId)) return null;
  final newLeaf = LeafNode(tileId: newTileId, tileType: tileType);
  return (
    root: _splitLeaf(root, tileId, newLeaf, minOf),
    tileId: newTileId,
  );
}

/// Rough reference bounds used only to rank leaves by area.
Rect2 boundsFor(LayoutNode root, MinSizeLookup minOf) {
  final min = root.minSize(minOf);
  // Give the tree lots of room so relative proportions decide "largest".
  return Rect2(0, 0, math.max(min.width, 1200), math.max(min.height, 800));
}

void _collectAreas(
  LayoutNode node,
  Rect2 bounds,
  MinSizeLookup minOf,
  List<(LeafNode, double)> out,
) {
  if (node is LeafNode) {
    out.add((node, bounds.width * bounds.height));
    return;
  }
  if (node is! SplitNode) return;

  final minA = node.a.minSize(minOf);
  final minB = node.b.minSize(minOf);
  final extent = node.vertical ? bounds.height : bounds.width;
  final minAExtent = node.vertical ? minA.height : minA.width;
  final minBExtent = node.vertical ? minB.height : minB.width;
  final usable = (extent - dividerWidth).clamp(0.0, double.infinity);
  final ratio = _clampRatio(node.ratio, usable, minAExtent, minBExtent);
  final firstExtent = ratio * usable;
  final secondExtent = usable - firstExtent;

  if (node.vertical) {
    _collectAreas(node.a, Rect2(bounds.left, bounds.top, bounds.width, firstExtent), minOf, out);
    _collectAreas(node.b, Rect2(bounds.left, bounds.top + firstExtent + dividerWidth, bounds.width, secondExtent), minOf, out);
  } else {
    _collectAreas(node.a, Rect2(bounds.left, bounds.top, firstExtent, bounds.height), minOf, out);
    _collectAreas(node.b, Rect2(bounds.left + firstExtent + dividerWidth, bounds.top, secondExtent, bounds.height), minOf, out);
  }
}

/// Replaces the leaf with [tileId] by a split containing it and [newLeaf].
LayoutNode _splitLeaf(
  LayoutNode node,
  String tileId,
  LeafNode newLeaf,
  MinSizeLookup minOf,
) {
  if (node is LeafNode) {
    if (node.tileId != tileId) return node;
    // Alternate orientation based on shape: wide → side-by-side.
    final rect = _lastKnownRects[tileId];
    final vertical = rect != null ? rect.height > rect.width : false;
    return SplitNode(vertical: vertical, ratio: 0.5, a: node, b: newLeaf);
  }
  if (node is SplitNode) {
    return node.withChildren(
      a: _splitLeaf(node.a, tileId, newLeaf, minOf),
      b: _splitLeaf(node.b, tileId, newLeaf, minOf),
    );
  }
  return node;
}

/// Remembered rects from the last real layout, used to pick split orientation
/// when inserting. Cleared/re-filled by the renderer each frame.
final Map<String, Rect2> _lastKnownRects = {};

/// Call from the renderer so insertions can pick a sensible split direction.
void updateKnownRects(LayoutResult result) {
  _lastKnownRects
    ..clear()
    ..addAll(result.leafRects);
}

/// Removes the leaf with [tileId]; a parent split with a single remaining
/// child collapses into that child.
LayoutNode? removeLeaf(LayoutNode? root, String tileId) {
  if (root == null) return null;
  if (root is LeafNode) {
    return root.tileId == tileId ? null : root;
  }
  if (root is! SplitNode) return null;

  final newA = removeLeaf(root.a, tileId);
  final newB = removeLeaf(root.b, tileId);

  if (newA == null) return newB;
  if (newB == null) return newA;
  return root.withChildren(a: newA, b: newB);
}

/// Replaces the tile type of the leaf with [tileId], keeping its id (and
/// therefore its position) stable. Settings travel with the leaf.
LayoutNode? retileLeaf(LayoutNode? root, String tileId, String newType) {
  if (root == null) return null;
  if (root is LeafNode) {
    return root.tileId == tileId
        ? LeafNode(
            tileId: root.tileId,
            tileType: newType,
            settings: root.settings,
          )
        : root;
  }
  if (root is SplitNode) {
    return root.withChildren(
      a: retileLeaf(root.a, tileId, newType),
      b: retileLeaf(root.b, tileId, newType),
    );
  }
  return root;
}

/// Replaces the settings bag of the leaf with [tileId], keeping its id,
/// type and position stable.
LayoutNode? setLeafSettings(
    LayoutNode? root, String tileId, Map<String, String> settings) {
  if (root == null) return null;
  if (root is LeafNode) {
    return root.tileId == tileId ? root.withSettings(settings) : root;
  }
  if (root is SplitNode) {
    return root.withChildren(
      a: setLeafSettings(root.a, tileId, settings),
      b: setLeafSettings(root.b, tileId, settings),
    );
  }
  return root;
}

/// Swaps the *content* of two leaves (drag a tile onto another).
LayoutNode? swapLeaves(LayoutNode? root, String tileId, String otherId) {
  if (root == null || tileId == otherId) return root;

  LeafNode? first;
  LeafNode? second;
  void collect(LayoutNode node) {
    if (node is LeafNode) {
      if (node.tileId == tileId) first = node;
      if (node.tileId == otherId) second = node;
    } else if (node is SplitNode) {
      collect(node.a);
      collect(node.b);
    }
  }

  collect(root);
  if (first == null || second == null) return root;
  final source = second!;
  final target = first!;

  LayoutNode replace(LayoutNode node) {
    if (node is LeafNode) {
      if (node.tileId == tileId) {
        return LeafNode(
            tileId: source.tileId,
            tileType: source.tileType,
            settings: source.settings);
      }
      if (node.tileId == otherId) {
        return LeafNode(
            tileId: target.tileId,
            tileType: target.tileType,
            settings: target.settings);
      }
      return node;
    }
    if (node is SplitNode) {
      return node.withChildren(a: replace(node.a), b: replace(node.b));
    }
    return node;
  }

  return replace(root);
}

// ── Directional splits + merge (pure) ────────────────────────────────────────

/// Which child subtree to keep when collapsing a split.
enum KeepSide { a, b }

/// The edge relative to an existing leaf where a new tile is inserted.
enum SplitDirection { left, right, top, bottom }

/// Returns the leaf tile-ids belonging to each child of the split [nodeId].
/// Returns empty sets when [nodeId] is not found — used by the group-highlight
/// overlay to tint tiles that share a divider.
({Set<String> a, Set<String> b}) splitGroupLeaves(
  LayoutNode? root,
  String nodeId,
) {
  if (root == null) return (a: {}, b: {});
  if (root is SplitNode) {
    if (root.id == nodeId) {
      return (
        a: root.a.leaves.map((l) => l.tileId).toSet(),
        b: root.b.leaves.map((l) => l.tileId).toSet(),
      );
    }
    final inA = splitGroupLeaves(root.a, nodeId);
    if (inA.a.isNotEmpty || inA.b.isNotEmpty) return inA;
    return splitGroupLeaves(root.b, nodeId);
  }
  return (a: {}, b: {});
}

/// Collapses the split [nodeId], keeping the [keepSide] subtree and
/// discarding the other. Returns [root] unchanged when [nodeId] is not found.
LayoutNode mergeAtDivider(LayoutNode root, String nodeId, KeepSide keepSide) {
  if (root is SplitNode) {
    if (root.id == nodeId) return keepSide == KeepSide.a ? root.a : root.b;
    final newA = mergeAtDivider(root.a, nodeId, keepSide);
    if (!identical(newA, root.a)) return root.withChildren(a: newA);
    final newB = mergeAtDivider(root.b, nodeId, keepSide);
    if (!identical(newB, root.b)) return root.withChildren(b: newB);
  }
  return root;
}

/// Inserts a new leaf ([tileType] / [newId], plus optional [settings])
/// directly beside [targetId] in the given [direction].
///   left / right  → side-by-side split (vertical: false)
///   top  / bottom → stacked split       (vertical: true)
/// No-op (returns [root] unchanged) when [targetId] is not in the tree.
LayoutNode insertBesideLeaf(
  LayoutNode root,
  String targetId,
  SplitDirection direction,
  String tileType,
  String newId, {
  Map<String, String> settings = const {},
}) {
  if (root is LeafNode) {
    if (root.tileId != targetId) return root;
    final newLeaf =
        LeafNode(tileId: newId, tileType: tileType, settings: settings);
    final vertical =
        direction == SplitDirection.top || direction == SplitDirection.bottom;
    final newFirst =
        direction == SplitDirection.left || direction == SplitDirection.top;
    return SplitNode(
      vertical: vertical,
      ratio: 0.5,
      a: newFirst ? newLeaf : root,
      b: newFirst ? root : newLeaf,
    );
  }
  if (root is SplitNode) {
    final newA = insertBesideLeaf(root.a, targetId, direction, tileType, newId,
        settings: settings);
    if (!identical(newA, root.a)) return root.withChildren(a: newA);
    final newB = insertBesideLeaf(root.b, targetId, direction, tileType, newId,
        settings: settings);
    if (!identical(newB, root.b)) return root.withChildren(b: newB);
  }
  return root;
}

/// Removes [sourceId] from the tree and re-inserts it beside [targetId] in
/// [direction]. Settings travel with the moved leaf. This is the
/// "restructure drag" operation.
/// No-ops: source == target, source is the sole leaf, target not found.
LayoutNode moveLeafBeside(
  LayoutNode root,
  String sourceId,
  String targetId,
  SplitDirection direction,
) {
  if (sourceId == targetId) return root;
  LeafNode? source;
  void findSource(LayoutNode n) {
    if (n is LeafNode && n.tileId == sourceId) {
      source = n;
    } else if (n is SplitNode) {
      findSource(n.a);
      findSource(n.b);
    }
  }
  findSource(root);
  if (source == null) return root;
  final afterRemove = removeLeaf(root, sourceId);
  if (afterRemove == null) return root; // sole leaf — can't leave the tree empty
  return insertBesideLeaf(
    afterRemove, targetId, direction, source!.tileType, source!.tileId,
    settings: source!.settings,
  );
}

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
    AppLog.warn('layout_tree: building tree from empty list');
  }
  return build(leaves, 0);
}
