// Builds the v2 core (native/mls_poc, Rust) as the code asset that
// lib/p2pc_core.dart binds to. `_assetName` and that file's @DefaultAsset
// must move together.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

const _assetName = 'p2pc_core.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await RustBuilder(
      assetName: _assetName,
      cratePath: '../../native/mls_poc',
      buildMode: input.config.linkingEnabled
          ? BuildMode.release
          : BuildMode.debug,
    ).run(input: input, output: output);
  });
}
