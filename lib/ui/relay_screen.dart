import 'dart:async';

import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../core/posture.dart';

const Duration _refreshInterval = Duration(seconds: 1);

/// Relay Mode: a black screen with forwarding counters. Entering it sets the posture to
/// Normal, since a relay that stays silent forwards nothing. Keeping the process alive
/// with the screen off needs the foreground service, which is not built yet.
class RelayScreen extends StatefulWidget {
  const RelayScreen({super.key, required this.controller});

  final ChatController controller;

  @override
  State<RelayScreen> createState() => _RelayScreenState();
}

class _RelayScreenState extends State<RelayScreen> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.setPosture(Posture.normal));
    _refresh = Timer.periodic(_refreshInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.controller.node;
    final lan = widget.controller.lan;
    const style = TextStyle(color: Colors.white, fontSize: 18);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Relay Mode',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 24),
              Text('Forwarded: ${node.relaysSent}', style: style),
              const SizedBox(height: 8),
              Text('Suppressed: ${node.relaysSuppressed}', style: style),
              const SizedBox(height: 8),
              Text('Links: ${lan.linkCount}', style: style),
              const Spacer(),
              OutlinedButton(
                key: const Key('relay-leave-button'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Leave'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
