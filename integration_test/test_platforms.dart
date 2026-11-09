// Stand-ins for the system share sheet and file picker, so the DAST run can
// carry the migration file "from the old phone to the new one" through the
// app's real share_plus / file_selector calls.
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

/// Receives shared files the way Quick Share would: as a copy elsewhere, so
/// the sender deleting its own file afterwards does not matter.
class FakeShare extends SharePlatform {
  final _inbox = Directory.systemTemp.createTempSync('received');

  /// The copy of the last file the app shared.
  File? last;

  @override
  Future<ShareResult> share(ShareParams params) async {
    final sent = File(params.files!.first.path);
    last = await sent.copy(p.join(_inbox.path, p.basename(sent.path)));
    return const ShareResult('fake', ShareResultStatus.success);
  }
}

/// Returns [file] from the "Open file" picker.
class FakeFileSelector extends FileSelectorPlatform {
  File? file;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final f = file;
    return f == null ? null : XFile(f.path);
  }
}
