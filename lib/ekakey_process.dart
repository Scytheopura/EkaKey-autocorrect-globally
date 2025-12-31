import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';
import 'package:flutter/services.dart';
import 'package:autotrie/autotrie.dart';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:dart_phonetics/dart_phonetics.dart';
import 'package:string_similarity/string_similarity.dart';

// notifiers for UI dynamic changes
final ValueNotifier<List<String>> globalSuggestions = ValueNotifier<List<String>>([]);
final ValueNotifier<String> globalCorrectWord = ValueNotifier<String>('');
final ValueNotifier<String> currentWordNotifier = ValueNotifier<String>('');
final ValueNotifier<int> selectedTileIndex = ValueNotifier<int>(0);
final ValueNotifier<String> selectedTileWord = ValueNotifier<String>('');
final ValueNotifier<String> status = ValueNotifier<String>('');
final ValueNotifier<bool> isSimulatingTyping = ValueNotifier<bool>(false);

// channel to communicate with C++
const MethodChannel _channel = MethodChannel('ekakey/keyboard');
//trie persistent file 
late File myFile;

// variables for last four words
var _thirdLastWord = '';
var _secondLastWord = '';
var _lastWord = '';
String get _currentWord => currentWordNotifier.value;
set _currentWord(String value) => currentWordNotifier.value = value;

// initialization stuff
sqlite.Database? _db;
sqlite.Database? _userDb;
AutoComplete? _trieEngine;

// for learing into user db
String _editOriginalTyped = ''; // What user originally typed (e.g., "helo")
String _editCorrectedTo = ''; // What it was corrected to (e.g., "hello") 

// errorCorrection stuff
var _lastIncorrectWord = '';    //if this is not empty then backspace gonna make it to edit system
bool _trackingUserEdit = false; //true while editing a word
bool _ignoreBackspace = false;  //ignore needed when keySym does it's job of backspacing
bool _ignoreSpaceCall = false;  //need to ignore space{no autoCorrect call} after edit is done
bool _skipErrorCheck = false;   //same same but different 
int _ignoreKeysForClearing = 0; //to ignore keySym typed things 

// to track modifier key states
bool isLeftShift = false;
bool isRightShift = false;
bool isLeftCtrl = false;
bool isRightCtrl = false;
bool isLeftAlt = false;
bool isRightAlt = false;
bool isLeftWin = false;
bool isRightWin = false;
bool isCapsLockOn = false;
bool get isShift => isLeftShift || isRightShift;
bool get isCtrl => isLeftCtrl || isRightCtrl;
bool get isAlt => isLeftAlt || isRightAlt;
bool get isWin => isLeftWin || isRightWin;
// vk code constants for modifier keys
const int vkLshift = 0xA0; // 160
const int vkRshift = 0xA1; // 161
const int vkLctrl = 0xA2; // 162
const int vkRctrl = 0xA3; // 163
const int vkLalt = 0xA4; // 164
const int vkRalt = 0xA5; // 165 
const int vkLwin = 0x5B; // 91 
const int vkRwin = 0x5C; // 92
const int vkCapsLockL = 0x14; // 20 

Future<String> _getEkaKeyPath() async {
  // 1. Get the directory where the .exe is actually running
  final String executableDir = dirname(Platform.resolvedExecutable);

  if (kReleaseMode) {
    // In Production: Assets are usually in 'data/flutter_assets/assets'
    // but your DBs should probably live in a persistent user folder.
    return join(executableDir, 'data', 'flutter_assets', 'assets');
  } else {
    // In Development: Just use the local assets folder
    return 'assets';
  }
}

// Settings var
Duration delayBeforeSearch = Duration(milliseconds: 50);

// as name says
void _clearAllWords() {
  if (_currentWord.isNotEmpty ||
      _lastWord.isNotEmpty ||
      _secondLastWord.isNotEmpty ||
      _thirdLastWord.isNotEmpty|| 
      globalSuggestions.value.isNotEmpty ||
      globalCorrectWord.value.isNotEmpty) {
    _currentWord = '';
    _lastWord = '';
    _secondLastWord = '';
    _thirdLastWord = '';
    _lastIncorrectWord = '';
    _trackingUserEdit = false;
    _editOriginalTyped = '';
    _editCorrectedTo = '';
    globalSuggestions.value = [];
    globalCorrectWord.value = '';
    selectedTileIndex.value = 0;
    selectedTileWord.value = '';
  }
}

void _shiftWordsBack() {
  _thirdLastWord = _secondLastWord;
  _secondLastWord = _lastWord;
  _lastWord = _currentWord;
  _currentWord = '';
}

