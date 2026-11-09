import 'package:flutter/material.dart';

import '../core/ui_prefs.dart';
import '../update/update_service.dart';

/// Version, where updates come from, and installing a newer one.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  UpdateService get u => UpdateService.instance;

  @override
  void initState() {
    super.initState();
    u.prepare(); // the installed version, even before any check ran
  }

  Future<void> _install(BuildContext context) async {
    if (!await u.canInstall()) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Zezwól na instalację'),
          content: const Text(
            'Android pyta, czy ta aplikacja może instalować aktualizacje. '
            'Włącz „Zezwalaj z tego źródła”, wróć tutaj i stuknij '
            '„Pobierz i zainstaluj” jeszcze raz. Każdą instalację i tak '
            'potwierdzasz osobno.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Otwórz ustawienia'),
            ),
          ],
        ),
      );
      if (go == true) await u.openInstallSettings();
      return;
    }
    await u.install();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final github = u.store == UpdateStore.github;
    return ListenableBuilder(
      listenable: Listenable.merge([u, UiPrefs.instance.autoUpdateCheck]),
      builder: (context, _) {
        final busy =
            u.phase == UpdatePhase.checking ||
            u.phase == UpdatePhase.downloading ||
            u.phase == UpdatePhase.installing;
        final notes = u.release?.notes ?? '';
        return Scaffold(
          appBar: AppBar(title: const Text('Aktualizacje')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: Text('Wersja ${u.current ?? '?'}'),
                subtitle: Text(
                  github
                      ? 'Źródło: wydania na GitHubie'
                      : 'Źródło: Google Play',
                ),
              ),
              if (github)
                SwitchListTile(
                  key: const ValueKey('update-auto'),
                  contentPadding: EdgeInsets.zero,
                  value: UiPrefs.instance.autoUpdateCheck.value,
                  onChanged: UiPrefs.instance.setAutoUpdateCheck,
                  title: const Text('Sprawdzaj automatycznie'),
                  subtitle: const Text(
                    'Raz dziennie pyta GitHub o najnowsze wydanie. GitHub '
                    'widzi wtedy twój adres IP; nic więcej nie jest '
                    'wysyłane.',
                  ),
                ),
              const SizedBox(height: 8),
              if (busy) ...[
                LinearProgressIndicator(value: u.progress),
                const SizedBox(height: 8),
              ],
              if (u.message != null)
                Text(u.message!, key: const ValueKey('update-status')),
              if (u.hasUpdate) ...[
                const SizedBox(height: 8),
                Text(
                  'Dostępna wersja ${u.newVersionLabel}',
                  key: const ValueKey('update-available'),
                  style: theme.textTheme.titleMedium,
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 240),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(notes, style: small),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              if (u.hasUpdate ||
                  u.phase == UpdatePhase.failed && u.release != null)
                FilledButton.icon(
                  key: const ValueKey('update-install'),
                  onPressed: busy ? null : () => _install(context),
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(
                    github
                        ? 'Pobierz i zainstaluj'
                        : 'Aktualizuj w Google Play',
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('update-check'),
                onPressed: busy ? null : u.check,
                icon: const Icon(Icons.refresh),
                label: const Text('Sprawdź teraz'),
              ),
              const SizedBox(height: 24),
              Text(
                github
                    ? 'Aktualizacja jest pobierana z GitHuba i sprawdzana '
                          'sumą SHA-256 z wydania. Android instaluje ją tylko, '
                          'jeśli jest podpisana tym samym kluczem co ta '
                          'aplikacja, i zawsze prosi o potwierdzenie. Twoje '
                          'rozmowy zostają.'
                    : 'Aktualizacje instaluje Google Play. Twoje rozmowy '
                          'zostają.',
                style: small,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Slim banner on the home screen when a newer version is available.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        if (!u.hasUpdate || u.bannerDismissed) return const SizedBox.shrink();
        return Card(
          key: const ValueKey('update-banner'),
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: Text('Nowa wersja ${u.newVersionLabel}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: u.dismissBanner,
                  child: const Text('Później'),
                ),
                FilledButton(onPressed: onOpen, child: const Text('Zobacz')),
              ],
            ),
          ),
        );
      },
    );
  }
}
