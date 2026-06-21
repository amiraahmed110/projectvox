import 'package:equatable/equatable.dart';

/// Lifecycle of the SOS flow.
enum SosStatus {
  /// No SOS. The big red "SOS" button is shown.
  idle,

  /// SOS triggered; inside the mandatory 3-second wait before dispatch.
  dispatching,

  /// SOS is live: contacts notified, background recording + location running.
  /// The red screen with the green "Safe" button is shown.
  active,

  /// A blocking problem occurred (e.g. permissions denied). The UI shows a
  /// dialog using [errorMessage], then we fall back to idle.
  error,
}

class SosState extends Equatable {
  const SosState({
    this.status = SosStatus.idle,
    this.locationLink,
    this.errorMessage,
  });

  final SosStatus status;

  /// The Google Maps link sent to contacts for the current/last session.
  final String? locationLink;

  /// Populated only when [status] is [SosStatus.error].
  final String? errorMessage;

  bool get isActive => status == SosStatus.active;
  bool get isDispatching => status == SosStatus.dispatching;

  SosState copyWith({
    SosStatus? status,
    String? locationLink,
    String? errorMessage,
  }) {
    return SosState(
      status: status ?? this.status,
      locationLink: locationLink ?? this.locationLink,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, locationLink, errorMessage];
}
