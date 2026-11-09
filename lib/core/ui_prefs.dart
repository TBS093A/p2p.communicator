import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-wide settings that are not tied to any room (they must not reveal
/// anything about rooms, since they are readable without a PIN): theme and
/// update checks.
class UiPrefs {
  UiPrefs._();
  static final UiPrefs instance = UiPrefs._();

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  /// Look for a new version on GitHub about once a day (GitHub build).
  final ValueNotifier<bool> autoUpdateCheck = ValueNotifier(true);

  /// When the last automatic check ran (ms since epoch), 0 = never.
  int lastUpdateCheck = 0;

  File? _file;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File(p.join(dir.path, 'ui_prefs.json'));
    try {
      final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      if (j['theme'] is String) {
        themeMode.value = ThemeMode.values.byName(j['theme'] as String);
      }
      if (j['autoUpdate'] is bool) {
        autoUpdateCheck.value = j['autoUpdate'] as bool;
      }
      if (j['lastUpdateCheck'] is int) {
        lastUpdateCheck = j['lastUpdateCheck'] as int;
      }
    } on Object {
      // First run or unreadable: keep the defaults.
    }
  }

  Future<void> _save() async => _file?.writeAsString(
    jsonEncode({
      'theme': themeMode.value.name,
      'autoUpdate': autoUpdateCheck.value,
      'lastUpdateCheck': lastUpdateCheck,
    }),
  );

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _save();
  }

  Future<void> setAutoUpdateCheck(bool on) async {
    autoUpdateCheck.value = on;
    await _save();
  }

  Future<void> markUpdateChecked(DateTime when) async {
    lastUpdateCheck = when.millisecondsSinceEpoch;
    await _save();
  }
}
