import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

class SecuritySheet extends StatefulWidget {
  final AppState state;
  const SecuritySheet({super.key, required this.state});

  @override
  State<SecuritySheet> createState() => _SecuritySheetState();
}

class _SecuritySheetState extends State<SecuritySheet> {
  String _hashPasscode(String code) => sha256.convert(utf8.encode(code)).toString();

  @override
  Widget build(BuildContext context) {
    final on = widget.state.passcode.isNotEmpty;
    return DraggableScrollableSheet(
      initialChildSize: .45,
      minChildSize: .3,
      maxChildSize: .7,
      expand: false,
      builder: (context, scroll) => Container(
        decoration: const BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Security', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Text('A 4-digit passcode is asked for whenever the app comes back to the foreground.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const Divider(height: 28, color: AppColors.border),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('App lock', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(on ? 'Passcode is set.' : 'No passcode set.', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
              value: on,
              onChanged: (v) async {
                if (v) {
                  final code = await _promptCode(context, title: 'Set a passcode');
                  if (code != null) await widget.state.setStr('passcode', _hashPasscode(code));
                } else {
                  await widget.state.setStr('passcode', '');
                }
                if (!mounted) return;
                setState(() {});
              },
            ),
            if (on)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Change passcode', style: TextStyle(fontSize: 13)),
                trailing: const Icon(Icons.chevron_right, color: AppColors.textDim),
                onTap: () async {
                  // Verify old passcode before allowing change
                  final oldCode = await _promptCode(context, title: 'Enter current passcode');
                  if (oldCode == null) return;
                  final oldHashed = _hashPasscode(oldCode);
                  if (oldHashed != widget.state.passcode) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Incorrect current passcode.')),
                    );
                    return;
                  }
                  final code = await _promptCode(context, title: 'New passcode');
                  if (code != null) await widget.state.setStr('passcode', _hashPasscode(code));
                  if (!mounted) return;
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptCode(BuildContext context, {required String title}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          maxLength: 4,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: '4 digits'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.length == 4 && RegExp(r'^\d{4}$').hasMatch(text)) Navigator.pop(context, text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((result) { ctrl.dispose(); return result; });
  }
}
