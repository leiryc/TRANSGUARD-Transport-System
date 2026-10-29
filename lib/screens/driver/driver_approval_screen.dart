import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../services/auth_service.dart';

class DriverApprovalScreen extends StatelessWidget {
  const DriverApprovalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return const SizedBox.shrink();

    return StreamBuilder<UserModel?>(
      stream: AuthService().watchUserProfile(userId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Driver approval')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not check your approval status: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final profile = snapshot.data;
        if (profile?.isApproved == true) {
          return Scaffold(
            body: Center(
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamedAndRemoveUntil('/driver_home', (_) => false),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Approval complete · Continue'),
              ),
            ),
          );
        }

        final rejected = profile?.approvalStatus == 'rejected';
        final revoked = profile?.approvalStatus == 'revoked';
        return Scaffold(
          appBar: AppBar(
            title: const Text('Driver accreditation'),
            actions: [
              IconButton(
                tooltip: 'Sign out',
                onPressed: () async {
                  await AuthService().signout();
                  if (!context.mounted) return;
                  Navigator.of(context)
                      .pushNamedAndRemoveUntil('/login', (_) => false);
                },
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      rejected || revoked
                          ? Icons.assignment_late_outlined
                          : Icons.hourglass_top_rounded,
                      size: 68,
                      color: rejected
                          ? const Color(0xFFD64545)
                          : const Color(0xFF168A5B),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      rejected
                          ? 'Accreditation needs attention'
                          : revoked
                          ? 'Driver approval revoked'
                          : 'Application pending review',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      rejected
                          ? 'Your driver application was not approved. Please contact your cooperative administrator to correct or resubmit your documents.'
                          : revoked
                          ? 'Your driver approval was revoked. Contact your cooperative administrator to discuss reinstatement. Your account cannot go online or accept rides.'
                          : 'Your franchise and plate numbers have been submitted. A cooperative administrator must verify them and approve your account before you can go online or accept rides.',
                      textAlign: TextAlign.center,
                    ),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.only(top: 20),
                        child: CircularProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
