import 'package:flutter/material.dart';
import 'package:veilid/veilid.dart';

import '../../core/veilid_node.dart';

/// Tiny network status: grey = offline, amber = connecting, green = online.
class NetworkDot extends StatelessWidget {
  const NetworkDot({super.key, this.showLabel = true});

  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AttachmentState>(
      valueListenable: VeilidNode.instance.attachment,
      builder: (context, state, _) {
        final (color, label) = switch (state) {
          AttachmentState.detached ||
          AttachmentState.detaching => (Colors.grey, 'offline'),
          AttachmentState.attaching => (Colors.amber, 'łączenie…'),
          _ => (Colors.green, 'sieć Veilid'),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            if (showLabel) ...[
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        );
      },
    );
  }
}
