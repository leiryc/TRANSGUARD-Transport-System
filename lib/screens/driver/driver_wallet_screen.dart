import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../services/ride_service.dart';

class DriverWalletScreen extends StatelessWidget {
  final String driverId;
  final RideService _rideService = RideService();

  DriverWalletScreen({super.key, required this.driverId});

  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dangerRed = Color(0xFFD64545);

  String _formatPhp(Object? value) {
    final amount = value is num ? value.toDouble() : 0.0;
    return '₱${amount.toStringAsFixed(2)}';
  }

  double _toDouble(Object? value) {
    return value is num ? value.toDouble() : 0.0;
  }

  String _formatDate(Object? value) {
    if (value is! Timestamp) return 'Recently completed';
    final date = value.toDate().toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = months[date.month - 1];
    final day = date.day.toString().padLeft(2, '0');
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';
    return '$month $day, ${date.year} · $hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F8),
      appBar: _buildAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _rideService.watchDriverLedger(driverId),
        builder: (context, snapshot) {
          return RefreshIndicator(
            color: _brandGreen,
            onRefresh: () async {
              await Future<void>.delayed(
                const Duration(milliseconds: 300),
              );
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _buildInfoCard(),
                const SizedBox(height: 20),
                _buildEarningsHeader(snapshot),
                const SizedBox(height: 16),
                _buildSectionHeader(snapshot),
                const SizedBox(height: 12),
                ..._buildLedgerContent(snapshot),
              ],
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      titleSpacing: 4,
      title: const Text(
        'Driver ledger',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: _brandDark,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _brandGreen.withValues(alpha: 0.08),
            _brandGreen.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _brandGreen.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _brandGreen.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: _brandGreen,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Collect the fare directly from the passenger in cash. This screen keeps a digital trip record only — the app does not process or transfer money.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF4A5C52),
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEarningsHeader(
      AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
      ) {
    final entries = snapshot.data ?? const <Map<String, dynamic>>[];
    final total = entries.fold<double>(0, (runningTotal, entry) {
      final fare =
          entry['cashFarePhp'] ?? entry['farePhp'] ?? entry['driverCreditPhp'];
      return runningTotal + _toDouble(fare);
    });
    final count = entries.length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1AA36B), _brandGreen],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _brandGreen.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Total cash collected',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _formatPhp(total),
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.3,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.receipt_long_outlined,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  '$count ${count == 1 ? 'completed ride' : 'completed rides'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
      AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
      ) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _brandGreen.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.list_alt_rounded,
            size: 18,
            color: _brandGreen,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Cash fare records',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _brandDark,
              letterSpacing: 0.2,
            ),
          ),
        ),
        if (snapshot.connectionState == ConnectionState.waiting)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _brandGreen,
            ),
          ),
      ],
    );
  }

  List<Widget> _buildLedgerContent(
      AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
      ) {
    if (snapshot.hasError) {
      return [
        _buildErrorCard('Could not load ledger entries: ${snapshot.error}'),
      ];
    }

    if (snapshot.connectionState == ConnectionState.waiting) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: CircularProgressIndicator(color: _brandGreen),
          ),
        ),
      ];
    }

    final entries = snapshot.data ?? const <Map<String, dynamic>>[];
    if (entries.isEmpty) {
      return [_buildEmptyState()];
    }

    return [
      for (int i = 0; i < entries.length; i++) ...[
        _buildLedgerCard(entries[i]),
        if (i != entries.length - 1) const SizedBox(height: 10),
      ],
    ];
  }

  Widget _buildErrorCard(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _dangerRed.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _dangerRed.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: _dangerRed,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                color: _dangerRed,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _brandGreen.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.receipt_long_outlined,
              color: _brandGreen,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'No records yet',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: _brandDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Completed cash fare records will appear here once you finish your first ride.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.black54,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerCard(Map<String, dynamic> entry) {
    final fare =
        entry['cashFarePhp'] ?? entry['farePhp'] ?? entry['driverCreditPhp'];
    final isCash = entry['paymentMethod'] == 'cash';
    final rideId = entry['rideId']?.toString() ?? '—';
    final shortRideId = rideId.length > 12
        ? '${rideId.substring(0, 8)}…'
        : rideId;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isCash
                      ? Icons.payments_outlined
                      : Icons.history_rounded,
                  size: 20,
                  color: _brandGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCash
                          ? 'Cash fare recorded'
                          : 'Historical ledger record',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _brandDark,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _formatDate(entry['createdAt']),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _formatPhp(fare),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: _brandGreen,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.black.withValues(alpha: 0.05),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.confirmation_number_outlined,
                  size: 14,
                  color: _brandGreen,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Ride ID',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  shortRideId,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _brandDark,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size: 14,
                  color: _brandGreen,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}