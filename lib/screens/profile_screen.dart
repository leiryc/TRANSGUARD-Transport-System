import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/passenger_id_service.dart';
import '../widgets/id_upload_field.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const Color _brandGreen = Color(0xFF168A5B);
  static const Color _brandDark = Color(0xFF17352A);
  static const Color _dangerRed = Color(0xFFD64545);

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  UserModel? _user;
  bool _isLoading = true;
  bool _isEditing = false;
  bool _isSaving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final user = await context.read<AuthService>().getCurrentUserData();
      if (!mounted) return;
      setState(() {
        _user = user;
        _isLoading = false;
        _loadError = user == null ? 'Profile could not be loaded.' : null;
      });
      if (user != null) {
        _nameController.text = user.name;
        _phoneController.text = user.phone;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Profile could not be loaded. Please try again.';
      });
    }
  }

  Future<void> _saveProfile() async {
    final user = _user;
    if (user == null || !_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final updatedUser = await context.read<AuthService>().updateUserDetails(
        // A locked name is sent unchanged (see UserModel.isNameLocked).
        name: user.isNameLocked ? user.name : _nameController.text.trim(),
        phone: _phoneController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _user = updatedUser;
        _isEditing = false;
        _isSaving = false;
      });
      _showSnackBar('Profile updated', isError: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showSnackBar('Could not update profile: $error', isError: true);
    }
  }

  void _cancelEditing() {
    final user = _user;
    if (user == null) return;
    setState(() {
      _nameController.text = user.name;
      _phoneController.text = user.phone;
      _isEditing = false;
    });
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: isError ? _dangerRed : _brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F8),
      appBar: _buildAppBar(),
      body: _buildBody(),
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
        'My profile',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 18,
          color: _brandDark,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: _brandGreen),
      );
    }
    if (_loadError != null) {
      return _buildErrorState();
    }
    final user = _user;
    if (user == null) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildProfileHeader(user),
          const SizedBox(height: 20),
          _buildDetailsCard(user),
          if (user.userType == 'passenger') ...[
            const SizedBox(height: 20),
            _buildIdVerificationCard(user),
          ],
          if (!user.isFromCache && !_isEditing) ...[
            const SizedBox(height: 20),
            _buildEditButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _dangerRed.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.person_off_outlined,
                size: 36,
                color: _dangerRed,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: _brandDark,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadError = null;
                });
                _loadProfile();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _brandGreen,
                side: const BorderSide(color: _brandGreen, width: 1.5),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileHeader(UserModel user) {
    final roleLabel = user.userType == 'driver' ? 'Driver' : 'Passenger';
    final initials = _getInitials(user.name);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1AA36B), _brandGreen],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: _brandGreen.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            child: CircleAvatar(
              radius: 44,
              backgroundColor: Colors.white,
              child: initials.isNotEmpty
                  ? Text(
                initials,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: _brandGreen,
                  letterSpacing: 1,
                ),
              )
                  : const Icon(
                Icons.person_outline,
                size: 42,
                color: _brandGreen,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            user.name.isEmpty ? 'Your profile' : user.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  user.userType == 'driver'
                      ? Icons.directions_car_outlined
                      : Icons.person_pin_circle_outlined,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  roleLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
                if (user.userType == 'passenger' && user.isIdVerified) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.verified_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Verified',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (user.isFromCache) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_outlined, size: 14, color: Colors.white),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Offline mode',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _getInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Widget _buildDetailsCard(UserModel user) {
    return Container(
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
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _brandGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.person_outline,
                      size: 18,
                      color: _brandGreen,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Personal details',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _brandDark,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
              if (user.isFromCache) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4E5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFE58A3A).withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: Color(0xFFE58A3A),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Showing saved profile data offline. Editing is unavailable until you reconnect.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8A5A20),
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (_isEditing) ...[
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  enabled: !_isSaving && !user.isNameLocked,
                  decoration: InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(
                      user.isNameLocked
                          ? Icons.lock_outline
                          : Icons.person_outline,
                    ),
                    helperText: !user.isNameLocked
                        ? null
                        : user.isIdVerified
                        ? 'Locked to match your verified ID'
                        : 'Locked while your ID is under review',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter your name'
                      : null,
                ),
                const SizedBox(height: 14),
                _ProfileDetail(
                  label: 'Email',
                  value: user.email,
                  icon: Icons.email_outlined,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  enabled: !_isSaving,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter your phone number'
                      : null,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSaving ? null : _cancelEditing,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _brandDark,
                          side: BorderSide(
                            color: _brandDark.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _saveProfile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _brandGreen,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                          _brandGreen.withValues(alpha: 0.5),
                          disabledForegroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Text(
                          'Save changes',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                _ProfileDetail(
                  label: 'Full name',
                  value: user.name.isEmpty ? 'Not provided' : user.name,
                  icon: Icons.person_outline,
                ),
                const SizedBox(height: 16),
                _ProfileDetail(
                  label: 'Email',
                  value: user.email,
                  icon: Icons.email_outlined,
                ),
                const SizedBox(height: 16),
                _ProfileDetail(
                  label: 'Phone number',
                  value:
                  user.phone.isEmpty ? 'Not provided' : user.phone,
                  icon: Icons.phone_outlined,
                ),
                const SizedBox(height: 16),
                _ProfileDetail(
                  label: 'Account type',
                  value: user.userType == 'driver' ? 'Driver' : 'Passenger',
                  icon: Icons.badge_outlined,
                  isLast: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdVerificationCard(UserModel user) {
    final status = user.idVerificationStatus;
    final (IconData icon, Color color, String label, String message) =
        switch (status) {
          'verified' => (
            Icons.verified_rounded,
            _brandGreen,
            'Verified',
            'Your ${PassengerIdService.labelFor(user.idType)} has been '
                'verified. Drivers see a "Verified passenger" badge on your '
                'ride requests.',
          ),
          'pending' => (
            Icons.hourglass_top_rounded,
            const Color(0xFFE58A3A),
            'Under review',
            'An administrator is reviewing your '
                '${PassengerIdService.labelFor(user.idType)}. You can keep '
                'booking rides in the meantime.',
          ),
          'rejected' => (
            Icons.gpp_bad_outlined,
            _dangerRed,
            'Rejected',
            user.idRejectionReason?.trim().isNotEmpty == true
                ? 'Reason: ${user.idRejectionReason!.trim()}\n'
                      'Please upload a clearer photo of a valid ID.'
                : 'Your ID could not be verified. Please upload a clearer '
                      'photo of a valid ID.',
          ),
          _ => (
            Icons.shield_outlined,
            Colors.black54,
            'Not verified',
            'Upload a valid ID to get a verified passenger badge.',
          ),
        };
    final canUpload =
        !user.isFromCache && (status == null || status == 'rejected');

    return Container(
      padding: const EdgeInsets.all(20),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _brandGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.badge_outlined,
                  size: 18,
                  color: _brandGreen,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'ID verification',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _brandDark,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.black54,
              height: 1.4,
            ),
          ),
          if (canUpload) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _openIdUploadSheet,
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: Text(status == 'rejected' ? 'Upload a new ID' : 'Upload ID'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _brandGreen,
                side: const BorderSide(color: _brandGreen, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openIdUploadSheet() async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _IdUploadSheet(),
    );
    if (submitted != true || !mounted) return;
    _showSnackBar('ID submitted for review', isError: false);
    await _loadProfile();
  }

  Widget _buildEditButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: () => setState(() => _isEditing = true),
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text(
          'Edit profile',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _brandGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

class _IdUploadSheet extends StatefulWidget {
  const _IdUploadSheet();

  @override
  State<_IdUploadSheet> createState() => _IdUploadSheetState();
}

class _IdUploadSheetState extends State<_IdUploadSheet> {
  final _formKey = GlobalKey<FormState>();
  String? _idType;
  IdImage? _image;
  String? _imageError;
  String? _submitError;
  bool _isSubmitting = false;

  Future<void> _submit() async {
    final formValid = _formKey.currentState?.validate() ?? false;
    setState(() {
      _imageError = _image == null ? 'Upload a photo of your valid ID' : null;
      _submitError = null;
    });
    if (!formValid || _image == null) return;

    setState(() => _isSubmitting = true);
    try {
      await PassengerIdService().submitForCurrentUser(
        PassengerIdUpload(idType: _idType!, image: _image!),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitError = error is StateError ? error.message : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Upload your ID',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF17352A),
                ),
              ),
              const SizedBox(height: 16),
              IdUploadField(
                idType: _idType,
                image: _image,
                enabled: !_isSubmitting,
                errorText: _imageError,
                showTitle: false,
                onIdTypeChanged: (value) => setState(() => _idType = value),
                onImageChanged: (value) => setState(() {
                  _image = value;
                  if (value != null) _imageError = null;
                }),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _submitError!,
                  style: const TextStyle(color: Color(0xFFD64545)),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    shape: const StadiumBorder(),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Submit for review',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileDetail extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool isLast;

  const _ProfileDetail({
    required this.label,
    required this.value,
    required this.icon,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF168A5B).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 20,
                color: const Color(0xFF168A5B),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF17352A),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.only(left: 54, top: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ),
      ],
    );
  }
}