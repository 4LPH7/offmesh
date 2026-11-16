import 'dart:convert';
import 'dart:typed_data';

import 'secret_store.dart';

/// Joined channel names, one per line. Kept in the secret store because the names say
/// what the unit talks about; panic wipe deletes them with the keys.
const String channelsKey = 'channels.v1';

/// Most channels one phone keeps joined.
const int maxJoinedChannels = 16;

class ChannelStore {
  const ChannelStore._();

  static Future<List<String>> load(SecretStore store) async {
    final raw = await store.read(channelsKey);
    if (raw == null) return const [];
    return utf8
        .decode(raw, allowMalformed: true)
        .split('\n')
        .where((name) => name.isNotEmpty)
        .take(maxJoinedChannels)
        .toList();
  }

  static Future<void> save(SecretStore store, Iterable<String> names) => store
      .write(channelsKey, Uint8List.fromList(utf8.encode(names.join('\n'))));
}
