import 'package:flutter/material.dart';

/// "Verified passenger" pill shown to drivers when an administrator has
/// verified the passenger's government ID.
class VerifiedPassengerBadge extends StatelessWidget {
  const VerifiedPassengerBadge({super.key});

  static const Color _brandGreen = Color(0xFF168A5B);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _brandGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: 14, color: _brandGreen),
          SizedBox(width: 4),
          Text(
            'Verified passenger',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _brandGreen,
            ),
          ),
        ],
      ),
    );
  }
}