void _shiftWordsForward() {
  _currentWord = _lastWord;
  _lastWord = _secondLastWord;
  _secondLastWord = _thirdLastWord;
  _thirdLastWord = '';
}

String _applyCasing(String result, String original) {
  if (original.isEmpty) return result;

  // check if all are upperCase
  bool isAllUpper = original == original.toUpperCase() && 
                    original != original.toLowerCase();
  
  // check if first char is uppercase 
  bool isFirstUpper = original[0] == original[0].toUpperCase() && 
                      original[0] != original[0].toLowerCase() && 
                      !isAllUpper;

  if (isAllUpper) {
    return result.toUpperCase();
  } else if (isFirstUpper) {
    if (result.isEmpty) return result;
    return result[0].toUpperCase() + result.substring(1);
  }

  //return the same thing if nothing matches, so storing iphone -> iPhone in user db is possible
  return result;
}

// each key(not modifiers) event listeners
class _KeyPayload {
  final VIRTUAL_KEY vkCode;
  final String label;
  _KeyPayload(this.vkCode, this.label);
}
final StreamController<_KeyPayload> _keyEventController = StreamController();

/// Background function that handles special keys logic 
Future<void> _processKeyEvents() async {
  await _initTrie();

  //this part run's for each(except modifiers) key stroke by user
  await for (final event in _keyEventController.stream) {
    final key = event.vkCode;
    //quickly ignore those changes which are due to keySym
    if (_ignoreKeysForClearing == 0) {
      if (key != 8) {_lastIncorrectWord = '';}
    } else {
      _ignoreKeysForClearing--;
    }

    // --- Reset keys ---
    final isArrowKey = key == 38 || key == 40 || key == 37 || key == 39;
    final isResetKey =
        key == 46 || key == 13 || (48 <= key && key <= 57) || 
        (key == 186 || key == 187 || key == 188 || (190 <= key && key <= 192)) || 
        (219 <= key && key <= 221);
    if (isArrowKey || isResetKey) {
      _trackingUserEdit = false;
      _editOriginalTyped = '';
      _editCorrectedTo = '';
      _clearAllWords();
      continue;
    }

    // --- Space key ---
    if (key == 32) {
      // learning when needed
      if (_trackingUserEdit && _currentWord.isNotEmpty) {
        if(selectedTileIndex.value != 0) {
          await _learnFromUserEdit(
            _editOriginalTyped,
            _editCorrectedTo,
            selectedTileWord.value, 
          );
        }else{
          await _learnFromUserEdit(
            _editOriginalTyped,
            _editCorrectedTo,
            _currentWord, 
          );
        }
        //resetting things after a spacebar 
        _trackingUserEdit = false;
        _editOriginalTyped = ''; 
        _editCorrectedTo = '';
        _lastIncorrectWord = '';
      }

      // call _errorCorrection for errors
      if (_currentWord.isNotEmpty) {
        await _errorCorrection(_currentWord, false);
      }

      // Update Trie and shift words
      if (_currentWord.isNotEmpty) {
        _trieEngine!.enter(_currentWord.toLowerCase());
      }
      globalSuggestions.value = [];
      selectedTileIndex.value = 0;
      selectedTileWord.value = '';
      _shiftWordsBack();
      continue;
    }

    // --- Backspace key ---
    if (key == 8) {
      if (isCtrl) {
        // ctrl+Backspace: exit editing 
        _trackingUserEdit = false;
        _lastIncorrectWord = '';
        _editOriginalTyped = '';
        _editCorrectedTo = '';

        if (_currentWord.isNotEmpty) {
          _currentWord = '';
        } else {
          _shiftWordsForward();
          _currentWord = '';
        }
        globalSuggestions.value = [];
        selectedTileIndex.value = 0;
        selectedTileWord.value = '';
      } else {
        // normal backspace.
        if (_currentWord.isNotEmpty) {
          _currentWord = _currentWord.substring(0, _currentWord.length - 1);
        } else {
          _shiftWordsForward();

          //restoring the lastIncorrectWord 
          if (_lastIncorrectWord.isNotEmpty) {
            if (_ignoreBackspace) {
              _ignoreBackspace = false;
            } else {
              debugPrint('Editing: "$_lastIncorrectWord"');
              status.value = 'Editing: "$_lastIncorrectWord"';

              _trackingUserEdit = true;
              _editOriginalTyped = _lastIncorrectWord;
              _editCorrectedTo = globalCorrectWord.value;
              FastKeyboard.backspacesAndType(
                globalCorrectWord.value.length,
                _lastIncorrectWord,
              );
              _ignoreSpaceCall = true;  //so it can't run errorCorrection after the edit 
              // Don't clear _lastIncorrectWord yet we need it for learning!
            }
          }

        }
        if (_currentWord.isNotEmpty) {
          _getSuggestions(_currentWord);
          _errorCorrection(_currentWord, true);
        } else {
          globalSuggestions.value = [];
          selectedTileIndex.value = 0;
          selectedTileWord.value = '';
        }
      }
      continue;
    }

    // --- Character keys ---
    //here each char are saved into currentWord  
    if (event.label.length == 1 && !isCtrl && !isAlt && !isWin) {
      _currentWord += event.label;
      _getSuggestions(_currentWord);
      _errorCorrection(_currentWord, true);
    }
    // print('"$_thirdLastWord" "$_secondLastWord" "$_lastWord" "$_currentWord"');
  }
}

