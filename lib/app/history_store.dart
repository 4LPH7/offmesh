import 'dart:convert';
import 'dart:typed_data';

import 'chat_controller.dart';
import 'secret_store.dart';

/// Message threads, kept in the secret store (Keystore-backed on Android, DPAPI on
/// Windows) so they survive a restart. Panic wipe deletes them with the keys.
const String historyKey = 'history.v1';

/// Newest messages kept per thread, and threads kept at most.
const int maxHistoryPerThread = 100;
const int maxHistoryThreads = 48;

class HistoryStore {
  const HistoryStore._();

  /// Messages held for a Quiet burst are not stored: the hold queue is memory-only.
  static Future<void> save(
    SecretStore store,
    Map<String, List<ChatMessage>> threads,
  ) {
    final out = <String, Object>{};
    for (final entry in threads.entries.take(maxHistoryThreads)) {
      final kept = entry.value.where((m) => !m.queued).toList();
      final start = kept.length > maxHistoryPerThread
          ? kept.length - maxHistoryPerThread
          : 0;
      out[entry.key] = [for (final m in kept.skip(start)) _encode(m)];
    }
    return store.write(
      historyKey,
      Uint8List.fromList(utf8.encode(jsonEncode(out))),
    );
  }

  /// A damaged record reads as no history rather than stopping the app.
  static Future<Map<String, List<ChatMessage>>> load(SecretStore store) async {
    final raw = await store.read(historyKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries.take(maxHistoryThreads))
          entry.key: [
            for (final m in (entry.value as List).take(maxHistoryPerThread))
              _decode(m as Map<String, dynamic>),
          ],
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, Object?> _encode(ChatMessage m) => {
    'o': m.outgoing,
    't': m.text,
    'a': m.at.millisecondsSinceEpoch,
    if (m.packetId != null) 'p': m.packetId,
    if (m.delivered) 'd': true,
    if (m.from != null) 'f': m.from,
  };

  static ChatMessage _decode(Map<String, dynamic> m) => ChatMessage(
    outgoing: m['o'] as bool,
    text: m['t'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(m['a'] as int),
    packetId: m['p'] as int?,
    delivered: m['d'] as bool? ?? false,
    from: m['f'] as String?,
  );
}
