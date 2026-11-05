import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/ride_model.dart';
import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../../services/driver_accreditation_service.dart';
import '../../services/passenger_id_service.dart';
import '../../services/ride_service.dart';
import '../../services/security_audit_service.dart';
import '../ride_chat_screen.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final RideService _rideService = RideService();
  final DriverAccreditationService _accreditationService =
      DriverAccreditationService();
  final SecurityAuditService _securityAuditService = SecurityAuditService();
  final PassengerIdService _passengerIdService = PassengerIdService();
  late Future<Map<String, dynamic>> _report;
  late Future<Map<String, dynamic>> _financialReport;

  @override
  void initState() {
    super.initState();
    _report = _rideService.getAdminRideReport();
    _financialReport = _rideService.getAdminFinancialReport();
  }

  void _refresh() {
    setState(() {
      _report = _rideService.getAdminRideReport();
      _financialReport = _rideService.getAdminFinancialReport();
    });
  }

  int _count(Map<String, dynamic> counts, String status) {
    final value = counts[status];
    return value is num ? value.toInt() : 0;
  }

  String _date(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return 'Date unavailable';
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin ride reports'),
        actions: [
          IconButton(
            tooltip: 'Refresh report',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              await context.read<AuthService>().signout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacementNamed('/login');
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _report,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Could not load admin report: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final report = snapshot.data!;
          final counts = Map<String, dynamic>.from(
            report['counts'] as Map? ?? const {},
          );
          final rides = (report['recentRides'] as List? ?? const [])
              .whereType<Map>()
              .map((ride) => Map<String, dynamic>.from(ride))
              .toList();
          final total = report['totalRides'] as num? ?? 0;
          final cashTotal = report['completedCashFarePhp'] as num? ?? 0;
          final averageDistance =
              report['averageCompletedDistanceKm'] as num? ?? 0;
          final forecast = Map<String, dynamic>.from(
            report['demandForecast'] as Map? ?? const {},
          );
          final ridesByDate = Map<String, dynamic>.from(
            report['ridesByDate'] as Map? ?? const {},
          );
          final recentDays = ridesByDate.keys.toList()..sort();
          final visibleDays = recentDays.length > 7
              ? recentDays.sublist(recentDays.length - 7)
              : recentDays;
          final busiestDayCount = visibleDays.fold<int>(
            0,
            (current, day) => _count(ridesByDate, day) > current
                ? _count(ridesByDate, day)
                : current,
          );

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SecurityAuditSection(
                service: _securityAuditService,
                accreditationService: _accreditationService,
              ),
              const SizedBox(height: 20),
              _DriverAccreditationSection(service: _accreditationService),
              const SizedBox(height: 20),
              _PassengerIdReviewSection(service: _passengerIdService),
              const SizedBox(height: 20),
              _FinancialAuditSection(
                report: _financialReport,
                ridesByDate: ridesByDate,
              ),
              const SizedBox(height: 20),
              Text(
                'Last ${report['periodDays'] ?? 30} days',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (report['capped'] == true)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Report is limited to the latest 1,000 rides in this period.',
                  ),
                ),
              const SizedBox(height: 12),
              _ReportMetric(label: 'Rides', value: '$total'),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Completed',
                value: '${_count(counts, 'completed')}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Active',
                value:
                    '${_count(counts, 'requested') + _count(counts, 'accepted') + _count(counts, 'in_progress')}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Cancelled',
                value: '${_count(counts, 'cancelled')}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Recorded cash fares',
                value: '₱${cashTotal.toStringAsFixed(2)}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Average completed trip distance',
                value: '${averageDistance.toStringAsFixed(1)} km',
              ),
              const SizedBox(height: 20),
              _DemandOutlook(forecast: forecast),
              const SizedBox(height: 20),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.bar_chart_rounded),
                  title: const Text('Ride volume by day (UTC)'),
                  subtitle: const Text('Tap to view daily ride counts'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    for (final day in visibleDays)
                      _DailyRideVolume(
                        day: day,
                        count: _count(ridesByDate, day),
                        maximum: busiestDayCount,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Recent rides'),
                  subtitle: const Text('Tap to view recent ride records'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (rides.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No rides were recorded during this period.',
                          ),
                        ),
                      ),
                    for (final ride in rides)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.receipt_long_outlined),
                          title: Text(
                            '${ride['status'] ?? 'Unknown'}${ride['farePhp'] is num ? ' · ₱${(ride['farePhp'] as num).toStringAsFixed(2)}' : ''}',
                          ),
                          subtitle: Text(
                            '${_date(ride['createdAt'])}\n${ride['pickupLocation'] ?? ''} → ${ride['dropoffLocation'] ?? ''}',
                          ),
                          isThreeLine: true,
                          trailing: ride['id'] is String
                              ? IconButton(
                                  tooltip: 'View chat',
                                  icon: const Icon(Icons.forum_outlined),
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => RideChatScreen(
                                        rideId: ride['id'] as String,
                                        viewerRole: 'admin',
                                      ),
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Reports show ride records and cash-fare amounts only; they do not represent payment processing or money held by the platform.',
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FinancialAuditSection extends StatelessWidget {
  const _FinancialAuditSection({
    required this.report,
    required this.ridesByDate,
  });

  final Future<Map<String, dynamic>> report;
  final Map<String, dynamic> ridesByDate;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: report,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Could not load financial ledger: ${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final data = snapshot.data!;
        final daily = Map<String, dynamic>.from(
          data['daily'] as Map? ?? const {},
        );
        final recentTransactions =
            (data['recentTransactions'] as List? ?? const [])
                .whereType<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList();
        final days = <String>{...ridesByDate.keys, ...daily.keys}.toList()
          ..sort((a, b) => b.compareTo(a));
        final visibleDays = days.take(14);
        final cashFares = data['totalCashFaresPhp'] as num? ?? 0;
        final driverAllocation = data['driverAllocationPhp'] as num? ?? 0;
        final coopFee = data['cooperativeFeePhp'] as num? ?? 0;

        return Card(
          child: ExpansionTile(
            leading: const Icon(Icons.account_balance_outlined),
            title: const Text('Transaction audit'),
            subtitle: Text(
              'Last ${data['periodDays'] ?? 35} days · ledger totals',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              if (data['capped'] == true)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Ledger summary is limited to the latest 1,000 transactions.',
                  ),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Cash accounting only; no funds are processed or transferred. '
                  'New fares are allocated 70% to the driver and 30% to the '
                  'cooperative. The driver collects the full cash fare and '
                  'remits the cooperative share separately.',
                ),
              ),
              _ReportMetric(
                label: 'Recorded cash fares',
                value: '₱${cashFares.toStringAsFixed(2)}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Completed cash transactions',
                value: '${data['completedTransactions'] ?? 0}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Driver cash allocation',
                value: '₱${driverAllocation.toStringAsFixed(2)}',
              ),
              const SizedBox(height: 8),
              _ReportMetric(
                label: 'Cooperative fee allocation',
                value: '₱${coopFee.toStringAsFixed(2)}',
              ),
              if ((data['legacyEntries'] as num? ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${data['legacyEntries']} legacy ledger entries lack one or '
                    'more split details; totals use the recorded cash fare '
                    'and the historical full-driver/zero-fee fallback.',
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'Daily ride and ledger totals (UTC)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final day in visibleDays)
                _DailyFinancialSummary(
                  day: day,
                  rideCount: _readCount(ridesByDate[day]),
                  transaction: Map<String, dynamic>.from(
                    daily[day] as Map? ?? const {},
                  ),
                ),
              if (recentTransactions.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Recent immutable cash records'),
                  children: [
                    for (final entry in recentTransactions)
                      _FinancialTransactionTile(entry: entry),
                  ],
                ),
              if (days.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No ride or transaction records in this period.'),
                ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Completed transaction records are immutable after creation. '
                  'They are client-submitted cash records, not independently '
                  'verified payment receipts.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  int _readCount(Object? value) => value is num ? value.toInt() : 0;
}

class _FinancialTransactionTile extends StatelessWidget {
  const _FinancialTransactionTile({required this.entry});

  final Map<String, dynamic> entry;

  String _date(Object? value) {
    if (value is! Timestamp) return 'Time unavailable';
    return value.toDate().toUtc().toString();
  }

  @override
  Widget build(BuildContext context) {
    final fare = entry['cashFarePhp'] as num? ?? 0;
    final driverShare = entry['driverAllocationPhp'] as num? ?? 0;
    final coopShare = entry['cooperativeFeePhp'] as num? ?? 0;
    final distance = entry['distanceKm'] as num?;
    final baseFare = entry['baseFarePhp'] as num?;
    final ratePerKm = entry['ratePerKmPhp'] as num?;
    final cooperativePercent = entry['cooperativeSharePercent'] as num? ?? 30;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(
        'Ride ${entry['rideId'] ?? 'unavailable'} · '
        '₱${fare.toStringAsFixed(2)}',
      ),
      subtitle: Text(
        '${_date(entry['createdAt'])}\n'
        'Driver ${entry['driverId'] ?? 'unavailable'} · '
        'Passenger ${entry['passengerId'] ?? 'unavailable'}\n'
        'Distance ${distance?.toStringAsFixed(2) ?? 'n/a'} km · '
        'Fare formula ₱${baseFare?.toStringAsFixed(2) ?? 'n/a'} base + '
        '₱${ratePerKm?.toStringAsFixed(2) ?? 'n/a'}/km\n'
        'Driver ₱${driverShare.toStringAsFixed(2)} · '
        'Co-op (${cooperativePercent.toStringAsFixed(0)}%) '
        '₱${coopShare.toStringAsFixed(2)}\n'
        'Formula ${entry['fareCalculationVersion'] ?? 'legacy record'}',
      ),
      isThreeLine: true,
    );
  }
}

class _DailyFinancialSummary extends StatelessWidget {
  const _DailyFinancialSummary({
    required this.day,
    required this.rideCount,
    required this.transaction,
  });

  final String day;
  final int rideCount;
  final Map<String, dynamic> transaction;

  @override
  Widget build(BuildContext context) {
    final transactions = transaction['transactions'] as int? ?? 0;
    final cashFares = transaction['cashFaresPhp'] as num? ?? 0;
    final driverAllocation = transaction['driverAllocationPhp'] as num? ?? 0;
    final cooperativeFee = transaction['cooperativeFeePhp'] as num? ?? 0;
    return Card(
      child: ListTile(
        title: Text(day),
        subtitle: Text(
          '$rideCount rides · $transactions completed cash fares\n'
          'Driver allocation ₱${driverAllocation.toStringAsFixed(2)} · '
          'Cooperative ₱${cooperativeFee.toStringAsFixed(2)}',
        ),
        trailing: Text(
          '₱${cashFares.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _SecurityAuditSection extends StatelessWidget {
  const _SecurityAuditSection({
    required this.service,
    required this.accreditationService,
  });

  final SecurityAuditService service;
  final DriverAccreditationService accreditationService;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.security_outlined),
        title: const Text('Security audit feed'),
        subtitle: const Text('Tap to view recent security events'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Client-reported indicators only; they are not verified '
                'server-side and may be incomplete or inaccurate.',
              ),
            ),
          ),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: service.watchEvents(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Could not load security events: ${snapshot.error}',
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }
              final events = snapshot.data!;
              if (events.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No client-reported security events.'),
                  ),
                );
              }
              return Column(
                children: [
                  for (final event in events)
                    _SecurityEventCard(
                      event: event,
                      accreditationService: accreditationService,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SecurityEventCard extends StatelessWidget {
  const _SecurityEventCard({
    required this.event,
    required this.accreditationService,
  });

  final Map<String, dynamic> event;
  final DriverAccreditationService accreditationService;

  String _label(String eventType) => switch (eventType) {
    'app_check_token_unavailable' => 'App Check token unavailable',
    'mock_location_detected' => 'Mock location signal',
    'gps_anomaly_detected' => 'Suspicious GPS activity',
    'root_indicator_detected' => 'Root indicator',
    'emulator_indicator_detected' => 'Emulator indicator',
    'firestore_permission_denied' => 'Firestore request rejected',
    _ => eventType,
  };

  String _date(Object? value) {
    if (value is! Timestamp) return 'Time unavailable';
    return value.toDate().toLocal().toString();
  }

  Future<void> _suspendDriver(BuildContext context, String driverId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke driver approval?'),
        content: const Text(
          'This revokes ride access in Firestore. It will not disable the '
          'Firebase Authentication account. A driver with an active ride '
          'cannot be revoked yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Revoke approval'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await accreditationService.setApproval(
        driverId,
        approved: false,
        rejected: false,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Driver approval revoked.')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not suspend driver: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final eventType = event['eventType']?.toString() ?? 'unknown';
    final actorUid = event['actorUid']?.toString();
    final flagged = eventType != 'firestore_permission_denied';
    return Card(
      child: ListTile(
        leading: Icon(
          flagged ? Icons.warning_amber_rounded : Icons.policy_outlined,
          color: flagged ? const Color(0xFFB7791F) : const Color(0xFF3D7EDB),
        ),
        title: Text(_label(eventType)),
        subtitle: Text(
          '${_date(event['occurredAt'])}\n'
          'Driver UID: ${actorUid ?? 'Unavailable'}\n'
          '${event['details'] ?? 'No details provided.'}\n'
          'Source: client-reported',
        ),
        isThreeLine: true,
        trailing: flagged && actorUid != null
            ? IconButton(
                tooltip: 'Revoke driver approval',
                onPressed: () => _suspendDriver(context, actorUid),
                icon: const Icon(Icons.block),
              )
            : null,
      ),
    );
  }
}

class _DriverAccreditationSection extends StatelessWidget {
  const _DriverAccreditationSection({required this.service});

  final DriverAccreditationService service;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Driver accreditation & fleet',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<UserModel>>(
          stream: service.watchDrivers(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Could not load drivers: ${snapshot.error}'),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }
            final drivers = snapshot.data!;
            if (drivers.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No driver applications or accounts found.'),
                ),
              );
            }
            return Column(
              children: [
                for (final driver in drivers)
                  _DriverAccreditationCard(driver: driver, service: service),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DriverAccreditationCard extends StatelessWidget {
  const _DriverAccreditationCard({required this.driver, required this.service});

  final UserModel driver;
  final DriverAccreditationService service;

  Future<void> _setApproval(
    BuildContext context, {
    required bool approved,
    required bool rejected,
  }) async {
    if (approved &&
        ((driver.franchiseNumber?.trim().isEmpty ?? true) ||
            (driver.plateNumber?.trim().isEmpty ?? true))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot approve: add the driver’s franchise and plate numbers '
            'to their Firestore profile, then retry.',
          ),
        ),
      );
      return;
    }

    try {
      await service.setApproval(
        driver.id,
        approved: approved,
        rejected: rejected,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approved ? 'Driver approved.' : 'Driver approval updated.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update approval: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        !driver.isApproved &&
        (driver.approvalStatus == null || driver.approvalStatus == 'pending');
    return Card(
      child: ExpansionTile(
        leading: Icon(
          driver.isApproved ? Icons.verified_user : Icons.pending_actions,
          color: driver.isApproved
              ? const Color(0xFF168A5B)
              : const Color(0xFFB7791F),
        ),
        title: Text(driver.name.isEmpty ? 'Driver application' : driver.name),
        subtitle: Text(
          '${driver.isApproved ? 'Approved' : driver.approvalStatus ?? 'Pending'}'
          ' · ${driver.email}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Phone: ${driver.phone.isEmpty ? 'Not provided' : driver.phone}\n'
              'MTFRB franchise: ${driver.franchiseNumber ?? 'Not provided'}\n'
              'LTO plate: ${driver.plateNumber ?? 'Not provided'}',
            ),
          ),
          const SizedBox(height: 10),
          _DriverOperationalStatus(driverId: driver.id),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!driver.isApproved)
                FilledButton.icon(
                  onPressed: () =>
                      _setApproval(context, approved: true, rejected: false),
                  icon: const Icon(Icons.check),
                  label: const Text('Approve'),
                ),
              if (pending)
                OutlinedButton.icon(
                  onPressed: () =>
                      _setApproval(context, approved: false, rejected: true),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              if (driver.isApproved)
                OutlinedButton.icon(
                  onPressed: () =>
                      _setApproval(context, approved: false, rejected: false),
                  icon: const Icon(Icons.block),
                  label: const Text('Revoke approval'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PassengerIdReviewSection extends StatefulWidget {
  const _PassengerIdReviewSection({required this.service});

  final PassengerIdService service;

  @override
  State<_PassengerIdReviewSection> createState() =>
      _PassengerIdReviewSectionState();
}

class _PassengerIdReviewSectionState extends State<_PassengerIdReviewSection> {
  static const _emptyMessages = {
    'pending': 'No passenger IDs waiting for review.',
    'verified': 'No verified passengers yet.',
    'rejected': 'No rejected IDs.',
  };

  String _status = 'pending';
  late Stream<List<UserModel>> _passengers = widget.service
      .watchPassengersByIdStatus(_status);

  void _selectStatus(String status) {
    if (status == _status) return;
    setState(() {
      _status = status;
      _passengers = widget.service.watchPassengersByIdStatus(status);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Passenger ID verification',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'pending', label: Text('Pending')),
            ButtonSegment(value: 'verified', label: Text('Verified')),
            ButtonSegment(value: 'rejected', label: Text('Rejected')),
          ],
          selected: {_status},
          onSelectionChanged: (selection) => _selectStatus(selection.single),
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<UserModel>>(
          // Keyed by tab so switching never shows the previous tab's list.
          key: ValueKey(_status),
          stream: _passengers,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Could not load passenger IDs: ${snapshot.error}',
                  ),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }
            final passengers = snapshot.data!;
            if (passengers.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_emptyMessages[_status]!),
                ),
              );
            }
            return Column(
              children: [
                for (final passenger in passengers)
                  _PassengerIdCard(
                    key: ValueKey(passenger.id),
                    passenger: passenger,
                    service: widget.service,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PassengerIdCard extends StatefulWidget {
  const _PassengerIdCard({
    super.key,
    required this.passenger,
    required this.service,
  });

  final UserModel passenger;
  final PassengerIdService service;

  @override
  State<_PassengerIdCard> createState() => _PassengerIdCardState();
}

class _PassengerIdCardState extends State<_PassengerIdCard> {
  Future<IdImage?>? _image;
  bool _isReviewing = false;

  // Loaded on first expand so the dashboard doesn't download every photo.
  Future<IdImage?> get _loadImage =>
      _image ??= widget.service.loadIdImage(widget.passenger.id);

  Future<void> _review({required bool verified}) async {
    String? reason;
    if (!verified) {
      final controller = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reject ID'),
          content: TextField(
            controller: controller,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Reason shown to the passenger (optional)',
              hintText: 'e.g. Photo is blurry',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reject'),
            ),
          ],
        ),
      );
      reason = controller.text;
      controller.dispose();
      if (confirmed != true || !mounted) return;
    }

    setState(() => _isReviewing = true);
    try {
      await widget.service.review(
        widget.passenger.id,
        verified: verified,
        rejectionReason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(verified ? 'Passenger verified.' : 'ID rejected.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isReviewing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the review: $error')),
      );
    }
  }

  void _openFullScreen(IdImage image) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(child: Image.memory(image.bytes)),
              ),
            ),
            SafeArea(
              child: IconButton(
                tooltip: 'Close',
                color: Colors.white,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(date)}, '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  @override
  Widget build(BuildContext context) {
    final passenger = widget.passenger;
    final status = passenger.idVerificationStatus;
    final isPending = status == 'pending';
    final (IconData icon, Color color, String dateLabel, DateTime? date) =
        switch (status) {
          'verified' => (
            Icons.verified_user,
            const Color(0xFF168A5B),
            'Verified',
            passenger.idReviewedAt,
          ),
          'rejected' => (
            Icons.gpp_bad_outlined,
            const Color(0xFFD64545),
            'Rejected',
            passenger.idReviewedAt,
          ),
          _ => (
            Icons.badge_outlined,
            const Color(0xFFB7791F),
            'Submitted',
            passenger.idSubmittedAt,
          ),
        };
    final rejectionReason = passenger.idRejectionReason?.trim() ?? '';
    return Card(
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(passenger.name.isEmpty ? 'Passenger' : passenger.name),
        subtitle: Text(
          '${PassengerIdService.labelFor(passenger.idType)} · '
          '${passenger.email}'
          '${date == null ? '' : '\n$dateLabel ${_formatDate(date)}'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Phone: ${passenger.phone.isEmpty ? 'Not provided' : passenger.phone}',
            ),
          ),
          if (status == 'rejected') ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Reason: '
                '${rejectionReason.isEmpty ? 'None given' : rejectionReason}',
              ),
            ),
          ],
          const SizedBox(height: 10),
          FutureBuilder<IdImage?>(
            future: _loadImage,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final image = snapshot.data;
              if (snapshot.hasError || image == null) {
                return Text(
                  snapshot.hasError
                      ? 'Could not load the ID photo: ${snapshot.error}'
                      : 'No ID photo found for this passenger.',
                );
              }
              return InkWell(
                onTap: () => _openFullScreen(image),
                borderRadius: BorderRadius.circular(12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    image.bytes,
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isPending
                  ? 'Tap the photo to zoom. Check that the name matches the '
                        'account.'
                  : 'Tap the photo to zoom.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          if (isPending) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _isReviewing
                      ? null
                      : () => _review(verified: true),
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Verify'),
                ),
                OutlinedButton.icon(
                  onPressed: _isReviewing
                      ? null
                      : () => _review(verified: false),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DriverOperationalStatus extends StatelessWidget {
  const _DriverOperationalStatus({required this.driverId});

  final String driverId;

  @override
  Widget build(BuildContext context) {
    final rideService = RideService();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('driver_presence')
          .doc(driverId)
          .snapshots(includeMetadataChanges: true),
      builder: (context, presenceSnapshot) {
        if (presenceSnapshot.hasError) {
          return Text(
            'Operational status unavailable: ${presenceSnapshot.error}',
          );
        }
        final presence = presenceSnapshot.data?.data();
        return StreamBuilder<RideModel?>(
          stream: rideService.getDriverCurrentRide(driverId),
          builder: (context, rideSnapshot) {
            if (rideSnapshot.hasError) {
              return Text(
                'Operational status unavailable: ${rideSnapshot.error}',
              );
            }
            final rideStatus = rideSnapshot.data?.status;
            final status = rideStatus == 'accepted'
                ? 'En-Route'
                : rideStatus == 'in_progress'
                ? 'In-Transit'
                : presence?['isOnline'] == true
                ? 'Online'
                : 'Offline';
            return Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                avatar: const Icon(Icons.circle, size: 12),
                label: Text('Current status: $status'),
              ),
            );
          },
        );
      },
    );
  }
}

class _ReportMetric extends StatelessWidget {
  final String label;
  final String value;

  const _ReportMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(label),
        trailing: Text(
          value,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _DailyRideVolume extends StatelessWidget {
  final String day;
  final int count;
  final int maximum;

  const _DailyRideVolume({
    required this.day,
    required this.count,
    required this.maximum,
  });

  @override
  Widget build(BuildContext context) {
    final progress = maximum == 0 ? 0.0 : count / maximum;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 92, child: Text(day)),
          Expanded(
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 24, child: Text('$count')),
        ],
      ),
    );
  }
}

class _DemandOutlook extends StatelessWidget {
  const _DemandOutlook({required this.forecast});

  final Map<String, dynamic> forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hourlyTrend = (forecast['hourlyTrend'] as List? ?? const [])
        .whereType<Map>()
        .map((hour) => Map<String, dynamic>.from(hour))
        .toList();
    final todayHourlyTrend = (forecast['todayHourlyTrend'] as List? ?? const [])
        .whereType<Map>()
        .map((hour) => Map<String, dynamic>.from(hour))
        .toList();
    final mlForecast = Map<String, dynamic>.from(
      forecast['mlDemandForecast'] as Map? ?? const {},
    );
    final mlPredictions = (mlForecast['predictions'] as List? ?? const [])
        .whereType<Map>()
        .map((prediction) => Map<String, dynamic>.from(prediction))
        .toList();
    final mlValues = mlPredictions
        .map(
          (prediction) =>
              (prediction['predictedRequests'] as num? ?? 0).toDouble(),
        )
        .toList();
    final mlTotal = mlValues.fold<double>(0, (total, value) => total + value);
    final peakForecast = mlPredictions.isEmpty
        ? null
        : mlPredictions.reduce(
            (a, b) =>
                (a['predictedRequests'] as num).compareTo(
                      b['predictedRequests'] as num,
                    ) >=
                    0
                ? a
                : b,
          );
    final forecastStart = DateTime.tryParse(
      mlForecast['forecastStart']?.toString() ?? '',
    );
    final demandZones = (forecast['topDemandZones'] as List? ?? const [])
        .whereType<Map>()
        .map((zone) => Map<String, dynamic>.from(zone))
        .toList();
    final recommendations = (forecast['recommendations'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final averages = hourlyTrend
        .map((hour) => (hour['averageRequests'] as num? ?? 0).toDouble())
        .toList();
    final palette = [
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
      theme.colorScheme.tertiary,
      Colors.deepOrange,
    ];
    final zoneSeries = demandZones.take(4).map((zone) {
      final values = (zone['hourlyTrend'] as List? ?? const [])
          .map((value) => (value as num).toDouble())
          .toList();
      return {
        'label': zone['label']?.toString() ?? 'Pickup grid',
        'values': values,
      };
    }).toList();
    final chartSeries = <Map<String, dynamic>>[
      if (todayHourlyTrend.isNotEmpty)
        {
          'label': 'Today actual rides',
          'values': todayHourlyTrend
              .map((hour) => (hour['rideCount'] as num? ?? 0).toDouble())
              .toList(),
        },
      ...zoneSeries,
      if (zoneSeries.isEmpty && todayHourlyTrend.isEmpty)
        {'label': 'Historical average', 'values': averages},
    ];
    final comparableDates = forecast['comparableDates'] as int? ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Actual ride activity and historical demand',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Today’s actual rides and weekday-matched historical averages · '
              '${forecast['timezone'] ?? 'UTC'} · '
              '$comparableDates comparable days',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              '${todayHourlyTrend.fold<int>(0, (total, hour) => total + ((hour['rideCount'] as num?)?.toInt() ?? 0))} '
              'rides recorded today · '
              '${(forecast['averageRequestsPerHour'] as num? ?? 0).toStringAsFixed(1)} '
              'average requests in the current hour on matching weekdays '
              '(${forecast['level'] ?? 'low'} historical level).',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'Hourly ride activity and demand by pickup grid · UTC',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (chartSeries.every(
              (series) => (series['values'] as List<double>).isEmpty,
            ))
              const Text(
                'No actual or historical hourly ride data is available.',
              )
            else
              Semantics(
                label: 'Line chart of average hourly pickups for the top approximate pickup grid clusters in UTC.',
                child: SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _HourlyDemandPainter(
                      series: chartSeries,
                      colors: palette,
                      gridColor: theme.dividerColor,
                      labelColor: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            if (chartSeries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    for (var index = 0; index < chartSeries.length; index++)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 3,
                            color: palette[index % palette.length],
                          ),
                          const SizedBox(width: 5),
                          Text(
                            chartSeries[index]['label'] as String,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'The highlighted line shows actual rides recorded today. Other '
              'lines show weekday-matched historical hourly averages for the '
              'top pickup grids. The ML forecast below is a separate model '
              'trained from recorded rides.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            Text(
              'AI/ML demand prediction · next 24 hours',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            if (mlForecast['available'] != true)
              Text(
                mlForecast['reason']?.toString() ?? 'A forecast is unavailable until sufficient ride history is available.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                'Model: ${mlForecast['model']} · trained on '
                '${mlForecast['trainingRideCount']} rides across '
                '${mlForecast['trainingDays']} days · UTC',
                style: theme.textTheme.bodySmall,
              ),
              if (mlForecast['trainingCapped'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Training data is limited to the latest 1,000 rides included in the report.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Expected total: ${mlTotal.toStringAsFixed(1)} rides'
                '${peakForecast == null ? '' : ' · busiest hour: ${peakForecast['label']} (${(peakForecast['predictedRequests'] as num).toStringAsFixed(1)} expected)'}.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (mlValues.isNotEmpty)
                Semantics(
                  label: 'Machine learning prediction of expected ride requests during each of the next 24 hours.',
                  child: SizedBox(
                    height: 180,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _HourlyDemandPainter(
                        series: [
                          {'label': 'ML predicted rides', 'values': mlValues},
                        ],
                        colors: [theme.colorScheme.tertiary],
                        gridColor: theme.dividerColor,
                        labelColor: theme.colorScheme.onSurfaceVariant,
                        startHour: forecastStart?.hour ?? 0,
                      ),
                    ),
                  ),
                ),
              if (forecastStart != null)
                Text(
                  'Forecast begins ${forecastStart.month.toString().padLeft(2, '0')}/${forecastStart.day.toString().padLeft(2, '0')} at ${forecastStart.hour.toString().padLeft(2, '0')}:00 UTC. Predictions are estimates, not guarantees.',
                  style: theme.textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: 16),
            Text(
              'Highest-demand approximate pickup grids',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'For San Francisco, Agusan del Sur planning: top valid pickup '
              'clusters in this report, not geofenced or authoritative municipal zones.',
              style: theme.textTheme.bodySmall,
            ),
            if (demandZones.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No valid pickup coordinates to rank zones.'),
              )
            else
              for (var index = 0; index < demandZones.length; index++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${index + 1}.',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${demandZones[index]['label']} '
                          '(${demandZones[index]['demandClusterId']})',
                        ),
                      ),
                      Text(
                        '${(demandZones[index]['averageRequests'] as num? ?? 0).toStringAsFixed(1)}/day',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            if (demandZones.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Estimated surge hours by grid · UTC',
                style: theme.textTheme.titleSmall,
              ),
              for (final zone in demandZones)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(zone['label']?.toString() ?? 'Pickup grid'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: Text(
                          _surgeHourLabels(zone['surgeHours'] as List?),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Text('Fleet guidance', style: theme.textTheme.titleSmall),
            for (final recommendation in recommendations)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.tips_and_updates_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(recommendation)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Pickup coordinates are snapped in memory to a 0.01° grid '
              '(about 1.1 km north–south). Clusters are approximate and '
              'longitude cell width varies by latitude. No ride documents '
              'are changed.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _surgeHourLabels(List? surgeHours) {
    if (surgeHours == null || surgeHours.isEmpty) {
      return 'No surge window detected';
    }
    return surgeHours
        .whereType<num>()
        .map((hour) => '${hour.toInt().toString().padLeft(2, '0')}:00')
        .join(', ');
  }
}

class _HourlyDemandPainter extends CustomPainter {
  const _HourlyDemandPainter({
    required this.series,
    required this.colors,
    required this.gridColor,
    required this.labelColor,
    this.startHour = 0,
  });

  final List<Map<String, dynamic>> series;
  final List<Color> colors;
  final Color gridColor;
  final Color labelColor;
  final int startHour;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty || size.width <= 0 || size.height <= 0) return;
    const left = 30.0;
    const right = 6.0;
    const top = 8.0;
    const bottom = 25.0;
    final chartWidth = size.width - left - right;
    final chartHeight = size.height - top - bottom;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    final values = series
        .expand((line) => line['values'] as List<double>)
        .toList();
    if (values.isEmpty) return;
    final maximum = values.reduce((a, b) => a > b ? a : b);
    final scaleMaximum = maximum <= 0 ? 1.0 : maximum;
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.7;
    final textStyle = TextStyle(color: labelColor, fontSize: 10);

    for (var line = 0; line <= 2; line++) {
      final y = top + chartHeight * line / 2;
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - right, y),
        gridPaint,
      );
      final value = scaleMaximum * (2 - line) / 2;
      final textPainter = TextPainter(
        text: TextSpan(text: value.toStringAsFixed(0), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 4);
      textPainter.paint(canvas, Offset(0, y - textPainter.height / 2));
    }

    final slotWidth = chartWidth / 23;
    for (var seriesIndex = 0; seriesIndex < series.length; seriesIndex++) {
      final lineValues = series[seriesIndex]['values'] as List<double>;
      if (lineValues.isEmpty) continue;
      final linePaint = Paint()
        ..color = colors[seriesIndex % colors.length]
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final pointPaint = Paint()
        ..color = colors[seriesIndex % colors.length]
        ..style = PaintingStyle.fill;
      final path = Path();
      for (var hour = 0; hour < lineValues.length; hour++) {
        final x = left + hour * slotWidth;
        final y =
            top +
            chartHeight -
            (lineValues[hour] / scaleMaximum).clamp(0.0, 1.0) * chartHeight;
        if (hour == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.2, pointPaint);
      }
      canvas.drawPath(path, linePaint);
    }

    for (final hour in const [0, 6, 12, 18, 23]) {
      final displayedHour = (startHour + hour) % 24;
      final textPainter = TextPainter(
        text: TextSpan(
          text: displayedHour.toString().padLeft(2, '0'),
          style: textStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = left + hour * slotWidth - textPainter.width / 2;
      textPainter.paint(
        canvas,
        Offset(
          x.clamp(left, size.width - right - textPainter.width),
          top + chartHeight + 5,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HourlyDemandPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.colors != colors ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.labelColor != labelColor ||
      oldDelegate.startHour != startHour;
}
