
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';

class Particle {
  double x;
  double y;
  double size;
  double opacity;
  double speedY;
  double speedX;
  Color color;

  Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.opacity,
    required this.speedY,
    required this.speedX,
    required this.color,
  });
}

class ParticlePainter extends CustomPainter {
  final List<Particle> particles;
  final bool isExpanded;
  final double scale;

  ParticlePainter({
    required this.particles,
    required this.isExpanded,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Clip to the main container shape
    final double radius = 16 * scale;
    final RRect clipRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, size.width, size.height),
      topLeft: Radius.circular(radius),
      bottomLeft: Radius.circular(radius),
      topRight: isExpanded ? Radius.zero : Radius.circular(radius),
      bottomRight: isExpanded ? Radius.zero : Radius.circular(radius),
    );

    canvas.clipRRect(clipRect);

    for (final particle in particles) {
      final paint = Paint()
        ..color = particle.color.withOpacity(particle.opacity)
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(Offset(particle.x, particle.y), particle.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant ParticlePainter oldDelegate) => true;
}

class ParticleEffect extends StatefulWidget {
  final Color accentColor;
  final double scale;
  final bool isExpanded;
  final bool isTyping;
  final bool isDemoMode;
  final VoidCallback onDemoEnd;

  const ParticleEffect({
    super.key,
    required this.accentColor,
    required this.scale,
    required this.isExpanded,
    required this.isTyping,
    this.isDemoMode = false,
    required this.onDemoEnd,
  });

  @override
  State<ParticleEffect> createState() => _ParticleEffectState();
}

class _ParticleEffectState extends State<ParticleEffect> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<Particle> _particles = [];
  final Random _random = Random();
  Timer? _spawnTimer;
  bool _isSpawning = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10), // Long duration loop
    )..repeat();
    
    _controller.addListener(_updateParticles);
    
    // Stop spawning after a set time
    Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _isSpawning = false;
        });
      }
    });

    // Spawn particles periodically if active
    _spawnTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_isSpawning || widget.isDemoMode) {
        _spawnParticle();
      } else if (_particles.isEmpty) {
        // Spawning stopped and no particles left
        timer.cancel();
        widget.onDemoEnd();
      }
    });

    if (widget.isDemoMode) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) widget.onDemoEnd();
      });
    }
  }
  
  void _spawnParticle() {
     if (!mounted) return;
  }

  void _updateParticles() {
    setState(() {
      // Remove dead particles
      _particles.removeWhere((p) => p.opacity <= 0.05 || p.y < 0);
      
      // Update existing
      for (var p in _particles) {
        p.y -= p.speedY; // Move up
        p.x += p.speedX; // Drift
        p.opacity -= 0.005; // Fade out
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _spawnTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Now we have size to spawn particles correctly
        if ((_isSpawning || widget.isDemoMode) && _particles.length < 50 && _random.nextDouble() < 0.3) {
             _particles.add(Particle(
              x: _random.nextDouble() * constraints.maxWidth,
              y: constraints.maxHeight, // Start at bottom
              size: (_random.nextDouble() * 3 + 1) * widget.scale,
              opacity: _random.nextDouble() * 0.5 + 0.3,
              speedY: _random.nextDouble() * 1.5 + 0.5,
              speedX: (_random.nextDouble() - 0.5) * 0.5,
              color: widget.accentColor,
            ));
        }

        return CustomPaint(
          painter: ParticlePainter(
            particles: List.from(_particles), // Copy list
            isExpanded: widget.isExpanded,
            scale: widget.scale,
          ),
          child: Container(),
        );
      },
    );
  }
}
