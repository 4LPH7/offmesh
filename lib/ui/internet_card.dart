import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../transports/relay_transport.dart';

/// Internet mode: a switch, the relay address, and what the relay can see. Off at every
/// launch; the first time it is switched on, a warning must be accepted.
class InternetCard extends StatefulWidget {
  const InternetCard({super.key, required this.controller});

  final ChatController controller;

  @override
  State<InternetCard> createState() => _InternetCardState();
}

class _InternetCardState extends State<InternetCard> {
  late final TextEditingController _address = TextEditingController(
    text: widget.controller.relayAddress ?? '',
  );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    final controller = widget.controller;
    if (on && !controller.internetAcked) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => const _InternetWarning(),
      );
      if (accepted != true) return;
      await controller.acknowledgeInternet();
    }
    await controller.setInternet(on);
  }

  String _status(ChatController controller) {
    if (!controller.internetOn) return 'Off. Only nearby phones are reachable.';
    return switch (controller.internetState) {
      RelayState.connected => 'Connected to the relay.',
      RelayState.connecting => 'Connecting…',
      RelayState.retrying => 'Cannot reach the relay. Retrying.',
      RelayState.stopped => 'Starting…',
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('internet-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Internet mode',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text(_status(controller)),
              value: controller.internetOn,
              onChanged: _toggle,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('relay-address-field'),
                    controller: _address,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Relay address',
                      hintText: 'host:7777',
                      isDense: true,
                    ),
                    onSubmitted: controller.setRelayAddress,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('relay-address-save'),
                  onPressed: () => controller.setRelayAddress(_address.text),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InternetWarning extends StatelessWidget {
  const _InternetWarning();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Use the internet?'),
      content: const Text(
        'Your messages stay encrypted, but the relay can see your phone\'s IP '
        'address, when you are online, and how much you send. Anyone watching '
        'your connection can see that you use the relay.\n\n'
        'Only turn this on when nearby links are not enough. Silent and Quiet '
        'turn it off.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('internet-warning-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('I understand'),
        ),
      ],
    );
  }
}
