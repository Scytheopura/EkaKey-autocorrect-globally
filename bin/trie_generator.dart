import 'dart:io';
import 'package:autotrie/autotrie.dart';

void main() async {
  final inputFile = File('rawDictionary.txt');
  final outputFile = File('dictionary_data.dat');

  if (!await inputFile.exists()) {
    print("Error: rawDictionary.txt not found!");
    return;
  }

  print("Initializing AutoTrie Engine...");
  
  // Matching the configuration from your ekakey_process.dart:
  // SortEngine.configMulti(Duration(seconds: 1), 15, 0.5, 0.5)
  final engine = AutoComplete(
    engine: SortEngine.configMulti(
      const Duration(seconds: 1), 
      15, 
      0.5, 
      0.5,
    ),
  );

  print("Reading words and training engine...");
  final lines = await inputFile.readAsLines();
  int count = 0;

  for (var rawWord in lines) {
    final word = rawWord.trim().toLowerCase();
    if (word.isEmpty) continue;

    // Use .enter() to add the word to the Trie
    engine.enter(word);
    
    count++;
    if (count % 5000 == 0) {
      print("Processed $count words...");
    }
  }

  print("Persisting data to ${outputFile.path}...");
  
  // Using the native .persist() method from AutoTrie documentation
  await engine.persist(outputFile);

  print("Success! Created dictionary_data.dat with $count entries.");
  print("You can now move this file to your Flutter assets folder.");
}