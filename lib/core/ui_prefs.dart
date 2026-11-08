import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-wide look that is not tied to any room (it must not reveal anything
/// about rooms, since it is readable without a PIN): only light/dark/system.
class UiPrefs {
  UiPrefs._();
  static final UiPrefs instance = UiPrefs._();

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);
  File? _file;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File(p.join(dir.path, 'ui_prefs.json'));
    try {
      final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      themeMode.value = ThemeMode.values.byName(j['theme'] as String);
    } on Object {
      // First run or unreadable: keep the default.
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _file?.writeAsString(jsonEncode({'theme': mode.name}));
  }
}
