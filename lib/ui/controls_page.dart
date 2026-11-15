import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../core/posture.dart';
import 'relay_screen.dart';

class ControlsPage extends StatelessWidget {
  const ControlsPage({super.key, required this.controller, this.onPanicWipe});

  final ChatController controller;
  final Future<void> Function()? onPanicWipe;

  Future<void> _confirmWipe(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _WipeDialog(),
    );
    if (confirmed != true) return;
    final onWipe = onPanicWipe;
    if (onWipe != null) {
      await onWipe();
    } else {
      await controller.panicWipe();
    }
  }

  void _openRelay(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RelayScreen(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final postureDescription = switch (controller.posture.current) {
      Posture.silent => 'No LAN listener or beacon is active.',
      Posture.quiet => 'Discovery is paused. Messages wait for a send burst.',
      Posture.normal => 'LAN discovery and messaging are active.',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Radio posture',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SegmentedButton<Posture>(
                  key: const Key('posture-selector'),
                  segments: const [
                    ButtonSegment(value: Posture.silent, label: Text('Silent')),
                    ButtonSegment(value: Posture.quiet, label: Text('Quiet')),
                    ButtonSegment(value: Posture.normal, label: Text('Normal')),
                  ],
                  selected: {controller.posture.current},
                  onSelectionChanged: (selection) =>
                      controller.setPosture(selection.first),
                ),
                const SizedBox(height: 10),
                Text(postureDescription),
              ],
            ),
          ),
        ),
        if (controller.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Card(
              color: colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  controller.lastError!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ),
          ),
        if (controller.posture.current == Posture.quiet) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: Text(
                '${controller.queuedCount} ${controller.queuedCount == 1 ? 'message' : 'messages'} held',
              ),
              subtitle: const Text('Send them together when you are ready.'),
              trailing: FilledButton(
                key: const Key('send-burst-button'),
                onPressed: controller.queuedCount == 0
                    ? null
                    : controller.sendBurst,
                child: const Text('Send burst'),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.link, color: colorScheme.secondary),
                title: Text(
                  '${controller.linkedNeighbours.length} direct links',
                ),
                subtitle: Text(
                  'Listening on port ${controller.listenPort ?? '—'}',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Bluetooth'),
                subtitle: const Text(
                  'Bluetooth messaging is not connected in this build.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.cell_tower),
            title: const Text('Relay Mode'),
            subtitle: Text(
              isAndroid
                  ? 'Keep LAN relaying active with the screen off.'
                  : 'Available on Android only.',
            ),
            trailing: OutlinedButton(
              key: const Key('relay-mode-button'),
              onPressed: isAndroid ? () => _openRelay(context) : null,
              child: const Text('Open'),
            ),
          ),
        ),
        if (isAndroid)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              'The BLE radio is not wired yet; Relay Mode currently keeps the LAN relay service alive.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('panic-wipe-button'),
          onPressed: () => _confirmWipe(context),
          icon: Icon(Icons.delete_forever_outlined, color: colorScheme.error),
          label: Text('Panic wipe', style: TextStyle(color: colorScheme.error)),
        ),
      ],
    );
  }
}

class _WipeDialog extends StatefulWidget {
  const _WipeDialog();

  @override
  State<_WipeDialog> createState() => _WipeDialogState();
}

class _WipeDialogState extends State<_WipeDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Panic wipe?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Deletes this device’s keys, roster and messages, and stops all radios. '
            'You must join the unit again. This cannot be undone.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('wipe-confirm-field'),
            controller: _typed,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Type WIPE'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('wipe-confirm-button'),
          onPressed: _typed.text == 'WIPE'
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Wipe'),
        ),
      ],
    );
  }
}
