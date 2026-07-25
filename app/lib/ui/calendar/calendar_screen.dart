import 'package:flutter/material.dart';

import '../../theme.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_month_rounded, size: 40, color: AppColors.inkDim),
          const SizedBox(height: 12),
          Text('Calendar', style: displayFont(size: 22)),
          const SizedBox(height: 6),
          Text('Deadlines & events — coming next',
              style: monoFont(size: 11, color: AppColors.inkDim)),
        ],
      ),
    );
  }
}
