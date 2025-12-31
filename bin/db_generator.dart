import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:dart_phonetics/dart_phonetics.dart';

void main() async {
  final inputFile = File('rawDictionary.txt');
  final dbFile = 'dictionary.db';

  if (!await inputFile.exists()) {
    print("Error: rawDictionary.txt not found!");
    return;
  }

  // Delete existing DB if it exists to start fresh
  if (File(dbFile).existsSync()) {
    File(dbFile).deleteSync();
  }

  final db = sqlite3.open(dbFile);
  final encoder = DoubleMetaphone();

  try {
    // 1. Create the table matching your specific structure
    db.execute('''
      CREATE TABLE dictionary (
        Word TEXT,
        FirstLetter TEXT,
        Length INTEGER,
        SoundexCode TEXT
      )
    ''');

    // 2. Prepare the insert statement
    final stmt = db.prepare(
      'INSERT OR IGNORE INTO dictionary (Word, FirstLetter, Length, SoundexCode) VALUES (?, ?, ?, ?)'
    );

    print("Processing words...");
    final lines = await inputFile.readAsLines();
    int count = 0;

    db.execute('BEGIN TRANSACTION'); // Use transaction for high-speed insertion

    for (var rawWord in lines) {
      final word = rawWord.trim().toLowerCase();
      if (word.isEmpty) continue;

      // Generate the Primary Metaphone code
      final phoneticResult = encoder.encode(word);
      final String soundCode = phoneticResult?.primary ?? "";

      stmt.execute([
        word,
        word[0],
        word.length,
        soundCode,
      ]);

      count++;
    }

    db.execute('COMMIT');
    stmt.dispose();

    // 3. Create an index for the error correction query in your ekakey_process.dart
    db.execute('CREATE INDEX idx_lookup ON dictionary (SoundexCode, FirstLetter, Length)');

    print("Success! Created $dbFile with $count words.");
  } catch (e) {
    print("An error occurred: $e");
    db.execute('ROLLBACK');
  } finally {
    db.dispose();
  }
}