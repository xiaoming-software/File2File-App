import 'package:flutter/material.dart';

import 'user_facing_error.dart';

void showAppSnack(
  BuildContext context,
  Object? message, {
  String? fallback,
}) {
  if (!context.mounted) return;
  final text = userFacingError(message, fallback: fallback);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
