import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import 'ekakey_process.dart';
import 'particle_effect.dart';
import 'glass_effect.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await hotKeyManager.unregisterAll();

  final prefs = await SharedPreferences.getInstance();
  double? lastX = prefs.getDouble('windowX');
  double? lastY = prefs.getDouble('windowY');
  
  WindowOptions windowOptions = WindowOptions(
    size: const Size(190, 160),
    center: lastX == null,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (lastX != null && lastY != null) {
      await windowManager.setPosition(Offset(lastX, lastY));
    }
    await windowManager.setResizable(false);
    // await windowManager.show();
    await windowManager.setOpacity(0.0); 
    await windowManager.show(inactive: true);
  });

  runApp(const MyApp());
}

enum BorderEffectType {
  glow,
  dotted,
  particles,
  glass,
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  final ValueNotifier<bool> _isEkaKeyOnNotifier = ValueNotifier<bool>(true);
  Timer? _snapTimer;
  Timer? _autoHideTimer;
  bool _keepShowing = false;
  bool _isExpanded = false;

  // System Tray & Window
  final AppWindow _appWindow = AppWindow();
  final SystemTray _systemTray = SystemTray();
  
  // Window Size Constants
  final Size _baseCollapsedSize = const Size(190, 160);
  final Size _baseExpandedSize = const Size(550, 160);
  int _windowScale = 100; // Percentage

  Size get _collapsedSize => Size(
      _baseCollapsedSize.width * _windowScale / 100,
      _baseCollapsedSize.height * _windowScale / 100);

  Size get _expandedSize => Size(
      _baseExpandedSize.width * _windowScale / 100,
      _baseExpandedSize.height * _windowScale / 100);

  double get _scale => _windowScale / 100.0;
  
  // Reduced scale for internal tiles to prevent overflow issues
  double get _tileScale => _windowScale <= 94 ? (_windowScale - 8) / 100.0 : (_windowScale - 5) / 100.0;
  
  // Settings State
  int _selectedSettingsTab = 0;
  bool _isDarkMode = true;
  int _autoHideSeconds = 5;
  String _selectedDbOption = 'User DB';
  bool _showDeleteConfirm = false;
  Color _accentColor = const Color.fromRGBO(30, 144, 255, 1.0);
  late TextEditingController _hexController;
  late TextEditingController _autoHideController;
  late TextEditingController _delayController;

  // Effects State
  BorderEffectType _currentBorderEffect = BorderEffectType.glow;
  bool _isDemoMode = false;
  bool _isEffectPlaying = false;
  
  // Logic Settings State
  String _startStopKeyChar = 'd';
  String _keepShowingKeyChar = 's';
  late TextEditingController _startStopKeyController;
  late TextEditingController _keepShowingKeyController;
  bool _hotKeysRegistered = false;

  // Status Bar State
  String _displayStatus = "EkaKey";
  IconData _displayIcon = Icons.keyboard_command_key_rounded;
  Timer? _statusResetTimer;
  Timer? _glowTimer;

  // Database Search State
  final TextEditingController _dbSearchMisspelledController = TextEditingController();
  final TextEditingController _dbSearchCorrectController = TextEditingController();
  final TextEditingController _deleteOlderController = TextEditingController();
  List<Map<String, Object?>> _dbSearchResults = [];
  int _dbSearchPage = 0;
  bool _dbSearchLoading = false;
  bool _showDeleteOlderInput = false;

  // Main DB Search State
  final TextEditingController _mainDbSearchController = TextEditingController();
  List<Map<String, Object?>> _mainDbSearchResults = [];
  int _mainDbSearchPage = 0;
  bool _mainDbSearchLoading = false;

  Future<void> _performDbSearch({bool resetPage = true}) async {
    if (resetPage) _dbSearchPage = 0;
    setState(() => _dbSearchLoading = true);
    
    final results = await searchUserCorrections(
      misspelled: _dbSearchMisspelledController.text,
      correct: _dbSearchCorrectController.text,
      limit: 10,
      offset: _dbSearchPage * 10,
    );
    
    setState(() {
      _dbSearchResults = results;
      _dbSearchLoading = false;
    });
  }

  Future<void> _performMainDbSearch({bool resetPage = true}) async {
    if (resetPage) _mainDbSearchPage = 0;
    setState(() => _mainDbSearchLoading = true);

    final results = await searchMainDictionary(
      query: _mainDbSearchController.text,
      limit: 10,
      offset: _mainDbSearchPage * 10,
    );

    setState(() {
      _mainDbSearchResults = results;
      _mainDbSearchLoading = false;
    });
  }
  
  Future<void> _deleteOlderThan() async {
    final days = int.tryParse(_deleteOlderController.text);
    if (days != null && days > 0) {
      await deleteUserCorrectionsOlderThan(days);
      setState(() => _showDeleteOlderInput = false);
      _deleteOlderController.clear();
      // Refresh search if active
      if (_dbSearchMisspelledController.text.isNotEmpty || _dbSearchCorrectController.text.isNotEmpty) {
        _performDbSearch(resetPage: true);
      }
    }
  }

  HotKey _hotKey = HotKey(
    key: PhysicalKeyboardKey.keyD,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );

  final HotKey _cycleHotKey = HotKey(
    key: PhysicalKeyboardKey.tab,
    modifiers: [HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );

  HotKey _toggleKeepShowingHotKey = HotKey(
    key: PhysicalKeyboardKey.keyS,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );


  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: "69F0AE");
    _autoHideController = TextEditingController(text: "5");
    _delayController = TextEditingController(text: "50");
    _startStopKeyController = TextEditingController(text: "d");
    _keepShowingKeyController = TextEditingController(text: "s");
    windowManager.addListener(this);
    _initSystemTray();
    startEkaKeyProcessing(_isEkaKeyOnNotifier);
    _loadSettings(); // Moved up to load before register
    // _registerHotKey(); // Called in _loadSettings or after it
    _performDbSearch();
    globalCorrectWord.addListener(handleAutoVisibility);
    globalSuggestions.addListener(handleAutoVisibility);
    
    isSimulatingTyping.addListener(() {
      if (isSimulatingTyping.value) {
        if (mounted) {
          setState(() {
            _isEffectPlaying = true;
          });
          
          if (_currentBorderEffect == BorderEffectType.glow) {
            _glowTimer?.cancel();
            _glowTimer = Timer(const Duration(milliseconds: 1000), () {
              if (mounted) {
                setState(() {
                  _isEffectPlaying = false;
                });
              }
            });
          }
        }
      }
    });

    // Status Listener
    status.addListener(_handleStatusChange);

