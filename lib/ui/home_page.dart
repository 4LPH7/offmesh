import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'unit_widgets.dart';

/// Single screen for the test build: my identity, the unit roster, neighbours, and one chat thread.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final ChatController controller;

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
                                  message.delivered
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
