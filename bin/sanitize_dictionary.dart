import 'dart:io';

void main() async {
  // 1. Ask for the source file location
  stdout.write('Enter the path to your source dictionary file (e.g., source.txt): ');
  final String? inputPath = stdin.readLineSync();

  if (inputPath == null || inputPath.isEmpty) {
    print('Error: No path provided.');
    return;
  }

  final inputFile = File(inputPath);
  final outputFile = File('rawDictionary.txt');

  if (!await inputFile.exists()) {
    print('Error: Source file "$inputPath" does not exist.');
    return;
  }

  print('Sanitizing... Please wait.');

  // 2. Define the Regex for standard English characters only
  // This matches lines that ONLY contain a-z or A-Z (no spaces, no numbers, no accents)
  final RegExp englishOnly = RegExp(r'^[a-zA-Z]+$');

  try {
    final List<String> lines = await inputFile.readAsLines();
    final List<String> sanitizedLines = [];
    int removedCount = 0;

    for (var line in lines) {
      final trimmed = line.trim();
      
      if (englishOnly.hasMatch(trimmed)) {
        sanitizedLines.add(trimmed.toLowerCase());
      } else {
        removedCount++;
      }
    }

    // 3. Write the cleaned content to rawDictionary.txt
    await outputFile.writeAsString(sanitizedLines.join('\n'));

    print('-----------------------------------------');
    print('Sanitization Complete!');
    print('Words saved: ${sanitizedLines.length}');
    print('Lines removed (special chars/numbers): $removedCount');
    print('Output file: ${outputFile.path}');
    print('-----------------------------------------');
    
  } catch (e) {
    print('An error occurred while reading/writing: $e');
  }
}