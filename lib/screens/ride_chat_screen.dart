import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/ride_chat_message.dart';
import '../models/ride_model.dart';
import '../services/ride_contact_service.dart';
import '../services/ride_service.dart';

/// Chat between a ride's passenger and driver. Messages can only be sent
/// while the driver is on the way (ride status 'accepted'). Admins get a
/// read-only view for reviewing reported problems.
class RideChatScreen extends StatefulWidget {
  const RideChatScreen({
    super.key,
    required this.rideId,
    required this.viewerRole,
    this.otherPartyName,
  });

  final String rideId;

  /// 'passenger', 'driver', or 'admin' (read-only).
  final String viewerRole;
  final String? otherPartyName;

  @override
  State<RideChatScreen> createState() => _RideChatScreenState();
}

class _RideChatScreenState extends State<RideChatScreen> {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);

  final RideContactService _contactService = RideContactService();
  final TextEditingController _textController = TextEditingController();
  StreamSubscription<List<RideChatMessage>>? _messagesSubscription;
  StreamSubscription<RideModel?>? _rideSubscription;
  List<RideChatMessage> _messages = const [];
  bool _hasLoadedMessages = false;
  Object? _messagesError;
  String? _rideStatus;
  bool _hasLoadedRide = false;

  bool get _isAdmin => widget.viewerRole == 'admin';
  bool get _canSend => !_isAdmin && _rideStatus == 'accepted';
  String? get _currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _messagesSubscription = _contactService
        .watchMessages(widget.rideId)
        .listen(
          (messages) {
            if (!mounted) return;
            setState(() {
              _messages = messages;
              _hasLoadedMessages = true;
              _messagesError = null;
            });
            _markRead(messages);
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _messagesError = error;
              _hasLoadedMessages = true;
            });
          },
        );
    if (!_isAdmin) {
      _rideSubscription = RideService()
          .watchRide(widget.rideId)
          .listen(
            (ride) {
              if (!mounted) return;
              setState(() {
                _rideStatus = ride?.status;
                _hasLoadedRide = true;
              });
            },
            onError: (Object _) {
              if (mounted) setState(() => _hasLoadedRide = true);
            },
          );
    }
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _rideSubscription?.cancel();
    _textController.dispose();
    super.dispose();
  }

  void _markRead(List<RideChatMessage> messages) {
    if (_isAdmin) return;
    DateTime? latest;
    for (final message in messages) {
      final createdAt = message.createdAt;
      if (message.senderId == _currentUserId || createdAt == null) continue;
      if (latest == null || createdAt.isAfter(latest)) latest = createdAt;
    }
    if (latest != null) _contactService.markRead(widget.rideId, latest);
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_canSend) return;
    final sentFromInput = _textController.text.trim() == trimmed;
    if (sentFromInput) _textController.clear();
    try {
      await _contactService.sendMessage(
        widget.rideId,
        senderRole: widget.viewerRole,
        text: trimmed,
      );
    } catch (error) {
      if (!mounted) return;
      if (sentFromInput && _textController.text.isEmpty) {
        _textController.text = trimmed;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error is StateError
                  ? error.message
                  : 'Could not send the message.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  String? get _bannerText {
    if (_isAdmin) {
      return 'Read-only. Ride chats are kept so admins can review reported '
          'problems.';
    }
    if (!_hasLoadedRide) return null;
    return switch (_rideStatus) {
      'accepted' => null,
      'in_progress' => 'Chat closed: the trip has started.',
      'completed' => 'Chat closed: this ride is complete.',
      'cancelled' => 'Chat closed: this ride was cancelled.',
      _ => 'Chat is only available while the driver is on the way.',
    };
  }

  String get _emptyText => switch (widget.viewerRole) {
    'driver' =>
      "No messages yet. Use a quick reply so you don't have to type while "
          'driving.',
    'passenger' =>
      'No messages yet. Let your driver know if you need anything, like '
          'exactly where you are waiting.',
    _ => 'No messages were sent on this ride.',
  };

  String _formatTime(DateTime time) {
    final localizations = MaterialLocalizations.of(context);
    final clock = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time));
    return _isAdmin ? '${localizations.formatShortDate(time)} $clock' : clock;
  }

  @override
  Widget build(BuildContext context) {
    final bannerText = _bannerText;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F8),
      appBar: _buildAppBar(),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (bannerText != null) _buildBanner(bannerText),
            Expanded(child: _buildMessageList()),
            if (_canSend) _buildComposer(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final title = switch (widget.viewerRole) {
      'driver' => 'Chat with passenger',
      'passenger' => 'Chat with your driver',
      _ => 'Ride chat',
    };
    final name = widget.otherPartyName?.trim();
    final subtitle = _isAdmin
        ? 'Ride ${widget.rideId}'
        : name == null || name.isEmpty
        ? null
        : name;
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 4,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _brandDark,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
        ],
      ),
    );
  }

  Widget _buildBanner(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _isAdmin ? const Color(0xFFEAF4EF) : const Color(0xFFFFF4E5),
      child: Row(
        children: [
          Icon(
            _isAdmin ? Icons.shield_outlined : Icons.lock_outline,
            size: 18,
            color: _isAdmin ? _brandGreen : const Color(0xFFB7791F),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: _brandDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (!_hasLoadedMessages) {
      return const Center(child: CircularProgressIndicator(color: _brandGreen));
    }
    if (_messagesError != null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Could not load messages. Check your connection and try again.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _emptyText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, height: 1.4),
          ),
        ),
      );
    }
    // Reversed so the newest message sits at the bottom and the list stays
    // scrolled there as messages arrive.
    final newestFirst = _messages.reversed.toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: newestFirst.length,
      itemBuilder: (context, index) => _buildBubble(newestFirst[index]),
    );
  }

  Widget _buildBubble(RideChatMessage message) {
    // Admins see the driver on the right and the passenger on the left.
    final alignRight = _isAdmin
        ? message.senderRole == 'driver'
        : message.senderId == _currentUserId;
    final createdAt = message.createdAt;
    final meta = message.isPending || createdAt == null
        ? 'Sending…'
        : _formatTime(createdAt);
    final textColor = alignRight ? Colors.white : _brandDark;
    final metaColor = alignRight ? Colors.white70 : Colors.black45;

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: alignRight ? _brandGreen : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(alignRight ? 16 : 4),
            bottomRight: Radius.circular(alignRight ? 4 : 16),
          ),
          border: alignRight
              ? null
              : Border.all(color: const Color(0xFFE6EEE9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isAdmin)
              Text(
                message.senderRole == 'driver' ? 'Driver' : 'Passenger',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: alignRight ? Colors.white70 : _brandGreen,
                ),
              ),
            Text(
              message.text,
              style: TextStyle(fontSize: 14, color: textColor, height: 1.3),
            ),
            const SizedBox(height: 2),
            Text(meta, style: TextStyle(fontSize: 10, color: metaColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    final quickReplies = widget.viewerRole == 'driver'
        ? RideContactService.driverQuickReplies
        : RideContactService.passengerQuickReplies;
    return Material(
      color: Colors.white,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: quickReplies.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) => ActionChip(
                  label: Text(quickReplies[index]),
                  onPressed: () => _send(quickReplies[index]),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: RideContactService.maxMessageLength,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _send,
                    decoration: InputDecoration(
                      hintText: 'Type a message',
                      counterText: '',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: () => _send(_textController.text),
                  icon: const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
