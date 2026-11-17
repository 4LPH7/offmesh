import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'unit_widgets.dart';

/// First run in three steps: your name, create or join a unit, done (the app then
/// switches to the talk screen). Nothing links until the phone is in a unit.
class ProvisioningPage extends StatefulWidget {
  const ProvisioningPage({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ProvisioningPage> createState() => _ProvisioningPageState();
}

class _ProvisioningPageState extends State<ProvisioningPage> {
  final _name = TextEditingController();
  int _step = 1;

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
        final step = myCode == null ? 1 : _step;
        return Scaffold(
          appBar: AppBar(
            leading: step == 2
                ? BackButton(onPressed: () => setState(() => _step = 1))
                : null,
            title: Text('Set up OffMesh · step $step of 3'),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'This phone is not in a unit and will not link to anyone.',
                    ),
                    const SizedBox(height: 16),
                    if (step == 1)
                      ..._nameStep(c, myCode)
                    else
                      ..._unitStep(c, myCode!),
                    if (c.lastError != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          c.lastError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _nameStep(ChatController c, String? myCode) => [
    Text('Your name', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 8),
    TextField(
      key: const Key('my-name-field'),
      controller: _name,
      autofocus: true,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) {
        if (myCode != null) setState(() => _step = 2);
      },
      decoration: const InputDecoration(
        hintText: 'e.g. Alpha 2',
        helperText: 'Up to 16 bytes. Unit members see this name.',
      ),
    ),
    const SizedBox(height: 8),
    Text('Fingerprint: ${c.myFingerprint}'),
    const SizedBox(height: 16),
    Align(
      alignment: Alignment.centerRight,
      child: FilledButton(
        key: const Key('name-next-button'),
        onPressed: myCode == null ? null : () => setState(() => _step = 2),
        child: const Text('Next'),
      ),
    ),
  ];

  List<Widget> _unitStep(ChatController c, String myCode) => [
    Text('Start a new unit', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 8),
    const Text('This phone becomes its first member.'),
    const SizedBox(height: 8),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton(
        key: const Key('create-unit-button'),
        onPressed: () => c.createUnit(_name.text),
        child: const Text('Create unit'),
      ),
    ),
    const Divider(height: 32),
    Text('Or join a unit', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 8),
    const Text('1. Show this identity code to a member, who adds you.'),
    const SizedBox(height: 8),
    CodeView(code: myCode),
    const SizedBox(height: 16),
    const Text('2. Paste or scan the unit code they share back.'),
    CodeInput(
      hint: 'OFFM-UNIT1:...',
      actionLabel: 'Join',
      fieldKey: const Key('unit-code-field'),
      buttonKey: const Key('join-unit-button'),
      onSubmit: c.importUnit,
    ),
  ];
}
