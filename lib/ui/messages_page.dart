import 'package:flutter/material.dart';

import '../app/chat_controller.dart';

class MessagesPage extends StatefulWidget {
  const MessagesPage({
    super.key,
    required this.controller,
    required this.onOpenUnit,
  });

  final ChatController controller;
  final VoidCallback onOpenUnit;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final _message = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final controller = widget.controller;
    final contact = controller.selectedContact;
    final text = _message.text.trim();
    if (contact == null || text.isEmpty) return;
    await controller.send(contact, text);
    if (mounted && controller.lastError == null) _message.clear();
  }

  /// Asks for a channel name. Every unit member who joins the same name shares it.
  Future<void> _joinChannel() async {
    final field = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join a channel'),
        content: TextField(
          key: const Key('channel-name-field'),
          controller: field,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: 'Channel name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('channel-join-confirm'),
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    field.dispose();
    if (name == null || name.trim().isEmpty) return;
    await widget.controller.joinChannel(name);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final conversations = controller.conversations;
    final selected = controller.selectedContact;

    if (controller.contacts.isEmpty) {
      return _EmptyState(
        icon: Icons.forum_outlined,
        title: 'No contacts yet',
        message: 'Add a unit member to start an encrypted chat.',
        action: 'Manage unit',
        onPressed: widget.onOpenUnit,
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Row(
            children: [
              Icon(
                Icons.link,
                size: 18,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 8),
              Text(
                '${controller.linkedNeighbours.length} direct links',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 54,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            scrollDirection: Axis.horizontal,
            children: [
              for (final id in conversations)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(controller.nameOf(id)),
                    selected: id == selected,
                    onSelected: (_) => controller.select(id),
                  ),
                ),
              ActionChip(
                key: const Key('join-channel-button'),
                avatar: const Icon(Icons.tag, size: 18),
                label: const Text('Channel'),
                tooltip: 'Join a channel',
                onPressed: _joinChannel,
              ),
            ],
          ),
        ),
        Expanded(
          child: selected == null
              ? const _EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'Choose a contact',
                  message:
                      'Select a unit member above to open the conversation.',
                )
              : _Thread(controller: controller, contactId: selected),
        ),
        if (selected != null &&
            ChatController.isChannel(selected) &&
            controller.voiceAvailable)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Listener(
              onPointerDown: (_) => controller.startTalking(),
              onPointerUp: (_) => controller.stopTalking(),
              onPointerCancel: (_) => controller.stopTalking(),
              child: FilledButton.icon(
                key: const Key('talk-button'),
                onPressed: () {},
                icon: Icon(controller.talking ? Icons.mic : Icons.mic_none),
                label: Text(
                  controller.talking
                      ? 'Talking…'
                      : controller.speakerOn(selected) != null
                      ? '${controller.speakerOn(selected)} is talking'
                      : 'Hold to talk',
                ),
              ),
            ),
          ),
        if (controller.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: _ErrorText(controller.lastError!),
          ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('message-field'),
                    controller: _message,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Message ${controller.nameOf(selected)}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('send-message-button'),
                  tooltip: 'Send message',
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({required this.controller, required this.contactId});

  final ChatController controller;
  final String contactId;

  @override
  Widget build(BuildContext context) {
    final messages = controller.thread(contactId);
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'Messages with ${controller.nameOf(contactId)} will appear here.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[messages.length - index - 1];
        final outgoing = message.outgoing;
        final colors = Theme.of(context).colorScheme;
        final status = message.queued
            ? ('Held', Icons.schedule)
            : message.delivered
            ? ('Delivered', Icons.done_all)
            : ('Sent', Icons.done);

        return Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.86,
            alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              key: ValueKey(
                'message-${message.packetId ?? message.at.microsecondsSinceEpoch}',
              ),
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: outgoing
                    ? colors.primaryContainer
                    : colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.from != null)
                    Text(
                      message.from!,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  Text(message.text),
                  if (outgoing) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(status.$2, size: 14, semanticLabel: status.$1),
                        const SizedBox(width: 4),
                        Text(
                          status.$1,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: colors.secondary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center),
            if (action != null && onPressed != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onPressed, child: Text(action!)),
            ],
          ],
        ),
      ),
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
