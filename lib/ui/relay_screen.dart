import 'dart:async';

import 'package:flutter/material.dart';

import '../app/chat_controller.dart';
import '../core/posture.dart';
import '../transports/relay_service.dart';

const Duration _refreshInterval = Duration(seconds: 1);

/// Relay Mode: a black screen with forwarding counters. Entering it sets the posture to
/// Normal (a silent relay forwards nothing) and starts the Android foreground service so
/// the links survive the screen going off. Leaving stops the service.
class RelayScreen extends StatefulWidget {
  const RelayScreen({super.key, required this.controller, this.service});

  final ChatController controller;

  /// Null in the app; tests pass a fake channel.
  final RelayService? service;

  @override
  State<RelayScreen> createState() => _RelayScreenState();
}

class _RelayScreenState extends State<RelayScreen> {
  Timer? _refresh;
  late final RelayService _service = widget.service ?? RelayService();

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.setPosture(Posture.normal));
    unawaited(_service.start().then((_) => _refreshed()));
    _refresh = Timer.periodic(_refreshInterval, (_) => _refreshed());
  }

  void _refreshed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _refresh?.cancel();
    unawaited(_service.stop());
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
              const SizedBox(height: 8),
              Text(
                _service.running
                    ? 'Background service: running'
                    : 'Background service: not running (${_service.lastError ?? 'starting'})',
                key: const Key('relay-service-status'),
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
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
