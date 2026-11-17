// Runs the OffMesh internet-mode relay: dart run bin/relay.dart [--port 7777]
//
// The relay forwards sealed frames between clients that share a rendezvous ID. It cannot
// read them and stores nothing. It does see each client's IP address and timing.
import 'dart:async';
import 'dart:io';

import 'package:offmesh/relay/relay_server.dart';

Future<void> main(List<String> args) async {
  var port = 7777;
  final at = args.indexOf('--port');
  if (at >= 0 && at + 1 < args.length) {
    final parsed = int.tryParse(args[at + 1]);
    if (parsed == null || parsed < 1 || parsed > 65535) {
      stderr.writeln('--port needs a number from 1 to 65535');
      exit(64);
    }
    port = parsed;
  }
  final server = RelayServer(port: port);
  final bound = await server.start();
  stdout.writeln('OffMesh relay listening on port $bound (Ctrl+C to stop)');
  Timer.periodic(const Duration(minutes: 1), (_) {
    stdout.writeln(
      'clients ${server.connectionCount}, rooms ${server.roomCount}, '
      'forwarded ${server.framesForwarded}, dropped ${server.framesDropped}',
    );
  });
  await ProcessSignal.sigint.watch().first;
  await server.stop();
  exit(0);
}
