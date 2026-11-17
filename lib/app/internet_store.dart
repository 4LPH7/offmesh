import 'dart:convert';
import 'dart:typed_data';

import 'secret_store.dart';

/// Relay address as 'host:port'. Kept in the secret store: it says where the unit meets.
const String relayAddressKey = 'relay.v1';

/// Set once the user has read the internet-mode warning.
const String internetAckKey = 'internet.ack.v1';

/// Port used when an address has none.
const int defaultRelayPort = 7777;

/// A relay address the user typed.
class RelayAddress {
  const RelayAddress(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  /// Accepts 'host', 'host:port' or '[ipv6]:port'. Throws [FormatException] with a
  /// message safe to show.
  static RelayAddress parse(String text) {
    final clean = text.trim();
    if (clean.isEmpty) throw const FormatException('Relay address is empty');
    if (clean.length > 253 || clean.contains(RegExp(r'\s'))) {
      throw const FormatException('Relay address must not contain spaces');
    }
    String host;
    String? portText;
    if (clean.startsWith('[')) {
      final end = clean.indexOf(']');
      if (end < 0) throw const FormatException('Relay address is not valid');
      host = clean.substring(1, end);
      final rest = clean.substring(end + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) {
          throw const FormatException('Relay address is not valid');
        }
        portText = rest.substring(1);
      }
    } else {
      final colon = clean.lastIndexOf(':');
      if (colon >= 0 && clean.indexOf(':') == colon) {
        host = clean.substring(0, colon);
        portText = clean.substring(colon + 1);
      } else if (colon >= 0) {
        throw const FormatException('Put an IPv6 address in [brackets]');
      } else {
        host = clean;
      }
    }
    if (host.isEmpty || !RegExp(r'^[A-Za-z0-9.:_-]+$').hasMatch(host)) {
      throw const FormatException('Relay host is not valid');
    }
    final port = portText == null ? defaultRelayPort : int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Relay port must be 1 to 65535');
    }
    return RelayAddress(host, port);
  }
}

class InternetStore {
  const InternetStore._();

  static Future<RelayAddress?> loadAddress(SecretStore store) async {
    final raw = await store.read(relayAddressKey);
    if (raw == null) return null;
    try {
      return RelayAddress.parse(utf8.decode(raw));
    } on Object {
      return null; // a damaged value reads as "no relay set"
    }
  }

  static Future<void> saveAddress(SecretStore store, RelayAddress address) =>
      store.write(
        relayAddressKey,
        Uint8List.fromList(utf8.encode(address.toString())),
      );

  static Future<bool> loadAck(SecretStore store) async =>
      await store.read(internetAckKey) != null;

  static Future<void> saveAck(SecretStore store) =>
      store.write(internetAckKey, Uint8List.fromList([1]));
}
