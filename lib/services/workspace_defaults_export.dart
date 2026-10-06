import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

/// Invokes validated developer tooling from an explicitly opened checkout.
Future<String?> exportWorkspaceDefaults(Map<String, dynamic> json) async {
  if (!kDebugMode) return 'Workspace export is available only in debug builds.';
  final root = Directory.current;
  final script = File('${root.path}/tool/workspace_codegen.dart');
  final target = File('${root.path}/lib/state/default_layouts.dart');
  if (!await script.exists() || !await target.exists()) {
    return 'Start the debug app from the repository root and retry.';
  }
  final temporary = await Directory.systemTemp.createTemp('trycatch_defaults_');
  try {
    final input = File('${temporary.path}/workspace.json');
    await input.writeAsString(jsonEncode(json));
    final result = await Process.run('dart', [
      script.path,
      input.path,
      target.path,
    ]);
    if (result.exitCode != 0) {
      return 'Generation failed: ${result.stdout}${result.stderr}';
    }
    return null;
  } catch (error) {
    return 'Could not run the workspace generator: $error';
  } finally {
    await temporary.delete(recursive: true);
  }
}
