import '../core/voice/tones.dart';
import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'unit_widgets.dart';

class UnitPage extends StatefulWidget {
  const UnitPage({super.key, required this.controller});

  final ChatController controller;

  @override
  State<UnitPage> createState() => _UnitPageState();
}

class _UnitPageState extends State<UnitPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty) {
      widget.controller.reportError('Enter the neighbour IP address');
      return;
    }
    if (port == null || port <= 0 || port > 65535) {
      widget.controller.reportError('Port must be a number from 1 to 65535');
      return;
    }
    await widget.controller.connect(host, port);
  }

  void _shareUnit() {
    final code = widget.controller.unitCode;
    if (code == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share unit'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This code contains the unit secret. Show it only to members in person.',
                ),
                const SizedBox(height: 12),
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
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
                  'This device',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                const Text('My ID'),
                SelectableText(
                  controller.myId,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                const Text('Fingerprint'),
                SelectableText(
                  controller.myFingerprint,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (controller.myIdentityCode != null) ...[
                  const Divider(height: 24),
                  ExpansionTile(
                    key: const Key('identity-code-section'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Identity code'),
                    children: [CodeView(code: controller.myIdentityCode!)],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: Text(
                  'Listening on port ${controller.listenPort ?? '—'}',
                ),
                subtitle: Text(
                  controller.listenPort == null
                      ? 'LAN listener is off'
                      : 'LAN discovery is active',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(
                  '${controller.linkedNeighbours.length} direct links',
                ),
                subtitle: const Text('Connected unit members'),
              ),
            ],
          ),
        ),
        ExpansionTile(
          key: const Key('manual-connect-section'),
          title: const Text('Connect by address'),
          subtitle: const Text(
            'Use when automatic discovery cannot find a member',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  TextField(
                    key: const Key('manual-connect-host'),
                    controller: _host,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'IP address'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('manual-connect-port'),
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _connect,
                      icon: const Icon(Icons.link),
                      label: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Unit members',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            OutlinedButton.icon(
              key: const Key('share-unit-button'),
              onPressed: _shareUnit,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Share'),
            ),
          ],
        ),
        for (final member in controller.members)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(member.isSelf ? Icons.person : Icons.person_outline),
            title: Text(
              member.isSelf ? '${member.name} (this device)' : member.name,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  member.fingerprint,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (!member.isSelf)
                  Text(
                    _heardLabel(controller.lastHeard(member.peerId)),
                    key: Key('last-heard-${member.peerId}'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text('Add a member', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Paste their identity code or scan it on Android.'),
        const SizedBox(height: 8),
        CodeInput(
          hint: 'OFFM-ID1:...',
          actionLabel: 'Add',
          fieldKey: const Key('member-code-field'),
          buttonKey: const Key('add-member-button'),
          onSubmit: controller.addMember,
        ),
        if (controller.lastError != null) ...[
          const SizedBox(height: 12),
          _ErrorText(controller.lastError!),
        ],
      ],
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: TextStyle(color: colors.onErrorContainer)),
    );
  }
}

String _heardLabel(DateTime? at) => at == null
    ? 'Not heard yet'
    : 'Heard ${heardAgo(DateTime.now().difference(at))}';
