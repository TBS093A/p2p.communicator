import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import '../core/veilid_node.dart';
import '../room/dht.dart';
import 'global_profile.dart';

/// Global profiles of everyone we share a public room with: opened and
/// watched once each, however many rooms they appear in. Feeds the user bar
/// on the home screen and the names/avatars inside public rooms.
class ProfileDirectory extends ChangeNotifier {
  ProfileDirectory({required this.myKey});

  /// Our own profile record key: never watched (we write it), but known so
  /// the user bar can leave us out.
  final String myKey;

  final Map<String, GlobalProfile> _profiles = {};
  final Map<String, RecordKey> _open = {};
  final Set<String> _opening = {};
  StreamSubscription<VeilidUpdate>? _sub;
  Timer? _poll;
  Timer? _presenceTick;
  bool _closed = false;

  GlobalProfile? operator [](String key) => _profiles[key];

  /// Everyone else, online first, then by name.
  List<MapEntry<String, GlobalProfile>> get others {
    final now = DateTime.now();
    final list = _profiles.entries.where((e) => e.key != myKey).toList()
      ..sort((a, b) {
        final pa = a.value.presenceAt(now) == Presence.offline ? 1 : 0;
        final pb = b.value.presenceAt(now) == Presence.offline ? 1 : 0;
        if (pa != pb) return pa - pb;
        return a.value.name.toLowerCase().compareTo(b.value.name.toLowerCase());
      });
    return list;
  }

  void start() {
    _sub = VeilidNode.instance.updates.listen(_onUpdate);
    _poll = Timer.periodic(GlobalProfile.heartbeat, (_) => refreshAll());
    // Presence is time-based: re-evaluate "offline" even with no new data.
    _presenceTick = Timer.periodic(
      const Duration(seconds: 30),
      (_) => notifyListeners(),
    );
  }

  /// Starts following [key] (idempotent).
  void track(String key) {
    if (key == myKey || _open.containsKey(key) || _opening.contains(key)) {
      return;
    }
    _opening.add(key);
    unawaited(_track(key));
  }

  Future<void> _track(String key) async {
    try {
      final rk = RecordKey.fromString(key);
      await Dht.retry(() => Dht.rc.openDHTRecord(rk));
      await Dht.rc.watchDHTValues(rk);
      _open[key] = rk;
      await _fetch(key, rk);
    } on Object catch (e) {
      debugPrint('[profiles] cannot follow a profile: $e');
    } finally {
      _opening.remove(key);
    }
  }

  Future<void> _fetch(String key, RecordKey rk) async {
    final j = await Dht.getJson(rk, 0);
    if (j == null || _closed) return;
    _profiles[key] = GlobalProfile.fromJson(j);
    notifyListeners();
  }

  Future<void> refreshAll() async {
    for (final e in _open.entries.toList()) {
      try {
        await _fetch(e.key, e.value);
      } on Object catch (err) {
        debugPrint('[profiles] refresh failed: $err');
      }
    }
  }

  void _onUpdate(VeilidUpdate u) {
    if (u is! VeilidUpdateValueChange || _closed) return;
    for (final e in _open.entries) {
      if (e.value.opaque == u.key.opaque) {
        unawaited(_fetch(e.key, e.value));
        return;
      }
    }
  }

  /// Our own profile, as last written (shown like everyone else's).
  void setMine(GlobalProfile p) {
    _profiles[myKey] = p;
    notifyListeners();
  }

  Future<void> close() async {
    _closed = true;
    _poll?.cancel();
    _presenceTick?.cancel();
    await _sub?.cancel();
    for (final k in _open.values) {
      await Dht.close(k);
    }
  }
}
