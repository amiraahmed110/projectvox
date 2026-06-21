import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/sos_message.dart';

/// Thrown when a message could not be delivered (or the device could not even
/// open a messaging app). The SOS flow catches this so a delivery failure
/// never aborts the rest of the emergency handling (the audio is still saved
/// locally, the UI still transitions, etc.).
class MessagingException implements Exception {
  MessagingException(this.message);
  final String message;
  @override
  String toString() => 'MessagingException: $message';
}

/// The swappable seam of the module.
///
/// Everything in the SOS flow talks to this interface only. To move off SMS
/// (e.g. to a custom backend API or the WhatsApp Business API) you implement
/// this once and inject it into `SosCubit` — no call sites change.
abstract class MessagingService {
  /// Delivers [payload]. Implementations should throw [MessagingException] on
  /// failure rather than returning silently.
  Future<void> send(MessagePayload payload);
}

/// Default "for now" implementation: opens the device SMS composer pre-filled
/// with the body (+ location link) via `url_launcher`.
///
/// Deliberate limitations (documented so the next dev isn't surprised):
///  * `sms:` cannot attach files, so [MessagePayload.attachmentPath] is
///    ignored here. The audio is always saved locally by `AudioService`, and a
///    future [MessagingService] (backend/WhatsApp) can upload it. See the TODO
///    below.
///  * We open the composer; the *user* taps send. Silent SMS would require the
///    `SEND_SMS` permission and is heavily restricted — intentionally avoided.
class SmsMessagingService implements MessagingService {
  const SmsMessagingService();

  @override
  Future<void> send(MessagePayload payload) async {
    if (payload.recipients.isEmpty) {
      throw MessagingException('no recipients provided');
    }

    // TODO(messaging): the recorded audio (payload.attachmentPath) cannot be
    // attached over the `sms:` scheme. Swap in a BackendMessagingService /
    // WhatsApp implementation to deliver the file. The file is saved locally
    // by AudioService regardless, so no evidence is lost.
    if (payload.hasAttachment) {
      debugPrint(
        '[SMS] attachment ${payload.attachmentPath} not sendable over sms:; '
        'kept locally for a backend/WhatsApp impl.',
      );
    }

    final String bodyText = payload.hasLocationLink
        ? '${payload.body}\n${payload.locationLink}'
        : payload.body;

    // Multiple recipients are comma-separated in the `sms:` path; most dialers
    // honor a single recipient most reliably, but the CSV form is standard.
    final String recipients = payload.recipients.join(',');
    final Uri smsUri = Uri(
      scheme: 'sms',
      path: recipients,
      queryParameters: <String, String>{'body': bodyText},
    );

    try {
      final bool launched = await launchUrl(
        smsUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw MessagingException('could not open the SMS composer');
      }
    } on MessagingException {
      rethrow;
    } catch (e) {
      throw MessagingException('failed to launch sms: $e');
    }
  }
}
