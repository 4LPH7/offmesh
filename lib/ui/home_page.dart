import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../core/posture.dart';
import 'relay_screen.dart';
import 'unit_widgets.dart';

/// Asks for the word WIPE. Pops true only when it has been typed and the button pressed.
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
            'Deletes this phone\'s keys, roster and messages, and stops all '
            'radios. The phone must be joined to the unit again. This cannot be undone.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('wipe-confirm-field'),
            controller: _typed,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Type WIPE'),
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

/// Single screen for the test build: my identity, the unit roster, neighbours, and one chat thread.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller, this.onPanicWipe});

  final ChatController controller;

  /// Runs after a confirmed panic wipe in place of [ChatController.panicWipe], so the
  /// caller can rebuild the controller with a new identity.
  final Future<void> Function()? onPanicWipe;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _message = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _message.dispose();
    super.dispose();
  }

  /// Two steps: a dialog that accepts the wipe only after the word WIPE is typed.
  Future<void> _confirmWipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _WipeDialog(),
    );
    if (confirmed != true) return;
    final onWipe = widget.onPanicWipe;
    if (onWipe != null) {
      await onWipe();
    } else {
      await widget.controller.panicWipe();
    }
  }

  void _openRelay() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RelayScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _connect() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      widget.controller.reportError('Port must be a number from 1 to 65535');
      return;
    }
    await widget.controller.connect(_host.text.trim(), port);
  }

  void _shareUnit() {
    final code = widget.controller.unitCode;
    if (code == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unit code'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Holds the unit secret. Show it only to unit members, in person.',
                ),
                const SizedBox(height: 8),
                CodeView(code: code),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final contact = widget.controller.selectedContact;
    final text = _message.text.trim();
    if (contact == null || text.isEmpty) return;
    await widget.controller.send(contact, text);
    _message.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return Scaffold(
          appBar: AppBar(title: const Text('OffMesh')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'My ID',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  c.myId,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                Text('Fingerprint: ${c.myFingerprint}'),
                if (c.myIdentityCode != null)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('My identity code'),
                    children: [CodeView(code: c.myIdentityCode!)],
                  ),
                const SizedBox(height: 4),
                Text(
                  'Listening on port ${c.listenPort ?? '-'} · '
                  'direct neighbours: ${c.linkedNeighbours.length}',
                ),
                const Divider(height: 32),
                const Text(
                  'Radio posture',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SegmentedButton<Posture>(
                  key: const Key('posture-selector'),
                  segments: const [
                    ButtonSegment(value: Posture.silent, label: Text('Silent')),
                    ButtonSegment(value: Posture.quiet, label: Text('Quiet')),
                    ButtonSegment(value: Posture.normal, label: Text('Normal')),
                  ],
                  selected: {c.posture.current},
                  onSelectionChanged: (selection) =>
                      c.setPosture(selection.first),
                ),
                if (c.posture.current == Posture.quiet) ...[
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('send-burst-button'),
                    onPressed: c.queuedCount == 0 ? null : c.sendBurst,
                    child: Text('Send burst (${c.queuedCount} held)'),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      key: const Key('relay-mode-button'),
                      onPressed: _openRelay,
                      child: const Text('Relay Mode'),
                    ),
                    OutlinedButton(
                      key: const Key('panic-wipe-button'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: _confirmWipe,
                      child: const Text('Panic wipe'),
                    ),
                  ],
                ),
                const Divider(height: 32),
                const Text('Connect to a neighbour (IP and port)'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          hintText: '192.168.43.1',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: 'port'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _connect,
                      child: const Text('Connect'),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Unit members',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    OutlinedButton(
                      key: const Key('share-unit-button'),
                      onPressed: _shareUnit,
                      child: const Text('Share unit'),
                    ),
                  ],
                ),
                for (final m in c.members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(m.isSelf ? '${m.name} (this phone)' : m.name),
                    subtitle: Text(
                      m.fingerprint,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text('Add member (paste or scan their identity code)'),
                CodeInput(
                  hint: 'OFFM-ID1:...',
                  actionLabel: 'Add',
                  fieldKey: const Key('member-code-field'),
                  buttonKey: const Key('add-member-button'),
                  onSubmit: c.addMember,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final id in c.contacts)
                      ChoiceChip(
                        label: Text(c.nameOf(id)),
                        selected: id == c.selectedContact,
                        onSelected: (_) => c.select(id),
                      ),
                  ],
                ),
                if (c.selectedContact != null) ...[
                  const Divider(height: 32),
                  for (final message in c.thread(c.selectedContact!))
                    Align(
                      alignment: message.outgoing
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: message.outgoing
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(child: Text('Me: ${message.text}')),
                                  const SizedBox(width: 4),
                                  message.queued
                                      ? const Icon(
                                          Icons.schedule,
                                          size: 16,
                                          semanticLabel: 'Held',
                                        )
                                      : message.delivered
                                      ? const Icon(
                                          Icons.done_all,
                                          size: 16,
                                          semanticLabel: 'Delivered',
                                        )
                                      : const Icon(
                                          Icons.done,
                                          size: 16,
                                          semanticLabel: 'Sent',
                                        ),
                                ],
                              )
                            : Text(message.text),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _message,
                          decoration: const InputDecoration(
                            hintText: 'Message',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _send, child: const Text('Send')),
                    ],
                  ),
                ],
                if (c.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    c.lastError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
