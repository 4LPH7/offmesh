import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Camera scanning is offered on Android only (ML Kit model bundled in the APK).
bool get canScanCodes => defaultTargetPlatform == TargetPlatform.android;

/// A code shown as a QR code plus selectable text with a copy button.
class CodeView extends StatelessWidget {
  const CodeView({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A full unit code is a version-40 QR (177 modules): use the full width.
        LayoutBuilder(
          builder: (context, constraints) => Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: code,
                size: (constraints.maxWidth - 16).clamp(160, 480).toDouble(),
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Opens the camera and returns the first QR code read, or null if cancelled.
Future<String?> scanCode(BuildContext context) {
  return Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan code')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}

/// A paste field with an action button and, on Android, a scan button that fills
/// the field and runs the action.
class CodeInput extends StatefulWidget {
  const CodeInput({
    super.key,
    required this.hint,
    required this.actionLabel,
    required this.onSubmit,
    this.fieldKey,
    this.buttonKey,
  });

  final String hint;
  final String actionLabel;
  final Future<bool> Function(String code) onSubmit;
  final Key? fieldKey;
  final Key? buttonKey;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (await widget.onSubmit(_field.text) && mounted) _field.clear();
  }

  Future<void> _scan() async {
    final code = await scanCode(context);
    if (code == null || !mounted) return;
    _field.text = code;
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: widget.fieldKey,
            controller: _field,
            decoration: InputDecoration(hintText: widget.hint),
          ),
        ),
        if (canScanCodes)
          IconButton(
            tooltip: 'Scan',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scan,
          ),
        const SizedBox(width: 8),
        FilledButton(
          key: widget.buttonKey,
          onPressed: _submit,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}
