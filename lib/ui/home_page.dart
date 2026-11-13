import 'package:flutter/material.dart';

import '../app/chat_controller.dart';

/// Single screen for the v0.1 test build: my ID, neighbours, contacts, and one chat thread.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final ChatController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _contactId = TextEditingController();
  final _message = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _contactId.dispose();
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

  void _addContact() {
    try {
      widget.controller.addContact(_contactId.text);
      _contactId.clear();
    } on FormatException catch (error) {
      widget.controller.reportError(error.message);
    }
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
                const Text('Contacts (paste the ID they show)'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('contact-id-field'),
                        controller: _contactId,
                        decoration: const InputDecoration(
                          hintText: '16 hex characters',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('add-contact-button'),
                      onPressed: _addContact,
                      child: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final id in c.contacts)
                      ChoiceChip(
                        label: Text(id),
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
                        child: Text(
                          message.outgoing
                              ? 'Me: ${message.text}'
                              : message.text,
                        ),
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
