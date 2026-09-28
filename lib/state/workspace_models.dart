import './layout_tree.dart';

import '../foundation/ids.dart';

/// Leaf settings key carrying the 3D flight tiles' camera mode
/// ([FlightCameraMode.name], e.g. `'orbit'`). Lives in the state layer so
/// both the persistence format and the UI scope agree on the vocabulary.
const String leafCameraModeKey = 'cameraMode';

/// A named workspace: an independent tile arrangement (a layout tree).
class Workspace {
  final String id;
  final String name;

  /// Root of the layout tree; `null` while the workspace is empty.
  final LayoutNode? root;

  const Workspace({
    required this.id,
    required this.name,
    required this.root,
  });

  Workspace copyWith({String? name, LayoutNode? root, bool clearRoot = false}) =>
      Workspace(
        id: id,
        name: name ?? this.name,
        root: clearRoot ? null : (root ?? this.root),
      );

  /// The tile leaf with [tileId], or `null`.
  LeafNode? leafOf(String tileId) {
    for (final leaf in root?.leaves ?? const <LeafNode>[]) {
      if (leaf.tileId == tileId) return leaf;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'root': root?.toJson(),
      };

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final rootJson = json['root'];
    final LayoutNode? root = rootJson == null
        ? null
        : LayoutNode.fromJson(rootJson as Map<String, dynamic>);

    return Workspace(
      id: json['id'] as String,
      name: json['name'] as String,
      root: root,
    );
  }
}

/// Monotonic id generator. Single owner is [Ids]; this alias keeps call
/// sites reading until they migrate to `Ids.next()`.
abstract final class GridIds {
  static String next() => Ids.next();
}
