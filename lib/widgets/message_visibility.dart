import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reports when [child] intersects the nearest scroll viewport.
///
/// With [repeatWhenVisible], fires again each time the bubble re-enters view
/// (leave chat / scroll away / come back) so type-25 can be re-sent.
class MessageVisibility extends StatefulWidget {
  const MessageVisibility({
    super.key,
    required this.onVisible,
    required this.child,
    this.enabled = true,
    this.repeatWhenVisible = false,
  });

  final VoidCallback onVisible;
  final Widget child;
  final bool enabled;
  final bool repeatWhenVisible;

  @override
  State<MessageVisibility> createState() => _MessageVisibilityState();
}

class _MessageVisibilityState extends State<MessageVisibility> {
  bool _reported = false;
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (!identical(next, _position)) {
      _position?.removeListener(_schedule);
      _position = next;
      _position?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(covariant MessageVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _reported = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted || !widget.enabled) return;
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(object);
    final scrollable = Scrollable.maybeOf(context);
    if (viewport == null || scrollable == null) return;

    final position = scrollable.position;
    final leading = viewport.getOffsetToReveal(object, 0).offset;
    final trailing = viewport.getOffsetToReveal(object, 1).offset;
    final top = leading < trailing ? leading : trailing;
    final bottom = leading < trailing ? trailing : leading;
    final viewTop = position.pixels;
    final viewBottom = viewTop + position.viewportDimension;
    final visible = bottom > viewTop && top < viewBottom;
    if (!visible) {
      if (widget.repeatWhenVisible) _reported = false;
      return;
    }
    if (_reported) return;
    _reported = true;
    widget.onVisible();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
