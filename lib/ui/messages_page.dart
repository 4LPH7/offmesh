import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../core/posture.dart';
import '../transports/relay_transport.dart';

/// Asks for a channel name. Every unit member who joins the same name shares it.
Future<void> joinChannelDialog(
  BuildContext context,
  ChatController controller,
) async {
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
  await controller.joinChannel(name);
}

/// One line saying whether anyone can hear this phone, with a colour dot.
(String, Color) statusOf(ChatController c, ColorScheme colors) {
  const amber = Color(0xFFB26A00);
  const green = Color(0xFF1E7D45);
  final posture = c.posture.current;
  if (posture == Posture.silent) return ('Silent: radios off', colors.error);
  if (c.talking) return ('Talking', colors.error);
  final selected = c.selectedContact;
  final speaker = selected == null ? null : c.speakerOn(selected);
  if (speaker != null) return ('$speaker is talking', colors.tertiary);
  final links = c.linkedNeighbours.length;
  final internet = c.internetState == RelayState.connected;
  final quiet = posture == Posture.quiet ? ' · Quiet' : '';
  if (links == 0 && !internet) return ('No one in range$quiet', amber);
  final parts = [if (links > 0) '$links linked', if (internet) 'internet'];
  return ('${parts.join(' · ')}$quiet', green);
}

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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selected = controller.selectedContact;
    final colors = Theme.of(context).colorScheme;
    final (status, dot) = statusOf(controller, colors);

    return Column(
      children: [
        Semantics(
          key: const Key('status-line'),
          container: true,
          liveRegion: true,
          label: 'Status: $status',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _body(controller, selected)),
        if (selected != null &&
            ChatController.isChannel(selected) &&
            controller.voiceAvailable)
          _TalkButton(controller: controller, channel: selected),
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

  Widget _body(ChatController controller, String? selected) {
    if (controller.conversations.isEmpty) {
      return _EmptyState(
        icon: Icons.forum_outlined,
        title: 'No one to talk to yet',
        message: 'Add a unit member, or join a channel from the name above.',
        action: 'Add a member',
        onPressed: widget.onOpenUnit,
      );
    }
    if (selected == null) {
      return const _EmptyState(
        icon: Icons.chat_bubble_outline,
        title: 'Choose who to talk to',
        message: 'Tap "Choose" above to pick a channel or a member.',
      );
    }
    return _Thread(controller: controller, contactId: selected);
  }
}

/// Large round hold-to-talk button. Holding records; releasing sends the end of burst.
class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.controller, required this.channel});

  final ChatController controller;
  final String channel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final talking = controller.talking;
    final speaker = controller.speakerOn(channel);
    final label = talking
        ? 'Talking…'
        : speaker != null
        ? '$speaker is talking'
        : 'Hold to talk';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: talking
                ? 'Talking. Release to stop.'
                : 'Hold to talk on ${controller.nameOf(channel)}',
            excludeSemantics: true,
            child: Listener(
              onPointerDown: (_) => controller.startTalking(),
              onPointerUp: (_) => controller.stopTalking(),
              onPointerCancel: (_) => controller.stopTalking(),
              child: SizedBox.square(
                dimension: 160,
                child: FilledButton(
                  key: const Key('talk-button'),
                  onPressed: () {},
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: talking ? colors.error : colors.primary,
                    foregroundColor: talking
                        ? colors.onError
                        : colors.onPrimary,
                  ),
                  child: Icon(talking ? Icons.mic : Icons.mic_none, size: 56),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            ChatController.isChannel(contactId)
                ? 'Nothing said on ${controller.nameOf(contactId)} yet.'
                : 'Messages with ${controller.nameOf(contactId)} will appear here.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
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
      child: SingleChildScrollView(
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
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(message, style: TextStyle(color: colors.onErrorContainer)),
      ),
    );
  }
}
