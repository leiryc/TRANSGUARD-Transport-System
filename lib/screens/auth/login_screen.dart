import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';
import '../../models/user_model.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _franchiseController = TextEditingController();
  final _plateController = TextEditingController();

  String _selectedUserType = 'passenger';
  bool _isLoading = false;
  bool _isLogin = true;
  bool _obscurePassword = true;
  bool _staySignedIn = true;
  bool _isLoadingStayPreference = true;

  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _loadStaySignedInPreference();
  }

  Future<void> _loadStaySignedInPreference() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _staySignedIn = preferences.getBool('stay_signed_in') ?? true;
        _isLoadingStayPreference = false;
      });
    } catch (error) {
      debugPrint('Could not load stay-signed-in preference: $error');
      if (mounted) setState(() => _isLoadingStayPreference = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _franchiseController.dispose();
    _plateController.dispose();
    super.dispose();
  }

  void _toggleMode() {
    setState(() {
      _isLogin = !_isLogin;
      _emailController.clear();
      _passwordController.clear();
      _nameController.clear();
      _phoneController.clear();
      _franchiseController.clear();
      _plateController.clear();
    });
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required';
    }
    final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Enter a valid email';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Full name is required';
    }
    return null;
  }

  String? _validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Phone number is required';
    }
    if (!RegExp(r'^\d{11}$').hasMatch(value.trim())) {
      return 'Phone number must contain exactly 11 digits';
    }
    return null;
  }

  String? _validateRequired(String? value) =>
      value == null || value.trim().isEmpty ? 'This field is required' : null;

  String? _validateAccreditationNumber(String? value, int maxLength) {
    final requiredError = _validateRequired(value);
    if (requiredError != null) return requiredError;
    if (value!.trim().length > maxLength) {
      return 'Maximum length is $maxLength characters';
    }
    return null;
  }

  Future<void> _handleAuth() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isLoading = true);

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('stay_signed_in', _isLogin && _staySignedIn);
      UserModel? user;

      if (_isLogin) {
        user = await authService.signin(
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        user = await authService.signup(
          _emailController.text.trim(),
          _passwordController.text,
          _nameController.text.trim(),
          _phoneController.text.trim(),
          _selectedUserType,
          franchiseNumber: _selectedUserType == 'driver'
              ? _franchiseController.text.trim()
              : null,
          plateNumber: _selectedUserType == 'driver'
              ? _plateController.text.trim()
              : null,
        );
      }

      if (!mounted) return;

      if (user != null) {
        final route = switch (user.userType) {
          'admin' => '/admin_home',
          'driver' when !user.isApproved => '/driver_approval',
          'driver' => '/driver_home',
          _ => '/passenger_home',
        };
        Navigator.of(context).pushReplacementNamed(route);
      } else {
        _showSnackBar(_isLogin ? 'Login failed' : 'Signup failed');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Error: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(colors),
                        const SizedBox(height: 32),
                        _buildFormCard(theme, colors),
                        const SizedBox(height: 24),
                        _buildFooter(theme, colors),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors.primary, colors.primary.withValues(alpha: 0.7)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(Icons.shield_outlined, size: 36, color: colors.onPrimary),
        ),
        const SizedBox(height: 20),
        Text(
          'TransGuard',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 32,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w800,
            color: colors.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _isLogin ? 'Welcome back' : 'Create your account',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildFormCard(ThemeData theme, ColorScheme colors) {
    return Card(
      elevation: 0,
      color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTextField(
              controller: _emailController,
              label: 'Email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
              validator: _validateEmail,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            _buildPasswordField(),
            if (_isLogin) ...[
              const SizedBox(height: 12),
              _buildStaySignedInToggle(colors),
            ],
            if (!_isLogin) ...[
              const SizedBox(height: 16),
              _buildTextField(
                controller: _nameController,
                label: 'Full Name',
                icon: Icons.person_outline,
                validator: _validateName,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _phoneController,
                label: 'Phone Number',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                validator: _validatePhone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 20),
              _buildUserTypeSelector(theme, colors),
              if (_selectedUserType == 'driver') ...[
                const SizedBox(height: 16),
                _buildDriverAccreditationFields(colors),
              ],
            ],
            const SizedBox(height: 24),
            _buildSubmitButton(colors),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _isLoading ? null : _toggleMode,
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                _isLogin
                    ? "Don't have an account? Sign up"
                    : 'Already registered? Sign in',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    List<TextInputFormatter>? inputFormatters,
    TextInputAction? textInputAction,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      enabled: !_isLoading,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
      ),
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      validator: _validatePassword,
      enabled: !_isLoading,
      textInputAction: _isLogin ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: _isLogin ? (_) => _handleAuth() : null,
      decoration: InputDecoration(
        labelText: 'Password',
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        filled: true,
      ),
    );
  }

  Widget _buildStaySignedInToggle(ColorScheme colors) {
    final disabled = _isLoading || _isLoadingStayPreference;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled
            ? null
            : () => setState(() => _staySignedIn = !_staySignedIn),
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _staySignedIn
                ? colors.primary.withValues(alpha: 0.06)
                : Colors.transparent,
            border: Border.all(
              color: _staySignedIn
                  ? colors.primary.withValues(alpha: 0.3)
                  : colors.outlineVariant.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  color: _staySignedIn ? colors.primary : Colors.transparent,
                  border: Border.all(
                    color: _staySignedIn
                        ? colors.primary
                        : colors.outline.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
                child: _staySignedIn
                    ? Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: colors.onPrimary,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stay signed in',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: disabled
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Keep me logged in on this device',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                _staySignedIn ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 18,
                color: _staySignedIn
                    ? colors.primary.withValues(alpha: 0.7)
                    : colors.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserTypeSelector(ThemeData theme, ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Account type',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildUserTypeTile(
                label: 'Passenger',
                value: 'passenger',
                icon: Icons.person_pin_circle_outlined,
                colors: colors,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildUserTypeTile(
                label: 'Driver',
                value: 'driver',
                icon: Icons.directions_car_outlined,
                colors: colors,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDriverAccreditationFields(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Driver accreditation',
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        _buildTextField(
          controller: _franchiseController,
          label: 'MTFRB franchise / permit number',
          icon: Icons.confirmation_number_outlined,
          validator: (value) => _validateAccreditationNumber(value, 50),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          controller: _plateController,
          label: 'LTO plate number',
          icon: Icons.directions_bike_outlined,
          validator: (value) => _validateAccreditationNumber(value, 20),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 12),
        const Text(
          'A cooperative administrator will verify these numbers before approval.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    );
  }

  Widget _buildUserTypeTile({
    required String label,
    required String value,
    required IconData icon,
    required ColorScheme colors,
  }) {
    final isSelected = _selectedUserType == value;
    return InkWell(
      onTap: _isLoading
          ? null
          : () => setState(() => _selectedUserType = value),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? colors.primary : colors.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          color: isSelected
              ? colors.primary.withValues(alpha: 0.08)
              : Colors.transparent,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton(ColorScheme colors) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleAuth,
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: _isLoading
            ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Text(
                _isLogin ? 'Login' : 'Create Account',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, ColorScheme colors) {
    return Text(
      'By continuing, you agree to our Terms & Privacy Policy.',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );
  }
}
