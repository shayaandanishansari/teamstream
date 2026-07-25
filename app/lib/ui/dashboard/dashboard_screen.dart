import 'package:flutter/material.dart';

import '../../theme.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insights_rounded, size: 40, color: AppColors.inkDim),
          const SizedBox(height: 12),
          Text('Dashboard', style: displayFont(size: 22)),
          const SizedBox(height: 6),
          Text('Effort concentration — coming next',
              style: monoFont(size: 11, color: AppColors.inkDim)),
        ],
      ),
    );
  }
}
