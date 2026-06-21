/// Transport-agnostic message describing what to deliver to emergency
/// contacts during the SOS / Safe flow.
///
/// This is the single payload every [MessagingService] implementation
/// consumes, so the rest of the module never has to know *how* a message is
/// delivered (SMS today, a backend / WhatsApp API later).
class MessagePayload {
  const MessagePayload({
    required this.recipients,
    required this.body,
    this.locationLink,
    this.attachmentPath,
  });

  /// Phone numbers (or, for future impls, contact ids) to deliver to.
  final List<String> recipients;

  /// The text body. For the final "Safe" message this is exactly `"ok"`.
  final String body;

  /// Optional shareable "live location" link (a Google Maps pin). When
  /// present it is appended to the SMS body by [SmsMessagingService].
  final String? locationLink;

  /// Optional path to a local file (the recorded audio) that should be
  /// attached.
  ///
  /// NOTE: the `sms:` URI scheme cannot carry attachments, so the SMS
  /// implementation ignores this field (see [SmsMessagingService]); a future
  /// backend / WhatsApp implementation uploads it. The field lives on the
  /// payload so swapping implementations needs no call-site changes.
  final String? attachmentPath;

  bool get hasAttachment =>
      attachmentPath != null && attachmentPath!.trim().isNotEmpty;

  bool get hasLocationLink =>
      locationLink != null && locationLink!.trim().isNotEmpty;
}
