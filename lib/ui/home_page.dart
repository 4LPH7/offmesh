import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import 'controls_page.dart';
import 'messages_page.dart';
import 'unit_page.dart';

/// The one talk screen. Everything else is the menu, then one item.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller, this.onPanicWipe});

  final ChatController controller;
  final Future<void> Function()? onPanicWipe;

  void _open(BuildContext context, String title, WidgetBuilder body) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => body(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openUnit(BuildContext context) => _open(
    context,
    'Unit and members',
    (_) => UnitPage(controller: controller),
  );

  void _openControls(BuildContext context) => _open(
    context,
    'Radio and internet',
    (_) => ControlsPage(controller: controller, onPanicWipe: onPanicWipe),
  );

  Future<void> _pickConversation(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final id in controller.conversations)
              ListTile(
                key: Key('conversation-$id'),
                leading: Icon(
                  ChatController.isChannel(id) ? Icons.tag : Icons.person,
                ),
                title: Text(controller.nameOf(id)),
                selected: id == controller.selectedContact,
                onTap: () => Navigator.of(context).pop(id),
              ),
            ListTile(
              key: const Key('join-channel-button'),
              leading: const Icon(Icons.add),
              title: const Text('Join a channel'),
              onTap: () => Navigator.of(context).pop(''),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (picked.isEmpty) {
      await joinChannelDialog(context, controller);
    } else {
      controller.select(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final selected = controller.selectedContact;
        return Scaffold(
          appBar: AppBar(
            title: Tooltip(
              message: 'Change channel or contact',
              child: TextButton.icon(
                key: const Key('conversation-picker'),
                onPressed: () => _pickConversation(context),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.expand_more),
                label: Text(
                  selected == null ? 'Choose' : controller.nameOf(selected),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            actions: [
              PopupMenuButton<String>(
                key: const Key('menu-button'),
                tooltip: 'Menu',
                icon: const Icon(Icons.menu),
                onSelected: (item) => item == 'unit'
                    ? _openUnit(context)
                    : _openControls(context),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    key: Key('menu-unit'),
                    value: 'unit',
                    child: ListTile(
                      leading: Icon(Icons.group_outlined),
                      title: Text('Unit and members'),
                    ),
                  ),
                  PopupMenuItem(
                    key: Key('menu-controls'),
                    value: 'controls',
                    child: ListTile(
                      leading: Icon(Icons.tune),
                      title: Text('Radio and internet'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: MessagesPage(
                  controller: controller,
                  onOpenUnit: () => _openUnit(context),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
