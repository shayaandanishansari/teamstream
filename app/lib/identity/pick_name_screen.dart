import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../models/member.dart';
import '../theme.dart';
import 'identity.dart';

/// First-launch identity + the shared-password gate: tap your name, then enter
/// the team password. The session persists on device, so this only shows until
/// you're signed in.
class PickNameScreen extends ConsumerStatefulWidget {
  const PickNameScreen({super.key});

  @override
  ConsumerState<PickNameScreen> createState() => _PickNameScreenState();
}

class _PickNameScreenState extends ConsumerState<PickNameScreen> {
  Member? _selected;
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  void _pick(Member m) => setState(() {
        _selected = m;
        _error = null;
        _pw.clear();
      });

  void _back() => setState(() {
        _selected = null;
        _error = null;
      });

  Future<void> _submit() async {
    final me = _selected;
    if (me == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(identityProvider.notifier).login(me.name, _pw.text);
      // On success, identity changes and RootGate swaps in the app.
    } catch (_) {
      setState(() {
        _busy = false;
        _error = 'Wrong password, or the server is unreachable.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(membersProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: membersAsync.when(
              loading: () => const CircularProgressIndicator(color: AppColors.teal),
              error: (e, _) => _ConnError(
                message: '$e',
                onRetry: () => ref.invalidate(membersProvider),
              ),
              data: (members) =>
                  _selected == null ? _pickView(members) : _passwordView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pickView(List<Member> members) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('who are you?', style: monoFont(size: 12, color: AppColors.teal)),
        const SizedBox(height: 10),
        Text('TeamStream', style: displayFont(size: 46, weight: FontWeight.w900)),
        const SizedBox(height: 28),
        for (final m in members) ...[
          _NameButton(member: m, onTap: () => _pick(m)),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _passwordView() {
    final me = _selected!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            InkWell(
              onTap: _busy ? null : _back,
              borderRadius: BorderRadius.circular(20),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.arrow_back_rounded, size: 20, color: AppColors.inkDim),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: hexToColor(me.color), shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text(me.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 24),
        Text('team password', style: monoFont(size: 12, color: AppColors.teal)),
        const SizedBox(height: 10),
        TextField(
          controller: _pw,
          obscureText: true,
          autofocus: true,
          enabled: !_busy,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: 'shared password',
            filled: true,
            fillColor: AppColors.card,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.line, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.line, width: 1.5),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Color(0xFFE5484D), fontSize: 13)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Enter'),
        ),
      ],
    );
  }
}

class _NameButton extends StatelessWidget {
  final Member member;
  final VoidCallback onTap;
  const _NameButton({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = hexToColor(member.color);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        child: Row(
          children: [
            Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 14),
            Text(member.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const Spacer(),
            const Icon(Icons.arrow_forward_rounded, size: 20, color: AppColors.inkDim),
          ],
        ),
      ),
    );
  }
}

class _ConnError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ConnError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.inkDim),
        const SizedBox(height: 12),
        Text("Can't reach the backend", style: displayFont(size: 20)),
        const SizedBox(height: 8),
        Text(
          'Is PocketBase running at the configured address?',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.inkDim, fontSize: 13),
        ),
        const SizedBox(height: 6),
        Text(message, textAlign: TextAlign.center, style: monoFont(size: 10, color: AppColors.inkDim)),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