    // Initial registration is handled by _loadSettings -> _updateHotKeys
    // But we need to make sure we register if loadSettings is delayed or if we need immediate registration
    // Actually, hotkeys are registered based on _isEkaKeyOnNotifier value.
    // So we should just let _loadSettings update the hotkey objects and then register if needed.
  }

  @override
  void dispose() {
    _hexController.dispose();
    _autoHideController.dispose();
    _delayController.dispose();
    _startStopKeyController.dispose();
    _keepShowingKeyController.dispose();
    _dbSearchMisspelledController.dispose();
    _dbSearchCorrectController.dispose();
    _deleteOlderController.dispose();
    _mainDbSearchController.dispose();
    windowManager.removeListener(this);
    hotKeyManager.unregister(_hotKey);
    hotKeyManager.unregister(_cycleHotKey);
    hotKeyManager.unregister(_toggleKeepShowingHotKey);
    _snapTimer?.cancel();
    super.dispose();
    _autoHideTimer?.cancel();
    _statusResetTimer?.cancel();
    status.removeListener(_handleStatusChange);
    globalCorrectWord.removeListener(handleAutoVisibility);
    globalSuggestions.removeListener(handleAutoVisibility);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _windowScale = prefs.getInt('windowScale') ?? 100;
      _isDarkMode = prefs.getBool('isDarkMode') ?? true;
      _autoHideSeconds = prefs.getInt('autoHideSeconds') ?? 5;
      _autoHideController.text = _autoHideSeconds.toString();
      final hex = prefs.getString('accentHex') ?? "69F0AE";
      _hexController.text = hex;
      _accentColor = _parseHexColor(hex);

      int delayMs = prefs.getInt('delayBeforeSearchMs') ?? 50;
      delayBeforeSearch = Duration(milliseconds: delayMs);
      _delayController.text = delayMs.toString();

      _startStopKeyChar = prefs.getString('startStopKeyChar') ?? 'd';
      _keepShowingKeyController.text = _keepShowingKeyChar = prefs.getString('keepShowingKeyChar') ?? 's';
      _startStopKeyController.text = _startStopKeyChar;
    });

    await _updateHotKeys();

    String? savedEffect = prefs.getString('currentBorderEffect');
    if (savedEffect != null) {
      try {
        _currentBorderEffect = BorderEffectType.values.firstWhere((e) => e.toString().split('.').last == savedEffect);
      } catch (e) {
        _currentBorderEffect = BorderEffectType.glow; // Fallback
      }
    } else {
      _currentBorderEffect = BorderEffectType.glow; // Default
    }

    // Apply size immediately if needed, or wait for expansion/collapse interaction
    // But to be safe, if we are collapsed (default), we should resize to the scaled collapsed size
    if (!_isExpanded) {
      await windowManager.setSize(_collapsedSize);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('windowScale', _windowScale);
    await prefs.setBool('isDarkMode', _isDarkMode);
    await prefs.setInt('autoHideSeconds', _autoHideSeconds);
    await prefs.setString('accentHex', _hexController.text);
    await prefs.setInt('delayBeforeSearchMs', delayBeforeSearch.inMilliseconds);
    await prefs.setString('startStopKeyChar', _startStopKeyChar);
    await prefs.setString('keepShowingKeyChar', _keepShowingKeyChar);
    await prefs.setString('currentBorderEffect', _currentBorderEffect.toString().split('.').last);
  }

  Color _parseHexColor(String hex) {
    try {
      String cleanHex = hex.replaceAll("#", "");
      if (cleanHex.length == 6) {
        return Color(int.parse("FF$cleanHex", radix: 16));
      } else if (cleanHex.length == 8) {
        return Color(int.parse(cleanHex, radix: 16));
      }
    } catch (e) {
      debugPrint("Error parsing hex: $e");
    }
    return const Color.fromRGBO(30, 144, 255, 1.0); // Fallback
  }

  void _updateAccentColor(String hex) {
    setState(() {
      _accentColor = _parseHexColor(hex);
    });
    _saveSettings();
  }

  void _toggleTheme() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    _saveSettings();
  }

  void _changeSize(int delta) async {
    int newScale = _windowScale + delta;
    if (newScale < 80) newScale = 80;
    if (newScale > 120) newScale = 120;

    if (newScale != _windowScale) {
      setState(() {
        _windowScale = newScale;
      });
      await _saveSettings();
      
      // Update window size immediately
      Size targetSize = _isExpanded ? _expandedSize : _collapsedSize;
      await windowManager.setSize(targetSize);
    }
  }

  void _handleStatusChange() {
    final rawStatus = status.value;
    if (rawStatus.isEmpty) return;

    String newText = rawStatus;
    IconData newIcon = Icons.info_outline_rounded;

    if (rawStatus.startsWith("Editing:")) {
      newText = rawStatus.replaceFirst("Editing:", "").trim();
      newIcon = Icons.edit_note_rounded;
    } else if (rawStatus.startsWith("Saved:")) {
      newText = rawStatus.replaceFirst("Saved:", "").trim();
      newIcon = Icons.save_as_rounded;
    } else if (rawStatus.startsWith("Auto-Corrected")) {
      newText = rawStatus.replaceFirst("Auto-Corrected", "").trim();
      newIcon = Icons.auto_fix_high_rounded;
    } else if (rawStatus == "Deleted User DB") {
      newText = "User DB Cleared";
      newIcon = Icons.delete_sweep_rounded;
    }

    // Update UI
    setState(() {
      _displayStatus = newText;
      _displayIcon = newIcon;
    });

    // Reset Timer
    _statusResetTimer?.cancel();
    _statusResetTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _displayStatus = "EkaKey";
          _displayIcon = Icons.keyboard_command_key_rounded;
        });
      }
    });
  }

  void handleAutoVisibility() async {
    // 1. If "Keep Showing" is ON, ignore auto-hide logic
    if (_keepShowing) return;

    // 2. Check if both are empty
    bool isEmpty = globalCorrectWord.value.isEmpty && globalSuggestions.value.isEmpty;
    if (isEmpty) {
      // If empty, hide immediately and cancel any pending hide timer
      // windowManager.hide();
      await windowManager.setOpacity(0.0);
      // await windowManager.setIgnoreMouseEvents(true);
      _autoHideTimer?.cancel();
    } else {
      // 3. Content changed and is not empty -> Show window
      // windowManager.show();
      await windowManager.setOpacity(1.0);
      // await windowManager.setIgnoreMouseEvents(false);
      // Reset the timer
      _autoHideTimer?.cancel();
      _autoHideTimer = Timer(Duration(seconds: _autoHideSeconds), () async {
        // Double check flag in case it changed during the timer
        if (!_keepShowing && selectedTileIndex.value == 0) {
          // windowManager.hide();
          await windowManager.setOpacity(0.0);
          // await windowManager.setIgnoreMouseEvents(true);
        }
      });
    }
  }

  @override
  void onWindowMove() {
    // Debounce the snap logic: wait for movement to stop
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(milliseconds: 200), _snapToCorners);
  }

  Future<void> _registerHotKey() async {
    try {
      await hotKeyManager.register(
        _hotKey,
        keyDownHandler: (hotKey) {
          _isEkaKeyOnNotifier.value = !_isEkaKeyOnNotifier.value;
        },
      );
      if (_isEkaKeyOnNotifier.value) {
         await hotKeyManager.register(_cycleHotKey, keyDownHandler: (_) => cycleTileSelection());
         await hotKeyManager.register(_toggleKeepShowingHotKey, keyDownHandler: (_) => _toggleKeepShowing());
      }
      _hotKeysRegistered = true;
    } catch (e) {
      debugPrint("Error registering hotkeys: $e");
    }
  }

  Future<void> _updateHotKeys() async {
    try {
      // Unregister old only if they have been registered
      if (_hotKeysRegistered) {
        await hotKeyManager.unregister(_hotKey);
        await hotKeyManager.unregister(_toggleKeepShowingHotKey);
      }
      
      // Recreate objects with new keys
      _hotKey = HotKey(
        key: _getKeyFromChar(_startStopKeyChar),
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        scope: HotKeyScope.system,
      );
      
      _toggleKeepShowingHotKey = HotKey(
        key: _getKeyFromChar(_keepShowingKeyChar),
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        scope: HotKeyScope.system,
      );

      // Register again
      await _registerHotKey();
      debugPrint("⌨️ Hotkeys Updated: Start/Stop=$_startStopKeyChar, KeepShowing=$_keepShowingKeyChar");
    } catch (e) {
      debugPrint("Error updating hotkeys: $e");
    }
  }

  PhysicalKeyboardKey _getKeyFromChar(String char) {
    switch (char.toLowerCase()) {
      case 'a': return PhysicalKeyboardKey.keyA;
      case 'b': return PhysicalKeyboardKey.keyB;
      case 'c': return PhysicalKeyboardKey.keyC;
      case 'd': return PhysicalKeyboardKey.keyD;
      case 'e': return PhysicalKeyboardKey.keyE;
      case 'f': return PhysicalKeyboardKey.keyF;
      case 'g': return PhysicalKeyboardKey.keyG;
      case 'h': return PhysicalKeyboardKey.keyH;
      case 'i': return PhysicalKeyboardKey.keyI;
      case 'j': return PhysicalKeyboardKey.keyJ;
      case 'k': return PhysicalKeyboardKey.keyK;
      case 'l': return PhysicalKeyboardKey.keyL;
      case 'm': return PhysicalKeyboardKey.keyM;
      case 'n': return PhysicalKeyboardKey.keyN;
      case 'o': return PhysicalKeyboardKey.keyO;
      case 'p': return PhysicalKeyboardKey.keyP;
      case 'q': return PhysicalKeyboardKey.keyQ;
      case 'r': return PhysicalKeyboardKey.keyR;
      case 's': return PhysicalKeyboardKey.keyS;
      case 't': return PhysicalKeyboardKey.keyT;
      case 'u': return PhysicalKeyboardKey.keyU;
      case 'v': return PhysicalKeyboardKey.keyV;
      case 'w': return PhysicalKeyboardKey.keyW;
      case 'x': return PhysicalKeyboardKey.keyX;
      case 'y': return PhysicalKeyboardKey.keyY;
      case 'z': return PhysicalKeyboardKey.keyZ;
      default: return PhysicalKeyboardKey.keyD;
    }
  }

  Future<void> _toggleExpand() async {
    if (!_isExpanded) {
      // Expanding: Resize window first, then animate content
      await windowManager.setSize(_expandedSize);
      setState(() {
        _isExpanded = true;
      });
    } else {
      // Collapsing: Animate content out, then resize window after a delay
      setState(() {
        _isExpanded = false;
      });
      // Wait for the AnimatedContainer duration (300ms) before shrinking window
      await Future.delayed(const Duration(milliseconds: 300));
      if (!_isExpanded) { // Check again in case user toggled back quickly
        await windowManager.setSize(_collapsedSize);
      }
    }
  }

  Future<void> _toggleKeepShowing() async {
    _keepShowing = !_keepShowing;
    
    // Apply logic
    if (_keepShowing) {
      _autoHideTimer?.cancel();
      await windowManager.setOpacity(1.0); 
      await windowManager.show(inactive: false);
      status.value = "Keep Showing: ON";
    } else {
      status.value = "Keep Showing: OFF";
      handleAutoVisibility();
    }
    
    await _updateSystemTrayMenu();
  }

  Future<void> _updateSystemTrayMenu() async {
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: _isEkaKeyOnNotifier.value ? 'Stop' : 'Start',
        onClicked: (menuItem) {
          _isEkaKeyOnNotifier.value = !_isEkaKeyOnNotifier.value;
        },
      ),
      MenuSeparator(),
      MenuItemCheckbox(
        label: 'Keep Showing',
        checked: _keepShowing,
        onClicked: (menuItem) async {
          await _toggleKeepShowing();
        },
      ),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) {
        _appWindow.close();
        stopEkaKeyProcessing();
      }),
    ]);
    await _systemTray.setContextMenu(menu);
  }

  Future<void> _initSystemTray() async {
    String path = Platform.isWindows
        ? 'assets/app_icon.ico'
        : 'assets/app_icon.png';

    await _systemTray.initSystemTray(title: "system tray", iconPath: path);

    await _updateSystemTrayMenu();

    _isEkaKeyOnNotifier.addListener(() async {
      if (_isEkaKeyOnNotifier.value) {
        // When STARTED: Register hotkeys
        await hotKeyManager.register(
          _cycleHotKey,
          keyDownHandler: (_) => cycleTileSelection(),
        );
        await hotKeyManager.register(
          _toggleKeepShowingHotKey,
          keyDownHandler: (_) => _toggleKeepShowing(),
        );
        print("⌨️ Hotkeys Registered");
      } else {
        // When STOPPED: Unregister hotkeys
        await hotKeyManager.unregister(_cycleHotKey);
        await hotKeyManager.unregister(_toggleKeepShowingHotKey);
        print("🚫 Hotkeys Unregistered");
      }
      await _updateSystemTrayMenu();
    });

    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        _appWindow.show();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
  }

  Future<void> _snapToCorners() async {
    try {
      final windowBounds = await windowManager.getBounds();
      // Calculate center of window to find which display it is on
      final Offset center = windowBounds.center;

      // Get all displays to find which one contains the window center
      final List<Display> displays = await screenRetriever.getAllDisplays();
      Display? targetDisplay;

      for (final display in displays) {
        final double dLeft = display.visiblePosition?.dx ?? 0;
        final double dTop = display.visiblePosition?.dy ?? 0;
        final double dWidth = display.visibleSize?.width ?? 0;
        final double dHeight = display.visibleSize?.height ?? 0;

        // Check if center is within this display's bounds
        // We use a loose check here to find the "active" screen even if slightly off
        if (center.dx >= dLeft &&
            center.dx <= (dLeft + dWidth) &&
            center.dy >= dTop &&
            center.dy <= (dTop + dHeight)) {
          targetDisplay = display;
          break;
        }
      }

      // Fallback to primary if not found
      targetDisplay ??= await screenRetriever.getPrimaryDisplay();

      final double screenLeft = targetDisplay.visiblePosition?.dx ?? 0;
      final double screenTop = targetDisplay.visiblePosition?.dy ?? 0;
      final double screenRight =
          screenLeft + (targetDisplay.visibleSize?.width ?? 0);
      final double screenBottom =
          screenTop + (targetDisplay.visibleSize?.height ?? 0);

      double newX = windowBounds.topLeft.dx;
      double newY = windowBounds.topLeft.dy;
      bool needsMove = false;

      // --- NEW LOGIC: Constrain to Screen Bounds ---

      // Check Left Boundary
      if (newX < screenLeft) {
        newX = screenLeft;
        needsMove = true;
      }
      // Check Right Boundary (Ensure right side doesn't overflow)
      else if (newX + windowBounds.width > screenRight) {
        newX = screenRight - windowBounds.width;
        needsMove = true;
      }

      // Check Top Boundary
      if (newY < screenTop) {
        newY = screenTop;
        needsMove = true;
      }
      // Check Bottom Boundary (Ensure bottom side doesn't overflow)
      else if (newY + windowBounds.height > screenBottom) {
        newY = screenBottom - windowBounds.height;
        needsMove = true;
      }

      if (needsMove) {
        await windowManager.setPosition(Offset(newX, newY));
      }

      // Persist the position
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('windowX', newX);
      await prefs.setDouble('windowY', newY);
    } catch (e) {
      debugPrint("Error snapping to corners: $e");
    }
  }

  Widget _buildTab(int index, IconData icon, String label) {
    bool isSelected = _selectedSettingsTab == index;
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedSettingsTab = index;
            });
          },
          behavior: HitTestBehavior.translucent,
          child: Container(
            color: isSelected ? textColor.withOpacity(0.05) : Colors.transparent,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 12 * _scale,
                  color: isSelected ? _accentColor : textColor.withOpacity(0.4),
                ),
                SizedBox(width: 6 * _scale),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? _accentColor : textColor.withOpacity(0.4),
                    fontSize: 11 * _scale,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _triggerDemo() {
    setState(() {
      _isDemoMode = true;
    });
    
    // For effects that are just state-based (like Glow) and don't have their own widget with onDemoEnd,
    // we need to manually turn off demo mode after a delay.
    if (_currentBorderEffect == BorderEffectType.glow) {
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted && _isDemoMode && _currentBorderEffect == BorderEffectType.glow) {
          setState(() {
            _isDemoMode = false;
          });
        }
      });
    }
  }

  Widget _buildGeneralSettings() {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 20 * _scale, vertical: 15 * _scale),
      children: [
        // Size Setting Tile
        _buildSettingTile(
          icon: Icons.photo_size_select_small_rounded,
          label: "Window Size",
          trailing: Row(
            children: [
              _buildSizeButton(Icons.add, () => _changeSize(2)),
              Container(
                width: 40 * _scale,
                alignment: Alignment.center,
                child: Text(
                  "$_windowScale",
                  style: TextStyle(
                    color: _accentColor,
                    fontSize: 14 * _scale,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ),
              _buildSizeButton(Icons.remove, () => _changeSize(-2)),
            ],
          ),
        ),

        // Color & Theme Setting Tile
        _buildSettingTile(
          icon: Icons.palette_rounded,
          label: "Theme & Color",
          trailing: Row(
            children: [
              // Color Dot
              Container(
                width: 8 * _scale,
                height: 8 * _scale,
                decoration: BoxDecoration(
                  color: _accentColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _accentColor.withOpacity(0.4),
                      blurRadius: 4 * _scale,
                      spreadRadius: 1 * _scale,
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8 * _scale),
              // Hex Input
              Container(
                width: 70 * _scale,
                height: 24 * _scale,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(6 * _scale),
                ),
                child: TextField(
                  controller: _hexController,
                  onChanged: _updateAccentColor,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 11 * _scale,
                    fontFamily: 'Consolas',
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    hintText: "HEX",
                    hintStyle: TextStyle(color: textColor.withOpacity(0.2), fontSize: 10),
                  ),
                ),
              ),
              SizedBox(width: 12 * _scale),
              // Theme Toggle
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _toggleTheme,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8 * _scale, vertical: 4 * _scale),
                    decoration: BoxDecoration(
                      color: textColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8 * _scale),
                    ),
                    child: Icon(
                      _isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                      size: 14 * _scale,
                      color: _accentColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Effects Setting Tile
        _buildSettingTile(
          icon: Icons.auto_awesome_outlined,
          label: "Effects",
          info: "Choose the visual effect for typing simulation.",
          trailing: Row(
            children: [
              _buildArrowButton(Icons.chevron_left_rounded, () {
                setState(() {
                  int currentIndex = BorderEffectType.values.indexOf(_currentBorderEffect);
                  int newIndex = (currentIndex - 1) % BorderEffectType.values.length;
                  if (newIndex < 0) newIndex = BorderEffectType.values.length - 1;
                  _currentBorderEffect = BorderEffectType.values[newIndex];
                  _triggerDemo(); // Trigger demo
                });
                _saveSettings();
              }),
              Container(
                width: 70 * _scale,
                alignment: Alignment.center,
                child: Text(
                  _capitalize(_currentBorderEffect.toString().split('.').last), // Display effect name
                  style: TextStyle(
                    color: _accentColor,
                    fontSize: 12 * _scale,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ),
              _buildArrowButton(Icons.chevron_right_rounded, () {
                setState(() {
                  int currentIndex = BorderEffectType.values.indexOf(_currentBorderEffect);
                  int newIndex = (currentIndex + 1) % BorderEffectType.values.length;
                  _currentBorderEffect = BorderEffectType.values[newIndex];
                  _triggerDemo(); // Trigger demo
                });
                _saveSettings();
              }),
            ],
          ),
        ),

        // Hide After Setting Tile
        _buildSettingTile(
          icon: Icons.timer_outlined,
          label: "Hide UI after",
          info: "Hide UI after, x sec of inactivity",
          trailing: Row(
            children: [
              Container(
                width: 40 * _scale,
                height: 24 * _scale,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(6 * _scale),
                ),
                child: TextField(
                  controller: _autoHideController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (val) {
                    setState(() {
                      _autoHideSeconds = int.tryParse(val) ?? 5;
                    });
                    _saveSettings();
                  },
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12 * _scale,
                    fontFamily: 'Segoe UI',
                  ),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
              SizedBox(width: 6 * _scale),
              Text(
                "sec",
                style: TextStyle(
                  color: textColor.withOpacity(0.5),
                  fontSize: 11 * _scale,
                  fontFamily: 'Segoe UI',
                ),
              ),
            ],
          ),
        ),

        // Delay Before Search Setting Tile
        _buildSettingTile(
          icon: Icons.manage_search_rounded,
          label: "Delay before search",
          info: "If user stop typing for more than this time, then search will initiate",
          trailing: Row(
            children: [
              Container(
                width: 40 * _scale,
                height: 24 * _scale,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(6 * _scale),
                ),
                child: TextField(
                  controller: _delayController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (val) {
                     int ms = int.tryParse(val) ?? 50;
                     delayBeforeSearch = Duration(milliseconds: ms);
                     _saveSettings();
                  },
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12 * _scale,
                    fontFamily: 'Segoe UI',
                  ),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
              SizedBox(width: 6 * _scale),
              Text(
                "ms",
                style: TextStyle(
                  color: textColor.withOpacity(0.5),
                  fontSize: 11 * _scale,
                  fontFamily: 'Segoe UI',
                ),
              ),
            ],
          ),
        ),

      ],
    );
  }

  Widget _buildSettingTile({required IconData icon, required String label, required Widget trailing, String? info}) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return Container(
      margin: EdgeInsets.only(bottom: 6 * _scale),
      padding: EdgeInsets.symmetric(horizontal: 12 * _scale, vertical: 5 * _scale),
      decoration: BoxDecoration(
        color: textColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12 * _scale),
        border: Border.all(color: textColor.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: textColor.withOpacity(0.7), size: 18 * _scale),
              SizedBox(width: 12 * _scale),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 14 * _scale,
                  fontFamily: 'Segoe UI',
                ),
              ),
              if (info != null) ...[
                SizedBox(width: 6 * _scale),
                Tooltip(
                  message: info,
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 14 * _scale,
                    color: textColor.withOpacity(0.5),
                  ),
                ),
              ],
            ],
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _buildSizeButton(IconData icon, VoidCallback onTap) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24 * _scale,
          height: 24 * _scale,
          decoration: BoxDecoration(
            color: textColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8 * _scale),
          ),
          child: Icon(icon, size: 14 * _scale, color: textColor.withOpacity(0.9)),
        ),
      ),
    );
  }

  Widget _buildArrowButton(IconData icon, VoidCallback onTap) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 4 * _scale),
          child: Icon(icon, size: 20 * _scale, color: textColor.withOpacity(0.6)),
        ),
      ),
    );
  }

  Widget _buildLogicSettings() {
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 20 * _scale, vertical: 15 * _scale),
      children: [
        // Tile 1: Start/Stop
        _buildHotkeyTile(
          label: "Start/Stop",
          fixedKeys: ["Ctrl", "Alt"],
          editableKey: _startStopKeyChar,
          controller: _startStopKeyController,
          onChanged: (val) {
             if (val.isNotEmpty) {
               setState(() => _startStopKeyChar = val.toLowerCase());
               _updateHotKeys();
               _saveSettings();
             }
          },
        ),
        // Tile 2: Keep Showing
         _buildHotkeyTile(
          label: "Keep Showing",
          fixedKeys: ["Ctrl", "Alt"],
          editableKey: _keepShowingKeyChar,
          controller: _keepShowingKeyController,
           onChanged: (val) {
             if (val.isNotEmpty) {
               setState(() => _keepShowingKeyChar = val.toLowerCase());
               _updateHotKeys();
               _saveSettings();
             }
          },
        ),
        // Tile 3: Switch Suggestions (Showcase)
        _buildHotkeyTile(
          label: "Switch Suggestions",
          fixedKeys: ["Shift", "Tab"],
          editableKey: null, 
          isShowcase: true,
        ),
      ],
    );
  }

  String _capitalize(String s) => s[0].toUpperCase() + s.substring(1);

  Widget _buildHotkeyTile({
    required String label,
    required List<String> fixedKeys,
    String? editableKey,
    TextEditingController? controller,
    Function(String)? onChanged,
    bool isShowcase = false,
  }) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    
    return Container(
      margin: EdgeInsets.only(bottom: 6 * _scale),
      padding: EdgeInsets.symmetric(horizontal: 12 * _scale, vertical: 8 * _scale),
      decoration: BoxDecoration(
        color: textColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12 * _scale),
        border: Border.all(color: textColor.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Label
          Row(
             children: [
               Icon(Icons.keyboard_outlined, color: textColor.withOpacity(0.7), size: 18 * _scale),
               SizedBox(width: 12 * _scale),
               Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 14 * _scale,
                  fontFamily: 'Segoe UI',
                ),
              ),
             ]
          ),
          
          // Right: Keys
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...fixedKeys.asMap().entries.map((entry) {
                int idx = entry.key;
                String keyText = entry.value;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8 * _scale, vertical: 4 * _scale),
                      decoration: BoxDecoration(
                        color: textColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6 * _scale),
                        border: Border.all(color: textColor.withOpacity(0.1)),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        keyText,
                        style: TextStyle(
                          color: textColor.withOpacity(0.7),
                          fontSize: 11 * _scale,
                          fontFamily: 'Consolas',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (idx < fixedKeys.length - 1 || editableKey != null)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4 * _scale),
                        child: Text(
                          "+",
                          style: TextStyle(
                            color: textColor.withOpacity(0.4),
                            fontSize: 12 * _scale,
                          ),
                        ),
                      ),
                  ],
                );
              }),
              
              if (editableKey != null && controller != null)
                 Container(
                    width: 24 * _scale,
                    height: 24 * _scale,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _accentColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6 * _scale),
                      border: Border.all(color: _accentColor.withOpacity(0.5)),
                    ),
                    child: TextField(
                      controller: controller,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _accentColor,
                        fontSize: 12 * _scale,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Consolas',
                      ),
                      maxLength: 1,
                      buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                      ],
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: onChanged,
                    ),
                 ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDatabaseSettings() {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final dbOptions = ['User DB', 'Main DB', 'Trie suggestions'];
    
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Compact Header
        Padding(
          padding: EdgeInsets.fromLTRB(10 * _scale, 5 * _scale, 10 * _scale, 4 * _scale),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Arrow Selector (Smaller)
              Container(
                height: 24 * _scale,
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8 * _scale),
                  border: Border.all(color: textColor.withOpacity(0.1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildArrowButton(Icons.chevron_left_rounded, () {
                      int currentIndex = dbOptions.indexOf(_selectedDbOption);
                      int newIndex = (currentIndex - 1) % dbOptions.length;
                      if (newIndex < 0) newIndex = dbOptions.length - 1;
                      setState(() {
                        _selectedDbOption = dbOptions[newIndex];
                        _showDeleteConfirm = false;
                      });
                      if (_selectedDbOption == 'User DB') _performDbSearch();
                      if (_selectedDbOption == 'Main DB') _performMainDbSearch();
                    }),
                    Container(
                      width: 80 * _scale,
                      alignment: Alignment.center,
                      child: Text(
                        _selectedDbOption,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 10 * _scale,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ),
                    _buildArrowButton(Icons.chevron_right_rounded, () {
                      int currentIndex = dbOptions.indexOf(_selectedDbOption);
                      int newIndex = (currentIndex + 1) % dbOptions.length;
                      setState(() {
                        _selectedDbOption = dbOptions[newIndex];
                        _showDeleteConfirm = false;
                        _showDeleteOlderInput = false;
                      });
                      if (_selectedDbOption == 'User DB') _performDbSearch();
                      if (_selectedDbOption == 'Main DB') _performMainDbSearch();
                    }),
                  ],
                ),
              ),
              
              // Action Buttons
              if (_selectedDbOption == 'User DB' || _selectedDbOption == 'Main DB')
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 1. Open Folder Button
                    Tooltip(
                      message: "open in explorer",
                      child: Container(
                        height: 28 * _scale,
                        width: 28 * _scale,
                        margin: EdgeInsets.only(right: 4 * _scale),
                        decoration: BoxDecoration(
                          color: textColor.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8 * _scale),
                          border: Border.all(color: textColor.withOpacity(0.1)),
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.folder_open_rounded, size: 16 * _scale, color: textColor.withOpacity(0.8)),
                          onPressed: () async {
                            final openFile  = await getApplicationSupportDirectory();
                            Process.run('explorer', [openFile.path]);
                          },
                        ),
                      ),
                    ),

                    if (_selectedDbOption == 'User DB') ...[
                      // 2. Delete Older Than (Animated)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 20),
                        curve: Curves.easeInOut,
                        height: 28 * _scale,
                        width: _showDeleteOlderInput ? 115 * _scale : 28 * _scale,
                        margin: EdgeInsets.only(right: 4 * _scale),
                        decoration: BoxDecoration(
                          color: textColor.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8 * _scale),
                          border: Border.all(color: textColor.withOpacity(0.1)),
                        ),
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.center,
                            minWidth: 0,
                            maxWidth: 115 * _scale,
                            child: _showDeleteOlderInput
                                ? Row(
                                    children: [
                                      Expanded(
                                        child: Padding(
                                          padding: EdgeInsets.only(left: 6 * _scale),
                                          child: TextField(
                                            controller: _deleteOlderController,
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                            autofocus: true,
                                            style: TextStyle(fontSize: 10 * _scale, color: textColor),
                                            decoration: InputDecoration(
                                              isDense: true,
                                              border: InputBorder.none,
                                              hintText: "older than...",
                                              hintStyle: TextStyle(color: textColor.withOpacity(0.4), fontSize: 9 * _scale),
                                              contentPadding: EdgeInsets.symmetric(vertical: 8 * _scale),
                                            ),
                                            onSubmitted: (_) => _deleteOlderThan(),
                                          ),
                                        ),
                                      ),
                                      Text("days", style: TextStyle(fontSize: 9 * _scale, color: textColor.withOpacity(0.6))),
                                      IconButton(
                                        icon: Icon(Icons.check_rounded, size: 14 * _scale, color: _accentColor),
                                        onPressed: _deleteOlderThan,
                                        padding: EdgeInsets.zero,
                                        constraints: BoxConstraints(minWidth: 22 * _scale, minHeight: 28 * _scale),
                                      ),
                                      IconButton(
                                        icon: Icon(Icons.close_rounded, size: 14 * _scale, color: Colors.red.withOpacity(0.7)),
                                        onPressed: () => setState(() => _showDeleteOlderInput = false),
                                        padding: EdgeInsets.zero,
                                        constraints: BoxConstraints(minWidth: 22 * _scale, minHeight: 28 * _scale),
                                      ),
                                    ],
                                  )
                                : Center(
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: Icon(Icons.auto_delete_rounded, size: 16 * _scale, color: textColor.withOpacity(0.8)),
                                      tooltip: "delete entries older than...",
                                      onPressed: () => setState(() {
                                        _showDeleteOlderInput = true;
                                        _showDeleteConfirm = false;
                                      }),
                                    ),
                                  ),
                          ),
                        ),
                      ),

                      // 3. Reset Button (Manual implementation to match size)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: _showDeleteConfirm
                            ? Container(
                                height: 28 * _scale,
                                decoration: BoxDecoration(
                                  color: textColor.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(8 * _scale),
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints(minWidth: 28 * _scale),
                                      icon: Icon(Icons.check_rounded, size: 16 * _scale, color: Colors.green),
                                      onPressed: () async {
                                        await resetUserDatabase();
                                        setState(() => _showDeleteConfirm = false);
                                      },
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints(minWidth: 28 * _scale),
                                      icon: Icon(Icons.close_rounded, size: 16 * _scale, color: Colors.red),
                                      onPressed: () => setState(() => _showDeleteConfirm = false),
                                    ),
                                  ],
                                ),
                              )
                            : Tooltip(
                                message: "reset user DB",
                                child: Container(
                                  height: 28 * _scale,
                                  width: 28 * _scale,
                                  decoration: BoxDecoration(
                                    color: textColor.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(8 * _scale),
                                    border: Border.all(color: textColor.withOpacity(0.1)),
                                  ),
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    icon: Icon(Icons.restart_alt_rounded, size: 16 * _scale, color: textColor.withOpacity(0.8)),
                                    onPressed: () => setState(() {
                                      _showDeleteConfirm = true;
                                      _showDeleteOlderInput = false;
                                    }),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),

        if (_selectedDbOption == 'User DB') ...[
          // Search Section
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10 * _scale, vertical: 4 * _scale),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 26 * _scale,
                    padding: EdgeInsets.symmetric(horizontal: 8 * _scale),
                    decoration: BoxDecoration(
                      color: textColor.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(6 * _scale),
                    ),
                    child: TextField(
                      controller: _dbSearchMisspelledController,
                      style: TextStyle(fontSize: 12 * _scale, color: textColor),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'misspelled',
                        hintStyle: TextStyle(color: textColor.withOpacity(0.3), fontSize: 11 * _scale),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6 * _scale),
                      ),
                      onSubmitted: (_) => _performDbSearch(),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6 * _scale),
                  child: Icon(Icons.arrow_forward_rounded, size: 14 * _scale, color: textColor.withOpacity(0.4)),
                ),
                Expanded(
                  child: Container(
                    height: 26 * _scale,
                    padding: EdgeInsets.symmetric(horizontal: 8 * _scale),
                    decoration: BoxDecoration(
                      color: textColor.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(6 * _scale),
                    ),
                    child: TextField(
                      controller: _dbSearchCorrectController,
                      style: TextStyle(fontSize: 12 * _scale, color: textColor),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'correct',
                        hintStyle: TextStyle(color: textColor.withOpacity(0.3), fontSize: 11 * _scale),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6 * _scale),
                      ),
                      onSubmitted: (_) => _performDbSearch(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          Divider(height: 1, thickness: 1, color: textColor.withOpacity(0.05)),

          // Results Section
          if (_dbSearchLoading)
            Padding(
              padding: EdgeInsets.all(20 * _scale),
              child: Center(child: SizedBox(
                width: 20 * _scale, height: 20 * _scale,
                child: CircularProgressIndicator(strokeWidth: 2, color: _accentColor)
              )),
            )
          else
            ..._dbSearchResults.asMap().entries.map((entry) {
              final item = entry.value;
              final misspelled = (item['misspelled'] as String?) ?? '';
              final correct = (item['correct'] as String?) ?? '';
              final metaphone = (item['metaphone'] as String?) ?? '';
              final timestamp = (item['updated_at'] as String?) ?? (item['created_at'] as String?) ?? '';
              
              return DatabaseResultTile(
                misspelled: misspelled,
                correct: correct,
                metaphone: metaphone,
                timestamp: timestamp,
                scale: _scale,
                textColor: textColor,
                accentColor: _accentColor,
                onDelete: () async {
                  await deleteUserCorrection(misspelled);
                  _performDbSearch(resetPage: false);
                },
              );
            }).toList(),
          
          // Pagination
          if (_dbSearchResults.isNotEmpty || _dbSearchPage > 0)
            Container(
              padding: EdgeInsets.symmetric(vertical: 4 * _scale),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: textColor.withOpacity(0.05))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.chevron_left_rounded, size: 18 * _scale),
                    color: textColor.withOpacity(_dbSearchPage > 0 ? 0.8 : 0.2),
                    onPressed: _dbSearchPage > 0 ? () {
                      setState(() => _dbSearchPage--);
                      _performDbSearch(resetPage: false);
                    } : null,
                  ),
                  Text(
                    'Page ${_dbSearchPage + 1}',
                    style: TextStyle(fontSize: 11 * _scale, color: textColor.withOpacity(0.6)),
                  ),
                  IconButton(
                    icon: Icon(Icons.chevron_right_rounded, size: 18 * _scale),
                    color: textColor.withOpacity(_dbSearchResults.length == 10 ? 0.8 : 0.2),
                    onPressed: _dbSearchResults.length == 10 ? () {
                      setState(() => _dbSearchPage++);
                      _performDbSearch(resetPage: false);
                    } : null,
                  ),
                ],
              ),
            ),
        ] else if (_selectedDbOption == 'Main DB') ...[
          // Search Section
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10 * _scale, vertical: 4 * _scale),
            child: Container(
              height: 26 * _scale,
              padding: EdgeInsets.symmetric(horizontal: 8 * _scale),
              decoration: BoxDecoration(
                color: textColor.withOpacity(0.05),
                borderRadius: BorderRadius.circular(6 * _scale),
              ),
              child: TextField(
                controller: _mainDbSearchController,
                style: TextStyle(fontSize: 12 * _scale, color: textColor),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'search dictionary...',
                  hintStyle: TextStyle(color: textColor.withOpacity(0.3), fontSize: 11 * _scale),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6 * _scale),
                  suffixIcon: Icon(Icons.search_rounded, size: 14 * _scale, color: textColor.withOpacity(0.3)),
                  suffixIconConstraints: BoxConstraints(minWidth: 24 * _scale, minHeight: 24 * _scale),
                ),
                onSubmitted: (_) => _performMainDbSearch(),
              ),
            ),
          ),
          
          Divider(height: 1, thickness: 1, color: textColor.withOpacity(0.05)),

          // Results Section
          if (_mainDbSearchLoading)
            Padding(
              padding: EdgeInsets.all(20 * _scale),
              child: Center(child: SizedBox(
                width: 20 * _scale, height: 20 * _scale,
                child: CircularProgressIndicator(strokeWidth: 2, color: _accentColor)
              )),
            )
          else
            ..._mainDbSearchResults.asMap().entries.map((entry) {
              final item = entry.value;
              final word = (item['Word'] as String?) ?? '';
              
              return MainDbResultTile(
                word: word,
                scale: _scale,
                textColor: textColor,
                accentColor: _accentColor,
                onDelete: () async {
                  await deleteMainDictionaryWord(word);
                  _performMainDbSearch(resetPage: false);
                },
              );
            }).toList(),
            
           // Pagination
          if (_mainDbSearchResults.isNotEmpty || _mainDbSearchPage > 0)
            Container(
              padding: EdgeInsets.symmetric(vertical: 4 * _scale),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: textColor.withOpacity(0.05))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.chevron_left_rounded, size: 18 * _scale),
                    color: textColor.withOpacity(_mainDbSearchPage > 0 ? 0.8 : 0.2),
                    onPressed: _mainDbSearchPage > 0 ? () {
                      setState(() => _mainDbSearchPage--);
                      _performMainDbSearch(resetPage: false);
                    } : null,
                  ),
                  Text(
                    'Page ${_mainDbSearchPage + 1}',
                    style: TextStyle(fontSize: 11 * _scale, color: textColor.withOpacity(0.6)),
                  ),
                  IconButton(
                    icon: Icon(Icons.chevron_right_rounded, size: 18 * _scale),
                    color: textColor.withOpacity(_mainDbSearchResults.length == 10 ? 0.8 : 0.2),
                    onPressed: _mainDbSearchResults.length == 10 ? () {
                      setState(() => _mainDbSearchPage++);
                      _performMainDbSearch(resetPage: false);
                    } : null,
                  ),
                ],
              ),
            ),
        ] else ...[
          Padding(
            padding: EdgeInsets.all(20 * _scale),
            child: Center(child: Text("Trie persistance will be added in future updates", style: TextStyle(color: textColor.withOpacity(0.5)))),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
    final surfaceColor = _isDarkMode ? Colors.black.withOpacity(0.2) : Colors.white.withOpacity(0.5);
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = _isDarkMode ? Colors.white.withOpacity(0.7) : Colors.black54;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: (_isDarkMode ? ThemeData.dark() : ThemeData.light()).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        primaryColor: _accentColor,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: ValueListenableBuilder<bool>(
          valueListenable: isSimulatingTyping,
          builder: (context, isTyping, _) {
            // Determine if an effect should be active
            bool effectActive = _isDemoMode || _isEffectPlaying;

            Widget mainContent = AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: _isExpanded
                    ? BorderRadius.horizontal(left: Radius.circular(16 * _scale))
                    : BorderRadius.circular(16 * _scale),
                border: _currentBorderEffect == BorderEffectType.glow && effectActive
                    ? Border.all(
                        color: _accentColor.withOpacity(0.9),
                        width: 1.5,
                      )
                    : Border.all(
                        color: textColor.withOpacity(0.1),
                        width: 1.0,
                      ),
                boxShadow: _currentBorderEffect == BorderEffectType.glow && effectActive
                    ? [
                        BoxShadow(
                          color: _accentColor.withOpacity(0.25),
                          blurRadius: 20,
                          spreadRadius: 1,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 16,
                          spreadRadius: 0,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7.0 * _scale, vertical: 6.0 * _scale),
                      child: ValueListenableBuilder<String>(
                        valueListenable: currentWordNotifier,
                        builder: (context, currentWord, _) {
                          return ValueListenableBuilder<String>(
                            valueListenable: globalCorrectWord,
                            builder: (context, correctWord, _) {
                              return ValueListenableBuilder<List<String>>(
                                valueListenable: globalSuggestions,
                                builder: (context, suggestions, _) {
                                  final List<String> words = [
                                    if (correctWord.isNotEmpty) correctWord,
                                    ...suggestions,
                                  ].take(4).toList();

                                  return ValueListenableBuilder<int>(
                                    valueListenable: selectedTileIndex,
                                    builder: (context, selectedIndex, _) {
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: words.asMap().entries.map((entry) {
                                          int index = entry.key;
                                          String word = entry.value;
                                          bool isCorrected = index == 0 && correctWord.isNotEmpty && word == correctWord;
                                          bool isSelected = index == selectedIndex;

                                          // Calculate matching prefix length
                                          int matchLength = 0;
                                          if (currentWord.isNotEmpty && word.toLowerCase().startsWith(currentWord.toLowerCase())) {
                                            matchLength = currentWord.length;
                                          }

                                          return AnimatedContainer(
                                            duration: const Duration(milliseconds: 150),
                                            curve: Curves.easeOut,
                                            margin: EdgeInsets.only(bottom: 4 * _tileScale),
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 5 * _tileScale,
                                              vertical: 1 * _tileScale,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isSelected
                                                  ? textColor.withOpacity(0.1)
                                                  : (isCorrected
                                                      ? (_isDarkMode ? const Color(0xFF004D40) : const Color(0xFFB2DFDB)).withOpacity(0.5)
                                                      : Colors.transparent),
                                              borderRadius: BorderRadius.circular(8 * _tileScale),
                                              border: isSelected
                                                  ? Border.all(color: textColor.withOpacity(0.2), width: 1)
                                                  : Border.all(color: Colors.transparent, width: 1),
                                            ),
                                            child: Row(
                                              children: [
                                                // Optional: visual indicator for the selected item
                                                if (isSelected)
                                                  Container(
                                                    width: 3 * _tileScale,
                                                    height: 12 * _tileScale,
                                                    margin: EdgeInsets.only(right: 8 * _tileScale),
                                                    decoration: BoxDecoration(
                                                      color: isCorrected ? _accentColor : textColor,
                                                      borderRadius: BorderRadius.circular(2 * _tileScale),
                                                    ),
                                                  ),
                                                Expanded(
                                                  child: RichText(
                                                    text: TextSpan(
                                                      style: TextStyle(
                                                        color: isCorrected ? _accentColor : textColor.withOpacity(0.9),
                                                        fontSize: 14 * _tileScale,
                                                        fontFamily: 'Segoe UI',
                                                        letterSpacing: 0.3,
                                                      ),
                                                      children: [
                                                        TextSpan(
                                                          text: word.substring(0, matchLength),
                                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                                        ),
                                                        TextSpan(
                                                          text: word.substring(matchLength),
                                                          style: TextStyle(
                                                            fontWeight: FontWeight.w400,
                                                            color: subTextColor,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                // Correction Icon
                                                if (isCorrected)
                                                  Icon(
                                                    Icons.auto_fix_high_rounded,
                                                    size: 14 * _tileScale,
                                                    color: _accentColor,
                                                  )
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  // Separator
                  Container(
                    height: 1,
                    color: textColor.withOpacity(0.05),
                  ),
                  // Footer / Status Bar
                  GestureDetector(
                    onPanStart: (details) => windowManager.startDragging(),
                    behavior: HitTestBehavior.translucent, // Ensure whole area is draggable
                    child: Container(
                      height: 28 * _scale,
                      padding: EdgeInsets.symmetric(horizontal: 12 * _scale),
                      decoration: BoxDecoration(
                          color: surfaceColor,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16 * _scale),
                            bottomRight: _isExpanded ? Radius.zero : Radius.circular(16 * _scale),
                          )),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Animated Status Text
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              transitionBuilder: (Widget child, Animation<double> animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(begin: const Offset(0.0, 0.5), end: Offset.zero).animate(animation),
                                    child: child,
                                  ),
                                );
                              },
                              child: Row(
                                key: ValueKey<String>(_displayStatus),
                                children: [
                                  Icon(_displayIcon, size: 14 * _scale, color: textColor.withOpacity(0.8)),
                                  SizedBox(width: 6 * _scale),
                                  Expanded(
                                    child: Text(
                                      _displayStatus,
                                      style: TextStyle(
                                        color: textColor.withOpacity(0.8),
                                        fontSize: 11 * _scale,
                                        fontWeight: FontWeight.w500,
                                        fontFamily: 'Segoe UI',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Expand/Collapse Button (Replaces Close Button)
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: _toggleExpand,
                              child: Icon(
                                _isExpanded ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded,
                                color: textColor.withOpacity(0.4),
                                size: 14 * _scale,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );

            return Row(
              children: [
                // Main Interface
                Expanded(
                  child: Stack(
                    children: [
                      mainContent,
                      if (_currentBorderEffect == BorderEffectType.dotted && effectActive)
                        Positioned.fill(
                          child: DottedBorderEffect(
                            child: const SizedBox.shrink(),
                            isTyping: isTyping,
                            accentColor: _accentColor,
                            scale: _scale,
                            isExpanded: _isExpanded,
                            isDemoMode: _isDemoMode,
                            onDemoEnd: () {
                              setState(() {
                                _isDemoMode = false;
                                _isEffectPlaying = false;
                              });
                            },
                          ),
                        ),
                      if (_currentBorderEffect == BorderEffectType.particles && effectActive)
                        Positioned.fill(
                          child: ParticleEffect(
                            accentColor: _accentColor,
                            scale: _scale,
                            isExpanded: _isExpanded,
                            isTyping: isTyping,
                            isDemoMode: _isDemoMode,
                            onDemoEnd: () {
                              setState(() {
                                _isDemoMode = false;
                                _isEffectPlaying = false;
                              });
                            },
                          ),
                        ),
                      if (_currentBorderEffect == BorderEffectType.glass && effectActive)
                        Positioned.fill(
                          child: GlassShineEffect(
                            accentColor: _accentColor,
                            scale: _scale,
                            isExpanded: _isExpanded,
                            isTyping: isTyping,
                            isDemoMode: _isDemoMode,
                            onDemoEnd: () {
                              setState(() {
                                _isDemoMode = false;
                                _isEffectPlaying = false;
                              });
                            },
                          ),
                        ),
                    ],
                  ),
                ),

                // Side Panel (Settings)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOutCubic,
                  width: _isExpanded ? 360 * _scale : 0,
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.horizontal(right: Radius.circular(16 * _scale)),
                    border: Border.all(
                      color: textColor.withOpacity(0.1),
                      width: 1.0,
                    ),
                  ),
                  child: ClipRect(
                    child: OverflowBox(
                      minWidth: 0,
                      maxWidth: 360 * _scale,
                      alignment: Alignment.centerLeft,
                      child: _isExpanded
                          ? Column(
                              children: [
                                // Tab Content
                                Expanded(
                                  child: _selectedSettingsTab == 0
                                      ? _buildGeneralSettings()
                                      : (_selectedSettingsTab == 1
                                          ? _buildLogicSettings()
                                          : _buildDatabaseSettings()),
                                ),

                                // Separator
                                Container(
                                  height: 1,
                                  color: textColor.withOpacity(0.05),
                                ),

                                // Tab Bar Footer
                                Container(
                                  height: 28 * _scale,
                                  decoration: BoxDecoration(
                                      color: surfaceColor,
                                      borderRadius: BorderRadius.only(
                                        bottomRight: Radius.circular(16 * _scale),
                                      )),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      _buildTab(0, Icons.tune_rounded, "General"),
                                      // Vertical Divider
                                      Container(width: 1, color: textColor.withOpacity(0.05)),
                                      _buildTab(1, Icons.keyboard, "Shorcut Keys"),
                                      Container(width: 1, color: textColor.withOpacity(0.05)),
                                      _buildTab(2, Icons.storage_rounded, "Database"),
                                    ],
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class DatabaseResultTile extends StatefulWidget {
  final String misspelled;
  final String correct;
  final String metaphone;
  final String timestamp;
  final double scale;
  final Color textColor;
  final Color accentColor;
  final VoidCallback onDelete;

  const DatabaseResultTile({
    super.key,
    required this.misspelled,
    required this.correct,
    required this.metaphone,
    required this.timestamp,
    required this.scale,
    required this.textColor,
    required this.accentColor,
    required this.onDelete,
  });

  @override
  State<DatabaseResultTile> createState() => _DatabaseResultTileState();
}

class _DatabaseResultTileState extends State<DatabaseResultTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        color: _isHovered ? widget.textColor.withOpacity(0.1) : Colors.transparent,
        padding: EdgeInsets.symmetric(horizontal: 12 * widget.scale, vertical: 6 * widget.scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontFamily: 'Segoe UI',
                        fontSize: 13 * widget.scale,
                        color: widget.textColor.withOpacity(0.9),
                      ),
                      children: [
                        TextSpan(text: widget.misspelled, style: const TextStyle(fontWeight: FontWeight.bold)),
                        WidgetSpan(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6 * widget.scale),
                            child: Icon(Icons.arrow_right_alt_rounded, size: 14 * widget.scale, color: widget.accentColor),
                          ),
                          alignment: PlaceholderAlignment.middle
                        ),
                        TextSpan(text: widget.correct),
                      ],
                    ),
                  ),
                ),
                Text(
                  widget.metaphone,
                  style: TextStyle(
                    fontSize: 11 * widget.scale,
                    color: widget.textColor.withOpacity(0.5),
                    fontFamily: 'Consolas',
                  ),
                ),
              ],
            ),
            SizedBox(height: 4 * widget.scale),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Lower Left Delete Button (Visible on hover)
                Opacity(
                  opacity: _isHovered ? 1.0 : 0.0,
                  child: GestureDetector(
                    onTap: widget.onDelete,
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 14 * widget.scale,
                      color: Colors.red.withOpacity(0.8),
                    ),
                  ),
                ),
                // Lower Right Timestamp
                Text(
                  widget.timestamp,
                  style: TextStyle(
                    fontSize: 9 * widget.scale,
                    color: widget.textColor.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DottedBorderPainter extends CustomPainter {
  final double animationValue;
  final Color color;
  final double scale;
  final bool isExpanded;

  DottedBorderPainter({
    required this.animationValue,
    required this.color,
    required this.scale,
    required this.isExpanded,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 2.0 * scale
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final double radius = 16 * scale;
    final Path path = Path()
      ..addRRect(RRect.fromRectAndCorners(
        Rect.fromLTWH(0, 0, size.width, size.height),
        topLeft: Radius.circular(radius),
        bottomLeft: Radius.circular(radius),
        topRight: isExpanded ? Radius.zero : Radius.circular(radius),
        bottomRight: isExpanded ? Radius.zero : Radius.circular(radius),
      ));

    final ui.PathMetrics metrics = path.computeMetrics();
    const double dashWidth = 3.0;
    const double dashSpace = 4.0;
    
    for (final metric in metrics) {
      final double totalLength = metric.length;
      // The "train" is 25% of the total length
      final double trainLength = totalLength * 0.25;
      final double startOffset = totalLength * animationValue;

      double currentPos = 0;
      while (currentPos < trainLength) {
        final double d = (startOffset + currentPos) % totalLength;
        final double end = (d + dashWidth * scale);
        
        if (end > totalLength) {
          canvas.drawPath(metric.extractPath(d, totalLength), paint);
          canvas.drawPath(metric.extractPath(0, end % totalLength), paint);
        } else {
          canvas.drawPath(metric.extractPath(d, end), paint);
        }
        currentPos += (dashWidth + dashSpace) * scale;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DottedBorderPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue || 
           oldDelegate.color != color ||
           oldDelegate.isExpanded != isExpanded;
  }
}

class DottedBorderEffect extends StatefulWidget {
  final Widget child;
  final bool isTyping;
  final Color accentColor;
  final double scale;
  final bool isExpanded;
  final bool isDemoMode;
  final VoidCallback onDemoEnd;

  const DottedBorderEffect({
    super.key,
    required this.child,
    required this.isTyping,
    required this.accentColor,
    required this.scale,
    required this.isExpanded,
    this.isDemoMode = false,
    required this.onDemoEnd,
  });

  @override
  State<DottedBorderEffect> createState() => _DottedBorderEffectState();
}

class _DottedBorderEffectState extends State<DottedBorderEffect> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  Timer? _safetyTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500), 
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(_controller)
      ..addListener(() {
        setState(() {});
      });

    _controller.forward();
    
    // Safety timer to force end
    _safetyTimer = Timer(const Duration(milliseconds: 1550), () {
      if (mounted) {
        widget.onDemoEnd();
      }
    });
  }

  @override
  void didUpdateWidget(covariant DottedBorderEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ignore updates
  }

  @override
  void dispose() {
    _controller.dispose();
    _safetyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: DottedBorderPainter(
        animationValue: _animation.value,
        color: widget.accentColor.withOpacity(0.9),
        scale: widget.scale +1,
        isExpanded: widget.isExpanded,
      ),
      child: widget.child,
    );
  }
}

class MainDbResultTile extends StatefulWidget {
  final String word;
  final double scale;
  final Color textColor;
  final Color accentColor;
  final VoidCallback onDelete;

  const MainDbResultTile({
    super.key,
    required this.word,
    required this.scale,
    required this.textColor,
    required this.accentColor,
    required this.onDelete,
  });

  @override
  State<MainDbResultTile> createState() => _MainDbResultTileState();
}

class _MainDbResultTileState extends State<MainDbResultTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * widget.scale, vertical: 8 * widget.scale),
        decoration: BoxDecoration(
          color: _isHovered ? widget.textColor.withOpacity(0.1) : Colors.transparent,
          border: Border(bottom: BorderSide(color: widget.textColor.withOpacity(0.02))),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_rounded, size: 14 * widget.scale, color: widget.accentColor.withOpacity(0.7)),
            SizedBox(width: 12 * widget.scale),
            Expanded(
              child: Text(
                widget.word,
                style: TextStyle(
                  fontFamily: 'Segoe UI',
                  fontSize: 13 * widget.scale,
                  color: widget.textColor.withOpacity(0.9),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // Delete Button (Visible on hover)
            Opacity(
              opacity: _isHovered ? 1.0 : 0.0,
              child: GestureDetector(
                onTap: widget.onDelete,
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 14 * widget.scale,
                  color: Colors.red.withOpacity(0.8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}