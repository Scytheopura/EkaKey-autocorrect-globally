import 'package:flutter/material.dart';

class GlassShineEffect extends StatefulWidget {
  final Color accentColor;
  final double scale;
  final bool isExpanded;
  final bool isTyping;
  final bool isDemoMode;
  final VoidCallback onDemoEnd;

  const GlassShineEffect({
    super.key,
    required this.accentColor,
    required this.scale,
    required this.isExpanded,
    required this.isTyping,
    this.isDemoMode = false,
    required this.onDemoEnd,
  });

  @override
  State<GlassShineEffect> createState() => _GlassShineEffectState();
}

class _GlassShineEffectState extends State<GlassShineEffect> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  int _playCount = 0;
  final int _maxPlays = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutSine,
    ));

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
         _playCount++;
         if (_playCount < _maxPlays || widget.isDemoMode) {
            Future.delayed(const Duration(milliseconds: 150), () {
              if (mounted) {
                _controller.forward(from: 0.0);
              }
            });
         } else {
            widget.onDemoEnd();
         }
      }
    });

    _controller.forward();

    if (widget.isDemoMode) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) widget.onDemoEnd();
      });
    }
  }

  @override
  void didUpdateWidget(GlassShineEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_controller.isAnimating && _playCount < _maxPlays) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Clip logic matching the main window
    final double radius = 16 * widget.scale;
    final BorderRadius borderRadius = BorderRadius.only(
      topLeft: Radius.circular(radius),
      bottomLeft: Radius.circular(radius),
      topRight: widget.isExpanded ? Radius.zero : Radius.circular(radius),
      bottomRight: widget.isExpanded ? Radius.zero : Radius.circular(radius),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return LayoutBuilder(
            builder: (context, constraints) {
               final double offset = constraints.maxWidth * _animation.value;
               return Stack(
                 children: [
                   if (_controller.isAnimating)
                   Positioned(
                     left: offset,
                     top: -50, // Extend beyond bounds for skew
                     bottom: -50,
                     width: constraints.maxWidth * 0.5, // Width of the shine
                     child: Transform(
                       transform: Matrix4.skewX(-0.4), // Slant the shine
                       child: Container(
                         decoration: BoxDecoration(
                           gradient: LinearGradient(
                             colors: [
                               Colors.transparent,
                               widget.accentColor.withOpacity(0.0),
                               widget.accentColor.withOpacity(0.15), // Subtle shine
                               Colors.white.withOpacity(0.3), // Bright core
                               widget.accentColor.withOpacity(0.15),
                               widget.accentColor.withOpacity(0.0),
                               Colors.transparent,
                             ],
                             stops: const [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0],
                             begin: Alignment.centerLeft,
                             end: Alignment.centerRight,
                           ),
                         ),
                       ),
                     ),
                   ),
                 ],
               );
            },
          );
        },
      ),
    );
  }
}
