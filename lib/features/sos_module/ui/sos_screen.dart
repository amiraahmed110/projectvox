import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/sos_cubit.dart';
import '../bloc/sos_state.dart';

/// Self-contained entry widget for the SOS module. Drop this anywhere (e.g. a
/// route) — it owns its own [SosCubit].
///
/// Wire real emergency contacts via [recipients]; the backend source is
/// `GET /trusted-contacts/index` (see lib/screens/safety/trusted_contacts_screen.dart).
class SosScreen extends StatelessWidget {
  const SosScreen({super.key, required this.recipients});

  /// Phone numbers to notify (E.164, e.g. "+201234567890").
  final List<String> recipients;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<SosCubit>(
      create: (_) => SosCubit(recipients: recipients),
      child: const _SosView(),
    );
  }
}

class _SosView extends StatelessWidget {
  const _SosView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SosCubit, SosState>(
      listenWhen: (prev, curr) => curr.status == SosStatus.error,
      listener: (context, state) => _showErrorDialog(context, state),
      builder: (context, state) {
        final bool active = state.isActive;
        return Scaffold(
          backgroundColor: active ? const Color(0xFFB71C1C) : Colors.white,
          appBar: AppBar(
            title: const Text('Emergency SOS'),
            backgroundColor: active ? const Color(0xFFB71C1C) : null,
            foregroundColor: active ? Colors.white : null,
            elevation: 0,
          ),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _statusText(state),
                const SizedBox(height: 40),
                _mainButton(context, state),
                const SizedBox(height: 24),
                if (state.isDispatching)
                  const Text(
                    'Sending alert in 3 seconds…',
                    style: TextStyle(color: Colors.black54),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusText(SosState state) {
    final active = state.isActive;
    return Text(
      switch (state.status) {
        SosStatus.idle => 'You are safe',
        SosStatus.dispatching => 'Activating SOS…',
        SosStatus.active => 'SOS ACTIVE',
        SosStatus.error => 'You are safe',
      },
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: active ? Colors.white : Colors.black87,
      ),
    );
  }

  Widget _mainButton(BuildContext context, SosState state) {
    final cubit = context.read<SosCubit>();

    // Active → green "Safe" button. Otherwise → red "SOS" button.
    final bool active = state.isActive;
    final bool busy = state.isDispatching;
    final Color color = active ? const Color(0xFF4CAF50) : const Color(0xFFD32F2F);
    final String label = active ? 'SAFE' : 'SOS';

    return GestureDetector(
      onTap: busy
          ? null
          : () => active ? cubit.markSafe() : cubit.triggerSos(),
      child: Container(
        height: 180,
        width: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 30,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Center(
          child: busy
              ? const CircularProgressIndicator(color: Colors.white)
              : Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _showErrorDialog(BuildContext context, SosState state) async {
    final cubit = context.read<SosCubit>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Permission needed'),
        content: Text(
          state.errorMessage ?? 'A required permission was denied.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    cubit.clearError(); // return to idle once acknowledged
  }
}
