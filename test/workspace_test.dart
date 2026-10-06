import 'helpers/layout_fixture.dart';

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/default_layouts.dart';
import 'package:trycatch/state/layout_tree.dart';
import 'package:trycatch/ui/tile_registry.dart';
import 'package:trycatch/state/workspace_models.dart';

Size _minOf(String tileType) => TileRegistry.minSizeOf(tileType);

LeafNode leaf(String tileType) =>
    LeafNode(tileId: 'w_$tileType', tileType: tileType);

void main() {
  group('layout tree', () {
    test('treeFromOrder keeps every widget exactly once', () {
      final root = treeFromOrder(['a', 'b', 'c', 'd', 'e'].map(leaf).toList());
      expect(root.leaves.map((l) => l.tileType), ['a', 'b', 'c', 'd', 'e']);
    });

    test('minSize combines children correctly per orientation', () {
      final minA = const Size(200, 120);
      final minB = const Size(240, 100);
      Size lookup(String id) => id == 'a' ? minA : minB;

      final horizontal = SplitNode(
        vertical: false,
        ratio: 0.5,
        a: leaf('a'),
        b: leaf('b'),
      );
      expect(horizontal.minSize(lookup).width, 200 + 240 + dividerWidth);
      expect(horizontal.minSize(lookup).height, 120);

      final vertical = SplitNode(
        vertical: true,
        ratio: 0.5,
        a: horizontal,
        b: leaf('b'),
      );
      expect(vertical.minSize(lookup).width, horizontal.minSize(lookup).width);
      expect(vertical.minSize(lookup).height, 120 + 100 + dividerWidth);
    });

    test('layoutTree fills the bounds and clamps ratios to minimums', () {
      // 200px minimum for the first child, 10px min width for everything.
      final root = SplitNode(
        vertical: false,
        ratio: 0.02, // would violate the 200px minimum
        a: leaf('map'),
        b: leaf('hall_sensor'),
      );

      final result = layoutTree(root, const Rect2(0, 0, 800, 300), _minOf);

      final a = result.leafRects['w_map']!;
      final b = result.leafRects['w_hall_sensor']!;
      expect(
        a.width,
        greaterThanOrEqualTo(TileRegistry.minSizeOf('map').width),
      );
      expect(
        b.width,
        greaterThanOrEqualTo(TileRegistry.minSizeOf('hall_sensor').width),
      );
      expect(a.left + a.width + dividerWidth, b.left);
      expect(result.dividers.length, 1);
    });

    test('insertLeaf splits the largest leaf', () {
      final tree = treeFromOrder([leaf('map'), leaf('stats')]);
      final result = insertLeaf(tree, 'fsm', 'new1', _minOf)!;

      final leaves = result.root.leaves;
      expect(leaves.length, 3);
      expect(leaves.where((l) => l.tileType == 'fsm').length, 1);
      expect(result.tileId, 'new1');
    });

    test('removeLeaf collapses its split', () {
      final root = SplitNode(
        vertical: false,
        ratio: 0.5,
        a: leaf('map'),
        b: SplitNode(
          vertical: true,
          ratio: 0.5,
          a: leaf('stats'),
          b: leaf('fsm'),
        ),
      );

      final after = removeLeaf(root, 'w_stats');
      expect(after!.leaves.map((l) => l.tileType).toSet(), {'map', 'fsm'});
      expect(removeLeaf(root, 'w_map')!.leaves.length, 2);
    });

    test('swapLeaves exchanges content, not structure', () {
      final original = treeFromOrder([leaf('map'), leaf('stats')]);
      final swapped = swapLeaves(original, 'w_map', 'w_stats')!;

      expect(swapped.leaves.length, 2);
      final types = swapped.leaves.map((l) => l.tileType).toSet();
      expect(types, {'map', 'stats'});
      // The leaf positions changed: map now sits where stats was.
      expect(swapped.leaves.first.tileType, 'stats');
    });

    test('splitLeaf splits the named tile, not the largest one', () {
      final root = treeFromOrder([leaf('map'), leaf('stats')]);
      final result = splitLeaf(root, 'w_stats', 'flight_3d', 'w_new', _minOf)!;

      expect(result.tileId, 'w_new');
      final types = result.root.leaves.map((l) => l.tileType).toSet();
      expect(types, {'map', 'stats', 'flight_3d'});

      // The new leaf sits next to stats inside the split that replaced it.
      final split = result.root as SplitNode;
      final subtreeTypes = <String>[
        ...split.a.leaves.map((l) => l.tileType),
        ...split.b.leaves.map((l) => l.tileType),
      ];
      expect(subtreeTypes, containsAll(['stats', 'flight_3d']));
    });

    test('splitLeaf returns null for an unknown widget id', () {
      final root = treeFromOrder([leaf('map'), leaf('stats')]);
      expect(splitLeaf(root, 'w_nope', 'stats', 'w_new', _minOf), isNull);
    });

    test('JSON round-trip preserves ids, ratios and leaves', () {
      final root = SplitNode(
        id: 'root1',
        vertical: true,
        ratio: 0.7,
        a: leaf('map'),
        b: leaf('fsm'),
      );

      final restored = LayoutNode.fromJson(root.toJson()) as SplitNode;
      expect(restored.id, 'root1');
      expect(restored.vertical, isTrue);
      expect(restored.ratio, 0.7);
      expect(restored.leaves.map((l) => l.tileType), ['map', 'fsm']);
    });

    test('leaf settings round-trip through JSON', () {
      const settings = {leafCameraModeKey: 'free'};
      final root = SplitNode(
        vertical: false,
        ratio: 0.5,
        a: LeafNode(tileId: 'w_3d', tileType: 'flight_3d', settings: settings),
        b: leaf('map'),
      );

      final restored = LayoutNode.fromJson(root.toJson()) as SplitNode;
      expect(restored.leaves.first.settings, settings);
      expect(restored.leaves.last.settings, isEmpty);
    });

    test('setLeafSettings updates only the target leaf', () {
      final root = treeFromOrder([leaf('map'), leaf('flight_3d')]);
      final next = setLeafSettings(root, 'w_flight_3d', {
        leafCameraModeKey: 'free',
      })!;
      final byId = {for (final l in next.leaves) l.tileId: l};
      expect(byId['w_flight_3d']!.settings[leafCameraModeKey], 'free');
      expect(byId['w_map']!.settings, isEmpty);
    });

    test('swap/retile/move carry the settings with the content', () {
      LeafNode camLeaf(String id) => LeafNode(
        tileId: id,
        tileType: 'flight_3d',
        settings: const {leafCameraModeKey: 'free'},
      );

      final swapped = swapLeaves(
        treeFromOrder([camLeaf('a'), leaf('map')]),
        'a',
        'w_map',
      )!;
      final swappedById = {for (final l in swapped.leaves) l.tileId: l};
      // Ids travel with the content, settings included.
      expect(swappedById['a']!.tileType, 'flight_3d');
      expect(swappedById['a']!.settings[leafCameraModeKey], 'free');
      expect(swappedById['w_map']!.tileType, 'map');
      expect(swappedById['w_map']!.settings, isEmpty);

      final retiled =
          retileLeaf(
                treeFromOrder([camLeaf('a'), leaf('map')]),
                'a',
                'flight_3d_sat',
              )!
              as SplitNode;
      expect(
        retiled.leaves
            .firstWhere((l) => l.tileId == 'a')
            .settings[leafCameraModeKey],
        'free',
      );

      final moved = moveLeafBeside(
        treeFromOrder([camLeaf('a'), leaf('map'), leaf('stats')]),
        'a',
        'w_stats',
        SplitDirection.left,
      );
      expect(
        moved.leaves
            .firstWhere((l) => l.tileId == 'a')
            .settings[leafCameraModeKey],
        'free',
      );
    });

    test('ignores unknown persisted fields', () {
      final workspace = Workspace.fromJson({
        'id': 'ws1',
        'name': 'Flight view',
        'root': {'type': 'leaf', 'tileId': 'a', 'tileType': 'map'},
        'placements': [
          {'tileId': 'b', 'tileType': 'stats', 'x': 5, 'y': 0, 'w': 3, 'h': 4},
        ],
      });

      expect(workspace.root, isNotNull);
      expect(workspace.root!.leaves.map((l) => l.tileType).toList(), ['map']);
    });
  });

  group('default layouts', () {
    test('use known tile types and lay out without empty leaves', () {
      final all = DefaultLayouts.all();
      expect(all, isNotEmpty);
      for (final ws in all) {
        expect(ws.name, isNotEmpty);
        expect(ws.root, isNotNull);
        for (final l in ws.root!.leaves) {
          expect(TileRegistry.byId(l.tileType), isNotNull);
        }
        // Layout is computable at a realistic dashboard size.
        final result = layoutTree(
          ws.root!,
          const Rect2(0, 0, 1800, 1000),
          _minOf,
        );
        expect(result.leafRects.length, ws.root!.leaves.length);
      }
    });
  });
}
