import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../models/member.dart';
import '../theme.dart';
import 'identity.dart';

/// First-launch identity: tap your name. Remembered on device.
class PickNameScreen extends ConsumerWidget {
  const PickNameScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              data: (members) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('who are you?', style: monoFont(size: 12, color: AppColors.teal)),
                  const SizedBox(height: 10),
                  Text('TeamStream', style: displayFont(size: 46, weight: FontWeight.w900)),
                  const SizedBox(height: 28),
                  for (final m in members) ...[
                    _NameButton(
                      member: m,
                      onTap: () => ref.read(identityProvider.notifier).select(m.id),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
