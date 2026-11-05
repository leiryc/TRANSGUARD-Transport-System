import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ride_chat_message.dart';
import '../models/ride_model.dart';
import '../screens/ride_chat_screen.dart';
import '../services/ride_contact_service.dart';

/// "Message" (and, for passengers, "Call") buttons shown on the tracking
/// screens while the driver is on the way. Shows an unread count, a preview
/// of the latest message, and an in-app alert when a new message arrives.
class RideContactActions extends StatefulWidget {
  const RideContactActions({
    super.key,
    required this.ride,
    required this.viewerRole,
    this.otherPartyName,
  });

  final RideModel ride;

  /// 'passenger' or 'driver'.
  final String viewerRole;
  final String? otherPartyName;

  @override
  State<RideContactActions> createState() => _RideContactActionsState();
}

class _RideContactActionsState extends State<RideContactActions> {
  static const Color _brandGreen = Color(0xFF168A5B);

  final RideContactService _contactService = RideContactService();
  final Set<String> _seenMessageIds = {};
  StreamSubscription<List<RideChatMessage>>? _subscription;
  List<RideChatMessage> _messages = const [];
  bool _hasLoadedMessages = false;
  DateTime? _lastReadAt;
  bool _hasLoadedLastRead = false;
  bool _isChatOpen = false;
  bool _isCalling = false;

  bool get _isPassenger => widget.viewerRole == 'passenger';
  String get _otherPartyLabel => _isPassenger ? 'Driver' : 'Passenger';

  @override
  void initState() {
    super.initState();
    _loadLastRead();
    _subscription = _contactService
        .watchMessages(widget.ride.id)
        .listen(
          _onMessages,
          onError: (Object error) =>
              debugPrint('Ride chat unavailable: $error'),
        );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _loadLastRead() async {
    final lastReadAt = await _contactService.lastReadAt(widget.ride.id);
    if (!mounted) return;
    setState(() {
      _lastReadAt = lastReadAt;
      _hasLoadedLastRead = true;
    });
  }

  bool _isFromOtherParty(RideChatMessage message) =>
      message.senderId != FirebaseAuth.instance.currentUser?.uid;

  void _onMessages(List<RideChatMessage> messages) {
    if (!mounted) return;
    // Only alert for messages that arrive after the first load.
    final newIncoming = _hasLoadedMessages
        ? messages
              .where(
                (message) =>
                    !_seenMessageIds.contains(message.id) &&
                    _isFromOtherParty(message),
              )
              .toList()
        : const <RideChatMessage>[];
    _seenMessageIds.addAll(messages.map((message) => message.id));
    setState(() {
      _messages = messages;
      _hasLoadedMessages = true;
    });
    if (newIncoming.isNotEmpty && !_isChatOpen) {
      _showNewMessageAlert(newIncoming.last);
    }
  }

  int get _unreadCount {
    if (!_hasLoadedLastRead) return 0;
    final lastReadAt = _lastReadAt;
    return _messages.where((message) {
      if (!_isFromOtherParty(message)) return false;
      final createdAt = message.createdAt;
      return lastReadAt == null ||
          createdAt == null ||
          createdAt.isAfter(lastReadAt);
    }).length;
  }

  void _showNewMessageAlert(RideChatMessage message) {
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '$_otherPartyLabel: ${message.text}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          // SnackBars with an action stay up until dismissed unless told
          // otherwise; this one should time out.
          persist: false,
          action: SnackBarAction(label: 'Reply', onPressed: _openChat),
        ),
      );
  }

  Future<void> _openChat() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _isChatOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RideChatScreen(
          rideId: widget.ride.id,
          viewerRole: widget.viewerRole,
          otherPartyName: widget.otherPartyName,
        ),
      ),
    );
    _isChatOpen = false;
    if (mounted) await _loadLastRead();
  }

  Future<void> _callDriver() async {
    final driverId = widget.ride.driverId;
    if (driverId == null) return;
    setState(() => _isCalling = true);
    try {
      final phone = await _contactService.fetchDriverPhone(driverId);
      if (!mounted) return;
      if (phone == null) {
        _showMessage(
          'Your driver has no phone number on file. Send a message instead.',
        );
        return;
      }
      final launched = await launchUrl(Uri(scheme: 'tel', path: phone));
      if (!launched && mounted) _showMessage('Could not open the phone app.');
    } catch (error) {
      debugPrint('Could not call the driver: $error');
      if (mounted) {
        _showMessage(
          "Could not get your driver's number. Send a message instead.",
        );
      }
    } finally {
      if (mounted) setState(() => _isCalling = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final unread = _unreadCount;
    final latest = _messages.isEmpty ? null : _messages.last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _openChat,
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
                ),
                label: Text(
                  _isPassenger ? 'Message driver' : 'Message passenger',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _brandGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            if (_isPassenger) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _isCalling ? null : _callDriver,
                icon: _isCalling
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.call_outlined, size: 20),
                label: const Text('Call'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _brandGreen,
                  side: const BorderSide(color: _brandGreen, width: 1.5),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  shape: const StadiumBorder(),
                ),
              ),
            ],
          ],
        ),
        if (latest != null) ...[
          const SizedBox(height: 8),
          Text(
            '${_isFromOtherParty(latest) ? _otherPartyLabel : 'You'}: '
            '${latest.text}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ],
    );
  }
}
