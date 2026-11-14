import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'unit_widgets.dart';

/// Shown while this phone is in no unit. Nothing links until a unit is created or joined.
class ProvisioningPage extends StatefulWidget {
  const ProvisioningPage({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ProvisioningPage> createState() => _ProvisioningPageState();
}

class _ProvisioningPageState extends State<ProvisioningPage> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, _name]),
      builder: (context, _) {
        final c = widget.controller;
        final myCode = c.identityCodeFor(_name.text.trim());
        return Scaffold(
          appBar: AppBar(title: const Text('OffMesh: join a unit')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'This phone is not in a unit and will not link to anyone.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Your name (up to 16 bytes)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                TextField(
                  key: const Key('my-name-field'),
                  controller: _name,
                  decoration: const InputDecoration(hintText: 'e.g. Alpha 2'),
                ),
                const SizedBox(height: 8),
                Text('Fingerprint: ${c.myFingerprint}'),
                const Divider(height: 32),
                const Text(
                  'Your identity code: a unit member adds you with it',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (myCode == null)
                  const Text('Enter a name to show your identity code.')
                else
                  CodeView(code: myCode),
                const Divider(height: 32),
                const Text(
                  'Join a unit (paste or scan its unit code)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                CodeInput(
                  hint: 'OFFM-UNIT1:...',
                  actionLabel: 'Join',
                  fieldKey: const Key('unit-code-field'),
                  buttonKey: const Key('join-unit-button'),
                  onSubmit: c.importUnit,
                ),
                const Divider(height: 32),
                const Text(
                  'Or start a new unit with this phone as its first member.',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    key: const Key('create-unit-button'),
                    onPressed: myCode == null
                        ? null
                        : () => c.createUnit(_name.text),
                    child: const Text('Create unit'),
                  ),
                ),
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