Future<void> _getSuggestions(String inputAtCallTime) async {
  await Future.delayed(delayBeforeSearch);
  if (inputAtCallTime != _currentWord || _currentWord.isEmpty) {
    return;
  }

  if (_trieEngine != null) {
    final suggestions = _trieEngine!.suggest(inputAtCallTime.toLowerCase());

    if (suggestions.isNotEmpty) {
      final topSuggestions = suggestions
          .take(3)
          .map((s) => _applyCasing(s, inputAtCallTime))
          .toList();
      globalSuggestions.value = topSuggestions;

      selectedTileIndex.value = 0;
      final List<String> words = [
        if (globalCorrectWord.value.isNotEmpty) globalCorrectWord.value,
        ...globalSuggestions.value,
      ].take(4).toList();
      if (words.isNotEmpty) selectedTileWord.value = words[0];
    } else {
      // clear global list if no matches
      globalSuggestions.value = []; 
      selectedTileIndex.value = 0;
      //tile selections
      if (globalCorrectWord.value.isNotEmpty) {
         selectedTileWord.value = globalCorrectWord.value;
      } else {
         selectedTileWord.value = '';
      }
    }
  }
}

Future<void> _errorCorrection(String inputAtCallTime, bool pass) async {
  if (pass) {
    await Future.delayed(delayBeforeSearch);
    if (inputAtCallTime != _currentWord || _currentWord.isEmpty) {
      return;
    }
  }

  // tile insertion before any db thing 
  if (!pass && selectedTileWord.value.isNotEmpty) {
    
    if (selectedTileIndex.value != 0) {
      globalCorrectWord.value = selectedTileWord.value;
      _skipErrorCheck = true;
      _lastIncorrectWord = inputAtCallTime;
      _ignoreBackspace = true;
      _ignoreKeysForClearing = inputAtCallTime.length + globalCorrectWord.value.length + 2;
      debugPrint("Auto-Corrected $inputAtCallTime -> ${globalCorrectWord.value}");
      status.value = "Auto-Corrected $inputAtCallTime -> ${globalCorrectWord.value}";
      FastKeyboard.backspacesAndType(
        inputAtCallTime.length + 1, 
        globalCorrectWord.value + ' ',
      );

      // reset flags as we handled the correction manually
      _ignoreSpaceCall = false;
      return; 
    }
  }

  if (_ignoreSpaceCall) {
    _ignoreSpaceCall = false;
    return;
  }

  if (_skipErrorCheck) {
    _skipErrorCheck = false;
    return;
  }

  //initialization confirmation 
  await _initDatabase();
  await _initUserDatabase();
  if (_db == null || _userDb == null) return;

  // start cheking for User db
  final userCorrection = _userDb!.select(
    'SELECT correct FROM user_corrections WHERE misspelled = ?',
    [inputAtCallTime.toLowerCase()],
  );

  if (userCorrection.isNotEmpty) {
    final String found = userCorrection.first['correct'] as String;
    final String correctWord = _applyCasing(found, inputAtCallTime);
    globalCorrectWord.value = correctWord;

    // to reset selection when new word updates
    selectedTileIndex.value = 0;
    final List<String> words = [
        if (globalCorrectWord.value.isNotEmpty) globalCorrectWord.value,
        ...globalSuggestions.value,
      ].take(4).toList();
    if (words.isNotEmpty) selectedTileWord.value = words[0];

    // identity mapping skips keySym
    if (correctWord == inputAtCallTime.toLowerCase()) {
      if (!pass) {
        _lastIncorrectWord = inputAtCallTime;
      }
      return;
    }
    // Apply user's preferred correction
    if (!pass && correctWord != inputAtCallTime.toLowerCase()) {
      _skipErrorCheck = true;
      _lastIncorrectWord = inputAtCallTime;
      _ignoreBackspace = true;
      _ignoreKeysForClearing = inputAtCallTime.length + correctWord.length + 2;
      debugPrint("Auto-Corrected $inputAtCallTime -> ${correctWord}");
      status.value = "Auto-Corrected $inputAtCallTime -> ${correctWord}";
      FastKeyboard.backspacesAndType(
        inputAtCallTime.length + 1,
        correctWord + ' ',
      );
    }
    //return if we already found what we searched for 
    return; 
  }

  // start checking for main db
  final encoder = DoubleMetaphone();
  final phoneticResult = encoder.encode(inputAtCallTime.toLowerCase());
  final String soundCode = phoneticResult?.primary ?? "";

  final results = _db!.select(
    'SELECT Word FROM dictionary WHERE SoundexCode = ? AND FirstLetter = ? AND Length BETWEEN ? AND ?',
    [
      soundCode,
      inputAtCallTime[0].toLowerCase(),
      inputAtCallTime.length - 2,
      inputAtCallTime.length + 2,
    ],
  );

  final List<String> candidates = results
      .map((row) => row['Word'] as String)
      .toList();
  if (candidates.isNotEmpty) {
    final bestMatchResult = StringSimilarity.findBestMatch(
      inputAtCallTime,
      candidates,
    );
    final String correctWord = _applyCasing(bestMatchResult.bestMatch.target!, inputAtCallTime);

    if (!pass && correctWord.toLowerCase() != inputAtCallTime.toLowerCase()) {
      _skipErrorCheck = true;
      _lastIncorrectWord = inputAtCallTime;
      _ignoreBackspace = true;
      _ignoreKeysForClearing = inputAtCallTime.length + correctWord.length + 2;
      debugPrint("Auto-Corrected $inputAtCallTime -> ${correctWord}");
      status.value = "Auto-Corrected $inputAtCallTime -> ${correctWord}";
      FastKeyboard.backspacesAndType(
        inputAtCallTime.length + 1,
        correctWord + ' ',
      );
    } else {
      if (!pass) {
        _lastIncorrectWord = inputAtCallTime;
      }
    }

    // reset when correct word updates
    globalCorrectWord.value = correctWord;
    selectedTileIndex.value = 0;
    final List<String> words = [
        if (globalCorrectWord.value.isNotEmpty) globalCorrectWord.value,
        ...globalSuggestions.value,
      ].take(4).toList();
    if (words.isNotEmpty) selectedTileWord.value = words[0];
  } else {
    if(!pass) {
      _lastIncorrectWord = inputAtCallTime;
    }
    globalCorrectWord.value = inputAtCallTime;
    selectedTileIndex.value = 0;
    final List<String> words = [
        if (globalCorrectWord.value.isNotEmpty) globalCorrectWord.value,
        ...globalSuggestions.value,
      ].take(4).toList();
    if (words.isNotEmpty) selectedTileWord.value = words[0];
  }
}

// initializes the main dictionary
Future<void> _initDatabase() async {
  if (_db != null) return;
  try {
    if (Platform.isWindows) {
      try {
        DynamicLibrary.open('sqlite3.dll');
      } catch (e) {
        debugPrint("Sqlite3.dll already loaded.");
      }
    }
    final Directory appSupportDir = await getApplicationSupportDirectory();
    final dbPath = join(appSupportDir.path, 'dictionary.db');
    final dbFile = File(dbPath);

    // Copy from assets to AppData if not present
    if (!await dbFile.exists()) {
      try {
        ByteData data = await rootBundle.load('assets/dictionary.db');
        await dbFile.writeAsBytes(data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ));
      } catch (e) {
        debugPrint("CRITICAL: Could not find assets/dictionary.db. Check pubspec.yaml");
        return;
      }
    }

    _db = sqlite.sqlite3.open(dbPath);
    debugPrint("Main DB connected at: $dbPath");
  } catch (e) {
    debugPrint("Main DB Initialization Error: $e");
  }
}

/// 2. Initializes the User's Personal Corrections Database
Future<void> _initUserDatabase() async {
  if (_userDb != null) return;

  final Directory appSupportDir = await getApplicationSupportDirectory();
  final dbFile = File(join(appSupportDir.path, 'user_corrections.db'));

  if (!await appSupportDir.exists()) {
    await appSupportDir.create(recursive: true);
  }

  try {
    _userDb = sqlite.sqlite3.open(dbFile.path);

    _userDb!.execute('''
      CREATE TABLE IF NOT EXISTS user_corrections (
        misspelled TEXT PRIMARY KEY,
        correct TEXT NOT NULL,
        metaphone TEXT,
        first_letter TEXT,
        length INTEGER,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    debugPrint("User DB connected at: ${dbFile.path}");
  } catch (e) {
    debugPrint("User DB Initialization Error: $e");
  }
}

/// 3. Initializes the Predictive Trie Engine
Future<void> _initTrie() async {
  if (_trieEngine != null) return;

  try {
    final Directory appSupportDir = await getApplicationSupportDirectory();
    final String triePath = join(appSupportDir.path, 'dictionary_data.dat');
    myFile = File(triePath);

    if (!await myFile.exists()) {
      try {
        // Try to load the pre-trained dictionary from assets
        ByteData data = await rootBundle.load('assets/dictionary_data.dat');
        await myFile.writeAsBytes(data.buffer.asUint8List());
      } catch (e) {
        // If asset doesn't exist, create an empty file so AutoTrie doesn't crash
        debugPrint("No default Trie asset. Creating fresh file at $triePath");
        await myFile.writeAsBytes([]); 
      }
    }

    // Now initialize. AutoTrie needs the file to exist even if empty.
    _trieEngine = AutoComplete.fromFile(
        file: myFile,
        engine: SortEngine.configMulti(const Duration(seconds: 1), 15, 0.5, 0.5,),
      );
    debugPrint("Trie initialized successfully.");
  } catch (e) {
    debugPrint("Trie Initialization Error: $e");
  }
}

//learn to user db
Future<void> _learnFromUserEdit(
  String originalTyped,
  String correctedTo,
  String userFinalChoice,
) async {
  await _initUserDatabase();
  if (_userDb == null) return;

  // not empty checks
  if (originalTyped.isEmpty || userFinalChoice.isEmpty) {
    // print('Cannot learn: empty words');
    return;
  }

  // length barrier 
  if (originalTyped.length > 100 || userFinalChoice.length > 100) {
    // print('Word too long, skiped learning');
    return;
  }

  // print(
  //   ' Learning: "$originalTyped" was corrected to "$correctedTo", user chose "$userFinalChoice"',
  // );

  // calculating phonetic codes
  final encoder = DoubleMetaphone();
  final originalMetaphone =
      encoder.encode(originalTyped.toLowerCase())?.primary ?? "";

  // correction entry in user db (example: hilo→hello)
  try {
    _userDb!.execute(
      '''INSERT OR REPLACE INTO user_corrections 
         (misspelled, correct, metaphone, first_letter, length, updated_at) 
         VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)''',
      [
        originalTyped.toLowerCase(),
        userFinalChoice,
        originalMetaphone,
        originalTyped[0].toLowerCase(),
        originalTyped.length,
      ],
    );

    print('Saved: $originalTyped → $userFinalChoice');
    status.value = 'Saved: $originalTyped → $userFinalChoice';

    // identity entry in user db (example: hilo→hilo)
    final finalMetaphone =
        encoder.encode(userFinalChoice.toLowerCase())?.primary ?? "";
    _userDb!.execute(
      '''INSERT OR IGNORE INTO user_corrections 
         (misspelled, correct, metaphone, first_letter, length, created_at, updated_at) 
         VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)''',
      [
        userFinalChoice,
        userFinalChoice,
        finalMetaphone,
        userFinalChoice[0].toLowerCase(),
        userFinalChoice.length,
      ],
    );

    // remove wrong learnings from trie engine
    if (_trieEngine!.contains(originalTyped.toLowerCase())) {
      _trieEngine!.delete(originalTyped.toLowerCase());
      // print('Removed from Trie: $originalTyped');
    }

    // print('Added identity: $userFinalChoice → $userFinalChoice');
  } catch (e) {
    // print('Error saving to user DB: $e');
  }
}

// for UI search user db
Future<List<Map<String, Object?>>> searchUserCorrections({
  String? misspelled,
  String? correct,
  int limit = 10,
  int offset = 0,
}) async {
  await _initUserDatabase();
  if (_userDb == null) return [];

  try {
    String query = 'SELECT * FROM user_corrections';
    List<Object> args = [];
    List<String> whereClauses = [];

    if (misspelled != null && misspelled.isNotEmpty) {
      whereClauses.add('misspelled LIKE ?');
      args.add('%$misspelled%');
    }

    if (correct != null && correct.isNotEmpty) {
      whereClauses.add('correct LIKE ?');
      args.add('%$correct%');
    }

    if (whereClauses.isNotEmpty) {
      query += ' WHERE ${whereClauses.join(' AND ')}';
    }

    query += ' ORDER BY updated_at DESC LIMIT ? OFFSET ?';
    args.add(limit);
    args.add(offset);

    final results = _userDb!.select(query, args);
    // Convert ResultSet to List<Map> because ResultSet isn't directly mutable/passable easily sometimes
    return results.map((row) => Map<String, Object?>.from(row)).toList();
  } catch (e) {
    debugPrint("Search Error: $e");
    return [];
  }
}
// for UI search main DB
Future<List<Map<String, Object?>>> searchMainDictionary({
  String? query,
  int limit = 10,
  int offset = 0,
}) async {
  await _initDatabase();
  if (_db == null) return [];

  try {
    String sql = 'SELECT * FROM dictionary';
    List<Object> args = [];
    
    if (query != null && query.isNotEmpty) {
      sql += ' WHERE Word LIKE ?';
      args.add('%$query%');
    }

    sql += ' ORDER BY Word ASC LIMIT ? OFFSET ?';
    args.add(limit);
    args.add(offset);

    final results = _db!.select(sql, args);
    return results.map((row) => Map<String, Object?>.from(row)).toList();
  } catch (e) {
    debugPrint("Main DB Search Error: $e");
    return [];
  }
}

// for UI delete entry in user db
Future<void> deleteUserCorrection(String misspelled) async {
  await _initUserDatabase();
  if (_userDb == null) return;

  try {
    _userDb!.execute(
      'DELETE FROM user_corrections WHERE misspelled = ?',
      [misspelled],
    );
    status.value = "Deleted correction for '$misspelled'";
  } catch (e) {
    debugPrint("Delete Entry Error: $e");
  }
}

//for UI delete entry in main db
Future<void> deleteMainDictionaryWord(String word) async {
  await _initDatabase();
  if (_db == null) return;

  try {
    _db!.execute(
      'DELETE FROM dictionary WHERE Word = ?',
      [word],
    );
    status.value = "Deleted '$word' from dictionary";
  } catch (e) {
    debugPrint("Main DB Delete Error: $e");
  }
}


//for UI delete eenrace older than x days
Future<int> deleteUserCorrectionsOlderThan(int days) async {
  await _initUserDatabase();
  if (_userDb == null) return 0;

  try {
    // sqlite's 'now' is in UTC. Ensure comparisons align if updated_at is UTC (CURRENT_TIMESTAMP is UTC).
    final stmt = _userDb!.prepare(
      "DELETE FROM user_corrections WHERE updated_at < datetime('now', '-' || ? || ' days')",
    );
    stmt.execute([days.toString()]);
    final changes = _userDb!.updatedRows;
    stmt.dispose();
    
    status.value = "Deleted $changes entries older than $days days";
    return changes;
  } catch (e) {
    debugPrint("Delete Error: $e");
    return 0;
  }
}

// dispose user DB and delete and start initUserDatabase
Future<void> resetUserDatabase() async {
  if (_userDb != null) {
    _userDb!.dispose();
    _userDb = null;
  }
  
  final Directory ekaKeyPath = await getApplicationSupportDirectory();
  final dbFile = File(join(ekaKeyPath.path, 'user_corrections.db'));
  
  if (await dbFile.exists()) {
    try {
      await dbFile.delete();
    } catch (e) {
      debugPrint("Error deleting user DB file: $e");
    }
  }
  
  await _initUserDatabase();
  status.value = "Deleted User DB";
}

void stopEkaKeyProcessing() {
  _stopKeyboardHook();
}
// EntryPoint of Logic
void startEkaKeyProcessing(ValueNotifier<bool> isEkaKeyOnNotifier) {
  _setupKeyboardListener();
  _initDatabase();
  // _initUserDatabase();
  _processKeyEvents();
  // _initTrie();
  isEkaKeyOnNotifier.addListener(() {
    if (isEkaKeyOnNotifier.value) {
      _startKeyboardHook();
    } else {
      _stopKeyboardHook();
      _resetModifierKeys();
    }
  });
  // if app starting with a true value 
  if (isEkaKeyOnNotifier.value) {
    _startKeyboardHook();
  }
}

// keyboard Hook
void _setupKeyboardListener() {
  // print('Keyboard Hook loaded');
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'onKeyPressed') {
      final String type = call.arguments['type'];
      if (type == 'keyboard') {
        final VIRTUAL_KEY vkCode = call.arguments['vkCode'];
        final String eventType = call.arguments['eventType'];
        _updateModifierKeyStates(vkCode, eventType);

        // only process DOWN events for regular keys
        if (eventType == 'DOWN' && !_isModifierKey(vkCode)) {
          _handleKeyPress(vkCode);
        }
      } else if (type == 'mouse') {
        final String button =
            call.arguments['button']; 
        final String eventType = call.arguments['eventType']; 
        if (button == 'left' && eventType == 'DOWN') {        // left mouse DOWN to clear
          if (_trackingUserEdit) {
            _trackingUserEdit = false;
            _editOriginalTyped = '';
            _editCorrectedTo = '';
          }
          _clearAllWords();
        }
      }
    }
  });
}

// adds keypress to keyEventControler 
void _handleKeyPress(vkCode) {
  var displayLabel = _vkCodeToString(vkCode);
  _keyEventController.add(_KeyPayload(vkCode, displayLabel));
}

// tells C++ to start listening
void _startKeyboardHook() async {
  try {
    final result = await _channel.invokeMethod('startHook');
    if (result == true) {
    }
  } catch (e) {
    // print('error starting kb hook: $e');
  }
}

// tells C++ to stop listening
void _stopKeyboardHook() async {
  try {
    final result = await _channel.invokeMethod('stopHook');
    if (result == true) {
      // print('keyboard hook STOPPED - No kb listening');
    }
  } catch (e) {
    // print('error stopping keyboard hook: $e');
  }
}

// to store isdown statements 
void _updateModifierKeyStates(int vkCode, String eventType) {
  bool isDown = (eventType == 'DOWN');

  switch (vkCode) {
    case vkLshift:
      isLeftShift = isDown;
      break;
    case vkRshift:
      isRightShift = isDown;
      break;
    case vkLctrl:
      isLeftCtrl = isDown;
      break;
    case vkRctrl:
      isRightCtrl = isDown;
      break;
    case vkLalt:
      isLeftAlt = isDown;
      break;
    case vkRalt:
      isRightAlt = isDown;
      break;
    case vkLwin:
      isLeftWin = isDown;
      break;
    case vkRwin:
      isRightWin = isDown;
      break;
    case vkCapsLockL:
      if (isDown) {
        isCapsLockOn = !isCapsLockOn;
      }
      break;
  }
}

// check if vkCode is a modifier key
bool _isModifierKey(int vkCode) {
  //clear words if any modifier key
  if (vkCode == vkRalt || vkCode == vkLalt  || vkCode == vkRctrl || vkCode == vkLctrl || vkCode == 91 || vkCode == 92) {
    _clearAllWords();
  }
  return vkCode == vkLshift ||
      vkCode == vkRshift ||
      vkCode == vkLctrl ||
      vkCode == vkRctrl ||
      vkCode == vkLalt ||
      vkCode == vkRalt ||
      vkCode == vkCapsLockL;
}

// helper fxn to convert vkCodes to readable char
String _vkCodeToString(int vkCode) {
  // A-Z keys
  if (vkCode >= 65 && vkCode <= 90) {
    return (isCapsLockOn ^ isShift)
        ? String.fromCharCode(vkCode).toUpperCase()
        : String.fromCharCode(vkCode).toLowerCase();
  }

  // 0-9 keys
  if (vkCode >= 48 && vkCode <= 57) {
    return String.fromCharCode(vkCode);
  }

  // special keys
  switch (vkCode) {
    case 8:
      return 'BACKSPACE';
    case 9:
      return 'TAB';
    case 13:
      return 'ENTER';
    case 16:
      return 'SHIFT';
    case 17:
      return 'CTRL';
    case 18:
      return 'ALT';
    case 27:
      return 'ESC';
    case 32:
      return 'SPACE';
    case 33:
      return 'PAGE UP';
    case 34:
      return 'PAGE DOWN';
    case 35:
      return 'END';
    case 36:
      return 'HOME';
    case 37:
      return 'LEFT ARROW';
    case 38:
      return 'UP ARROW';
    case 39:
      return 'RIGHT ARROW';
    case 40:
      return 'DOWN ARROW';
    case 46:
      return 'DELETE';
    case 189: 
      return isShift ? '_' : '-';
    case 222:
      return isShift ? '"' : "'";
    default:
      return 'KEY_$vkCode';
  }
}

void _resetModifierKeys() {
  isLeftShift = false;
  isRightShift = false;
  isLeftCtrl = false;
  isRightCtrl = false;
  isLeftAlt = false;
  isRightAlt = false;
  isCapsLockOn = false;
}

// KeySym : vibe coded 
class FastKeyboard {
  static final _user32 = DynamicLibrary.open('user32.dll');

  static final _keybd_event = _user32
      .lookupFunction<
        Void Function(Uint8, Uint8, Uint32, IntPtr),
        void Function(int, int, int, int)
      >('keybd_event');

  // Key event flags
  static const int KEYEVENTF_KEYUP = 0x0002;

  // Virtual Key Codes (complete and accurate)
  static const Map<String, int> VK_CODES = {
    // Letters
    'a': 0x41, 'b': 0x42, 'c': 0x43, 'd': 0x44, 'e': 0x45,
    'f': 0x46, 'g': 0x47, 'h': 0x48, 'i': 0x49, 'j': 0x4A,
    'k': 0x4B, 'l': 0x4C, 'm': 0x4D, 'n': 0x4E, 'o': 0x4F,
    'p': 0x50, 'q': 0x51, 'r': 0x52, 's': 0x53, 't': 0x54,
    'u': 0x55, 'v': 0x56, 'w': 0x57, 'x': 0x58, 'y': 0x59,
    'z': 0x5A,

    // Numbers
    '0': 0x30, '1': 0x31, '2': 0x32, '3': 0x33, '4': 0x34,
    '5': 0x35, '6': 0x36, '7': 0x37, '8': 0x38, '9': 0x39,

    // Special keys
    'backspace': 0x08,
    'tab': 0x09,
    'enter': 0x0D,
    'shift': 0x10,
    'ctrl': 0x11,
    'alt': 0x12,
    'pause': 0x13,
    'capslock': 0x14,
    'escape': 0x1B,
    'space': 0x20,
    'pageup': 0x21,
    'pagedown': 0x22,
    'end': 0x23,
    'home': 0x24,
    'left': 0x25,
    'up': 0x26,
    'right': 0x27,
    'down': 0x28,
    'delete': 0x2E,

    "'": 0xDE,
    "-": 0xBD,
    "_": 0xBD,

    // Function keys
    'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73,
    'f5': 0x74, 'f6': 0x75, 'f7': 0x76, 'f8': 0x77,
    'f9': 0x78, 'f10': 0x79, 'f11': 0x7A, 'f12': 0x7B,
  };

  /// Press and release a key instantly
  static void click(String key) {
    // Check if the character is an uppercase letter
    bool isUppercase = key.length == 1 && 
                       key == key.toUpperCase() && 
                       key != key.toLowerCase();
    
    final vkCode = VK_CODES[key.toLowerCase()];
    if (vkCode == null) {
      throw ArgumentError('Unknown key: $key');
    }

    if (isUppercase) {
      _keybd_event(VK_CODES['shift']!, 0, 0, 0); // Shift Down
    }

    _keybd_event(vkCode, 0, 0, 0); // Key Down
    _keybd_event(vkCode, 0, KEYEVENTF_KEYUP, 0); // Key Up

    if (isUppercase) {
      _keybd_event(VK_CODES['shift']!, 0, KEYEVENTF_KEYUP, 0); // Shift Up
    }
  }

  /// Press a key (hold down)
  static void press(String key) {
    final vkCode = VK_CODES[key];
    if (vkCode == null) {
      throw ArgumentError('Unknown key: $key');
    }

    _keybd_event(vkCode, 0, 0, 0);
  }

  /// Type a string of text (letters, numbers, spaces only)
  static void type(String text) {
    for (var char in text.split('')) {
      if (char == ' ') {
        click('space');
      } else if (VK_CODES.containsKey(char.toLowerCase())) {
        click(char);
      }
    }
  }

  /// Your specific use case: backspace multiple times + type text
  static void backspacesAndType(int backspaceCount, String text) {
    // Trigger UI Glow
    isSimulatingTyping.value = true;

    // Delete characters
    for (int i = 0; i < backspaceCount; i++) {
      click('backspace');
    }

    // Type the text
    type(text);

    // Reset UI Glow after a short delay
    Future.delayed(const Duration(milliseconds: 300), () {
      isSimulatingTyping.value = false;
    });
  }
}

void cycleTileSelection() {
  final List<String> words = [
    if (globalCorrectWord.value.isNotEmpty) globalCorrectWord.value,
    ...globalSuggestions.value,
  ].take(4).toList();

  if (words.isNotEmpty) {
    int newIndex = (selectedTileIndex.value + 1) % words.length;
    selectedTileIndex.value = newIndex;
    selectedTileWord.value = words[newIndex];
    // print("selected: ${selectedTileWord.value}");
  }
}

void disposeDatabases() {
  _db?.dispose();
  _userDb?.dispose();
  _db = null;
  _userDb = null;
  debugPrint("Databases closed safely.");
}


//----------------------FOR CONTRIBUTORS-----------------------------------------------
//bug#### --------- should have exited editing if ur pressed backspace more than boundary of that word
//bug#### --------- write 'abc xyzFm' and then do backspaces